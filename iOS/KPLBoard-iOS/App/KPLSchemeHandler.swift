import Foundation
import WebKit
import os

/// 自定义 scheme 处理器：把本地前端资源与 Swift 数据层拼成一个「同源站点」。
///
/// 为什么用自定义 scheme 而不是 file://：
///   - 前端用 fetch('/api/board') 取数，file:// 下相对路径会变成 file 请求，无法拦截且会撞同源限制；
///   - 用自定义 scheme（kplboard://app/）后，fetch 与页面同源，请求都会走到这里，由 Swift 直接返回数据。
/// 这也是 Capacitor / Cordova 的通用做法。
final class KPLSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "kplboard"
    static let host = "app"

    /// 本地前端根目录（Xcode 中以 folder reference 引入的 web/）
    private var webRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true)
    }

    private func mime(of path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        default: return "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFinish()
            return
        }
        let path = url.path
        // task 存活标识：直接用 ObjectIdentifier，不经过实例方法——
        // WKURLSchemeHandler 协议是 @MainActor 隔离的，而 start/stop 之外的
        // 辅助方法若被推断为 nonisolated，会触发
        // "Call to main actor-isolated instance method in a synchronous nonisolated context"。
        let key = ObjectIdentifier(urlSchemeTask)

        // 静态资源
        if !path.hasPrefix("/api/") {
            let rel = String(path.dropFirst())                 // 去掉首个 "/"
            let file = webRoot?.appendingPathComponent(rel)
            if let file, let data = try? Data(contentsOf: file) {
                respond(urlSchemeTask, url: url, data: data, mime: mime(of: path))
            } else if let index = webRoot?.appendingPathComponent("index.html"),
                      let data = try? Data(contentsOf: index) {
                // 未知路径回落到首页（前端是单页应用）
                respond(urlSchemeTask, url: url, data: data, mime: mime(of: "index.html"))
            } else {
                urlSchemeTask.didFinish()
            }
            return
        }

        // 图片代理单独走一条路：它返回的是二进制图片而不是 JSON，
        // 且要带 X-Img-Cache / X-Img-Fallback 等自定义头，不能在 handleAPI 里统一处理。
        // isAlive 用**同步**闭包：ImgProxy.serve 把「检查存活 + task 回调」放进
        // 同一次 MainActor.run 里原子执行（此前 async 检查会把两者拆到两次线程
        // 投递，stop 可恰好插进中间，导致 "This task has already been stopped" 崩溃）。
        if path == "/api/tools/img" {
            Task { [weak self] in
                await ImgProxy.serve(urlSchemeTask, url: url, query: url.query) { [weak self] in
                    self?.isTaskAliveSync(key) ?? false
                }
            }
            return
        }

        // API：异步组装后返回
        // X-KPL-Force：前端 KPLStore 的强制刷新（手动点刷新 / 立即同步）带此头，
        // 数据层据此绕过各自的 TTL 直接重打上游——比赛刚打完时用户点刷新
        // 必须立刻看到最终比分，而不是 20s 轮询周期内的旧数据。
        let force = urlSchemeTask.request.value(forHTTPHeaderField: "X-KPL-Force") == "1"
        Task { [weak self] in
            let data = await Self.handleAPI(path: path, query: url.query ?? "", force: force)
            guard await self?.isTaskAlive(key) ?? false else { return }
            self?.respond(urlSchemeTask, url: url, data: data, mime: "application/json; charset=utf-8")
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 记录已停止的 task：页面切换 / 重载 / 取消时 WebKit 会调这里，
        // 此后任何 didReceive / didFinish 都会抛 NSInternalInconsistencyException
        // （"This task has already been stopped"）崩溃。start 里的异步回调在
        // await 之后必须先用 isTaskAlive 确认，否则慢请求返回时必崩。
        //
        // 必须同步写入：若这里用 Task 异步插入，插入可能晚于回调里的
        // isAlive 检查，崩溃照样发生。
        _ = stoppedTasks.withLock { $0.insert(ObjectIdentifier(urlSchemeTask)) }
    }

    // MARK: - task 存活追踪

    /// 已停止 task 的标识集合，用 OSAllocatedUnfairLock 保护。
    /// 不能用 NSLock：它的 lock()/unlock() 在 Swift 6 并发检查下禁止从
    /// async 上下文调用（"Instance method 'lock' is unavailable from
    /// asynchronous contexts"）；OSAllocatedUnfairLock 的 withLock 是
    /// 官方提供的 async-safe 作用域锁，同步（stop）与异步（isTaskAlive）
    /// 两侧都能安全调用。
    /// 锁只在插入/查询的极短临界区内持有，不会阻塞网络等待。
    private let stoppedTasks = OSAllocatedUnfairLock<Set<ObjectIdentifier>>(initialState: [])

    /// 异步路径使用（API 响应回调，其 Task 继承 start 的 @MainActor 隔离，
    /// 与 stop 同线程，检查与响应之间无挂起点，天然无竞态）。
    private func isTaskAlive(_ key: ObjectIdentifier) async -> Bool {
        stoppedTasks.withLock { !$0.contains(key) }
    }

    /// **同步**读取：供 ImgProxy 的闭包在 MainActor.run 里直接调用——
    /// 检查与 task 回调必须在同一次主线程投递里完成（见 start 里的注释）。
    /// OSAllocatedUnfairLock 的 withLock 是同步安全的，只是不能跨 await 持有。
    private func isTaskAliveSync(_ key: ObjectIdentifier) -> Bool {
        stoppedTasks.withLock { !$0.contains(key) }
    }

    /// 重置存活记录（页面重新加载时调用）。
    /// 因为旧 task 对象已随上次加载释放，其 ObjectIdentifier 不可能再出现，
    /// 留着只会让 stopped 集合无意义地增长——每次加载清空一次即可。
    /// 注意：只应在「所有旧 task 都已被 stop」之后（如新页面 didFinish）调用，
    /// 否则会误清掉仍在进行中的记录。
    func resetStopped() {
        stoppedTasks.withLock { $0.removeAll(keepingCapacity: true) }
    }

    /// 处理器销毁时清空记录，打破对已停止 task 的无意义强引用
    ///（ObjectIdentifier 只是地址值，Set 本身不持对象，但集合随处理器释放一并清掉更干净）。
    deinit {
        stoppedTasks.withLock { $0.removeAll(keepingCapacity: true) }
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
        // 乱码根因修复：WebKit 不认 mimeType 里内嵌的 "; charset=..."（会当成
        // 未知类型按 text/plain 显示源码），且 URLResponse 的 textEncodingName 为 nil 时
        // 中文不按 UTF-8 解码。改用 HTTPURLResponse + 标准 Content-Type 头（charset 放头里）。
        let resp = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Cache-Control": "no-cache"]
        ) ?? URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8")
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    // MARK: - API 路由

    static func handleAPI(path: String, query: String, force: Bool = false) async -> Data {
        var params: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                params[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
        // 双通道识别强制刷新：X-KPL-Force 头（start 里传入）或 URL 上的 _f=1
        //（自定义 scheme 不保证保留 fetch 的自定义头，_f 是可靠通道；
        //  KPLStore 的缓存键会剔除 _f，不影响命中）
        let forced = force || params["_f"] == "1"

        let payload: [String: Any]
        do {
            switch path {
            case "/api/board":
                payload = await BoardStore.shared.board(eventId: params["event"], stage: params["stage"],
                                                        force: forced)
            case "/api/events":
                payload = await BoardStore.shared.eventsPayload()
            case "/api/health":
                payload = await BoardStore.shared.healthPayload()
            case "/api/refresh":
                if let id = params["event"], let ev = await BoardStore.shared.event(by: id) {
                    // archive 赛事是按阶段串行抓取的 HTML 解析（最坏几分钟），
                    // 同步等待会把 scheme task 占死、页面刷新按钮长时间无响应；
                    // 已结束赛事数据本身不变，后台刷新即可，立即返回最新 updatedAt。
                    if ev.mode == "archive" {
                        await BoardStore.shared.refresh(ev, wait: false)
                        let rec = await BoardStore.shared.cachedRecord(of: ev.id)
                        payload = ["ok": true, "updatedAt": Int((rec?.updatedAt ?? 0) * 1000),
                                   "refreshing": true]
                    } else {
                        await BoardStore.shared.refresh(ev, wait: true)
                        let rec = await BoardStore.shared.cachedRecord(of: ev.id)
                        payload = ["ok": true, "updatedAt": Int((rec?.updatedAt ?? 0) * 1000)]
                    }
                } else {
                    await BoardStore.shared.refreshAll()
                    payload = ["ok": true, "updatedAt": Int(Date().timeIntervalSince1970 * 1000)]
                }

            /* ---------- 工具箱：官方英雄 / 装备 / 铭文 / 皮肤库 + 玩加职业赛场统计 ---------- */
            case "/api/tools/heroes":
                payload = ["ok": true, "heroes": try await ToolsStore.shared.heroesSafe()]
            case "/api/tools/items":
                payload = ["ok": true, "items": try await ToolsStore.shared.itemsSafe()]
            case "/api/tools/runes":
                payload = Self.spread(try await ToolsStore.shared.runesSafe())
            case "/api/tools/skins":
                payload = Self.spread(try await ToolsStore.shared.skinsSafe())
            case "/api/tools/coverage":
                payload = Self.spread(await ToolsStore.shared.coverage())
            case "/api/tools/gradient":
                payload = try await Self.gradientPayload(params["event"])
            case "/api/tools/players":
                payload = try await Self.playersPayload(params["event"])
            case "/api/tools/teams":
                payload = try await Self.teamsPayload(params["event"])
            case "/api/tools/hero":
                guard let id = params["id"], !id.isEmpty else {
                    payload = ["ok": false, "error": "缺少英雄 id"]
                    break
                }
                payload = ["ok": true, "hero": try await ToolsStore.shared.heroDetailSafe(id)]

            /* ---------- 版本动态：王者荣耀官网更新公告 ---------- */
            case "/api/patch":
                payload = await Self.patchPayload(params)

            default:
                payload = ["ok": false, "error": "未知接口（\(path)）"]
            }
        } catch {
            // 上游不可用且无缓存可回落时，返回明确错误而不是让前端拿到空数据后卡住
            payload = ["ok": false, "error": error.localizedDescription]
        }
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    }

    // MARK: - 工具箱路由

    /// 对齐桌面版的 `{ ok: true, ...(await tools.xxx()) }`：把对象字段平铺到顶层
    private static func spread(_ extra: Any) -> [String: Any] {
        var out: [String: Any] = ["ok": true]
        if let d = extra as? [String: Any] { for (k, v) in d { out[k] = v } }
        else { out["data"] = extra }
        return out
    }

    /// 把「实际下发的条数」写回赛季元信息。
    /// coverage 里的 players / teams 是离线探测得到的上游行数（同一选手按阶段会重复多行），
    /// 与去重后的名单长度不同；前端「基础资料」直接读 event.players，
    /// 所以这里统一按下发实体覆盖，保证同一屏只出现一个数字。
    private static func actualCounts(_ meta: [String: Any], _ over: [String: Int]) -> [String: Any] {
        var out = meta
        for (k, v) in over where v > 0 { out[k] = v }
        return out
    }

    private static func eventId(_ requested: String?) async -> String {
        if let r = requested, !r.isEmpty { return r }
        return await ToolsStore.shared.defaultEventId()
    }

    private static func gradientPayload(_ requested: String?) async throws -> [String: Any] {
        let eid = await eventId(requested)
        let data = try await ToolsStore.shared.gradient(eid)
        var out: [String: Any] = ["ok": true]
        out["event"] = actualCounts(await ToolsStore.shared.eventMeta(eid), [
            "players": data["totalPlayers"] as? Int ?? 0,
            "teams": data["totalTeams"] as? Int ?? 0,
        ])
        for (k, v) in data { out[k] = v }
        return out
    }

    private static func playersPayload(_ requested: String?) async throws -> [String: Any] {
        let eid = await eventId(requested)
        let list = try await ToolsStore.shared.players(eid)
        return [
            "ok": true,
            "eventId": eid,
            "event": actualCounts(await ToolsStore.shared.eventMeta(eid), ["players": list.count]),
            "count": list.count,
            "players": list,
        ]
    }

    private static func teamsPayload(_ requested: String?) async throws -> [String: Any] {
        let eid = await eventId(requested)
        let list = try await ToolsStore.shared.teams(eid)
        return [
            "ok": true,
            "eventId": eid,
            "event": actualCounts(await ToolsStore.shared.eventMeta(eid), ["teams": list.count]),
            "count": list.count,
            "teams": list,
        ]
    }

    // MARK: - 版本动态路由

    private static func patchPayload(_ params: [String: String]) async -> [String: Any] {
        let what = params["what"] ?? "feed"
        // 前端「立即同步 / 页头刷新」会带 &_f=1（KPLStore 的缓存键会剔除它），
        // 表示强制绕过内嵌缓存直打上游——否则 TTL 内 feed 返回与上次完全相同的
        // JSON，前端 revalidate 判定无变化，公告与调整条目永远不更新。
        let force = params["_f"] == "1" || params["force"] == "1"
        do {
            switch what {
            case "news":
                return Self.spread(try await PatchStore.shared.newsList(
                    page: Int(params["page"] ?? "") ?? 1,
                    pageSize: Int(params["pageSize"] ?? "") ?? 20,
                    force: force))
            case "detail":
                guard let id = params["id"], !id.isEmpty else {
                    return ["ok": false, "error": "缺少公告 id"]
                }
                return Self.spread(try await PatchStore.shared.newsDetail(id, force: force))
            case "changes":
                return Self.spread(try await PatchStore.shared.changesByName(force: force))
            case "refresh":
                guard params["force"] == "1" else {
                    return ["ok": false, "error": "需带 force=1"]
                }
                return try await PatchStore.shared.refresh()
            default:
                return Self.spread(try await PatchStore.shared.feed(
                    limit: Int(params["limit"] ?? "") ?? 8,
                    scan: Int(params["scan"] ?? ""),
                    force: force))
            }
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }
}

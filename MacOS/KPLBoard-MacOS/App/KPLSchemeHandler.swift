import Foundation
import WebKit

/// 自定义 scheme 处理器：把本地前端资源与 Swift 数据层拼成一个「同源站点」。
///
/// 为什么用自定义 scheme 而不是 file://：
///   - 前端用 fetch('/api/board') 取数，file:// 下相对路径会变成 file 请求，无法拦截且会撞同源限制；
///   - 用自定义 scheme（kplboard://app/）后，fetch 与页面同源，请求都会走到这里，由 Swift 直接返回数据。
/// 这也是 Capacitor / Cordova 的通用做法。
final class KPLSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "kplboard"
    static let host = "app"

    /// 已发起、尚未结束的任务。页面切换/请求取消时 WebKit 会先调 `stop`，
    /// 之后任何 `didReceive` / `didFinish` 都会抛 NSInternalInconsistencyException
    /// （"This task has already been stopped"）导致整个 App 崩溃。
    /// API 与图片代理都是异步返回的，所以完成前必须查这张表确认任务还活着。
    private let tracker = TaskTracker()

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
        tracker.begin(urlSchemeTask)

        // 静态资源
        if !path.hasPrefix("/api/") {
            let rel = String(path.dropFirst())                 // 去掉首个 "/"
            // 路径穿越防护：`../`、百分号编码的 `%2e%2e`、URL 双斜杠等都可能逃出 web/ 目录。
            // WebKit 传来的 URL.path 已做一轮百分号解码，因此必须在标准化的绝对路径上做前缀校验，
            // 而不是校验原始字符串。逃出根目录的请求一律回落到 index.html（SPA 行为）。
            let file = webRoot?.appendingPathComponent(rel).standardizedFileURL
            let rootPath = webRoot?.standardizedFileURL.path ?? ""
            let insideRoot = file.map { $0.path == rootPath || $0.path.hasPrefix(rootPath + "/") } ?? false
            if let file, insideRoot, let data = try? Data(contentsOf: file) {
                respond(urlSchemeTask, url: url, data: data, mime: mime(of: path))
            } else if let index = webRoot?.appendingPathComponent("index.html"),
                      let data = try? Data(contentsOf: index) {
                // 未知路径 / 非法路径回落到首页（前端是单页应用）
                respond(urlSchemeTask, url: url, data: data, mime: mime(of: "index.html"))
            } else {
                urlSchemeTask.didFinish()
            }
            return
        }

        // 图片代理单独走一条路：它返回的是二进制图片而不是 JSON，
        // 且要带 X-Img-Cache / X-Img-Fallback 等自定义头，不能在 handleAPI 里统一处理。
        if path == "/api/tools/img" {
            Task { [weak self] in
                guard let self else { return }
                await ImgProxy.serve(urlSchemeTask, url: url, query: url.query) { [weak self] in
                    self?.tracker.isAlive(urlSchemeTask) ?? false
                }
                // serve() 无论走 200 / 404 / 403 哪条路都会调用 finish → isAlive 检查后回包。
                // 这里统一摘除登记，否则 TaskTracker.alive 集合只增不减（每张图泄漏一条）。
                self.tracker.end(urlSchemeTask)
            }
            return
        }

        // API：异步组装后返回
        Task { [weak self] in
            let data = await Self.handleAPI(path: path, query: url.query ?? "")
            self?.respondGuarded(urlSchemeTask, url: url, data: data, mime: "application/json; charset=utf-8")
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 页面切换/取消时回调：登记为已停止，异步回调前会据此跳过，避免崩溃。
        tracker.stop(urlSchemeTask)
    }

    /// 静态资源响应（同步，发生在 start 内，stop 尚不可能触发）。
    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
        // 静态资源在 start 内同步回包，stop 不可能先于它触发；仍走 tracker 收尾，保持统一。
        guard tracker.isAlive(task) else { return }
        respondData(task, url: url, data: data, mime: mime)
        tracker.end(task)
    }

    /// 异步路径（API / 图片代理）回包前检查任务是否还活着。
    private func respondGuarded(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
        guard tracker.isAlive(task) else { return }
        respondData(task, url: url, data: data, mime: mime)
        tracker.end(task)
    }

    private func respondData(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
        // 乱码根因修复：macOS 的 WebKit 不认 mimeType 里内嵌的 "; charset=..."（会当成
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

    static func handleAPI(path: String, query: String) async -> Data {
        var params: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                params[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }

        let payload: [String: Any]
        do {
            switch path {
            case "/api/board":
                payload = await BoardStore.shared.board(eventId: params["event"], stage: params["stage"])
            case "/api/events":
                payload = await BoardStore.shared.eventsPayload()
            case "/api/health":
                payload = await BoardStore.shared.healthPayload()
            case "/api/refresh":
                if let id = params["event"], let ev = await BoardStore.shared.event(by: id) {
                    await BoardStore.shared.refresh(ev, wait: true)
                } else {
                    await BoardStore.shared.refreshAll()
                }
                payload = ["ok": true, "updatedAt": Int(Date().timeIntervalSince1970 * 1000)]

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
        do {
            switch what {
            case "news":
                return Self.spread(try await PatchStore.shared.newsList(
                    page: Int(params["page"] ?? "") ?? 1,
                    pageSize: Int(params["pageSize"] ?? "") ?? 20))
            case "detail":
                guard let id = params["id"], !id.isEmpty else {
                    return ["ok": false, "error": "缺少公告 id"]
                }
                return Self.spread(try await PatchStore.shared.newsDetail(id))
            case "changes":
                return Self.spread(try await PatchStore.shared.changesByName())
            case "refresh":
                guard params["force"] == "1" else {
                    return ["ok": false, "error": "需带 force=1"]
                }
                return try await PatchStore.shared.refresh()
            default:
                return Self.spread(try await PatchStore.shared.feed(
                    limit: Int(params["limit"] ?? "") ?? 8,
                    scan: Int(params["scan"] ?? "")))
            }
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }
}

/// 跟踪仍「活着」的 WKURLSchemeTask。begin → 异步回调前 isAlive 必须为真 → end/stop 收尾。
/// 用身份比较（===）而非 ObjectIdentifier，避免对 ObjC 协议 existential 桥接产生新对象导致 identity 漂移。
private final class TaskTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var alive: Set<ObjectIdentifier> = []

    func begin(_ task: WKURLSchemeTask) {
        lock.lock(); defer { lock.unlock() }
        alive.insert(ObjectIdentifier(task as AnyObject))
    }

    /// 是否仍存活：返回 false 表示已被 stop（或从未 begin），此时不得再回调。
    func isAlive(_ task: WKURLSchemeTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return alive.contains(ObjectIdentifier(task as AnyObject))
    }

    /// 正常回包完成后摘除（异步路径与静态路径共用）。
    func end(_ task: WKURLSchemeTask) {
        lock.lock(); defer { lock.unlock() }
        alive.remove(ObjectIdentifier(task as AnyObject))
    }

    /// 页面切走/请求取消：登记为已停止，异步回调前的 isAlive 检查据此跳过，防崩溃。
    func stop(_ task: WKURLSchemeTask) {
        lock.lock(); defer { lock.unlock() }
        alive.remove(ObjectIdentifier(task as AnyObject))
    }
}

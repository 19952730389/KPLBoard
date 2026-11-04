import Foundation
import WebKit

/// 图片代理（对齐桌面版 server.js 的 /api/tools/img）：
/// 白名单域名 + 按域名带 Referer（部分 CDN 有防盗链）+ 内存缓存 + 备用地址链 + 404 占位。
///
/// 前端 img.js 把白名单域名的图片统一改写成 `/api/tools/img?u=<encodeURIComponent(原图)>`，
/// 由这里代理取回，避免直连被防盗链拦下；上游 4xx/5xx 或返回 HTML（部分 CDN 用 200 包错误页）
/// 一律视为不可用，返回 404 + `X-Img-Fallback: 1`，交给前端渲染占位图（不缓存，便于上游恢复即生效）。
enum ImgProxy {

    /// 白名单：只代理这几个官方 CDN，并按域名带对应的 Referer
    private static let hosts: [(host: String, referer: String)] = [
        ("game.gtimg.cn", "https://pvp.qq.com/"),
        ("pvp.qq.com", "https://pvp.qq.com/"),
        ("game-1255653016.file.myqcloud.com", "https://pvp.qq.com/"),
        ("static.wanplus.cn", "https://wanplus.cn/"),
    ]

    /// 装备图标备用路径：老库 itemimg 缺图 → 新库 itemimgo
    private static let itemImgRe = try! NSRegularExpression(
        pattern: #"^https://game\.gtimg\.cn/images/yxzj/img201606/itemimg/(\d+)\.(?:jpg|png)$"#)

    private static func altURL(for target: String) -> String? {
        guard let m = itemImgRe.firstMatch(in: target, range: NSRange(target.startIndex..., in: target)),
              let r = Range(m.range(at: 1), in: target) else { return nil }
        return "https://game.gtimg.cn/images/yxzj/img201606/itemimgo/\(target[r]).png"
    }

    private static let cacheMax = 600          // 内存缓存条数
    private static let cacheTTL: TimeInterval = 6 * 3600
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private struct Entry {
        let data: Data
        let type: String
        let at: Date
        var fresh: Bool { Date().timeIntervalSince(at) < cacheTTL }
    }

    /// 内存缓存放在 actor 里。
    /// 原先的 NSLock 在 async 上下文中不可用（Swift 6 语言模式会直接编译报错），
    /// 且阻塞式加锁在并发取图时会拖慢整个代理。
    private actor ImageCache {
        private var items: [(String, Entry)] = []
        func hit(_ key: String) -> (Data, String)? {
            guard let e = items.first(where: { $0.0 == key && $0.1.fresh }) else { return nil }
            return (e.1.data, e.1.type)
        }
        func put(_ key: String, _ data: Data, _ type: String) {
            if items.count >= cacheMax { items.removeFirst() }   // FIFO 淘汰，与 server.js 的 Map 策略一致
            items.append((key, Entry(data: data, type: type, at: Date())))
        }
    }
    private static let cache = ImageCache()

    /// 按域名挑 Referer；不在白名单返回 nil
    static func referer(of target: String) -> String? {
        guard let host = URL(string: target)?.host else { return nil }
        return hosts.first { $0.host == host }?.referer
    }

    /// 拉取一张远程图（带内存缓存 + 备用地址链，最多一层避免死循环）
    private static func fetchImage(_ target: String, depth: Int = 0) async -> (data: Data, type: String)? {
        guard let referer = referer(of: target) else { return nil }

        if let hit = await cache.hit(target) { return hit }

        guard let url = URL(string: target) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let type = ((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "")
                .split(separator: ";").first.map(String.init) ?? ""
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               type.hasPrefix("image/"), !data.isEmpty {
                await cache.put(target, data, type)
                return (data, type)
            }
        } catch { /* 网络异常：继续走备用地址 */ }

        // 备用地址链（最多一层）
        if depth < 1, let alt = altURL(for: target), alt != target,
           let got = await fetchImage(alt, depth: depth + 1) {
            return got
        }
        return nil
    }

    /// 处理 /api/tools/img?u=<url>；不在路由里的情况不会进来
    static func serve(_ task: WKURLSchemeTask, url: URL, query: String?, isAlive: () -> Bool) async {
        // 逐个取健值，不用 Dictionary(uniqueKeysWithValues:)——后者遇到重复参数
        // （?u=a&u=b）会直接 fatalError 拖垮整个 App。
        var target = ""
        for pair in (query ?? "").split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, String(kv[0]) == "u" else { continue }
            target = String(kv[1]).removingPercentEncoding ?? String(kv[1])
        }

        func finish(_ status: Int, type: String?, data: Data?, extra: [String: String] = [:]) {
            // 任务可能已被 WebKit stop（页面切走），再回调 didReceive/didFinish 会抛
            // NSInternalInconsistencyException 直接崩溃。
            guard isAlive() else { return }
            var headers = ["Cache-Control": status == 200 ? "public, max-age=604800, immutable" : "no-store"]
            if let type { headers["Content-Type"] = type }
            for (k, v) in extra { headers[k] = v }
            let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
                ?? URLResponse(url: url, mimeType: type, expectedContentLength: data?.count ?? 0, textEncodingName: nil)
            task.didReceive(resp)
            if let data { task.didReceive(data) }
            task.didFinish()
        }

        guard referer(of: target) != nil else {
            return finish(403, type: "application/json; charset=utf-8",
                          data: #"{"ok":false,"error":"仅允许官方资源域名"}"#.data(using: .utf8))
        }
        guard let got = await fetchImage(target) else {
            // 上游无图：交给前端渲染占位图（不缓存，便于上游恢复后立即生效）
            return finish(404, type: nil, data: nil, extra: ["X-Img-Fallback": "1"])
        }
        finish(200, type: got.type, data: got.data)
    }
}

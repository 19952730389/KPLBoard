import Foundation

/// 统一的网络层。所有上游请求都走这里，便于统一 UA / 超时 / 错误处理。
enum Net {
    // macOS 版改发 Mac Safari UA（iPad 版为 iPad UA）；上游据此返回桌面版页面结构
    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    enum NetError: Error, LocalizedError {
        case badStatus(Int)
        case notJSON
        case upstream(String)

        var errorDescription: String? {
            switch self {
            case .badStatus(let c): return "上游返回 \(c)"
            case .notJSON: return "响应不是合法 JSON"
            case .upstream(let m): return m
            }
        }
    }

    /// 安全构造 URL：URL 由字符串拼接而成，含非法字符（中文/空格/未编码）时
    /// `URL(string:)` 会返回 nil。此前全部用 `!` 强制解包——一旦上游返回带中文的
    /// stageId 或配置里出现空格 id 就直接崩溃。改为可捕获的错误。
    private static func makeURL(_ url: String) throws -> URL {
        guard let u = URL(string: url) else { throw NetError.upstream("非法 URL: \(url)") }
        return u
    }

    /// 共享 session：此前每个请求都 `URLSession(configuration: .ephemeral)` 新建一个，
    /// 用完既不复用也不 invalidate —— TCP/TLS 握手每次重来，且 .ephemeral 意味着
    /// 没有 URLCache、没有 ETag/304 复用，看板 20s 轮询会把整份赛程完整重下。
    /// 改为进程级单例（.default 具备缓存能力），超时改在 URLRequest 上按请求设置。
    private static let shared: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = ["User-Agent": ua]
        cfg.timeoutIntervalForRequest = 20      // 兜底；实际超时由请求自身覆盖
        cfg.timeoutIntervalForResource = 60
        cfg.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                diskCapacity: 64 * 1024 * 1024,
                                diskPath: "kpl.netcache")
        return URLSession(configuration: cfg)
    }()

    private static func session(timeout: TimeInterval) -> URLSession { shared }

    /// POST application/x-www-form-urlencoded，返回 JSON 对象
    static func postForm(_ url: String,
                         form: [String: String],
                         headers: [String: String] = [:],
                         timeout: TimeInterval = 15) async throws -> [String: Any] {
        var comps = URLComponents()
        comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        let body = (comps.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()

        var req = URLRequest(url: try makeURL(url))
        req.timeoutInterval = timeout   // session 已共享，超时必须按请求设置
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let (data, resp) = try await session(timeout: timeout).data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NetError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data), let obj = json as? [String: Any] else {
            throw NetError.notJSON
        }
        return obj
    }

    /// POST application/x-www-form-urlencoded，返回原始文本（archive 通道返回 HTML）
    static func postFormText(_ url: String,
                             form: [String: String],
                             headers: [String: String] = [:],
                             timeout: TimeInterval = 20) async throws -> String {
        var comps = URLComponents()
        comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        let body = (comps.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()

        var req = URLRequest(url: try makeURL(url))
        req.timeoutInterval = timeout   // session 已共享，超时必须按请求设置
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let (data, resp) = try await session(timeout: timeout).data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NetError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        // 玩加 archive 通道偶发 GBK 编码，回退一次
        let gb = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(data: data, encoding: gb) ?? ""
    }

    /// POST JSON，返回 JSON 对象（KPL 官方接口）
    static func postJSON(_ url: String,
                         body: [String: Any],
                         headers: [String: String] = [:],
                         timeout: TimeInterval = 12) async throws -> [String: Any] {
        var req = URLRequest(url: try makeURL(url))
        req.timeoutInterval = timeout   // session 已共享，超时必须按请求设置
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let (data, resp) = try await session(timeout: timeout).data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NetError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data), let obj = json as? [String: Any] else {
            throw NetError.notJSON
        }
        return obj
    }

    /// GBK / GB18030 解码（官网英雄详情页是 GBK 页面）
    static func decodeGBK(_ data: Data) -> String {
        let enc = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(data: data, encoding: enc) ?? String(data: data, encoding: .utf8) ?? ""
    }

    /// GET 任意 JSON（数组或对象）。官方 herolist/item/ming 接口顶层是数组。
    static func getJSONAny(_ url: String,
                           headers: [String: String] = [:],
                           timeout: TimeInterval = 15) async throws -> Any {
        var req = URLRequest(url: try makeURL(url))
        req.timeoutInterval = timeout   // session 已共享，超时必须按请求设置
        req.httpMethod = "GET"
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session(timeout: timeout).data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NetError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// GET 原始字节 + 响应对象。图片可达性探测、GBK 页面抓取、取 Set-Cookie 都用它。
    /// 返回 HTTPURLResponse 而不仅是头字典：`allHeaderFields` 的 value 可能是数组，
    /// 直接 as? [String: String] 会整体失败，用 `value(forHTTPHeaderField:)` 才稳。
    ///
    /// ⚠️ 与 Net 其他方法不同：这里**不校验状态码**（是唯一的一个）——
    /// 调用方拿到的可能是 4xx/5xx 的错误页，必须自行检查 `status`。
    /// 现有三个调用点都已正确校验（其中英雄详情特意把 404 当「官网未建页」
    /// 下发基础资料版详情，是有意为之，不是遗漏）。新增调用点时务必校验。:)` 才稳。
    static func getRaw(_ url: String,
                       headers: [String: String] = [:],
                       timeout: TimeInterval = 15) async throws -> (Data, Int, HTTPURLResponse?) {
        var req = URLRequest(url: try makeURL(url))
        req.timeoutInterval = timeout   // session 已共享，超时必须按请求设置
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session(timeout: timeout).data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? -1, resp as? HTTPURLResponse)
    }

    /// GET 文本（UTF-8 优先，用于官网公告的 JS literal 接口）
    static func getText(_ url: String,
                        headers: [String: String] = [:],
                        timeout: TimeInterval = 15) async throws -> String {
        var req = URLRequest(url: try makeURL(url))
        req.timeoutInterval = timeout   // session 已共享，超时必须按请求设置
        req.httpMethod = "GET"
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session(timeout: timeout).data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NetError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return String(data: data, encoding: .utf8) ?? decodeGBK(data)
    }

    /// 带自定义头 + 返回响应头的 POST（玩加 /ajax/stats/list 需要 Cookie 与 X-CSRF-Token，
    /// 首次握手还要从 Set-Cookie 里取 wanplus_token 做 time33 签名）
    static func postFormDetailed(_ url: String,
                                 form: [String: String],
                                 headers: [String: String] = [:],
                                 timeout: TimeInterval = 20) async throws -> (Any, HTTPURLResponse?) {
        var comps = URLComponents()
        comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        let body = (comps.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()

        var req = URLRequest(url: try makeURL(url))
        req.timeoutInterval = timeout   // session 已共享，超时必须按请求设置
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        // 关掉自动 cookie 处理：签名要用请求返回的原始 Set-Cookie，且 cookie 由我们手动带
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.httpAdditionalHeaders = ["User-Agent": ua]
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        let sess = URLSession(configuration: cfg)
        // 用完必须 invalidate：否则 session（及其底层 delegate / 连接池）泄漏。
        // 玩加分页一赛季最多 21 次请求 → 每赛季泄漏 21 个 session。
        defer { sess.finishTasksAndInvalidate() }

        let (data, resp) = try await sess.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NetError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let json = try JSONSerialization.jsonObject(with: data)
        return (json, http)
    }

    /// GET JSON（PandaScore 聚合源）
    static func getJSON(_ url: String, timeout: TimeInterval = 12) async throws -> [String: Any] {
        var req = URLRequest(url: try makeURL(url))
        req.timeoutInterval = timeout   // session 已共享，超时必须按请求设置
        req.httpMethod = "GET"
        // 实时比分专用：显式禁本地缓存。共享 session 带 URLCache，
        // 上游虽回 no-store，但不该让「20 秒前的比分」有任何被复用的可能。
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session(timeout: timeout).data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NetError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data), let obj = json as? [String: Any] else {
            throw NetError.notJSON
        }
        return obj
    }
}

// MARK: - 任意 JSON 值的安全取值

extension Dictionary where Key == String {
    func num(_ k: String) -> Int {
        if let n = self[k] as? NSNumber { return n.intValue }
        if let s = self[k] as? String { return Int(s) ?? 0 }
        if let d = self[k] as? Double { return Int(d) }
        return 0
    }
    func str(_ k: String) -> String {
        if let s = self[k] as? String { return s }
        if let n = self[k] as? NSNumber { return String(n.intValue) }
        return ""
    }
    func boolish(_ k: String) -> Bool {
        if let b = self[k] as? Bool { return b }
        if let n = self[k] as? NSNumber { return n.intValue != 0 }
        if let s = self[k] as? String { return s == "1" || s.lowercased() == "true" }
        return false
    }
    func dict(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
    func arr(_ k: String) -> [[String: Any]]? { self[k] as? [[String: Any]] }
}

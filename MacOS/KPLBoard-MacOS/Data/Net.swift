import Foundation

/// 统一的网络层。所有上游请求都走这里，便于统一 UA / 超时 / 错误处理。
enum Net {
    // macOS 版改发 Mac Safari UA（iPad 版为 iPad UA）；上游据此返回桌面版页面结构
    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    enum NetError: Error, LocalizedError {
        case badStatus(Int)
        case notJSON
        case upstream(String)
        case badURL(String)

        var errorDescription: String? {
            switch self {
            case .badStatus(let c): return "上游返回 \(c)"
            case .notJSON: return "响应不是合法 JSON"
            case .upstream(let m): return m
            case .badURL(let u): return "URL 非法（\(u)）"
            }
        }
    }

    /// 统一创建 URL：上游 id 含非法字符（空格 / 未编码中文）时返回 nil，
    /// 此处用 guard 抛出而非强制解包，避免直接 fatalError 拖垮 App。
    private static func makeURL(_ s: String) throws -> URL {
        guard let u = URL(string: s) else { throw NetError.badURL(s) }
        return u
    }

    /// 按超时档位复用 session（ephemeral，不落 cookie/缓存）。
    /// 之前每个请求都新建 URLSession 且从不 invalidate，session 及其底层
    /// 连接池会一直滞留；按 timeout 建一个小缓存池，常见 3~4 个档位全部复用。
    private static let sessionLock = NSLock()
    private static var sessionPool: [Int: URLSession] = [:]

    private static func session(timeout: TimeInterval) -> URLSession {
        let bucket = Int(timeout)
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let hit = sessionPool[bucket] { return hit }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.httpAdditionalHeaders = ["User-Agent": ua]
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        let s = URLSession(configuration: cfg)
        sessionPool[bucket] = s
        return s
    }

    /// POST application/x-www-form-urlencoded，返回 JSON 对象
    static func postForm(_ url: String,
                         form: [String: String],
                         headers: [String: String] = [:],
                         timeout: TimeInterval = 15) async throws -> [String: Any] {
        var comps = URLComponents()
        comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        let body = (comps.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()

        var req = URLRequest(url: try makeURL(url))
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
    static func getRaw(_ url: String,
                       headers: [String: String] = [:],
                       timeout: TimeInterval = 15) async throws -> (Data, Int, HTTPURLResponse?) {
        var req = URLRequest(url: try makeURL(url))
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
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        // 关掉自动 cookie 处理：签名要用请求返回的原始 Set-Cookie，且 cookie 由我们手动带。
        // session() 统一建池时已关闭 cookie（httpShouldSetCookies=false + acceptPolicy=.never），
        // 这里直接复用池里的 session，不再每次新建。
        let sess = session(timeout: timeout)

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
        req.httpMethod = "GET"
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

    /// Unix 秒取值：官方源的时间戳是字符串（"1790920800"），其他源可能是数字，
    /// 两种情况都要能读。取不到 / 解析失败返回 0。
    func epoch(_ k: String) -> Int {
        if let n = self[k] as? NSNumber { return n.intValue }
        if let s = self[k] as? String { return Int(s.trimmingCharacters(in: .whitespaces)) ?? 0 }
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

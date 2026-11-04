import Foundation

/// 工具箱的纯函数工具层。逐行对齐 tools-sources.js 的「小工具」段。
enum ToolsUtil {

    // MARK: - 数值

    /// 去掉百分号等装饰字符（种子数据里 `goldPercent: "20.3%"` 这类值是真实存在的）。
    /// 此前 `Double("26.5%")` 返回 nil → dbl 静默返回 0，所有百分数统计全部失真。
    private static func numericString(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if let d = Double(t) { return d }
        // 去掉 % / 千分位逗号 / 全角逗号后再试
        let stripped = t.trimmingCharacters(in: CharacterSet(charactersIn: "%，,"))
        if let d = Double(stripped) { return d }
        return nil
    }

    /// 任意 JSON 值 → Double（'26.5%' / 0.265 / '12' / nil 都能吃）
    static func dbl(_ v: Any?) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return numericString(s) ?? 0 }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return 0
    }

    /// 任意 JSON 值 → 可空 Double（区分「上游没给」与「上游给了 0」）
    static func dblOpt(_ v: Any?) -> Double? {
        if v == nil { return nil }
        if v is NSNull { return nil }
        if let s = v as? String { return numericString(s) }
        return dbl(v)
    }

    static func int(_ v: Any?) -> Int { Int(dbl(v)) }

    /// 任意 JSON 值 → 字符串（NSNumber 走 stringValue，null / 缺失一律空串）
    static func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    /// 保留 1 位小数
    static func r1(_ v: Any?) -> Double {
        let n = dbl(v)
        return (n * 10).rounded() / 10
    }

    /// 保留 2 位小数
    static func r2(_ v: Any?) -> Double {
        let n = dbl(v)
        return (n * 100).rounded() / 100
    }

    /// 数字 → 字符串，整数去掉小数点。
    /// 对齐 JS 的模板字符串：${26.0} 是 "26"，Swift 的 "\(26.0)" 是 "26.0"，
    /// 前端展示的百分比因此必须走这里。
    static func fmtNum(_ d: Double) -> String {
        guard d.isFinite else { return "0" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    // MARK: - 字符串

    /// HTML → 单行文本（列表展示用）
    static func stripHtml(_ s: Any?) -> String {
        var t = String(describing: s ?? "")
        t = replace(t, #"<br\s*/?>"#, " ")
        t = replace(t, #"</p>"#, " ")
        t = replace(t, #"<[^>]+>"#, "")
        t = replace(t, "&nbsp;", " ")
        t = replace(t, "&amp;", "&")
        t = replace(t, "&lt;", "<")
        t = replace(t, "&gt;", ">")
        return collapse(t)
    }

    /// HTML → 逐行文本（详情页展示用，官方数据用 <p> / <br> 分行）
    static func htmlLines(_ s: Any?) -> [String] {
        var t = String(describing: s ?? "")
        t = replace(t, #"</p>"#, "\n")
        t = replace(t, #"<br\s*/?>"#, "\n")
        t = replace(t, #"<[^>]+>"#, "")
        t = replace(t, "&nbsp;", " ")
        t = replace(t, "&amp;", "&")
        t = replace(t, "&lt;", "<")
        t = replace(t, "&gt;", ">")
        return t.components(separatedBy: "\n")
            .map { collapse($0) }
            .filter { !$0.isEmpty }
    }

    /// 正则按 pattern 缓存。这些 helper 在热路径上被逐行/逐条调用
    /// （如 collapse 在 htmlLines 里逐行跑），每次新建 NSRegularExpression 编译开销明显。
    private static let reCacheLock = NSLock()
    private static var reCache: [String: NSRegularExpression] = [:]

    private static func cachedRE(_ pattern: String) -> NSRegularExpression? {
        reCacheLock.lock()
        if let hit = reCache[pattern] { reCacheLock.unlock(); return hit }
        reCacheLock.unlock()
        guard let made = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        reCacheLock.lock()
        reCache[pattern] = made
        reCacheLock.unlock()
        return made
    }

    private static func replace(_ s: String, _ pattern: String, _ with: String) -> String {
        guard let re = cachedRE(pattern) else { return s }
        return re.stringByReplacingMatches(in: s,
                                           range: NSRange(s.startIndex..., in: s),
                                           withTemplate: with)
    }

    /// 连续空白折叠为一个空格并去首尾
    static func collapse(_ s: String) -> String {
        guard let re = cachedRE(#"\s+"#) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// '20261001' → '2026-10-01'
    static func fmtDate(_ s: Any?) -> String {
        let t = String(describing: s ?? "").trimmingCharacters(in: .whitespaces)
        guard t.count == 8, t.allSatisfy({ $0.isNumber }) else { return "" }
        let a = Array(t)
        return "\(String(a[0..<4]))-\(String(a[4..<6]))-\(String(a[6..<8]))"
    }

    /// 官方品质文字规范化：「史诗（品级可提升：勇者 → 史诗）」→「史诗」
    static func cleanQuality(_ s: Any?) -> String {
        var t = String(describing: s ?? "").trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "" }
        // 去掉括号内容
        t = replace(t, #"[（(][^）)]*[）)]"#, "")
        // 「勇者 → 史诗」取箭头右侧
        if t.contains("→"), let last = t.components(separatedBy: "→").last { t = last }
        t = t.replacingOccurrences(of: "（", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: "）", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespaces)
        return ToolsDict.qualityAlias[t] ?? t
    }

    /// 官方获取方式 → 更精确的价格说明
    static func priceFromObtain(_ obtain: Any?, _ fallback: String) -> String {
        let o = String(describing: obtain ?? "")
        if o.isEmpty { return fallback }
        if let m = firstMatch(o, #"(\d+)\s*点券"#) { return "\(m) 点券" }
        if o.contains("荣耀水晶") { return "荣耀水晶兑换" }
        if o.contains("祈愿") { return "祈愿获取" }
        if o.contains("战令") { return "荣耀战令" }
        if o.contains("碎片") { return "皮肤碎片兑换" }
        if o.contains("免费") { return "0（免费获取）" }
        return fallback
    }

    /// 去掉「（xxx）」后缀：「花木兰（剑舞者）」→「花木兰」
    static func bare(_ s: Any?) -> String {
        String(describing: s ?? "").replacingOccurrences(of: #"[（(].*$"#,
                                                         with: "",
                                                         options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 正则

    /// 返回第一个捕获组（复用已编译的正则，热路径用）
    static func firstMatch(_ s: String, _ re: NSRegularExpression) -> String? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// 返回第一个捕获组
    static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// 返回整段匹配（对应 JS 的 `String.match(re)[0]`）
    static func firstMatchWhole(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }

    /// 全局匹配：每个匹配返回「整段 + 各捕获组」
    static func allMatches(_ s: String, _ pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        var out: [[String]] = []
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            var g: [String] = []
            for i in 0..<m.numberOfRanges {
                g.append(m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)))
            }
            out.append(g)
        }
        return out
    }

    /// 是否匹配
    static func test(_ s: String, _ pattern: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// 字符串替换（正则，返回新串）
    static func replacing(_ s: String, _ pattern: String, _ with: String) -> String { replace(s, pattern, with) }

    // MARK: - 玩加签名

    /// 玩加前端 time33 令牌算法：取 token 前 7 位做 hash。
    /// JS 的 `d << 5` 是 int32 截断后左移，这里用 truncatingIfNeeded 复现，
    /// 否则 Swift 的 64 位 Int 会得到与上游不一致的 gtk。
    static func time33(_ str: String) -> Int {
        let a = Array(String(str).prefix(7))
        var d: Int64 = 5381
        for ch in a {
            guard let v = ch.unicodeScalars.first?.value else { continue }
            let shifted = Int64(Int32(truncatingIfNeeded: d) << 5)
            d = d + shifted + Int64(v)
        }
        return Int(Int32(truncatingIfNeeded: d) & 0x7FFF_FFFF)
    }

    // MARK: - 资源地址

    static func skinTagIconUrl(_ id: String) -> String {
        "https://game.gtimg.cn/images/yxzj/ingame/skin/icon/\(id).png"
    }
    static func heroDetailUrl(_ e: Any) -> String {
        "https://pvp.qq.com/web201605/herodetail/\(e).shtml"
    }
    static func heroIconUrl(_ e: Any) -> String {
        "https://game.gtimg.cn/images/yxzj/img201606/heroimg/\(e)/\(e).jpg"
    }
    static func heroSkinUrl(_ e: Any, _ n: Int) -> String {
        "https://game.gtimg.cn/images/yxzj/img201606/skin/hero-info/\(e)/\(e)-bigskin-\(n).jpg"
    }
    static func skillIconUrl(_ e: Any, _ code: String) -> String {
        "https://game.gtimg.cn/images/yxzj/img201606/heroimg/\(e)/\(code).png"
    }
    static func itemIconUrl(_ id: Any) -> String {
        "https://game.gtimg.cn/images/yxzj/img201606/itemimg/\(id).jpg"
    }
    static func itemIconAltUrl(_ id: Any) -> String {
        "https://game.gtimg.cn/images/yxzj/img201606/itemimgo/\(id).png"
    }
    static func mingIconUrl(_ id: Any) -> String {
        "https://game.gtimg.cn/images/yxzj/img201606/mingwen/\(id).png"
    }

    // MARK: - 排序

    /// 中文字符串比较（对齐 JS 的 localeCompare(_, 'zh') —— ICU 中文排序）。
    /// Locale 构造开销不小，排序里会调用 O(n log n) 次，缓存为静态常量。
    private static let zhLocale = Locale(identifier: "zh_CN")

    static func zhCompare(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [], range: nil, locale: zhLocale) == .orderedAscending
    }

    /// 稳定排序。JS 的 Array.prototype.sort 在 V8 中是**稳定**的，Swift 的 sort 不是 ——
    /// 比较键相等时（同场次、同分、同计数）顺序会被打乱，表现为列表项随机错位。
    /// 所有移植自 JS 的排序都必须走这里，用原始下标做最终 tie-breaker。
    static func stableSorted<T>(_ arr: [T], by less: (T, T) -> Bool) -> [T] {
        arr.enumerated()
            .map { (offset: $0.offset, element: $0.element) }
            .sorted { a, b in
                if less(a.element, b.element) { return true }
                if less(b.element, a.element) { return false }
                return a.offset < b.offset
            }
            .map { $0.element }
    }

    /// 无 locale 比较（对齐 JS 的 localeCompare(_) —— 默认 ICU collation）。
    /// 两者对中文结果不同：默认 collation 按码位，zh_CN 按拼音。
    /// 移植时必须看 JS 源码有没有传 'zh'，否则排序会整段错位。
    static func cmp(_ a: String, _ b: String) -> Bool {
        a.compare(b) == .orderedAscending
    }
}

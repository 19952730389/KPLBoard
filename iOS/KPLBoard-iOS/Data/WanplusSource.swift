import Foundation

/// 玩加赛事（wanplus.cn）主源：赛程 / 阶段 / 队标 / 历史数据。
/// 两套通道与 server.js 一致：
///   live    —— 当前赛季，POST /ajax/schedule/list，按周取，含实况状态与逐小局
///   archive —— 历史赛季，POST /ajax/event/shedule/detail，返回 HTML，正则解析
enum WanplusSource {
    private static let api = "https://wanplus.cn/ajax/schedule/list"
    private static let archiveAPI = "https://wanplus.cn/ajax/event/shedule/detail"
    private static let game = "kog"
    private static let gameType = "6"

    private static var baseHeaders: [String: String] {
        ["Accept": "application/json, text/javascript, */*; q=0.01",
         "X-Requested-With": "XMLHttpRequest",
         "Referer": "https://wanplus.cn/\(game)/schedule",
         "Origin": "https://wanplus.cn"]
    }

    // MARK: - live 通道

    static func fetchWeek(eventId: String, weekStartSec: Int) async throws -> [String: Any] {
        let obj = try await Net.postForm(
            api,
            form: ["game": game, "eids": eventId, "time": String(weekStartSec)],
            headers: baseHeaders
        )
        // server.js: if (json.ret !== 0 && json.code !== 0) throw
        if let ret = obj["ret"] as? NSNumber, ret.intValue != 0,
           let code = obj["code"] as? NSNumber, code.intValue != 0 {
            throw Net.NetError.upstream((obj["msg"] as? String) ?? "上游数据异常")
        }
        return (obj["data"] as? [String: Any]) ?? [:]
    }

    /// 赛事周期内所有周一（北京时间）的 00:00 Unix 秒
    static func weekStarts(of ev: KBEvent) -> [Int] {
        guard let start = ev.start, let end = ev.end else { return [] }
        var cursor = KPLTime.dayStartSec(start)
        let wd = KPLTime.weekdayOf(unixSec: cursor)   // 0=周日 … 6=周六
        cursor -= (wd == 0 ? 6 : wd - 1) * 86400      // 回退到本周一
        let limit = KPLTime.dayStartSec(end) + 14 * 86400
        var out: [Int] = []
        while cursor <= limit {
            out.append(cursor)
            cursor += 7 * 86400
        }
        return out
    }

    /// 玩加单条赛程 → 内部 Match
    private static func normalize(_ m: [String: Any], dateKey: String, dateLabel: String) -> KBMatch {
        let gamesA = m["oneScore"] as? [Any] ?? []
        let gamesB = m["twoScore"] as? [Any] ?? []
        let len = max(gamesA.count, gamesB.count, m.num("bonum"))
        var legs: [String?] = []
        for i in 0..<len {
            let a = (i < gamesA.count) ? (gamesA[i] as? NSNumber)?.intValue ?? -1 : -1
            let b = (i < gamesB.count) ? (gamesB[i] as? NSNumber)?.intValue ?? -1 : -1
            legs.append(a == 1 ? "A" : (b == 1 ? "B" : nil))
        }
        return KBMatch(
            id: m.str("scheduleid"),
            date: dateKey,
            dateLabel: dateLabel.isEmpty ? m.str("date") : dateLabel,
            time: m.str("starttime"),
            stage: (m["groupname"] as? String) ?? "",
            bo: m.num("bonum"),
            over: m.boolish("isover"),
            liveFlag: m.boolish("live"),
            hasVideo: m.boolish("hasvideo"),
            a: TeamSide(id: m.str("oneseedid"),
                        name: (m["oneseedname"] as? String) ?? "待定",
                        icon: (m["oneicon"] as? String) ?? "",
                        score: m.num("onewin")),
            b: TeamSide(id: m.str("twoseedid"),
                        name: (m["twoseedname"] as? String) ?? "待定",
                        icon: (m["twoicon"] as? String) ?? "",
                        score: m.num("twowin")),
            legs: legs
        )
    }

    static func parseWeek(_ data: [String: Any]) -> [KBMatch] {
        guard let list = data["scheduleList"] as? [String: Any] else { return [] }
        var out: [KBMatch] = []
        for (dateKey, dayAny) in list {
            guard let day = dayAny as? [String: Any],
                  let arr = day["list"] as? [[String: Any]] else { continue }
            let label = (day["date"] as? String) ?? ""
            for m in arr {
                out.append(normalize(m, dateKey: dateKey, dateLabel: label))
            }
        }
        return out
    }

    static func fetchLiveEvent(_ ev: KBEvent) async throws -> [KBMatch] {
        var map: [String: KBMatch] = [:]
        for ws in weekStarts(of: ev) {
            let week = try await fetchWeek(eventId: ev.id, weekStartSec: ws)
            for m in parseWeek(week) {
                let key = m.id.isEmpty ? "\(m.date)-\(m.time)-\(m.a.name)-\(m.b.name)" : m.id
                map[key] = m
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 与 server.js 一致的 200ms 节流
        }
        // 字典遍历顺序不保证：同一日期同一时间（典型 19:00 双赛场并行）的两场
        // 会随机互换，表现为「刷新后比赛顺序跳动」。这里先做确定性排序，
        // 再交给 sortMatches 统一排（它已带 id 兜底 tie-breaker）。
        var out = Array(map.values)
        out.sort { x, y in
            if x.id != y.id { return x.id < y.id }
            return "\(x.a.name)-\(x.b.name)" < "\(y.a.name)-\(y.b.name)"
        }
        return out
    }

    // MARK: - archive 通道（HTML 解析）

    static func fetchStage(eid: String, sid: String) async throws -> String {
        try await Net.postFormText(
            archiveAPI,
            form: ["eId": eid, "stageId": sid, "gameType": gameType],
            headers: ["Accept": "text/html, */*; q=0.01",
                      "X-Requested-With": "XMLHttpRequest",
                      "Referer": "https://wanplus.cn/event/\(eid).html",
                      "Origin": "https://wanplus.cn"]
        )
    }

    /// 从一段 HTML 中提取所有正则捕获组
    private static func matches(of pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        let results = re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        return results.map { m in
            (0..<m.numberOfRanges).map { i -> String in
                i < m.numberOfRanges && m.range(at: i).location != NSNotFound
                    ? ns.substring(with: m.range(at: i))
                    : ""
            }
        }
    }

    /// 解析阶段 HTML。版面结构：<div class="NO">…<span class="time">MM-DD</span><span class="time">HH:mm</span>
    private static func parseStageHtml(_ html: String, stageName: String) -> [KBMatch] {
        let head = #"<div class="NO">\s*<span class="blod[^"]*">[^<]*</span>\s*<span class="time">([^<]*)</span>\s*<span class="time">([^<]*)</span>"#
        let ns = html as NSString
        guard let re = try? NSRegularExpression(pattern: head, options: []) else { return [] }
        let found = re.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))

        var out: [KBMatch] = []
        for m in found {
            guard m.numberOfRanges >= 3 else { continue }
            let start = m.range(at: 0).location
            let segLen = min(2200, ns.length - start)
            let seg = ns.substring(with: NSRange(location: start, length: segLen))

            let href = matches(of: #"href="/schedule/(\d+)\.html""#, in: seg).first?[1] ?? ""
            let names = matches(of: #"<div class="teamname">([^<]*)</div>"#, in: seg).map { $0[1].trimmingCharacters(in: .whitespacesAndNewlines) }
            guard names.count >= 2 else { continue }
            let codes = matches(of: #"<div class="teamcode[^"]*">([^<]*)</div>"#, in: seg).map { $0[1].trimmingCharacters(in: .whitespacesAndNewlines) }
            let tids = matches(of: #"/team/(\d+)_min\.png"#, in: seg).map { $0[1] }

            let dRaw = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let tRaw = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)

            // MM-DD
            let parts = dRaw.split(separator: "-").map { Int($0) ?? 0 }
            guard parts.count == 2 else { continue }

            func scoreAt(_ i: Int) -> Int? {
                guard i < codes.count else { return nil }
                let v = codes[i]
                return Int(v)
            }
            let sa = scoreAt(0), sb = scoreAt(1)
            let hasResult = sa != nil && sb != nil

            let t0 = tids.indices.contains(0) ? tids[0] : ""
            let t1 = tids.indices.contains(1) ? tids[1] : ""

            out.append(KBMatch(
                id: href,
                date: "",
                dateLabel: "",
                time: tRaw,
                stage: stageName,
                bo: 0,
                over: hasResult,
                liveFlag: false,
                hasVideo: false,
                a: TeamSide(id: t0, name: names[0],
                            icon: t0.isEmpty ? "" : "https://static.wanplus.cn/data/kog/team/\(t0)_mid.png",
                            score: sa ?? 0),
                b: TeamSide(id: t1, name: names[1],
                            icon: t1.isEmpty ? "" : "https://static.wanplus.cn/data/kog/team/\(t1)_mid.png",
                            score: sb ?? 0),
                legs: []
            ))

            // mmdd 需要保留到调用方补年份，这里临时塞进 dateLabel 前缀
            out[out.count - 1].dateLabel = String(format: "%02d%02d", parts[0], parts[1])
        }
        return out
    }

    static func fetchArchiveEvent(_ ev: KBEvent) async throws -> [KBMatch] {
        var all: [KBMatch] = []
        var curYear = ev.year ?? 2016
        var prevMm = 0
        for st in ev.stages ?? [] {
            let html: String
            do {
                html = try await fetchStage(eid: ev.id, sid: st.id)
            } catch {
                print("[warn] \(ev.name) 阶段「\(st.name)」抓取失败: \(error.localizedDescription)")
                continue
            }
            for var m in parseStageHtml(html, stageName: st.name) {
                let mmdd = m.dateLabel               // 临时存放的 MMDD
                let mm = Int(String(mmdd.prefix(2))) ?? 0
                if prevMm != 0 && mm < prevMm - 6 { curYear += 1 }  // 跨年回绕
                prevMm = mm
                m.date = "\(curYear)\(mmdd)"
                m.dateLabel = "\(mmdd.prefix(2))-\(mmdd.suffix(2))"
                if m.id.isEmpty { m.id = "\(m.date)-\(m.time)-\(m.a.name)-\(m.b.name)" }
                all.append(m)
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return all
    }

    // MARK: - 排序与 BO 推断

    static func sortMatches(_ list: inout [KBMatch]) {
        // Swift 的 sort 不保证稳定，且同 date 同 time（双赛场并行）需要确定性顺序。
        // 用 ToolsUtil.stableSorted：比较相等时按原索引保序；再用 id 做最终
        // tie-breaker，彻底消除「刷新后列表顺序跳动」。
        list = ToolsUtil.stableSorted(list) { x, y in
            if x.date != y.date { return x.date < y.date }
            if x.time != y.time { return x.time < y.time }
            return x.id < y.id
        }
    }

    /// 无 bo 字段时按赛果推断（3/5/7 局），与 server.js inferBo 一致
    static func inferBo(_ matches: [KBMatch]) -> Int {
        let sums = matches.filter { $0.over }.map { $0.a.score + $0.b.score }
        let mx = sums.max() ?? 0
        if mx <= 3 { return 3 }
        if mx <= 5 { return 5 }
        return 7
    }
}

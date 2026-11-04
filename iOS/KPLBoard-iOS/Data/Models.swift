import Foundation

// MARK: - 时间工具（统一按北京时间 UTC+8，与 server.js 完全一致）

enum KPLTime {
    static let tz = TimeZone(secondsFromGMT: 8 * 3600)!

    static var bjCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    /// 当前北京日期，格式 yyyyMMdd（对应 server.js 的 todayKey）
    static func todayKey() -> String {
        let d = Date()
        let c = bjCalendar
        return String(format: "%04d%02d%02d",
                      c.component(.year, from: d),
                      c.component(.month, from: d),
                      c.component(.day, from: d))
    }

    /// 北京时间当日已过分钟数（用于「到点即视为进行中」的推断）
    static func nowMinutes() -> Int {
        let c = bjCalendar
        let d = Date()
        return c.component(.hour, from: d) * 60 + c.component(.minute, from: d)
    }

    /// "2026-10-02" → 该日北京 00:00 的 Unix 秒
    static func dayStartSec(_ s: String) -> Int {
        let p = s.split(separator: "-").map { Int($0) ?? 0 }
        guard p.count >= 3 else { return 0 }
        var comp = DateComponents()
        comp.timeZone = tz
        comp.year = p[0]; comp.month = p[1]; comp.day = p[2]
        comp.hour = 0; comp.minute = 0; comp.second = 0
        return Int(bjCalendar.date(from: comp)?.timeIntervalSince1970 ?? 0)
    }

    /// 北京时间星期几（0=周日 … 6=周六），对应 JS 的 getUTCDay()
    static func weekdayOf(unixSec: Int) -> Int {
        let c = bjCalendar
        let comp = c.component(.weekday, from: Date(timeIntervalSince1970: TimeInterval(unixSec)))
        return comp - 1 // Apple: 1=周日 → JS: 0=周日
    }

    /// Unix 秒 → 北京日期键 yyyyMMdd。实时源（官方 start_timestamp /
    /// PandaScore date）都要靠它换算成与赛程一致的日期，供 Aggregator 按天配准。
    static func dateKey(ofUnixSec unixSec: Int) -> String {
        guard unixSec > 0 else { return "" }
        let c = bjCalendar
        let d = Date(timeIntervalSince1970: TimeInterval(unixSec))
        return String(format: "%04d%02d%02d",
                      c.component(.year, from: d),
                      c.component(.month, from: d),
                      c.component(.day, from: d))
    }

    static func pad2(_ n: Int) -> String { String(format: "%02d", n) }

    /// 北京时间日期键，用于 PandaScore 的 date= 参数（yyyy-MM-dd）
    static func bjDateKey() -> String {
        let c = bjCalendar
        let d = Date()
        return String(format: "%04d-%@-%@",
                      c.component(.year, from: d),
                      pad2(c.component(.month, from: d)),
                      pad2(c.component(.day, from: d)))
    }
}

// MARK: - 队名归一化（与 server.js normName 一致：去空格/点/间隔号 → 小写）

func normName(_ n: String?) -> String {
    let s = n ?? ""
    var out = ""
    for ch in s {
        switch ch {
        case " ", ".", "·", "．": continue
        default: out.append(ch)
        }
    }
    return out.lowercased()
}

// MARK: - 赛事（events.json）

struct StageRef: Codable {
    let id: String
    let name: String
    let way: Int?
}

struct KBEvent: Codable {
    let id: String
    let name: String
    let short: String?
    let year: Int?
    let category: String?
    let mode: String
    let start: String?
    let end: String?
    let catOrder: Int?
    let grouped: Bool?
    let stages: [StageRef]?

    /// 赛事是否处于进行中（today 落在 [start, end] 内）
    func isActive() -> Bool {
        guard mode == "live", let s = start, let e = end else { return false }
        let t = KPLTime.todayKey()
        // 归一化为纯数字 yyyymmdd：events.json 目前是 `yyyy-MM-dd`，
        // 但若写成 `2026/10/02` 之类，原来的 `replacingOccurrences(of: "-")`
        // 会留下斜杠 → 字符串比较失效 → 赛事被永久当成「已结束」。
        let norm = { (v: String) -> String in
            v.filter { $0.isNumber }
        }
        let sn = norm(s), en = norm(e)
        guard sn.count == 8, en.count == 8 else { return false }
        return t >= sn && t <= en
    }
}

// MARK: - 比赛

struct TeamSide {
    var id: String
    var name: String
    var icon: String
    var score: Int

    var dict: [String: Any] {
        ["id": id, "name": name, "icon": icon, "score": score]
    }
}

/// 一场比赛。字段命名与 server.js 保持一致，保证前端 JS 无需改动。
struct KBMatch {
    var id: String
    var date: String          // yyyyMMdd
    var dateLabel: String     // MM-DD
    var time: String          // HH:mm
    var stage: String
    var bo: Int
    var over: Bool
    var liveFlag: Bool
    var hasVideo: Bool
    var a: TeamSide
    var b: TeamSide
    var legs: [String?]       // "A" / "B" / nil

    // decorate() 附加字段
    var status: String = "upcoming"   // upcoming / live / finished
    var isToday: Bool = false
    var playedLegs: Int = 0
    var winner: String? = nil
    var realtime: Bool = false
    var officialScore: Bool = false
    var scoreFromLegs: Bool = false

    var dict: [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "date": date,
            "dateLabel": dateLabel,
            "time": time,
            "stage": stage,
            "bo": bo,
            "over": over,
            "liveFlag": liveFlag,
            "hasVideo": hasVideo,
            "a": a.dict,
            "b": b.dict,
            "legs": legs.map { $0 as Any },
            "status": status,
            "isToday": isToday,
            "playedLegs": playedLegs,
            "winner": winner as Any,
        ]
        if realtime { d["realtime"] = true }
        if officialScore { d["officialScore"] = true }
        if scoreFromLegs { d["scoreFromLegs"] = true }
        return d
    }
}

// MARK: - 实时源条目（官方 / PandaScore 归一化后的统一形状）

struct RealtimeEntry {
    var cnA: String?
    var cnB: String?
    var scoreA: Int
    var scoreB: Int
    var status: String   // scheduled / live / completed
    var bestOf: Int
    var legs: [String?]
    /// 开赛时刻换算出的北京日期键 yyyyMMdd。
    /// KPL 年度总决赛这类赛制里同一对战队会在不同阶段多次交手
    /// （如 重庆狼队 vs 深圳DYG 既有 10-16 擂台赛也有 10-20 突围赛），
    /// 只按队名配准时，上游按时间正序返回、后写入的条目会覆盖先写入的，
    /// 旧比赛的结果就被盖到新比赛上。Aggregator 靠它按「队名+日期」配对。
    var dateKey: String = ""
}

// MARK: - 实时通道状态（对应 server.js 的 kplState / rtState）

struct RealtimeState {
    var at: TimeInterval = 0
    var updatedAt: TimeInterval = 0
    var ok: Bool = false
    var error: String? = nil
    var list: [RealtimeEntry] = []
    var matched: Int = 0
    var seen: Int = 0

    var dict: [String: Any] {
        [
            "ok": ok,
            "updatedAt": Int(updatedAt * 1000),
            "matched": matched,
            "seen": seen,
            "error": error as Any,
        ]
    }
}

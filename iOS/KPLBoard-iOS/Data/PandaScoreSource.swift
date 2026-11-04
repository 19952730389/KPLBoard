import Foundation

/// PandaScore 聚合源（esportsresults.com）：官方接口不含逐小局胜方，小局由这里补充；
/// 官方源不可用时，本通道全量兜底（大比分 + 状态 + 小局）。
enum PandaScoreSource {
    static let endpoint = "https://esportsresults.com/api/matches?date="

    /// 实时源英文队名（归一化后）→ 玩加中文队名，与 server.js TEAM_ALIAS 一致
    private static let alias: [String: String] = [
        "agsuperplay": "成都AG超玩会",
        "douyugaming": "深圳DYG",
        "jdgaming": "北京JDG",
        "herojiujing": "南通Hero久竞",
        "talentgaming": "广州TTG",
        "roguewarriors": "济南RW侠",
        "wolves": "重庆狼队",
        "edwardgaming": "上海EDG.M",
        "weibogaming": "北京WB",
        "topesportsarmor": "长沙TES.A",
        "kuaishougaming": "KSG",
        "lgdnbw": "杭州LGD.NBW",
    ]

    static func fetch(dateKey: String) async throws -> [RealtimeEntry] {
        let obj = try await Net.getJSON(endpoint + dateKey)
        guard let arr = obj["matches"] as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        return arr
            .filter { ($0["game"] as? String ?? "").localizedCaseInsensitiveContains("king of glory") }
            .map { m in
                let games = m["games"] as? [[String: Any]] ?? []
                // 只认「已结束」的小局；未结束的局即便有 winner 也不计入，避免多算
                let legs: [String?] = games.map { g -> String? in
                    if let finished = g["finished"] as? Bool, finished == false { return nil }
                    guard let w = g["winner"] as? String, w == "A" || w == "B" else { return nil }
                    return w
                }
                // "2026-10-20T10:07:49Z" 是 UTC，换算成北京日期键；上游偶发缺字段时回落空串
                let raw = m["date"] as? String ?? ""
                let parsed = iso.date(from: raw) ?? isoPlain.date(from: raw)
                return RealtimeEntry(
                    cnA: alias[normName(m["teamA"] as? String)],
                    cnB: alias[normName(m["teamB"] as? String)],
                    scoreA: m.num("scoreA"),
                    scoreB: m.num("scoreB"),
                    status: (m["status"] as? String) ?? "",
                    bestOf: m.num("bestOf"),
                    legs: legs,
                    dateKey: parsed.map { KPLTime.dateKey(ofUnixSec: Int($0.timeIntervalSince1970)) } ?? ""
                )
            }
    }
}

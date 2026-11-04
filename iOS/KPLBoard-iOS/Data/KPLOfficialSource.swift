import Foundation

/// KPL 官方接口（kpl.qq.com 官网同款）：大比分与状态最权威、最快。
/// POST https://kplshop-op.timi-esports.qq.com/kplow/getScheduleList
/// body: {"direction":1,"pivot_scheduleid":"","page_size":50}
/// 注意：必须 POST，且 RPC 名是 getScheduleList（GET 或 getSchedules 都会返回 rpc name invalid）。
enum KPLOfficialSource {
    static let endpoint = "https://kplshop-op.timi-esports.qq.com/kplow/getScheduleList"
    private static let detailEndpoint = "https://kplshop-op.timi-esports.qq.com/kplow/getScheduleDetail"

    /// 官方 schedule_status → 内部状态（1/2=未开始 3=进行中 4=已结束）
    private static let statusMap: [Int: String] = [1: "scheduled", 2: "scheduled", 3: "live", 4: "completed"]

    static func fetch() async throws -> [RealtimeEntry] {
        let obj = try await Net.postJSON(
            endpoint,
            body: ["direction": 1, "pivot_scheduleid": "", "page_size": 50],
            headers: ["Origin": "https://kpl.qq.com", "Referer": "https://kpl.qq.com/"]
        )
        if let r = obj["result"] as? NSNumber, r.intValue != 0 {
            throw Net.NetError.upstream((obj["msg"] as? String) ?? "官方源数据异常")
        }
        guard let data = obj["data"] as? [String: Any], let list = data["list"] as? [[String: Any]] else {
            throw Net.NetError.upstream("官方源数据异常")
        }
        var entries: [RealtimeEntry] = []
        var liveIdx: [Int] = []        // 进行中场次在 entries 里的下标，稍后用逐小局详情自纠
        var liveRaw: [[String: Any]] = []
        for m in list {
            guard let cnA = m["team_a_name"] as? String, !cnA.isEmpty,
                  let cnB = m["team_b_name"] as? String, !cnB.isEmpty else { continue }
            let status = statusMap[m.num("schedule_status")] ?? "scheduled"
            let e = RealtimeEntry(
                cnA: cnA,
                cnB: cnB,
                scoreA: m.num("team_a_score"),
                scoreB: m.num("team_b_score"),
                status: status,
                bestOf: m.num("bo_total"),
                legs: [], // 官方列表接口不含逐小局胜方，由 PandaScore 通道补充
                // 官方时间戳是 Unix 秒（UTC，可能是字符串），换算成北京日期键，
                // 供 Aggregator 按「队名+日期」配准
                dateKey: KPLTime.dateKey(ofUnixSec: m.num("start_timestamp"))
            )
            if status == "live" {
                liveIdx.append(entries.count)
                liveRaw.append(m)
            }
            entries.append(e)
        }
        // 官方 list 接口的大比分在赛中/刚结束时可能滞后（实测出现过 0-0 而实际已 2-0、
        // 或已到赛点仍报 live）。逐小局详情接口（getScheduleDetail）由赛事数据系统直出、
        // 更新最快：对进行中场次拉一次详情，用每局 win_team 直接推导大比分与逐小局，
        // 覆盖滞后的 list 数据。进行中场次通常只有 1-3 场，代价可控。
        await withTaskGroup(of: (Int, [String: Any]?, [String: Any]).self) { group in
            for (k, m) in liveRaw.enumerated() {
                let sid = m.str("scheduleid"), season = m.str("seasonid")
                guard !sid.isEmpty, !season.isEmpty else { continue }
                group.addTask {
                    let d = try? await Net.postJSON(
                        detailEndpoint,
                        body: ["scheduleid": sid, "seasonid": season],
                        headers: ["Origin": "https://kpl.qq.com", "Referer": "https://kpl.qq.com/"],
                        timeout: 8)
                    return (k, d, m)
                }
            }
            for await (k, resp, raw) in group {
                guard let resp, let data = resp["data"] as? [String: Any] else { continue }
                let teamA = raw.str("team_a_id")
                let rounds = data["round_details"] as? [[String: Any]] ?? []
                guard !rounds.isEmpty else { continue }   // 刚开局还没有小局结束，维持 list 数据
                var a = 0, b = 0
                var legs: [String?] = []
                for r in rounds {
                    let w = r.str("win_team")
                    if w.isEmpty { legs.append(nil); continue }
                    if w == teamA { a += 1; legs.append("A") }
                    else { b += 1; legs.append("B") }
                }
                let i = liveIdx[k]
                var e = entries[i]
                // list 与详情都来自官方，详情逐小局更细粒度、更新更快：以详情为准
                e.scoreA = a
                e.scoreB = b
                e.legs = legs
                // 赛点判定：BO 制拿到所需胜局即视为结束（Aggregator 里也有同样兜底，
                // 这里提前翻转，让状态与比分一次到位）
                let need = e.bestOf > 0 ? Int(ceil(Double(e.bestOf) / 2.0)) : 0
                if need > 0 && max(a, b) >= need { e.status = "completed" }
                entries[i] = e
            }
        }
        return entries
    }
}

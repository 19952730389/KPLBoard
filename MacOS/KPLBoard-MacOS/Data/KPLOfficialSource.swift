import Foundation

/// KPL 官方接口（kpl.qq.com 官网同款）：大比分与状态最权威、最快。
/// POST https://kplshop-op.timi-esports.qq.com/kplow/getScheduleList
/// body: {"direction":1,"pivot_scheduleid":"","page_size":50}
/// 注意：必须 POST，且 RPC 名是 getScheduleList（GET 或 getSchedules 都会返回 rpc name invalid）。
enum KPLOfficialSource {
    static let endpoint = "https://kplshop-op.timi-esports.qq.com/kplow/getScheduleList"

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
        return list.compactMap { m -> RealtimeEntry? in
            guard let cnA = m["team_a_name"] as? String, !cnA.isEmpty,
                  let cnB = m["team_b_name"] as? String, !cnB.isEmpty else { return nil }
            return RealtimeEntry(
                cnA: cnA,
                cnB: cnB,
                scoreA: m.num("team_a_score"),
                scoreB: m.num("team_b_score"),
                status: statusMap[m.num("schedule_status")] ?? "scheduled",
                bestOf: m.num("bo_total"),
                legs: [], // 官方列表接口不含逐小局胜方，由 PandaScore 通道补充
                // 官方时间戳是 Unix 秒（UTC），换算成北京日期键，供 Aggregator 按天配准
                dateKey: KPLTime.dateKey(ofUnixSec: m.epoch("start_timestamp"))
            )
        }
    }
}

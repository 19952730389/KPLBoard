import Foundation

/// KPL 官方统计接口（kpl.qq.com 官网同款 RPC，与 KPLOfficialSource 同一 host）。
///
/// **为什么需要它**：玩加赛事的「逐选手英雄池」只收录到 2022 年，2023 年及以后
/// （含 2026 KPL 年度总决赛）在 App 内一直显示「上游尚未收录」的空态——
/// 梯度榜与选手详情因此看不到这些赛季的数据。
///
/// 官方这几条 RPC 无需签名、直接 POST JSON，可完整补齐：
///   · `getHeroRankList`     → 逐英雄出场数 / 胜率（梯度榜数据源）
///   · `getSeasonPlayerPerf` → 逐选手 KDA / 伤害占比 / 经济占比 / 参团率（选手榜）
///   · `getScheduleList` + `getScheduleDetail` → 逐小局英雄选择（聚合选手英雄池）
///
/// 数据已实测校验：2026 年度总决赛擂台赛 24 场已结束比赛 → 97 小局、83 个出场英雄；
/// 且 `hero_id` 与官方英雄库 `herolist.json` 的 `ename` **完全一致**，
/// 可直接复用现有的英雄图标 / 类型 / 分路元数据。
enum KPLStatsSource {

    private static let base = "https://kplshop-op.timi-esports.qq.com/kplow/"

    private static let headers = ["Origin": "https://kpl.qq.com",
                                  "Referer": "https://kpl.qq.com/"]

    /// App 赛事 id → 官方 seasonid。
    ///
    /// 只收录 **KPL 正赛**：官方赛季清单里没有独立条目的赛事（预选赛 / 席位赛 /
    /// KGL / KRKPL / 甲级 / 资格赛 / 亚运 / 世冠 / 挑战者杯）不在此表——硬塞会张冠李戴，
    /// 例如把「2020 KPLGT 春季赛」映射到 KPL 春季赛的统计上。
    /// 映射按「年份一致 + 赛事日期区间重叠」逐条核对得出。
    ///
    /// ⚠️ 边界（实测）：官方 `getHeroRankList` / `getSeasonPlayerPerf` 只覆盖
    /// **2023 年起**的赛季（2022 及更早返回空列表），因此这里只列 2023+；
    /// 更早的赛季由玩加通道负责（其数据本就完整）。
    private static let seasonMap: [String: String] = [
        "1201": "KPL2026S3",   // 2026 KPL年度总决赛
        "1172": "KPL2026S2",   // 2026KPL夏季赛
        "1167": "KPL2026S1",   // 2026KPL春季赛
        "1162": "KPL2025S3",   // 2025KPL年度总决赛
        "1158": "KPL2025S2",   // 2025KPL夏季赛
        "1155": "KPL2025S1",   // 2025KPL春季赛
        "1148": "KPL2024S3",   // 2024年王者荣耀KPL年度总决赛
        "1144": "KPL2024S2",   // 2024 KPL 夏季赛
        "1140": "KPL2024S1",   // 2024KPL春季赛
        "1128": "KPL2023S2",   // 2023 KPL夏季赛
        "1124": "KPL2023S1",   // 2023 KPL春季赛
    ]

    /// 官方 `position` → 分路。
    ///
    /// ⚠️ 与 `ToolsDict.lane` **不是同一套编号**：官方是 2=中路 / 3=发育路 / 4=打野，
    /// 而 ToolsDict.lane 是 2=打野 / 3=中路 / 4=发育路。混用会把选手分路整列标错
    /// （实测：妖刀 position=3 是射手/发育路，按 ToolsDict 会标成「中路」）。
    private static let laneOfPosition: [Int: String] = [
        1: "对抗路", 2: "中路", 3: "发育路", 4: "打野", 5: "游走",
    ]

    /// 该 App 赛事是否可由官方通道提供数据
    static func seasonId(of eventId: String) -> String? { seasonMap[eventId] }

    /// 官方通道覆盖的 App 赛事 id 清单（供 coverage 展示）
    static var coveredEventIds: [String] { Array(seasonMap.keys) }

    // MARK: - RPC

    private static func rpc(_ name: String, _ body: [String: Any]) async throws -> Any {
        let obj = try await Net.postJSON(base + name, body: body, headers: headers, timeout: 25)
        if let r = obj["result"] as? NSNumber, r.intValue != 0 {
            let msg = ToolsUtil.str(obj["msg"])
            throw Net.NetError.upstream(msg.isEmpty ? "官方统计接口返回异常" : msg)
        }
        return obj["data"] ?? [:]
    }

    // MARK: - 原始数据

    /// 逐英雄出场数 / 胜率。返回 133 条（含 0 出场的英雄，调用方自行过滤）。
    static func heroRank(seasonId: String) async throws -> [[String: Any]] {
        let data = try await rpc("getHeroRankList", ["seasonid": seasonId])
        return (data as? [String: Any])?["list"] as? [[String: Any]] ?? []
    }

    /// 逐选手核心指标（KDA / 各占比 / 场次 / 位置）。
    static func playerPerf(seasonId: String) async throws -> [[String: Any]] {
        let data = try await rpc("getSeasonPlayerPerf", ["seasonid": seasonId])
        if let arr = data as? [[String: Any]] { return arr }
        return (data as? [String: Any])?["list"] as? [[String: Any]] ?? []
    }

    /// 该赛季的赛程（官方 schedule_status：1/2 未开始 · 3 进行中 · 4 已结束）。
    ///
    /// ⚠️ 必须带 `seasonid`：实测不带该参数时接口只返回**当前赛季**的赛程
    /// （查 2025 赛季会拿到 2026 的场次）；带上后 page_size=200 一次即可取完
    /// 单赛季全部场次（实测 2026S1 共 136 场）。
    static func schedule(seasonId: String, pageSize: Int = 200) async throws -> [[String: Any]] {
        let data = try await rpc("getScheduleList",
                                 ["seasonid": seasonId, "direction": 1,
                                  "pivot_scheduleid": "", "page_size": pageSize])
        let list = (data as? [String: Any])?["list"] as? [[String: Any]] ?? []
        return list.filter { ToolsUtil.str($0["seasonid"]) == seasonId }
    }

    /// 逐小局英雄选择记录（用于聚合选手英雄池）。
    ///
    /// 每场比赛一次 `getScheduleDetail`，因此**限制抓取场次**：官方 list 接口按
    /// page_size 返回，历史大赛季动辄上百场，逐场抓取既慢又无必要（那些赛季
    /// 玩加 / 种子已有数据，不会走到本通道）。这里默认最多 60 场已结束比赛，
    /// 分批并发（每批 6 个）以控制上游压力。
    ///
    /// 返回每条：playerId / playerName / teamId / heroId / heroName / win
    static func roundPicks(seasonId: String, limit: Int = 60, batch: Int = 6) async throws -> [[String: Any]] {
        let list = try await schedule(seasonId: seasonId)
        let finished = list.filter { ToolsUtil.int($0["schedule_status"]) == 4 }
        let targets = Array(finished.prefix(limit))
        guard !targets.isEmpty else { return [] }

        var out: [[String: Any]] = []
        var i = 0
        while i < targets.count {
            let slice = Array(targets[i..<min(i + batch, targets.count)])
            let got = await withTaskGroup(of: [[String: Any]].self) { group -> [[String: Any]] in
                for m in slice {
                    let sid = ToolsUtil.str(m["scheduleid"])
                    let season = ToolsUtil.str(m["seasonid"])
                    guard !sid.isEmpty, !season.isEmpty else { continue }
                    group.addTask { await detailRounds(scheduleId: sid, seasonId: season) }
                }
                var acc: [[String: Any]] = []
                for await part in group { acc.append(contentsOf: part) }
                return acc
            }
            out.append(contentsOf: got)
            i += batch
        }
        return out
    }

    /// 单场比赛 → 逐小局每选手的英雄与胜负
    private static func detailRounds(scheduleId: String, seasonId: String) async -> [[String: Any]] {
        guard let obj = try? await rpc("getScheduleDetail",
                                       ["scheduleid": scheduleId, "seasonid": seasonId]),
              let data = obj as? [String: Any] else { return [] }

        // 顶层 players 提供 playerid → team_id / 简称（round_details 里没有队属信息）
        var teamOf: [String: String] = [:]
        var nameOf: [String: String] = [:]
        for p in data["players"] as? [[String: Any]] ?? [] {
            let pid = ToolsUtil.str(p["playerid"])
            guard !pid.isEmpty else { continue }
            teamOf[pid] = ToolsUtil.str(p["team_id"])
            let short = ToolsUtil.str(p["player_name_short"])
            nameOf[pid] = short.isEmpty ? ToolsUtil.str(p["player_name"]) : short
        }

        var out: [[String: Any]] = []
        for r in data["round_details"] as? [[String: Any]] ?? [] {
            let winner = ToolsUtil.str(r["win_team"])
            for p in r["players"] as? [[String: Any]] ?? [] {
                let pid = ToolsUtil.str(p["playerid"])
                guard !pid.isEmpty else { continue }
                let tid = teamOf[pid] ?? ""
                out.append([
                    "playerId": pid,
                    "playerName": nameOf[pid] ?? "",
                    "teamId": tid,
                    "heroId": ToolsUtil.int(p["hero_id"]),
                    "heroName": ToolsUtil.str(p["hero_name"]),
                    "win": !winner.isEmpty && winner == tid,
                ])
            }
        }
        return out
    }

    // MARK: - 聚合：梯度榜

    /// 聚合梯度榜，输出形状对齐 `ToolsStore.buildGradient`（前端无需区分数据来源）。
    /// `heroIndex` 为官方英雄库索引（heroId → 英雄条目），用于补图标 / 类型 / 分路。
    static func buildGradient(seasonId: String,
                              heroIndex: [Int: [String: Any]]) async throws -> [String: Any] {
        let rank = try await heroRank(seasonId: seasonId)

        var list: [[String: Any]] = rank.compactMap { h -> [String: Any]? in
            let games = ToolsUtil.int(h["match_count"])
            guard games > 0 else { return nil }          // 官方榜含 0 出场英雄，需剔除
            let hid = ToolsUtil.int(h["hero_id"])
            let upName = ToolsUtil.str(h["hero_name"])
            let wr = ToolsUtil.dbl(h["win_cr"])
            let wins = Int((Double(games) * wr).rounded())
            let losses = max(0, games - wins)
            let official = heroIndex[hid] ?? [:]
            let smooth = Double(wins + 2) / Double(games + 4)   // 与玩加通道同口径的贝叶斯平滑
            return [
                "name": ToolsUtil.str(official["name"]).isEmpty ? upName : ToolsUtil.str(official["name"]),
                "alias": (ToolsUtil.str(official["name"]).isEmpty || ToolsUtil.str(official["name"]) == upName) ? "" : upName,
                "heroId": hid,
                "icon": ToolsUtil.str(official["icon"]).isEmpty
                    ? (hid > 0 ? ToolsUtil.heroIconUrl(hid) : "")
                    : ToolsUtil.str(official["icon"]),
                "types": official["types"] as? [String] ?? ["未分类"],
                "lanes": official["lanes"] as? [String] ?? ["未知"],
                "title": ToolsUtil.str(official["title"]),
                "games": games,
                "wins": wins,
                "losses": losses,
                "winRate": ToolsUtil.r2(wr),
                "smooth": ToolsUtil.r2(smooth),
                // 官方通道不提供逐选手英雄池与 KDA（只有汇总出场/胜率），
                // 这三个字段置 null，前端表格显示「—」而不是误导性的 0。
                "kda": NSNull(),
                "users": NSNull(),
                "userList": [String](),
                "share": 0.0,
            ]
        }
        guard !list.isEmpty else {
            return ["eventId": seasonId, "list": [Any](), "totalPlayers": 0, "totalTeams": 0,
                    "totalHeroPicks": 0, "totalPlayerGames": 0, "source": "kpl",
                    "updatedAt": Int(Date().timeIntervalSince1970 * 1000)]
        }

        let totalPicks = list.reduce(0) { $0 + ToolsUtil.int($1["games"]) }
        let denom = max(totalPicks, 1)
        for i in list.indices {
            list[i]["share"] = ToolsUtil.r1(Double(ToolsUtil.int(list[i]["games"])) / Double(denom) * 100)
        }

        // score = 平滑胜率 * 0.65 + 出场占比 * 0.35（与玩加通道一致），再按 score 稳定降序
        let maxGames = max(list.reduce(1) { max($0, ToolsUtil.int($1["games"])) }, 1)
        for i in list.indices {
            let s = ToolsUtil.dbl(list[i]["smooth"])
            list[i]["score"] = ToolsUtil.r2(s * 0.65 + (ToolsUtil.dbl(list[i]["games"]) / Double(maxGames)) * 0.35)
        }
        list = ToolsUtil.stableSorted(list) { a, b in
            let sa = ToolsUtil.dbl(a["score"]), sb = ToolsUtil.dbl(b["score"])
            if sa != sb { return sa > sb }
            return ToolsUtil.dbl(a["winRate"]) > ToolsUtil.dbl(b["winRate"])
        }

        let n = max(list.count, 1)
        let tierLabel = ["T0": "版本答案", "T1": "主流选择", "T2": "体系英雄", "T3": "冷门 / 样本较少"]
        for i in list.indices {
            let pct = Double(i + 1) / Double(n)
            list[i]["rank"] = i + 1
            let tier = pct <= 0.1 ? "T0" : pct <= 0.3 ? "T1" : pct <= 0.6 ? "T2" : "T3"
            list[i]["tier"] = tier
            list[i]["tierLabel"] = tierLabel[tier] ?? ""
            list[i]["pct"] = Int(round(pct * 100))
        }

        return [
            "eventId": seasonId,
            "totalHeroPicks": totalPicks,
            "totalPlayers": 0,          // 由调用方（ToolsStore）按选手名单覆盖
            "totalTeams": 0,
            "source": "kpl",
            "sourceName": "KPL 官方",
            "updatedAt": Int(Date().timeIntervalSince1970 * 1000),
            "list": list,
        ]
    }

    // MARK: - 聚合：选手榜

    /// 聚合选手榜，输出形状对齐 `ToolsStore.buildPlayers`。
    ///
    /// 数据来源分工：
    ///   · `getSeasonPlayerPerf` → KDA、经济/伤害/承伤占比、参团率、位置、战队
    ///   · `getScheduleDetail` 逐小局 → 出场小局、胜负、英雄池
    /// 官方未提供分均经济 / 分均伤害等绝对值，对应字段留空（前端显示「—」）。
    static func buildPlayers(seasonId: String,
                             heroIndex: [Int: [String: Any]],
                             heroNameIndex: [String: [String: Any]]) async throws -> [[String: Any]] {
        let perf = try await playerPerf(seasonId: seasonId)
        guard !perf.isEmpty else { return [] }

        // 逐小局记录 → 按选手聚合出场 / 胜负 / 英雄池
        let picks = (try? await roundPicks(seasonId: seasonId)) ?? []
        var games: [String: Int] = [:]
        var wins: [String: Int] = [:]
        var losses: [String: Int] = [:]
        var poolOrder: [String: [String]] = [:]
        var pool: [String: [String: [String: Int]]] = [:]   // pid → heroName → [games, wins]
        for r in picks {
            let pid = ToolsUtil.str(r["playerId"])
            guard !pid.isEmpty else { continue }
            let hname = ToolsUtil.str(r["heroName"])
            games[pid, default: 0] += 1
            if (r["win"] as? Bool) == true { wins[pid, default: 0] += 1 }
            else { losses[pid, default: 0] += 1 }
            guard !hname.isEmpty else { continue }
            if pool[pid]?[hname] == nil {
                poolOrder[pid, default: []].append(hname)
                pool[pid, default: [:]][hname] = ["games": 0, "wins": 0]
            }
            pool[pid]?[hname]?["games"]? += 1
            if (r["win"] as? Bool) == true { pool[pid]?[hname]?["wins"]? += 1 }
        }

        var out: [[String: Any]] = []
        for p in perf {
            let pid = ToolsUtil.str(p["player_id"])
            guard !pid.isEmpty else { continue }
            let pos = ToolsUtil.int(p["position"])
            let lane = laneOfPosition[pos] ?? "未知"
            // 场次/胜负口径：优先逐小局聚合（与英雄池、胜负自洽）；
            // 逐小局不可用（抓取失败/超限）时才回落官方 Matchcount，
            // 且胜负置 null 显示「—」——此前用 `l = g - w`（w=0）会把
            // 无数据选手标成「0 胜全负」，胜率也被拉成 0。
            let g: Int
            let w: Any?
            let l: Any?
            if let gg = games[pid] {
                g = gg
                w = wins[pid] ?? 0
                l = losses[pid] ?? 0
            } else {
                g = ToolsUtil.int(p["Matchcount"])
                w = nil
                l = nil
            }
            let totalKill = ToolsUtil.int(p["TotalKill"])

            // 英雄池：按出场降序、同场次按胜率降序（稳定排序保持上游顺序）
            var pl: [[String: Any]] = []
            let names = poolOrder[pid] ?? []
            for hn in names {
                let st = pool[pid]?[hn] ?? [:]
                let hg = st["games"] ?? 0
                let hw = st["wins"] ?? 0
                let official = heroNameIndex[hn] ?? [:]
                let hid = ToolsUtil.int(official["id"])
                pl.append([
                    "name": ToolsUtil.str(official["name"]).isEmpty ? hn : ToolsUtil.str(official["name"]),
                    "alias": ToolsUtil.str(official["name"]).isEmpty ? "" : hn,
                    "heroId": hid,
                    "games": hg,
                    "wins": hw,
                    "losses": max(0, hg - hw),
                    "winRate": hg > 0 ? ToolsUtil.r2(Double(hw) / Double(hg)) : 0,
                    "kda": NSNull(),
                    "icon": ToolsUtil.str(official["icon"]).isEmpty
                        ? (hid > 0 ? ToolsUtil.heroIconUrl(hid) : "")
                        : ToolsUtil.str(official["icon"]),
                    "types": official["types"] as? [String] ?? [],
                    "lanes": official["lanes"] as? [String] ?? [],
                    "title": ToolsUtil.str(official["title"]),
                ])
            }
            pl = ToolsUtil.stableSorted(pl) { a, b in
                let ga = ToolsUtil.int(a["games"]), gb = ToolsUtil.int(b["games"])
                if ga != gb { return ga > gb }
                return ToolsUtil.dbl(a["winRate"]) > ToolsUtil.dbl(b["winRate"])
            }
            for i in pl.indices { pl[i]["rank"] = i + 1 }

            // 主打分路按英雄池出场加权（与玩加通道同口径）
            var laneWeight: [String: Int] = [:]
            for it in pl {
                for ln in it["lanes"] as? [String] ?? [] {
                    laneWeight[ln, default: 0] += ToolsUtil.int(it["games"])
                }
            }
            let lanes = laneWeight.keys.sorted { (laneWeight[$0] ?? 0) > (laneWeight[$1] ?? 0) }
            let types = (heroIndex[ToolsUtil.int(pl.first?["heroId"])]?["types"] as? [String]) ?? []

            var row: [String: Any] = [
                "id": pid,
                "name": ToolsUtil.str(p["player_short_name"]).isEmpty
                    ? ToolsUtil.str(p["player_real_name"]) : ToolsUtil.str(p["player_short_name"]),
                "team": ToolsUtil.str(p["team_name"]),
                "teamId": ToolsUtil.str(p["team_id"]),
                "games": g,
                "wins": w ?? NSNull(),
                "losses": l ?? NSNull(),
                "winRate": (w != nil && g > 0) ? ToolsUtil.r2(Double(w as? Int ?? 0) / Double(g)) : NSNull(),
                "kda": ToolsUtil.r2(p["KDA"]),
                "kills": g > 0 ? ToolsUtil.r1(Double(totalKill) / Double(g)) : 0,
                "lane": lanes.first ?? lane,
                "lanes": lanes.isEmpty ? [lane] : lanes,
                "types": types,
                "pool": pl,
                "poolSize": pl.count,
                // 占比类：官方直接给百分数（如 "22.8" 表示 22.8%）
                "goldPercent": Self.pctText(p["AVGGoldCR"]),
                "goldPercentNum": ToolsUtil.r1(p["AVGGoldCR"]),
                "dmgPercent": Self.pctText(p["AVGHurtCR"]),
                "dmgPercentNum": ToolsUtil.r1(p["AVGHurtCR"]),
                "dmgTakenPercent": Self.pctText(p["AVGBeHurtCr"]),
                "dmgTakenPercentNum": ToolsUtil.r1(p["AVGBeHurtCr"]),
                "attendRate": Self.pctText(p["AVGPartacipationCR"]),
                "attendRateNum": ToolsUtil.r1(p["AVGPartacipationCR"]),
                "totals": ["kills": totalKill],
                // 官方未提供：显式置空，前端显示「—」而不是误导性的 0
                "deaths": NSNull(),
                "assists": NSNull(),
                "goldPerMin": NSNull(),
                "dmgPerMin": NSNull(),
                "dmgTakenPerMin": NSNull(),
                "mostKills": NSNull(),
                "mostAssists": NSNull(),
                "mostDeaths": NSNull(),
                "dmgConversion": NSNull(),
                "durationSec": NSNull(),
                "durationMin": NSNull(),
                "rank": 0,
                "rankPct": 0,
            ]
            row["source"] = "kpl"
            out.append(row)
        }

        out = ToolsUtil.stableSorted(out) { a, b in
            let ka = ToolsUtil.dbl(a["kda"]), kb = ToolsUtil.dbl(b["kda"])
            if ka != kb { return ka > kb }
            let ga = ToolsUtil.int(a["games"]), gb = ToolsUtil.int(b["games"])
            if ga != gb { return ga > gb }
            return ToolsUtil.zhCompare(ToolsUtil.str(a["name"]), ToolsUtil.str(b["name"]))
        }
        let n = max(out.count, 1)
        for i in out.indices {
            out[i]["rank"] = i + 1
            out[i]["rankPct"] = Int(round(Double(i + 1) / Double(n) * 100))
        }
        return out
    }

    /// 官方占比字段是「22.8」这种裸数字（含义为 22.8%），统一补成 "22.8%"；
    /// 上游缺失时返回 nil，前端走「—」分支。
    private static func pctText(_ v: Any?) -> Any {
        let s = ToolsUtil.str(v)
        if s.isEmpty { return NSNull() }
        if s.contains("%") { return s }
        return "\(ToolsUtil.fmtNum(ToolsUtil.dbl(v)))%"
    }
}

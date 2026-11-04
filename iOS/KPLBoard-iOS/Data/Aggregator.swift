import Foundation

/// 内置分组配置（server.js 中无 groups.json 时的默认值，年度总决赛专用）
struct GroupConf {
    let key: String
    let name: String
    let desc: String
    let rule: String
    let accent: String
    let direct: Int
    let playin: Int
    let out: Int
    let teams: [String]

    var advanceDict: [String: Any] { ["direct": direct, "playin": playin, "out": out] }
}

let kplGroups: [GroupConf] = [
    GroupConf(key: "masters", name: "大师组", desc: "年度积分 1-6 名",
              rule: "组内前 4 直接晋级淘汰赛，第 5-6 名进入突围赛",
              accent: "#f5c451", direct: 4, playin: 2, out: 0,
              teams: ["重庆狼队", "成都AG超玩会", "北京JDG", "广州TTG", "KSG", "北京WB"]),
    GroupConf(key: "elite", name: "精英组", desc: "年度积分 7-12 名",
              rule: "组内第 1 直接晋级淘汰赛，第 2-5 名进入突围赛，第 6 名淘汰",
              accent: "#9b6bff", direct: 1, playin: 4, out: 1,
              teams: ["长沙TES.A", "上海EDG.M", "杭州LGD.NBW", "深圳DYG", "济南RW侠", "南通Hero久竞"]),
]

enum Aggregator {

    // MARK: - 实时覆盖：官方源（第一优先）

    /// 实时源条目索引：主键「归一化队名 + 北京日期键」，兜底键「仅归一化队名」。
    ///
    /// 年度总决赛这类赛制里同一对战队会在不同阶段多次交手（如 重庆狼队 vs 深圳DYG
    /// 既有 10-16 擂台赛也有 10-20 突围赛）。早期版本只按队名建索引，后写入的
    /// 10-20 突围赛条目会覆盖 10-16 擂台赛条目，于是看板把 10-16 那场的
    /// 3:1 当成 10-20 这场的结果，出现「16 号的比赛数据冒充进行中比赛」。
    private static func index(_ state: RealtimeState) -> (byDay: [String: RealtimeEntry], byTeam: [String: RealtimeEntry]) {
        var byDay: [String: RealtimeEntry] = [:]
        var byTeam: [String: RealtimeEntry] = [:]
        for r in state.list {
            guard let a = r.cnA, let b = r.cnB else { continue }
            let teams = "\(normName(a))|\(normName(b))"
            if !r.dateKey.isEmpty {
                // 同一天同一对阵出现多条时保留状态最新的那条（completed 视为 live 的终态）。
                // 注意：第一次插入时 old 为 nil，必须无条件写入，否则 byDay 会永远是空的。
                let key = "\(teams)@\(r.dateKey)"
                if let old = byDay[key], rank(r.status) <= rank(old.status) { } else {
                    byDay[key] = r
                }
            }
            // 上游偶发缺日期字段时仍要能配准，故保留纯队名兜底索引
            byTeam[teams] = r
        }
        return (byDay, byTeam)
    }

    /// 状态新鲜度：数字越大信息越新（completed 视为 live 的终态）
    private static func rank(_ s: String) -> Int {
        switch s {
        case "scheduled": return 0
        case "live": return 1
        default: return 2
        }
    }

    /// 从索引里取某场比赛的实时条目；返回 (条目, 是否需要交换左右)。
    /// 先按「队名 + 日期」精确匹配，实时源缺日期时才退回「仅队名」。
    private static func lookup(
        _ a: String, _ b: String, date: String,
        byDay: [String: RealtimeEntry], byTeam: [String: RealtimeEntry]
    ) -> (RealtimeEntry, Bool)? {
        let na = normName(a), nb = normName(b)
        if !date.isEmpty {
            if let r = byDay["\(na)|\(nb)@\(date)"] { return (r, false) }
            if let r = byDay["\(nb)|\(na)@\(date)"] { return (r, true) }
        }
        if let r = byTeam["\(na)|\(nb)"] { return (r, false) }
        if let r = byTeam["\(nb)|\(na)"] { return (r, true) }
        return nil
    }

    /// 用官方源覆盖大比分与状态；命中打 officialScore，返回匹配场次
    @discardableResult
    static func applyOfficial(_ matches: inout [KBMatch], state: RealtimeState) -> Int {
        var matched = 0
        guard state.ok, !state.list.isEmpty else { return 0 }

        let idx = index(state)

        for i in matches.indices {
            let m = matches[i]
            guard !m.a.name.isEmpty, !m.b.name.isEmpty else { continue }
            guard let (rr, swap) = lookup(m.a.name, m.b.name, date: m.date, byDay: idx.byDay, byTeam: idx.byTeam) else { continue }

            let playable = rr.status == "live" || rr.status == "completed"
            if playable {
                matches[i].a.score = swap ? rr.scoreB : rr.scoreA
                matches[i].b.score = swap ? rr.scoreA : rr.scoreB
            }
            if rr.status == "completed" {
                matches[i].over = true
                matches[i].liveFlag = false
            } else if rr.status == "live" {
                matches[i].over = false
                matches[i].liveFlag = true
                // 上游偶发状态滞后（已到赛点仍报 live）：BO 制拿到所需胜局即视为结束
                let need = rr.bestOf > 0 ? Int(ceil(Double(rr.bestOf) / 2.0)) : 0
                if need > 0 && max(matches[i].a.score, matches[i].b.score) >= need {
                    matches[i].over = true
                    matches[i].liveFlag = false
                }
            }
            matches[i].realtime = true
            // officialScore 只在「可结算」（live/completed）时置位：scheduled（未开始）
            // 时即便官方源没有实时数据也不该屏蔽 PandaScore 的兜底覆盖。
            if playable { matches[i].officialScore = true }
            matched += 1
        }
        return matched
    }

    // MARK: - 实时覆盖：PandaScore（补充逐小局 + 官方未覆盖时兜底）

    @discardableResult
    static func applyRealtime(_ matches: inout [KBMatch], state: RealtimeState) -> Int {
        var matched = 0
        guard state.ok, !state.list.isEmpty else { return 0 }

        let idx = index(state)

        for i in matches.indices {
            let m = matches[i]
            guard !m.a.name.isEmpty, !m.b.name.isEmpty else { continue }
            guard let (rr, swap) = lookup(m.a.name, m.b.name, date: m.date, byDay: idx.byDay, byTeam: idx.byTeam) else { continue }

            // 官方源已给出大比分/状态 → 只补逐小局，不覆盖大比分与状态
            let playable = rr.status == "live" || rr.status == "completed"
            if playable && !matches[i].officialScore {
                matches[i].a.score = swap ? rr.scoreB : rr.scoreA
                matches[i].b.score = swap ? rr.scoreA : rr.scoreB
            }

            if !rr.legs.isEmpty {
                var legs = rr.legs
                if swap {
                    legs = legs.map { x -> String? in
                        guard let v = x else { return nil }
                        return v == "A" ? "B" : "A"
                    }
                }
                let remoteCount = legs.compactMap { $0 }.count
                let localCount = matches[i].legs.compactMap { $0 }.count
                if remoteCount >= localCount { // 信息不倒退
                    matches[i].legs = legs
                    // 上游大比分常滞后于逐小局：用逐小局推导比分校正，保证卡片上下一致。
                    // 但若官方源已给出权威大比分，则尊重官方、不覆盖。
                    if !matches[i].officialScore {
                        let dA = legs.filter { $0 == "A" }.count
                        let dB = legs.filter { $0 == "B" }.count
                        if dA + dB > matches[i].a.score + matches[i].b.score {
                            matches[i].a.score = dA
                            matches[i].b.score = dB
                            matches[i].scoreFromLegs = true
                            // 比分被小局推正后，状态必须跟着重判：
                            // 官方 list 接口更新慢时会给「已 3:1 但状态仍 live」的滞后数据，
                            // 若不在这里补判，比赛打完了卡片却一直显示 LIVE。
                            let need = rr.bestOf > 0 ? Int(ceil(Double(rr.bestOf) / 2.0)) : 0
                            if need > 0 && max(dA, dB) >= need {
                                matches[i].over = true
                                matches[i].liveFlag = false
                            }
                        }
                    }
                }
            }

            if !matches[i].officialScore {
                if rr.status == "completed" {
                    matches[i].over = true
                    matches[i].liveFlag = false
                } else if rr.status == "live" {
                    matches[i].over = false
                    matches[i].liveFlag = true
                    let need = rr.bestOf > 0 ? Int(ceil(Double(rr.bestOf) / 2.0)) : 0
                    if need > 0 && max(matches[i].a.score, matches[i].b.score) >= need {
                        matches[i].over = true
                        matches[i].liveFlag = false
                    }
                }
            }
            matches[i].realtime = true
            matched += 1
        }
        return matched
    }

    // MARK: - 状态推断

    /// 对应 server.js decorate()。就地填充 status / isToday / playedLegs / winner。
    static func decorate(_ matches: inout [KBMatch]) -> Int {
        let t = KPLTime.todayKey()
        let nowMin = KPLTime.nowMinutes()
        for i in matches.indices {
            var status = "upcoming"
            if matches[i].over {
                status = "finished"
            } else if matches[i].liveFlag {
                status = "live"
            } else {
                let parts = matches[i].time.split(separator: ":").map { Int($0) ?? 0 }
                let hh = parts.first ?? 0
                let mm = parts.count > 1 ? parts[1] : 0
                // 缺少 date / time 时**不要**靠时间推断：
                // · date 为空时 `"" < t` 恒真 → 被判成 finished，0-0 的比赛
                //   也会被计入积分榜（与 buildStandings 联动出脏数据）；
                // · time 为空时 hh/mm 都解析成 0 → `nowMin >= 0` 恒真 →
                //   当天任何无时间的比赛都被标成「进行中」。
                // 两种情况都保留 upcoming，等上游给出明确状态。
                let d = matches[i].date
                if d.count == 8, !matches[i].time.isEmpty {
                    if d < t {
                        status = "finished"
                    } else if d == t && nowMin >= hh * 60 + mm {
                        status = "live"
                    }
                }
                // date/time 缺失时保持 upcoming，不做时间推断
            }
            matches[i].status = status
            matches[i].isToday = matches[i].date == t
            matches[i].playedLegs = matches[i].legs.compactMap { $0 }.count
            if status == "finished" && matches[i].a.score != matches[i].b.score {
                matches[i].winner = matches[i].a.score > matches[i].b.score ? "A" : "B"
            } else {
                matches[i].winner = nil
            }
        }
        return matches.reduce(0) { $0 + ($1.realtime ? 1 : 0) }
    }

    // MARK: - 积分榜

    private struct Row {
        var id: String
        var name: String
        var icon: String
        var matches = 0
        var wins = 0
        var losses = 0
        var gameWins = 0
        var gameLosses = 0
        var points = 0
        var form: [[String: Any]] = []
        var opponents: Set<String> = []
        var rank = 0
        var adv: String? = nil
        var groupKey: String? = nil

        var net: Int { gameWins - gameLosses }
    }

    private static func sortRows(_ rows: inout [Row]) {
        let zh = Locale(identifier: "zh_CN")
        rows.sort { x, y in
            if x.points != y.points { return x.points > y.points }
            if x.net != y.net { return x.net > y.net }
            if x.gameWins != y.gameWins { return x.gameWins > y.gameWins }
            if x.gameLosses != y.gameLosses { return x.gameLosses < y.gameLosses }
            return x.name.compare(y.name, locale: zh) == .orderedAscending
        }
        for i in rows.indices { rows[i].rank = i + 1 }
    }

    private static func round3(_ x: Double) -> Double {
        (x * 1000).rounded() / 1000
    }

    private static func rowDict(_ r: Row) -> [String: Any] {
        var d: [String: Any] = [
            "id": r.id, "name": r.name, "icon": r.icon,
            "matches": r.matches, "wins": r.wins, "losses": r.losses,
            "gameWins": r.gameWins, "gameLosses": r.gameLosses,
            "net": r.net, "points": r.points,
            "winRate": r.matches > 0 ? round3(Double(r.wins) / Double(r.matches)) : 0,
            "gameRate": (r.gameWins + r.gameLosses) > 0
                ? round3(Double(r.gameWins) / Double(r.gameWins + r.gameLosses)) : 0,
            "form": Array(r.form.suffix(6)),
            "opponents": Array(r.opponents),
            "rank": r.rank,
            "groupKey": r.groupKey as Any,
        ]
        if let adv = r.adv { d["adv"] = adv }
        return d
    }

    private static func groupKeyOf(_ name: String) -> String? {
        let n = normName(name)
        if n.isEmpty { return nil }
        var map: [String: String] = [:]
        for g in kplGroups { for t in g.teams { map[normName(t)] = g.key } }
        if let v = map[n] { return v }
        for (k, key) in map where k.contains(n) || n.contains(k) { return key }
        return nil
    }

    private static func buildStandings(_ matches: [KBMatch]) -> [Row] {
        var table: [String: Row] = [:]
        /// 队伍键：id 为空时回退到 name。
        /// 根因：WanplusSource 在队标正则匹配不到时 id 会是空串 ""，
        /// 所有无 id 的队伍会塌缩成同一个键 → 积分榜变成唯一一行垃圾数据；
        /// 且 A/B 同键时 `table[A.id] = A` 随后被 `table[B.id] = B` 覆盖，
        /// 导致 matches 只加 1、胜负与积分写反。
        func key(of team: TeamSide) -> String {
            team.id.isEmpty ? "name:\(team.name)" : team.id
        }
        func ensure(_ team: TeamSide) -> Row {
            let k = key(of: team)
            if table[k] == nil {
                table[k] = Row(id: team.id, name: team.name, icon: team.icon)
            }
            return table[k]!
        }

        for m in matches {
            // 跳过未定对阵：WanplusSource.normalize 把空名字兜底成「待定」，
            // 所以 `!name.isEmpty` 永远为真、形同虚设，必须显式排除「待定」。
            guard m.status == "finished",
                  !m.a.name.isEmpty, !m.b.name.isEmpty,
                  m.a.name != "待定", m.b.name != "待定",
                  m.a.name != m.b.name else { continue }
            var A = ensure(m.a)
            var B = ensure(m.b)
            A.matches += 1; B.matches += 1
            A.opponents.insert(B.name); B.opponents.insert(A.name)
            A.gameWins += m.a.score; A.gameLosses += m.b.score
            B.gameWins += m.b.score; B.gameLosses += m.a.score
            if m.a.score > m.b.score {
                A.wins += 1; B.losses += 1; A.points += 1
                A.form.append(["r": "W", "vs": B.name, "score": "\(m.a.score)-\(m.b.score)"])
                B.form.append(["r": "L", "vs": A.name, "score": "\(m.b.score)-\(m.a.score)"])
            } else if m.b.score > m.a.score {
                B.wins += 1; A.losses += 1; B.points += 1
                A.form.append(["r": "L", "vs": B.name, "score": "\(m.a.score)-\(m.b.score)"])
                B.form.append(["r": "W", "vs": A.name, "score": "\(m.b.score)-\(m.a.score)"])
            } else {
                A.form.append(["r": "D", "vs": B.name, "score": "\(m.a.score)-\(m.b.score)"])
                B.form.append(["r": "D", "vs": A.name, "score": "\(m.b.score)-\(m.a.score)"])
            }
            // 写回必须用同一个 key，否则 ensure 与写回键不一致会产生幽灵行
            table[key(of: m.a)] = A
            table[key(of: m.b)] = B
        }
        return Array(table.values)
    }

    /// 统一返回 { mode, groups, ungrouped }
    static func buildGroupedStandings(_ matches: [KBMatch], ev: KBEvent?) -> [String: Any] {
        let rows = buildStandings(matches)

        if ev?.grouped != true {
            var inner = rows
            sortRows(&inner)
            inner = inner.map { r in
                var c = r
                c.groupKey = groupKeyOf(r.name)
                return c
            }
            return [
                "mode": "flat",
                "groups": [[
                    "key": "all", "name": "战队战绩榜",
                    "desc": "共 \(rows.count) 支战队 · 按积分 → 净胜小局排序",
                    "rule": "", "accent": "#f5c451",
                    "rows": inner.map(rowDict),
                ]],
                "ungrouped": [],
            ]
        }

        var used = Set<String>()
        let groups: [[String: Any]] = kplGroups.map { g in
            let set = Set(g.teams.map(normName))
            var inner = rows.filter { set.contains(normName($0.name)) || groupKeyOf($0.name) == g.key }
            inner.forEach { used.insert($0.id) }
            sortRows(&inner)
            inner = inner.map { r in
                var c = r
                let direct = g.direct
                let playin = g.playin
                c.adv = c.rank <= direct ? "direct" : (c.rank <= direct + playin ? "playin" : "out")
                c.groupKey = g.key
                return c
            }
            return [
                "key": g.key, "name": g.name, "desc": g.desc, "rule": g.rule,
                "accent": g.accent, "advance": g.advanceDict,
                "rows": inner.map(rowDict),
            ]
        }

        let ungrouped = rows.filter { !used.contains($0.id) }.map { r -> [String: Any] in
            var d = rowDict(r)
            d["adv"] = NSNull()
            return d
        }
        return ["mode": "grouped", "groups": groups, "ungrouped": ungrouped]
    }

    // MARK: - 概览

    static func buildSummary(_ matches: [KBMatch]) -> [String: Any] {
        let t = KPLTime.todayKey()
        let finished = matches.filter { $0.status == "finished" }
        let live = matches.filter { $0.status == "live" }
        let upcoming = matches.filter { $0.status == "upcoming" }
        let today = matches.filter { $0.date == t }
        let totalGames = finished.reduce(0) { $0 + $1.a.score + $1.b.score }
        let bo = matches.first(where: { $0.bo > 0 })?.bo ?? WanplusSource.inferBo(matches)
        let need = Int(ceil(Double(bo) / 2.0))
        return [
            "totalMatches": matches.count,
            "finished": finished.count,
            "live": live.count,
            "upcoming": upcoming.count,
            "todayTotal": today.count,
            "todayDone": today.filter { $0.status == "finished" }.count,
            "totalGames": totalGames,
            // server.js: +(totalGames / finished.length).toFixed(2)
            "avgGames": finished.isEmpty ? 0 : (Double(totalGames) / Double(finished.count) * 100).rounded() / 100,
            "bo": bo,
            "decidingGames": finished.filter { $0.a.score + $0.b.score == bo }.count,
            "sweep": finished.filter { min($0.a.score, $0.b.score) == 0 && max($0.a.score, $0.b.score) >= need }.count,
        ]
    }

    static func collectStages(_ matches: [KBMatch]) -> [[String: Any]] {
        var counts: [(String, Int)] = []
        var map: [String: Int] = [:]
        var order: [String] = []
        for m in matches where !m.stage.isEmpty {
            if map[m.stage] == nil { order.append(m.stage) }
            map[m.stage, default: 0] += 1
        }
        for s in order { counts.append((s, map[s] ?? 0)) }
        return counts.map { ["name": $0.0, "count": $0.1] }
    }
}

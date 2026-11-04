import Foundation

/// 赛季数据仓储 + 看板组装。对应 server.js 的 store / refreshEvent / boardOf。
/// 用 actor 保证多线程（WebView 回调线程各异）下的状态安全。
actor BoardStore {
    static let shared = BoardStore()

    struct Record {
        var matches: [KBMatch] = []
        var updatedAt: TimeInterval = 0
        var error: String? = nil
    }

    // MARK: - 配置（与 server.js 默认一致）

    /// 单位统一为**毫秒**：`ttlOf` 的返回值在使用处（stale 计算）会 `/1000` 转成秒。
    /// 此前 `archiveTTL` 写成秒（365*24*3600），/1000 后只剩 31 536 秒 ≈ 26 小时，
    /// 导致历史赛事隔天就被误判为「数据已过期」——而历史数据本身永不变化。
    private let pollMs: TimeInterval = 20_000        // 进行中赛季刷新间隔
    private let historyMs: TimeInterval = 600_000    // 已结束赛季缓存时长
    private let rtTTL: TimeInterval = 20_000         // 实时通道 TTL（毫秒）
    private let archiveTTL: TimeInterval = 365 * 24 * 3600 * 1000

    private var events: [KBEvent] = []
    private var store: [String: Record] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// 赛事最近一次刷新失败的时间戳（用于失败冷却，避免每次 board() 都同步重拉）
    private var lastFailAt: [String: TimeInterval] = [:]
    /// 玩加 live 赛程最近一次成功拉取的时间戳（board(force) 的 10s 去重窗口）
    private var lastWpPullAt: [String: TimeInterval] = [:]

    private var kplState = RealtimeState()   // 官方通道
    private var rtState = RealtimeState()    // PandaScore 通道

    // MARK: - 初始化

    func bootstrap() {
        events = loadEvents()
        primeCache()
    }

    private func loadEvents() -> [KBEvent] {
        guard let url = Bundle.main.url(forResource: "events", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["events"] as? [[String: Any]],
              let json = try? JSONSerialization.data(withJSONObject: arr) else {
            return []
        }
        return (try? JSONDecoder().decode([KBEvent].self, from: json)) ?? []
    }

    var allEvents: [KBEvent] { events }

    func event(by id: String?) -> KBEvent? {
        if let id, let hit = events.first(where: { $0.id == id }) { return hit }
        return events.first(where: { $0.isActive() }) ?? events.first
    }

    func activeEvent() -> KBEvent? { events.first { $0.isActive() } }

    // MARK: - 磁盘缓存

    private var cacheDir: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir = base?.appendingPathComponent("KPLBoard/data", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func primeCache() {
        guard let dir = cacheDir else { return }
        var n = 0
        for ev in events {
            let f = dir.appendingPathComponent("\(ev.id).json")
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["matches"] as? [[String: Any]], !arr.isEmpty else { continue }
            store[ev.id] = Record(matches: decodeMatches(arr),
                                  updatedAt: (obj["updatedAt"] as? NSNumber)?.doubleValue ?? 0)
            n += 1
        }
        if n > 0 { print("[KPL] 已从磁盘缓存恢复 \(n) 个赛季") }
    }

    private func saveCache(_ id: String, _ rec: Record) {
        guard let dir = cacheDir else { return }
        let obj: [String: Any] = ["matches": rec.matches.map { $0.dict }, "updatedAt": rec.updatedAt]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        // .atomic：iPad 多窗口 + 轮询下同一赛季文件可能被并发写入，
        // 非原子写入交错会产出损坏 JSON（下次 primeCache 静默解析失败）
        try? data.write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
    }

    /// 从缓存 JSON 还原 Match（只需还原持久字段，decorate 字段运行时重算）
    private func decodeMatches(_ arr: [[String: Any]]) -> [KBMatch] {
        arr.map { d in
            func side(_ k: String) -> TeamSide {
                let s = d[k] as? [String: Any] ?? [:]
                return TeamSide(id: s.str("id"), name: s.str("name"), icon: s.str("icon"), score: s.num("score"))
            }
            return KBMatch(
                id: d.str("id"), date: d.str("date"), dateLabel: d.str("dateLabel"),
                time: d.str("time"), stage: d.str("stage"), bo: d.num("bo"),
                over: d.boolish("over"), liveFlag: d.boolish("liveFlag"), hasVideo: d.boolish("hasVideo"),
                a: side("a"), b: side("b"),
                legs: (d["legs"] as? [Any] ?? []).map { $0 as? String }
            )
        }
    }

    // MARK: - 刷新

    private func ttlOf(_ ev: KBEvent) -> TimeInterval {
        if ev.mode == "archive" { return archiveTTL }
        return ev.isActive() ? pollMs : historyMs
    }

    /// 刷新某赛事。wait=true 时等待完成，否则后台执行。
    func refresh(_ ev: KBEvent, wait: Bool) async {
        if let t = inFlight[ev.id] {
            if wait { await t.value }
            return
        }
        let task = Task { await performRefresh(ev) }
        inFlight[ev.id] = task
        if wait { await task.value }
    }

    private func performRefresh(_ ev: KBEvent) async {
        defer { inFlight[ev.id] = nil }
        var rec = store[ev.id] ?? Record()
        do {
            var matches: [KBMatch]
            if ev.mode == "archive" {
                matches = try await WanplusSource.fetchArchiveEvent(ev)
                let bo = WanplusSource.inferBo(matches)
                for i in matches.indices { matches[i].bo = bo }
            } else {
                matches = try await WanplusSource.fetchLiveEvent(ev)
            }
            WanplusSource.sortMatches(&matches)
            if !matches.isEmpty {
                rec.matches = matches
                rec.updatedAt = Date().timeIntervalSince1970
                rec.error = nil
                lastFailAt.removeValue(forKey: ev.id)
                lastWpPullAt[ev.id] = Date().timeIntervalSince1970
                store[ev.id] = rec
                saveCache(ev.id, rec)
            } else if rec.matches.isEmpty {
                rec.error = rec.error ?? "未获取到赛程数据"
                store[ev.id] = rec
            }
        } catch {
            rec.error = error.localizedDescription
            store[ev.id] = rec
            lastFailAt[ev.id] = Date().timeIntervalSince1970
        }
    }

    // MARK: - 实时通道

    private func refreshOfficial() async {
        if Date().timeIntervalSince1970 - kplState.at < rtTTL, kplState.at > 0 { return }
        do {
            let list = try await KPLOfficialSource.fetch()
            kplState.list = list
            kplState.ok = true
            kplState.error = nil
            kplState.updatedAt = Date().timeIntervalSince1970
            kplState.seen = list.count
        } catch {
            kplState.ok = false
            kplState.error = error.localizedDescription
            if kplState.updatedAt == 0 { kplState.updatedAt = Date().timeIntervalSince1970 }
        }
        kplState.at = Date().timeIntervalSince1970
    }

    private func refreshPanda() async {
        if Date().timeIntervalSince1970 - rtState.at < rtTTL, rtState.at > 0 { return }
        do {
            let list = try await PandaScoreSource.fetch(dateKey: KPLTime.bjDateKey())
            rtState.list = list
            rtState.ok = true
            rtState.error = nil
            rtState.updatedAt = Date().timeIntervalSince1970
            rtState.seen = list.count
        } catch {
            rtState.ok = false
            rtState.error = error.localizedDescription
            if rtState.updatedAt == 0 { rtState.updatedAt = Date().timeIntervalSince1970 }
        }
        rtState.at = Date().timeIntervalSince1970
    }

    /// 与 server.js /api/board 一致：首次请求同步等待（最多 6s），之后后台刷新。
    /// `force=true`（用户手动刷新）：两条实时通道**无视 20s TTL 立即重打上游**，
    /// 并且都等完成（各自请求自带 12s 超时兜底）——比赛刚打完时点刷新必须
    /// 马上看到最终比分，而不是等下一个轮询周期；也不取消任何一条通道，
    /// 避免把正在成功的通道打成 error 态。
    func ensureRealtimeChannels(force: Bool = false) async {
        if force {
            // 清掉两个通道的去重时间戳，让 refreshOfficial/Panda 的 TTL 检查放行
            kplState.at = 0
            rtState.at = 0
            // 两条通道并发、全部等完（不 cancelAll：取消会让 catch 把成功通道标成失败）
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.refreshOfficial() }
                group.addTask { await self.refreshPanda() }
                await group.waitForAll()
            }
            return
        }
        // `first` 用「上次成功时间」判定：官方通道成功后 rtState.at 会被写入，
        // 不再每次都进等待分支（此前因 at 恒为 0 导致每轮都白等）。
        let first = kplState.at == 0 || rtState.at == 0
        if first {
            // 关键：刷新的两个任务必须是 TaskGroup **自己的子任务**。
            // 此前在外层用 Task 创建再 `await a.value` 作为子任务挂起，
            // `cancelAll()` 只能取消 group 的子任务、无法取消外层的 a/b，
            // 结果 6s 上限形同虚设（要等两者各自 12s 超时跑完）。
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.refreshOfficial() }
                group.addTask { await self.refreshPanda() }
                group.addTask { try? await Task.sleep(nanoseconds: 6_000_000_000) }
                _ = await group.next()      // 任一完成（含 6s 超时）即继续
                group.cancelAll()           // 现在才能真正取消未完成的刷新
            }
        } else {
            async let a: Void = refreshOfficial()
            async let b: Void = refreshPanda()
            _ = await (a, b)
        }
    }

    // MARK: - 看板组装

    func board(eventId: String?, stage: String?, force: Bool = false) async -> [String: Any] {
        let ev = event(by: eventId)
        guard let ev else { return ["ok": false, "error": "无可用赛事"] }

        let active = ev.isActive()
        if active { await ensureRealtimeChannels(force: force) }

        // 手动刷新：玩加 live 赛程也重拉一次（isover 标志可能滞后于实时通道）。
        // 10s 去重窗口：防止用户连点刷新导致整周赛程被反复全量重下；
        // 时间戳在 performRefresh 成功路径里写，失败不占用窗口。
        if force, ev.mode == "live",
           Date().timeIntervalSince1970 - (lastWpPullAt[ev.id] ?? 0) > 10 {
            await refresh(ev, wait: true)
        }

        let rec = store[ev.id]
        // 失败冷却：失败后 matches 仍为空，若不设冷却，之后每次 board() 都会
        // 走 `wait: true` 同步全量重拉（按周串行 N 个请求）→ 弱网下每进一次
        // 看板都卡十几秒。这里给失败加 30s 最短重试间隔。
        let failedRecently = rec.map { $0.error != nil &&
            Date().timeIntervalSince1970 - lastFailAt[ev.id, default: 0] < 30 } ?? false
        if (rec == nil || rec?.matches.isEmpty == true) && !failedRecently {
            await refresh(ev, wait: true)
        } else if active, let r = rec, Date().timeIntervalSince1970 - r.updatedAt > ttlOf(ev) / 1000 {
            Task { await self.refresh(ev, wait: false) }
        }

        let base = store[ev.id] ?? Record()
        var src = base.matches                     // 复制，避免污染缓存
        var kMatched = 0, rMatched = 0
        if active {
            kMatched = Aggregator.applyOfficial(&src, state: kplState)
            rMatched = Aggregator.applyRealtime(&src, state: rtState)
        }
        kplState.matched = kMatched
        rtState.matched = rMatched
        let rtCount = Aggregator.decorate(&src)

        let filtered = (stage?.isEmpty == false) ? src.filter { $0.stage == stage } : src

        var board: [String: Any] = [
            "ok": true,
            "serverTime": Int(Date().timeIntervalSince1970 * 1000),
            "event": eventDict(ev),
            "stage": stage ?? "",
            "stages": Aggregator.collectStages(src),
            "summary": Aggregator.buildSummary(filtered),
            "standings": Aggregator.buildGroupedStandings(filtered, ev: ev),
            "matches": filtered.map { $0.dict },
            "updatedAt": Int(base.updatedAt * 1000),
            "error": base.error as Any,
            "stale": (Date().timeIntervalSince1970 - base.updatedAt) > ttlOf(ev) / 1000 * 3,
        ]
        if active {
            board["realtime"] = [
                "enabled": true,
                "ok": kplState.ok || rtState.ok,
                "source": "KPL官方 · PandaScore",
                "updatedAt": Int(max(kplState.updatedAt, rtState.updatedAt) * 1000),
                "matched": rtCount,
                "officialMatched": kplState.matched,
                "seen": kplState.seen,
                "error": kplState.ok ? NSNull() : (kplState.error as Any),
            ]
        } else {
            board["realtime"] = NSNull()
        }
        return board
    }

    func eventDict(_ ev: KBEvent) -> [String: Any] {
        ["id": ev.id, "name": ev.name, "short": ev.short ?? ev.name,
         "year": ev.year ?? 0, "category": ev.category ?? "", "mode": ev.mode,
         "start": ev.start ?? "", "end": ev.end ?? "",
         "grouped": ev.grouped ?? false, "active": ev.isActive()]
    }

    /// /api/events
    func eventsPayload() -> [String: Any] {
        let list = events.map { ev -> [String: Any] in
            let rec = store[ev.id]
            return [
                "id": ev.id, "name": ev.name, "short": ev.short ?? ev.name,
                "year": ev.year ?? 0, "category": ev.category ?? "", "mode": ev.mode,
                "start": ev.start ?? "", "end": ev.end ?? "", "grouped": ev.grouped ?? false,
                "active": ev.isActive(),
                "loaded": rec?.matches.isEmpty == false,
                "matchCount": rec?.matches.count ?? 0,
                "updatedAt": Int((rec?.updatedAt ?? 0) * 1000),
            ]
        }
        return ["ok": true, "events": list, "defaultId": event(by: nil)?.id ?? ""]
    }

    /// /api/health
    func healthPayload() async -> [String: Any] {
        // 让健康检查也反映两条实时通道的真实状态（TTL 缓存，不会每次都打接口）
        if activeEvent() != nil { await ensureRealtimeChannels() }
        let info = events.filter { store[$0.id] != nil }.map { ev -> [String: Any] in
            let rec = store[ev.id]!
            return ["id": ev.id, "name": ev.name, "count": rec.matches.count,
                    "updatedAt": Int(rec.updatedAt * 1000), "error": rec.error as Any]
        }
        let active = activeEvent()
        let officialDict: [String: Any] = [
            "enabled": true, "source": KPLOfficialSource.endpoint,
            "ok": kplState.ok, "updatedAt": Int(kplState.updatedAt * 1000),
            "matched": kplState.matched, "seen": kplState.seen,
            "error": kplState.error as Any,
        ]
        let pandaDict: [String: Any] = [
            "enabled": true, "source": PandaScoreSource.endpoint,
            "ok": rtState.ok, "updatedAt": Int(rtState.updatedAt * 1000),
            "matched": rtState.matched, "error": rtState.error as Any,
        ]
        let activeDict: Any = active == nil ? NSNull() : ["id": active!.id, "name": active!.name]
        let rtDict: [String: Any] = [
            "enabled": true,
            "activeEvent": activeDict,
            "official": officialDict,
            "pandascore": pandaDict,
        ]
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let out: [String: Any] = [
            "ok": true,
            "version": version,
            "total": events.count,
            "cached": info.count,
            "events": info,
            "realtime": rtDict,
        ]
        return out
    }

    func refreshAll() async {
        for ev in events where ev.mode == "live" {
            await refresh(ev, wait: false)
        }
    }

    /// 读取某赛事的当前缓存记录（供 /api/refresh 返回最新 updatedAt）
    func cachedRecord(of eventId: String) -> Record? {
        store[eventId]
    }
}

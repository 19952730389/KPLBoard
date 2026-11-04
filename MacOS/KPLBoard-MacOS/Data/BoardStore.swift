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

    private let pollMs: TimeInterval = 20_000          // 进行中赛季刷新间隔（毫秒）
    private let historyMs: TimeInterval = 600_000      // 已结束赛季缓存时长（毫秒）
    private let rtTTL: TimeInterval = 20               // 实时通道 TTL（秒）
    // 归档赛季缓存时长（毫秒）。注意：与上面两个常量一样按毫秒声明，
    // 下方 ttlSeconds(of:) 统一换算成秒使用。原值误写成了「秒」(365*24*3600)，
    // 走了 /1000 后实际只剩 ~8.76 小时而非一年，导致历史赛事被反复重抓。
    private let archiveTTL: TimeInterval = 365 * 24 * 3600 * 1000

    private var events: [KBEvent] = []
    private var store: [String: Record] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]

    private var kplState = RealtimeState()   // 官方通道
    private var rtState = RealtimeState()    // PandaScore 通道

    // MARK: - 初始化

    /// 是否已 bootstrap。WKWebView 在 makeNSView 里就开始加载页面，
    /// 而 bootstrap() 在 RootView.task 里才执行 —— 早期进来的 /api/events
    /// 请求会拿到空列表、defaultId 为空，前端将停在「连接中」。
    private var bootstrapped = false

    /// 保证只跑一次且线程安全：所有 API 路由先 await 这个再取数据。
    func ensureBootstrapped() async {
        if bootstrapped { return }
        bootstrap()
    }

    func bootstrap() {
        events = loadEvents()
        primeCache()
        bootstrapped = true
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
        guard let dir = base?.appendingPathComponent("KPLBoard-MacOS/data", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 旧版缓存目录名为 KPLBoard/data，与 ToolsCache 的 KPLBoard-MacOS/tools 不一致。
    /// 升级时把旧赛季缓存平移到新目录，避免首启重新联网抓取所有赛季。
    private func migrateLegacyCacheIfNeeded() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let legacy = base?.appendingPathComponent("KPLBoard/data", isDirectory: true),
              let dir = cacheDir,
              (try? FileManager.default.contentsOfDirectory(atPath: legacy.path)) != nil else { return }
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(atPath: legacy.path)) ?? [] where f.hasSuffix(".json") {
            let from = legacy.appendingPathComponent(f)
            let to = dir.appendingPathComponent(f)
            if (try? to.checkResourceIsReachable()) != true {
                try? fm.moveItem(at: from, to: to)
            }
        }
    }

    private func primeCache() {
        migrateLegacyCacheIfNeeded()
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
        try? data.write(to: dir.appendingPathComponent("\(id).json"))
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

    /// 把毫秒 TTL 换算成秒（统一口径，避免散落的 /1000 各处不一致）。
    private func ttlSeconds(_ ev: KBEvent) -> TimeInterval {
        ttlOf(ev) / 1000
    }

    /// 刷新某赛事。wait=true 时等待完成，否则后台执行。
    func refresh(_ ev: KBEvent, wait: Bool) async {
        await ensureBootstrapped()
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
                store[ev.id] = rec
                saveCache(ev.id, rec)
            } else if rec.matches.isEmpty {
                rec.error = rec.error ?? "未获取到赛程数据"
                store[ev.id] = rec
            }
        } catch {
            rec.error = error.localizedDescription
            store[ev.id] = rec
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

    /// 与 server.js /api/board 一致：首次请求同步等待（最多 6s），之后后台刷新
    func ensureRealtimeChannels() async {
        let first = kplState.at == 0 || rtState.at == 0
        let a = Task { await self.refreshOfficial() }
        let b = Task { await self.refreshPanda() }
        if first {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await a.value }
                group.addTask { await b.value }
                group.addTask { try? await Task.sleep(nanoseconds: 6_000_000_000) }
                _ = await group.next()
                group.cancelAll()
            }
        } else {
            await a.value
            await b.value
        }
    }

    // MARK: - 看板组装

    func board(eventId: String?, stage: String?) async -> [String: Any] {
        await ensureBootstrapped()
        let ev = event(by: eventId)
        guard let ev else { return ["ok": false, "error": "无可用赛事"] }

        let active = ev.isActive()
        if active { await ensureRealtimeChannels() }

        let rec = store[ev.id]
        if rec == nil || rec?.matches.isEmpty == true {
            await refresh(ev, wait: true)
        } else if active, let r = rec, Date().timeIntervalSince1970 - r.updatedAt > ttlSeconds(ev) {
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
            "stale": (Date().timeIntervalSince1970 - base.updatedAt) > ttlSeconds(ev) * 3,
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
    func eventsPayload() async -> [String: Any] {
        await ensureBootstrapped()
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
        await ensureBootstrapped()
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
}

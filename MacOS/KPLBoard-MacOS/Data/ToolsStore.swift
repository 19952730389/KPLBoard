import Foundation

/// KPL 工具箱 · 数据源（Swift 版）。逐行移植自桌面版 tools-sources.js。
///
/// 两条数据通道，与桌面版一致：
///   - **官方**（pvp.qq.com / game.gtimg.cn）：英雄库、装备库、铭文库、皮肤图鉴、英雄详情（GBK 页面）
///   - **玩加**（wanplus.cn）：选手 / 战队职业统计，需要 `_gtk` 签名会话（cookie + time33 + X-CSRF-Token）
///
/// 缓存语义严格对齐桌面版：可写目录（受 TTL）→ 种子目录（受 TTL）→ 忽略 TTL 兜底。
/// 种子目录随安装包分发 299 个 JSON（约 12 MB），保证断网时梯度榜 / 选手榜仍有内容。
actor ToolsStore {
    static let shared = ToolsStore()

    // MARK: - 常量

    private static let urlHeroList = "https://pvp.qq.com/web201605/js/herolist.json"
    private static let urlItemList = "https://pvp.qq.com/web201605/js/item.json"
    private static let urlSkinList = "https://pvp.qq.com/zlkdatasys/heroskinlist.json"
    private static let urlMingList = "https://pvp.qq.com/web201605/js/ming.json"

    private static let ttlHeroes: TimeInterval = 12 * 3600 * 1000
    private static let ttlSkins: TimeInterval = 6 * 3600 * 1000
    private static let ttlItems: TimeInterval = 12 * 3600 * 1000
    private static let ttlRunes: TimeInterval = 12 * 3600 * 1000
    private static let ttlHeroDetail: TimeInterval = 7 * 86400 * 1000
    private static let ttlItemIcons: TimeInterval = 30 * 86400 * 1000
    private static let ttlStats: TimeInterval = 10 * 60 * 1000

    private struct Pct { let num: Double; let text: String }

    // MARK: - 缓存辅助

    /// 缓存值是否有内容：空列表 / {list:[]} 视为「无值」。
    /// 旧版本曾把上游 0 行的空结果落盘（如 1.3.1 的 gradient-1201.json），
    /// 这类「投毒缓存」会永远遮蔽包内种子与官方通道，必须在读写两侧都拦掉。
    private func hasContent(_ v: Any?) -> Bool {
        guard let v else { return false }
        if let arr = v as? [Any] { return !arr.isEmpty }
        if let d = v as? [String: Any] {
            if let l = d["list"] as? [Any] { return !l.isEmpty }
            if let a = d["players"] as? [Any] { return !a.isEmpty }
        }
        return true
    }

    /// 先试网络；失败则回落到「已过期的缓存」，再失败才抛错
    private func withStaleFallback(_ name: String, _ builder: () async throws -> Any) async throws -> Any {
        do {
            let v = try await builder()
            // 空结果不落盘：落了会遮蔽种子/官方通道，形成永久空态
            if hasContent(v) { ToolsCache.set(name, v) }
            return v
        } catch {
            if let stale = ToolsCache.getAny(name), hasContent(stale) {
                if stale is [Any] { return stale }
                return stale
            }
            throw error
        }
    }

    /// 导出层统一套的「过期缓存兜底」：上游不可用返回上次成功的数据，而不是让页面空白
    private func staleSafe(_ name: String, _ fn: () async throws -> Any) async throws -> Any {
        do { return try await fn() }
        catch {
            if let stale = ToolsCache.getAny(name) { return stale }
            throw error
        }
    }

    // MARK: - HTML → 结构化行（铭文 / 装备属性）

    // MARK: - 官方：英雄库

    func heroes() async throws -> [[String: Any]] {
        if let c = ToolsCache.get("heroes.json", ttlMs: Self.ttlHeroes) as? [[String: Any]], !c.isEmpty { return c }
        let raw = try await Net.getJSONAny(Self.urlHeroList, timeout: 15)
        var out: [[String: Any]] = []
        for item in ToolsJSON.array(raw) {
            guard let h = item as? [String: Any] else { continue }
            let ename = ToolsUtil.str(h["ename"])
            let skins = ToolsUtil.str(h["skin_name"])
                .components(separatedBy: "|").filter { !$0.isEmpty }
            let typeName = ToolsDict.heroType[ToolsUtil.int(h["hero_type"])]
            let lanes = ToolsUtil.str(h["roles"])
                .components(separatedBy: "|")
                .compactMap { ToolsDict.lane[Int($0.trimmingCharacters(in: .whitespaces)) ?? 0] }
            // id 保留上游原类型（ename 是 number）。前端按 id 关联英雄与图标，
            // 转成字符串后类型不一致会让关联失败。
            var hero: [String: Any] = [
                "id": h["ename"] ?? ename,
                "name": ToolsUtil.str(h["cname"]),
                "title": ToolsUtil.str(h["title"]),
                "pinyin": ToolsUtil.str(h["id_name"]),
                "skinCount": skins.count,
                "icon": ToolsUtil.heroIconUrl(ename),
            ]
            hero["types"] = typeName.map { [$0] } ?? []
            hero["lanes"] = lanes
            hero["skins"] = skins.enumerated().map { i, n -> [String: Any] in
                ["name": n, "big": ToolsUtil.heroSkinUrl(ename, i + 1)]
            }
            out.append(hero)
        }
        // JS 此处是 localeCompare 不带 locale（pinyin 为 ASCII，两种比较结果一致）
        out = ToolsUtil.stableSorted(out) { ToolsUtil.cmp(ToolsUtil.str($0["pinyin"]), ToolsUtil.str($1["pinyin"])) }
        ToolsCache.set("heroes.json", out)
        return out
    }

    private func heroIndexByName() async throws -> [String: [String: Any]] {
        var m: [String: [String: Any]] = [:]
        for h in try await heroes() { m[ToolsUtil.str(h["name"])] = h }
        return m
    }

    private func heroIndexById() async throws -> [Int: [String: Any]] {
        var m: [Int: [String: Any]] = [:]
        for h in try await heroes() { m[ToolsUtil.int(h["id"])] = h }
        return m
    }

    // MARK: - 官方：皮肤图鉴

    func skinsCatalog() async throws -> [String: Any] {
        if let c = ToolsCache.get("skins.json", ttlMs: Self.ttlSkins) as? [String: Any],
           c["heroes"] != nil, c["types"] != nil { return c }

        let raw = try await Net.getJSONAny(Self.urlSkinList, timeout: 30)
        let obj = raw as? [String: Any] ?? [:]
        let rows = obj["pflb20_3469"] as? [Any] ?? []
        let heroRows = obj["yxlb20_2489"] as? [Any] ?? []

        // 官方英雄库（拿 ename 做原画回退 + 分路信息）
        let heroList = (try? await heroes()) ?? []
        var byName: [String: [String: Any]] = [:]
        for h in heroList {
            let n = ToolsUtil.str(h["name"])
            byName[n] = h
            byName[ToolsUtil.bare(n)] = h
        }
        func heroBasics(_ name: String) -> (types: [String], pinyin: String) {
            let h = byName[name] ?? byName[ToolsUtil.bare(name)]
            return ((h?["types"] as? [String]) ?? [], ToolsUtil.str(h?["pinyin"]))
        }

        // 英雄基础信息（皮肤图鉴自带，不依赖英雄库）
        var heroMeta: [String: [String: Any]] = [:]
        for item in heroRows {
            guard let h = item as? [String: Any] else { continue }
            let name = ToolsUtil.str(h["yxmclb_9965"]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            var id = ToolsUtil.str(h["yxid_a7"]).trimmingCharacters(in: .whitespaces)
            if id.isEmpty, let hit = byName[name] { id = ToolsUtil.str(hit["id"]) }
            let b = heroBasics(name)
            heroMeta[name] = [
                "name": name,
                "id": id,
                "lane": ToolsUtil.str(h["fllb_2105"]).trimmingCharacters(in: .whitespaces),
                "types": b.types,
                "pinyin": b.pinyin,
                "icon": ToolsUtil.str(h["yxtxlb_8443"]).replacingOccurrences(of: "\\/", with: "/"),
                "cover": ToolsUtil.str(h["fmb1lb_5300"] ?? h["fmlb_4536"]).replacingOccurrences(of: "\\/", with: "/"),
                "release": ToolsUtil.fmtDate(h["sxsjlb_1516"]),
                "intro": ToolsUtil.stripHtml(h["yjhjsl_5003"]),
            ]
        }

        var list: [[String: Any]] = []
        for item in rows {
            guard let r = item as? [String: Any] else { continue }
            let heroName = ToolsUtil.str(r["yxmclb_9965"]).trimmingCharacters(in: .whitespaces)
            let name = ToolsUtil.str(r["pfmclb_7523"]).trimmingCharacters(in: .whitespaces)
            if heroName.isEmpty || name.isEmpty { continue }

            let tagId = ToolsUtil.str(r["pfbqlb_1811"])
            let tag = ToolsDict.skinTag[tagId]
            let officialQ = ToolsUtil.cleanQuality(r["pfpzlb_3289"])
            let quality = officialQ.isEmpty ? (tag?[1] ?? "其他") : officialQ
            let label = tag?[0] ?? ""
            let obtain = ToolsUtil.str(r["hqfs_8609"]).trimmingCharacters(in: .whitespaces)
            let priceText = ToolsUtil.priceFromObtain(obtain, tag?[2] ?? "—")

            // 大图：官方图鉴封面 → 回退到英雄皮肤大图（bigskin-N）
            var big = ToolsUtil.str(r["fmlb_4536"]).replacingOccurrences(of: "\\/", with: "/")
            if big.isEmpty {
                if let h = byName[heroName] ?? byName[ToolsUtil.bare(heroName)],
                   let skins = h["skins"] as? [[String: Any]],
                   let i = skins.firstIndex(where: { ToolsUtil.str($0["name"]) == name }) {
                    big = ToolsUtil.heroSkinUrl(ToolsUtil.str(h["id"]), i + 1)
                }
            }
            if big.isEmpty { continue }

            if heroMeta[heroName] == nil {
                let h = byName[heroName] ?? byName[ToolsUtil.bare(heroName)]
                let b = heroBasics(heroName)
                heroMeta[heroName] = [
                    "name": heroName,
                    "id": ToolsUtil.str(h?["id"]),
                    "lane": (h?["lanes"] as? [String])?.first ?? "",
                    "types": b.types,
                    "pinyin": b.pinyin,
                    "icon": ToolsUtil.str(r["yxtxlb_8443"]).replacingOccurrences(of: "\\/", with: "/"),
                    "cover": "",
                    "release": "",
                    "intro": "",
                ]
            }

            let thumb = ToolsUtil.str(r["yxtxlb_8443"]).replacingOccurrences(of: "\\/", with: "/")
            list.append([
                "id": ToolsUtil.str(r["pfidlb_3934"]),
                "hero": heroName,
                "name": name,
                "quality": quality,
                "label": label,
                "tagId": tagId,
                "tagIcon": tag != nil ? ToolsUtil.skinTagIconUrl(tagId) : "",
                "priceText": priceText,
                "officialQuality": !officialQ.isEmpty,
                "date": ToolsUtil.fmtDate(r["sxsjlb_1516"]),
                "obtain": obtain,
                "intro": ToolsUtil.stripHtml(r["yjhjsl_5003"]),
                "big": big,
                "thumb": thumb.isEmpty ? big : thumb,
            ])
        }

        // 按英雄分组（JS 用 Map，保持首次出现顺序）
        var groups: [String: [[String: Any]]] = [:]
        var groupOrder: [String] = []
        for s in list {
            let hero = ToolsUtil.str(s["hero"])
            if groups[hero] == nil { groupOrder.append(hero); groups[hero] = [] }
            groups[hero]?.append(s)
        }
        var heroesOut: [[String: Any]] = []
        for name in groupOrder {
            guard var skins = groups[name] else { continue }
            let meta = heroMeta[name] ?? ["name": name, "id": "", "lane": "", "types": [], "pinyin": "",
                                          "icon": "", "cover": "", "release": "", "intro": ""]
            // JS 是 localeCompare 不带 locale：中文按码位、不按拼音。
            // 误用 zh_CN 会让同日期的皮肤整段错位（表现为 id / 名称 / 徽章全串位）。
            skins = ToolsUtil.stableSorted(skins) { a, b in
                let da = ToolsUtil.str(a["date"]).isEmpty ? "9999" : ToolsUtil.str(a["date"])
                let db = ToolsUtil.str(b["date"]).isEmpty ? "9999" : ToolsUtil.str(b["date"])
                if da != db { return da < db }
                return ToolsUtil.cmp(ToolsUtil.str(a["name"]), ToolsUtil.str(b["name"]))
            }
            var dist: [String: Int] = [:]
            for s in skins {
                let q = ToolsUtil.str(s["quality"])
                dist[q] = (dist[q] ?? 0) + 1
            }
            let lane = ToolsUtil.str(meta["lane"])
            heroesOut.append([
                "name": name,
                "id": ToolsUtil.str(meta["id"]),
                "lane": lane,
                "lanes": lane.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                "types": meta["types"] as? [String] ?? [],
                "pinyin": ToolsUtil.str(meta["pinyin"]),
                "icon": ToolsUtil.str(meta["icon"]),
                "cover": ToolsUtil.str(meta["cover"]),
                "release": ToolsUtil.str(meta["release"]),
                "intro": ToolsUtil.str(meta["intro"]),
                "count": skins.count,
                "qualities": dist,
                "topQuality": ToolsDict.qualityOrder.first { (dist[$0] ?? 0) > 0 } ?? "伴生",
                "skins": skins,
            ])
        }
        // 英雄排序：皮肤多的在前，其次名字
        heroesOut = ToolsUtil.stableSorted(heroesOut) { a, b in
            let ca = a["count"] as? Int ?? 0, cb = b["count"] as? Int ?? 0
            if ca != cb { return ca > cb }
            return ToolsUtil.zhCompare(ToolsUtil.str(a["name"]), ToolsUtil.str(b["name"]))
        }

        var qCount: [String: Int] = [:]
        for s in list {
            let q = ToolsUtil.str(s["quality"])
            qCount[q] = (qCount[q] ?? 0) + 1
        }
        var qualities: [[String: Any]] = ToolsDict.qualityOrder.filter { (qCount[$0] ?? 0) > 0 }
            .map { ["name": $0, "count": qCount[$0] ?? 0] }
        for k in qCount.keys where !ToolsDict.qualityOrder.contains(k) {
            qualities.append(["name": k, "count": qCount[k] ?? 0])
        }

        // Object.keys(labels) 是插入序，之后的 sort 不稳定 —— 必须保留插入序再稳定排序
        let labelValues = list.map { ToolsUtil.str($0["label"]) }.filter { !$0.isEmpty }
        let labelCount = counting(labelValues)
        let labels = labelCount.count

        // 英雄分类汇总（职业 / 分路）
        var typeCount: [String: Int] = [:]
        var untyped = 0
        for h in heroesOut {
            let ts = h["types"] as? [String] ?? []
            if ts.isEmpty { untyped += 1; continue }
            for t in ts { typeCount[t] = (typeCount[t] ?? 0) + 1 }
        }
        // 按官方英雄库顺序输出（1 战士 … 6 辅助），供画廊筛选
        let orderedTypes = ToolsDict.heroType.sorted { $0.key < $1.key }.map { $0.value }
        var types: [[String: Any]] = orderedTypes.filter { (typeCount[$0] ?? 0) > 0 }
            .map { ["name": $0, "count": typeCount[$0] ?? 0] }
        for t in typeCount.keys where !orderedTypes.contains(t) {
            types.append(["name": t, "count": typeCount[t] ?? 0])
        }

        var laneCount: [String: Int] = [:]
        for h in heroesOut {
            for l in h["lanes"] as? [String] ?? [] { laneCount[l] = (laneCount[l] ?? 0) + 1 }
        }
        let orderedLanes = ToolsDict.lane.sorted { $0.key < $1.key }.map { $0.value }
        let lanes = orderedLanes.filter { (laneCount[$0] ?? 0) > 0 }
            .map { ["name": $0, "count": laneCount[$0] ?? 0] }

        let payload: [String: Any] = [
            "updatedAt": Int(Date().timeIntervalSince1970 * 1000),
            "total": list.count,
            "heroCount": heroesOut.count,
            "untypedHeroes": untyped,
            "dated": list.filter { !ToolsUtil.str($0["date"]).isEmpty }.count,
            "heroes": heroesOut,
            "qualities": qualities,
            "labels": ToolsUtil.stableSorted(labelCount.keys) { (labels[$0] ?? 0) > (labels[$1] ?? 0) }
                .map { ["name": $0, "count": labels[$0] ?? 0] },
            "types": types,
            "lanes": lanes,
            "priceNote": "官方未公开皮肤定价，价格按官方品质徽章与获取方式推算，仅供参考",
        ]
        ToolsCache.set("skins.json", payload)
        return payload
    }

    // MARK: - 官方：装备库

    /// 老库 itemimg/{id}.jpg 对少量新装备缺图（404），官方新库 itemimgo/{id}.png 齐全。
    /// 首次构建逐个探测一次，结果缓存 30 天。
    private nonisolated static func iconReachable(_ url: String) async -> Bool {
        guard let (data, status, resp) = try? await Net.getRaw(url, headers: ["Referer": "https://pvp.qq.com/"], timeout: 12) else { return false }
        guard (200..<300).contains(status), !data.isEmpty else { return false }
        let type = (resp?.value(forHTTPHeaderField: "Content-Type") ?? "").components(separatedBy: ";").first ?? ""
        return type.hasPrefix("image/")
    }

    private func itemIconMap(_ ids: [String]) async -> [String: String] {
        var map: [String: String] = [:]
        if let c = ToolsCache.get("item-icons.json", ttlMs: Self.ttlItemIcons) as? [String: Any],
           let m = c["map"] as? [String: String] { map = m }
        let todo = ids.filter { map[$0] == nil }
        if todo.isEmpty { return map }

        /* 并发探测。桌面版是「10 个 worker 争抢一个游标」，Swift 的 TaskGroup
           无法共享可变游标，改为按段划分（worker 数 10，语义等价）。 */
        let workers = min(10, max(todo.count, 1))
        let chunk = max(1, Int(ceil(Double(todo.count) / Double(workers))))
        var chunks: [[String]] = []
        var cur: [String] = []
        for id in todo {
            cur.append(id)
            if cur.count >= chunk { chunks.append(cur); cur = [] }
        }
        if !cur.isEmpty { chunks.append(cur) }

        await withTaskGroup(of: [String: String].self) { group in
            for part in chunks {
                group.addTask {
                    var local: [String: String] = [:]
                    for id in part {
                        let primary = ToolsUtil.itemIconUrl(id)
                        local[id] = await Self.iconReachable(primary) ? primary : ToolsUtil.itemIconAltUrl(id)
                    }
                    return local
                }
            }
            for await part in group { for (k, v) in part { map[k] = v } }
        }
        ToolsCache.set("item-icons.json", ["at": Int(Date().timeIntervalSince1970 * 1000), "map": map])
        return map
    }

    func items() async throws -> [[String: Any]] {
        if let c = ToolsCache.get("items.json", ttlMs: Self.ttlItems) as? [[String: Any]],
           !c.isEmpty, c[0]["passive"] != nil { return c }
        let raw = try await Net.getJSONAny(Self.urlItemList, timeout: 15)
        let rows = ToolsJSON.dicts(raw)
        let iconOf = await itemIconMap(rows.map { ToolsUtil.str($0["item_id"]) })
        let out: [[String: Any]] = rows.map { it -> [String: Any] in
            let id = ToolsUtil.str(it["item_id"])
            let des2 = ToolsUtil.str(it["des2"])
            return [
                "id": id,
                "name": ToolsUtil.str(it["item_name"]),
                "typeId": ToolsUtil.int(it["item_type"]),
                "type": ToolsDict.itemType[ToolsUtil.int(it["item_type"])] ?? "其他",
                "price": ToolsUtil.int(it["price"]),
                "total": ToolsUtil.int(it["total_price"] ?? it["price"]),
                "desc": ToolsUtil.stripHtml(it["des1"]),
                "lines": ToolsUtil.htmlLines(it["des1"]),
                "passive": ToolsUtil.stripHtml(des2),
                "passives": ToolsUtil.htmlLines(des2),
                "hasPassive": !des2.trimmingCharacters(in: .whitespaces).isEmpty,
                "icon": iconOf[id] ?? ToolsUtil.itemIconUrl(id),
            ]
        }
        ToolsCache.set("items.json", out)
        return out
    }

    // MARK: - 官方：铭文库

    func runes() async throws -> [String: Any] {
        if let c = ToolsCache.get("runes.json", ttlMs: Self.ttlRunes) as? [String: Any],
           let list = c["list"] as? [Any], !list.isEmpty { return c }
        let raw = try await Net.getJSONAny(Self.urlMingList, timeout: 15)

        var list: [[String: Any]] = []
        for item in ToolsJSON.array(raw) {
            guard let m = item as? [String: Any] else { continue }
            let id = ToolsUtil.str(m["ming_id"])
            let head = id.first.map(String.init) ?? ""
            let color = head == "1" ? "red" : head == "2" ? "blue" : "green"
            let name = ToolsUtil.str(m["ming_name"]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            let c = ToolsDict.runeColor[color] ?? [:]
            list.append([
                "id": id,
                "name": name,
                "color": color,
                "colorName": ToolsUtil.str(c["name"]),
                "grade": ToolsUtil.int(m["ming_grade"]) == 0 ? 1 : ToolsUtil.int(m["ming_grade"]),
                "desc": ToolsUtil.stripHtml(m["ming_des"]),
                "lines": ToolsUtil.htmlLines(m["ming_des"]),
                "officialType": ToolsUtil.str(m["ming_type"]),
                "icon": ToolsUtil.mingIconUrl(id),
            ])
        }

        let cOrder: [String: Int] = ["red": 0, "blue": 1, "green": 2]
        list = ToolsUtil.stableSorted(list) { a, b in
            let ca = cOrder[ToolsUtil.str(a["color"])] ?? 9, cb = cOrder[ToolsUtil.str(b["color"])] ?? 9
            if ca != cb { return ca < cb }
            let ga = a["grade"] as? Int ?? 0, gb = b["grade"] as? Int ?? 0
            if ga != gb { return ga > gb }
            return ToolsUtil.zhCompare(ToolsUtil.str(a["name"]), ToolsUtil.str(b["name"]))
        }

        let colors: [[String: Any]] = ["red", "blue", "green"].compactMap { k -> [String: Any]? in
            guard let c = ToolsDict.runeColor[k] else { return nil }
            var o: [String: Any] = [:]
            for (kk, vv) in c { o[kk] = vv }
            o["count"] = list.filter { ToolsUtil.str($0["color"]) == k }.count
            o["level5"] = list.filter { ToolsUtil.str($0["color"]) == k && ($0["grade"] as? Int) == 5 }.count
            return o
        }
        let grades: [[String: Any]] = [5, 4, 3, 2, 1].map { g in
            ["grade": g as Any, "count": list.filter { ($0["grade"] as? Int) == g }.count]
        }

        let payload: [String: Any] = [
            "updatedAt": Int(Date().timeIntervalSince1970 * 1000),
            "total": list.count,
            "topLevel": 5,
            "slotPerColor": 10,
            "colors": colors,
            "grades": grades,
            "note": "铭文页共 30 个槽位：红、蓝、绿三色各 10 个。每色 10 种铭文，分 1~5 级（等级越高属性越强），" +
                    "职业赛场与排位普遍使用整套 5 级铭文。属性数值为该等级下的单枚加成，凑满 10 枚即 ×10。",
            "priceNote": "铭文通过铭文碎片合成（1 级 10 碎片 → 5 级 1600 碎片），官方未公开点券定价。",
            "list": list,
        ]
        ToolsCache.set("runes.json", payload)
        return payload
    }

    // MARK: - 官方：英雄详情

    private struct SkinArtIndex {
        var byName: [String: String] = [:]      // 英雄名|皮肤名 → 可缩放高清图
        var byId: [String: (byName: [String: String], list: [[String: Any]])] = [:]
    }
    private var skinArtIndexCache: SkinArtIndex?

    private func skinArtIndex() async throws -> SkinArtIndex {
        if let c = skinArtIndexCache { return c }
        let cat = try await skinsCatalog()
        var idx = SkinArtIndex()
        for h in cat["heroes"] as? [[String: Any]] ?? [] {
            let name = ToolsUtil.str(h["name"])
            let skins = h["skins"] as? [[String: Any]] ?? []
            var byName: [String: String] = [:]
            for s in skins {
                let big = ToolsUtil.str(s["big"])
                if !big.isEmpty { byName[ToolsUtil.str(s["name"])] = big }
            }
            let hid = ToolsUtil.str(h["id"])
            if !hid.isEmpty { idx.byId[hid] = (byName, skins) }
            for s in skins {
                let big = ToolsUtil.str(s["big"])
                if !big.isEmpty { idx.byName["\(name)|\(ToolsUtil.str(s["name"]))"] = big }
            }
        }
        skinArtIndexCache = idx
        return idx
    }

    /// 丢弃进程内记忆化索引（skinsCatalog 刷新后旧索引里的高清图映射已过期）。
    func invalidateMemoCaches() {
        skinArtIndexCache = nil
    }

    private func preferHiResSkins(_ heroId: Any?, _ heroName: String, _ list: [[String: Any]]) async -> [[String: Any]] {
        guard !list.isEmpty else { return list }
        guard let idx = try? await skinArtIndex() else { return list }
        let o = heroId.map { ToolsUtil.str($0) }.flatMap { idx.byId[$0] }
        return list.enumerated().map { i, s -> [String: Any] in
            let name = ToolsUtil.str(s["name"])
            var big = heroName.isEmpty ? "" : (idx.byName["\(heroName)|\(name)"] ?? "")
            if big.isEmpty, let o {
                big = o.byName[name] ?? ""
                if big.isEmpty, o.list.count == list.count, i < o.list.count {
                    big = ToolsUtil.str(o.list[i]["big"])
                }
            }
            guard !big.isEmpty else { return s }
            var out = s
            out["big"] = big
            out["bigAlt"] = ToolsUtil.str(s["big"])
            return out
        }
    }

    func heroDetail(_ id: String) async throws -> [String: Any] {
        let key = "hero-\(id).json"
        if let c = ToolsCache.get(key, ttlMs: Self.ttlHeroDetail) as? [String: Any] { return c }

        let url = ToolsUtil.heroDetailUrl(id)
        let (data, status, _) = try await Net.getRaw(url, timeout: 15)
        /* 官网尚未建页的英雄（新英雄 / 多形态英雄）会返回 404：
           这里不抛错，改为下发「基础资料版」详情（属性/技能留空、partial 标记），
           保证离线时点开这些英雄也有名字、头像、皮肤图。 */
        let partial = !(200..<300).contains(status)
        let html = partial ? "" : Net.decodeGBK(data)

        let heroList = try await heroes()
        var base = heroList.first { ToolsUtil.str($0["id"]) == id }
        if base == nil {
            base = ["id": ToolsUtil.int(id), "name": "", "title": "", "types": [], "lanes": [],
                    "skins": [], "icon": ToolsUtil.heroIconUrl(id)]
        }
        var out = base ?? [:]

        /* 属性评分：生存能力 / 攻击伤害 / 技能效果 / 上手难度 */
        var attr: [[String: Any]] = []
        for g in ToolsUtil.allMatches(html, #"<em class="cover-list-text fl">([^<]+)</em>[\s\S]{0,260}?width:\s*(\d+)%"#) {
            guard g.count > 2, let v = Int(g[2]) else { continue }
            attr.append(["label": g[1].trimmingCharacters(in: .whitespaces), "value": v])
        }

        /* 技能：名称 / 冷却 / 消耗 / 描述 + 图标 */
        let iconPattern = "heroimg/\(id)/(\\d+)\\.png"
        var iconCodes: [String] = []
        for g in ToolsUtil.allMatches(html, iconPattern) where g.count > 1 && !iconCodes.contains(g[1]) {
            iconCodes.append(g[1])
        }
        var skills: [[String: Any]] = []
        let skRe = #"<p class="skill-name">\s*<b>([^<]*)</b>\s*<span>([^<]*)</span>\s*<span>([^<]*)</span>\s*</p>\s*<p class="skill-desc">([\s\S]*?)</p>"#
        for g in ToolsUtil.allMatches(html, skRe) {
            if skills.count >= 8 { break }
            guard g.count > 4 else { continue }
            let name = g[1].trimmingCharacters(in: .whitespaces)
            let desc = ToolsUtil.stripHtml(g[4])
            if name.isEmpty && desc.isEmpty { continue }
            let i = skills.count
            var cd = g[2]
            var cost = g[3]
            if let r = cd.range(of: #"^冷却值[:：]?"#, options: .regularExpression) { cd.removeSubrange(r) }
            if let r = cost.range(of: #"^消耗[:：]?"#, options: .regularExpression) { cost.removeSubrange(r) }
            skills.append([
                "name": name.isEmpty ? "技能\(skills.count + 1)" : name,
                "cd": cd.trimmingCharacters(in: .whitespaces),
                "cost": cost.trimmingCharacters(in: .whitespaces),
                "desc": desc,
                "icon": i < iconCodes.count ? ToolsUtil.skillIconUrl(id, iconCodes[i]) : "",
            ])
        }

        /* 故事 / 台词（可选展示） */
        let story = ToolsUtil.firstMatch(html, #"<div class="pop-story[^"]*">[\s\S]*?<p[^>]*>([\s\S]*?)</p>"#)
            .map { String(ToolsUtil.stripHtml($0).prefix(400)) } ?? ""

        out["skins"] = await preferHiResSkins(out["id"], ToolsUtil.str(out["name"]),
                                              out["skins"] as? [[String: Any]] ?? [])
        out["attr"] = attr
        out["skills"] = skills
        out["story"] = story
        out["partial"] = partial
        out["source"] = url
        ToolsCache.set(key, out)
        return out
    }

    // MARK: - 玩加：签名会话

    private struct WPSession { var cookie = ""; var gtk = ""; var at: TimeInterval = 0; var token = "" }
    private var wps = WPSession()

    private func wpSession(force: Bool) async throws -> WPSession {
        if !force, !wps.gtk.isEmpty, Date().timeIntervalSince1970 - wps.at < 30 * 60 { return wps }
        let (_, status, resp) = try await Net.getRaw("https://wanplus.cn/kog/teamstats", timeout: 15)
        guard (200..<300).contains(status) else { throw Net.NetError.badStatus(status) }
        let raw = resp?.value(forHTTPHeaderField: "Set-Cookie") ?? ""
        let url = URL(string: "https://wanplus.cn/")!
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": raw], for: url)
        var jar: [String: String] = [:]
        for c in cookies { jar[c.name] = c.value }
        let token = jar["wanplus_token"] ?? ""
        wps = WPSession(cookie: jar.map { "\($0.key)=\($0.value)" }.joined(separator: "; "),
                        gtk: String(ToolsUtil.time33(token)),
                        at: Date().timeIntervalSince1970,
                        token: token)
        return wps
    }

    private func wpPost(_ pathname: String, _ params: [String: String], _ retried: Bool = false) async throws -> [String: Any] {
        let s = try await wpSession(force: false)
        var form = params
        form["_gtk"] = s.gtk
        let headers: [String: String] = [
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "X-Requested-With": "XMLHttpRequest",
            "X-CSRF-Token": s.gtk,
            "Referer": "https://wanplus.cn/kog/teamstats",
            "Origin": "https://wanplus.cn",
            "Cookie": s.cookie,
        ]
        let (json, _) = try await Net.postFormDetailed("https://wanplus.cn" + pathname,
                                                       form: form, headers: headers, timeout: 20)
        guard let obj = json as? [String: Any] else { throw Net.NetError.notJSON }
        if let ret = obj["ret"] as? NSNumber, ret.intValue != 0 {
            if !retried {
                _ = try? await wpSession(force: true)   // 会话失效 → 换 cookie 重试一次
                return try await wpPost(pathname, params, true)
            }
            throw Net.NetError.upstream(ToolsUtil.str(obj["msg"]).isEmpty ? "玩加上游返回异常" : ToolsUtil.str(obj["msg"]))
        }
        if let retStr = obj["ret"] as? String, Int(retStr) != 0, !retried {
            _ = try? await wpSession(force: true)
            return try await wpPost(pathname, params, true)
        }
        return obj
    }

    /// 数据中心全量分页拉取（type=player | team）
    ///
    /// 上游是 DataTables 服务端分页，且只认现代参数名 `start` / `length`；
    /// 老式 iDisplayStart / iDisplayLength 会被完全忽略、恒定只返回前 30 行。
    private func wpStatsAll(_ eid: String, _ type: String) async throws -> [[String: Any]] {
        let page = 500
        func query(_ start: Int, _ len: Int, _ draw: Int) -> [String: String] {
            ["draw": String(draw), "start": String(start), "length": String(len),
             "area": "", "time": "", "eid": eid, "type": type, "gametype": "6", "filter": "[]"]
        }
        let first = try await wpPost("/ajax/stats/list", query(0, page, 1))
        var rows = first["data"] as? [[String: Any]] ?? []
        let total = ToolsUtil.int(first["iTotalRecords"]) == 0 ? rows.count : ToolsUtil.int(first["iTotalRecords"])
        var guardCount = 0
        while rows.count < total && guardCount < 20 {
            let before = rows.count
            guardCount += 1
            let next = try await wpPost("/ajax/stats/list", query(before, page, guardCount + 1))
            let d = next["data"] as? [[String: Any]] ?? []
            if d.isEmpty { break }
            rows.append(contentsOf: d)
            if rows.count == before { break }
        }
        return rows
    }

    // MARK: - 玩加：选手 / 战队

    private func normPct(_ v: Any?, _ fallbackNum: Double?) -> Pct {
        var num: Double? = nil
        if let v, !(v is NSNull) {
            let s = ToolsUtil.str(v)
            if !s.isEmpty {
                // 注意：JS 的 String.match()[0] 是「整段匹配」，不是捕获组。
                // 用捕获组会只拿到 ".1" 而非 "20.1"，占比会差 100 倍。
                if let m = ToolsUtil.firstMatchWhole(s, #"-?\d+(?:\.\d+)?"#) { num = Double(m) }
                else if v is NSNumber { num = ToolsUtil.dbl(v) }
            }
        }
        if num == nil, let f = fallbackNum, f.isFinite { num = f }
        guard let n = num else { return Pct(num: 0, text: "0%") }
        let r = ToolsUtil.r1(n)
        return Pct(num: r, text: "\(ToolsUtil.fmtNum(r))%")
    }

    /// 上游 `herojson` 是 **JSON 字符串**（不是对象）——桌面版靠 safeJSON() 解析，
    /// 直接 `as? [String: Any]` 会静默拿到空池，选手页与梯度榜就全空了。
    private func poolOf(_ r: [String: Any]) -> [[String: Any]] {
        let obj: [String: Any]
        switch r["herojson"] {
        case let d as [String: Any]: obj = d
        case let s as String:
            guard let data = s.data(using: .utf8),
                  let any = try? JSONSerialization.jsonObject(with: data) else { return [] }
            if let d = any as? [String: Any] { obj = d }
            else { return (any as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }
        case let a as [Any]:
            return a.compactMap { $0 as? [String: Any] }
        default:
            return []
        }
        /* JS 的 Object.values() 对整数型 key 按**数值升序**枚举（"531"、"146" …），
           Swift 字典则是哈希序。不显式排序，同场次英雄的先后会与桌面版不一致。 */
        let keys = obj.keys.sorted { a, b in
            switch (Int(a), Int(b)) {
            case let (ia?, ib?): return ia < ib
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a < b
            }
        }
        return keys.compactMap { obj[$0] as? [String: Any] }
    }

    /// 上游 herojson 的一条英雄池记录 → 统一结构（图标 / 定位 / 分路按 id 反查官方库）
    private func normPoolItem(_ raw: [String: Any],
                              _ byId: [Int: [String: Any]],
                              _ byName: [String: [String: Any]]) -> [String: Any] {
        let heroId = ToolsUtil.int(raw["heroid"])
        let official = byId[heroId] ?? byName[ToolsUtil.str(raw["heroname"])]
        let games = ToolsUtil.int(raw["appearancetimes"])
        let wins = ToolsUtil.int(raw["winnum"])
        let losses = ToolsUtil.int(raw["losenum"]) == 0 ? (games > 0 ? max(0, games - wins) : 0) : ToolsUtil.int(raw["losenum"])
        let wr = games > 0 ? Double(wins) / Double(games) : 0
        let upWr = ToolsUtil.dblOpt(raw["winrate"])
        let name = ToolsUtil.str(official?["name"]).isEmpty ? ToolsUtil.str(raw["heroname"]) : ToolsUtil.str(official?["name"])
        let upName = ToolsUtil.str(raw["heroname"])
        return [
            "name": name,
            "alias": (official != nil && !upName.isEmpty && name != upName) ? upName : "",
            "heroId": heroId,
            "games": games,
            "wins": wins,
            "losses": losses,
            "winRate": ToolsUtil.r2((upWr ?? 0) > 0 ? (upWr ?? 0) : wr),
            "kda": ToolsUtil.r1(raw["kda"]),
            "icon": (ToolsUtil.str(official?["icon"]).isEmpty) ? (heroId > 0 ? ToolsUtil.heroIconUrl(heroId) : "") : ToolsUtil.str(official?["icon"]),
            "types": official?["types"] as? [String] ?? [],
            "lanes": official?["lanes"] as? [String] ?? [],
            "title": ToolsUtil.str(official?["title"]),
        ]
    }

    /// 按「出场场次加权」求选手的主打位置与擅长类型。
    /// JS 用 Map 累加（插入序），再用不稳定排序取降序 —— 同权重的先后依赖插入序，
    /// 所以这里用 keys 数组固定插入序，再交给稳定排序。
    private func weightedTop(_ items: [[String: Any]], _ key: String) -> [String] {
        var keys: [String] = []
        var acc: [String: Double] = [:]
        for it in items {
            for v in it[key] as? [String] ?? [] {
                if acc[v] == nil { keys.append(v); acc[v] = 0 }
                acc[v] = (acc[v] ?? 0) + ToolsUtil.dbl(it["games"])
            }
        }
        guard !keys.isEmpty else { return [] }
        return ToolsUtil.stableSorted(keys) { (acc[$0] ?? 0) > (acc[$1] ?? 0) }
    }

    /// 计数累加（保持首次出现顺序），供后续稳定排序使用
    private func counting(_ values: [String]) -> (keys: [String], count: [String: Int]) {
        var keys: [String] = []
        var map: [String: Int] = [:]
        for v in values {
            if map[v] == nil { keys.append(v); map[v] = 0 }
            map[v] = (map[v] ?? 0) + 1
        }
        return (keys, map)
    }

    private func buildPlayers(_ eid: String) async throws -> [[String: Any]] {
        let rows = try await wpStatsAll(eid, "player")
        let byName = try await heroIndexByName()
        let byId = try await heroIndexById()

        /* 去重：上游会按「阶段数」把同一选手的整行重复返回（字段完全一致）。
           不去重会让选手表出现重复行、梯度榜的出场场次虚高（按阶段数放大 3~5 倍）。 */
        var uniq: [[String: Any]] = []
        var seen = Set<String>()
        for r in rows {
            let n = ToolsUtil.str(r["playername"])
            if n.isEmpty { continue }
            let k = "\(n)|\(ToolsUtil.str(r["teamname"]))"
            if seen.contains(k) { continue }
            seen.insert(k)
            uniq.append(r)
        }

        /* 第一遍：基础数值（含队伍小计，用于百分比兜底） */
        let base: [[String: Any]] = uniq.map { r -> [String: Any] in
            var pool = ToolsUtil.stableSorted(
                poolOf(r)
                    .map { normPoolItem($0, byId, byName) }
                    .filter { !ToolsUtil.str($0["name"]).isEmpty && ToolsUtil.int($0["games"]) > 0 }
            ) { a, b in
                let ga = ToolsUtil.int(a["games"]), gb = ToolsUtil.int(b["games"])
                if ga != gb { return ga > gb }
                return ToolsUtil.dbl(a["winRate"]) > ToolsUtil.dbl(b["winRate"])
            }
            for i in pool.indices { pool[i]["rank"] = i + 1 }
            return [
                "id": ToolsUtil.str(r["playerid"]),
                "name": ToolsUtil.str(r["playername"]),
                "team": ToolsUtil.str(r["teamname"]),
                "teamId": ToolsUtil.str(r["teamid"]),
                "games": ToolsUtil.int(r["appearedTimes"]),
                "wins": ToolsUtil.int(r["winnum"]),
                "losses": ToolsUtil.int(r["losenum"]),
                "winRate": ToolsUtil.r2(r["winrate"]),
                "kda": ToolsUtil.r1(r["kda"]),
                "kills": ToolsUtil.r1(r["killsPergame"]),
                "deaths": ToolsUtil.r1(r["deathsPergame"]),
                "assists": ToolsUtil.r1(r["assistsPergame"]),
                "goldPerMin": ToolsUtil.dbl(r["goldsPermin"]),
                "dmgPerMin": ToolsUtil.dbl(r["damagetoheroPermin"]),
                "dmgTakenPerMin": ToolsUtil.dbl(r["damagetakenPermin"]),
                "mostKills": ToolsUtil.int(r["mostkills"]),
                "mostAssists": ToolsUtil.int(r["mostassists"]),
                "mostDeaths": ToolsUtil.int(r["mostdeaths"]),
                "dmgConversion": ToolsUtil.r2(r["damagetoheroConversionRate"]),
                "durationSec": ToolsUtil.dbl(r["duration"]),
                "totals": [
                    "kills": ToolsUtil.int(r["kills"]),
                    "deaths": ToolsUtil.int(r["deaths"]),
                    "assists": ToolsUtil.int(r["assists"]),
                    "golds": ToolsUtil.int(r["golds"]),
                    "damage": ToolsUtil.int(r["damagetohero"]),
                    "damageTaken": ToolsUtil.int(r["damagetaken"]),
                ],
                "rawPct": [
                    "gold": ToolsUtil.str(r["goldsPercent"]),
                    "dmg": ToolsUtil.str(r["damagetoheroPercent"]),
                    "dmgTaken": ToolsUtil.str(r["damagetakenPercent"]),
                    "attend": ToolsUtil.str(r["attendrate"]),
                ],
                "pool": pool,
            ]
        }

        /* 队伍小计 → 占比兜底数据源 */
        var teamSum: [String: [String: Double]] = [:]
        for p in base {
            let tid = ToolsUtil.str(p["teamId"])
            var t = teamSum[tid] ?? ["golds": 0, "dmg": 0, "taken": 0, "kills": 0, "assists": 0]
            let tot = p["totals"] as? [String: Any] ?? [:]
            t["golds"] = (t["golds"] ?? 0) + ToolsUtil.dbl(tot["golds"])
            t["dmg"] = (t["dmg"] ?? 0) + ToolsUtil.dbl(tot["damage"])
            t["taken"] = (t["taken"] ?? 0) + ToolsUtil.dbl(tot["damageTaken"])
            t["kills"] = (t["kills"] ?? 0) + ToolsUtil.dbl(tot["kills"])
            t["assists"] = (t["assists"] ?? 0) + ToolsUtil.dbl(tot["assists"])
            teamSum[tid] = t
        }

        /* 第二遍：把占比类字段一次性算成「一定非空」的形式 */
        var out: [[String: Any]] = base.map { p -> [String: Any] in
            let t = teamSum[ToolsUtil.str(p["teamId"])] ?? [:]
            let tot = p["totals"] as? [String: Any] ?? [:]
            let rawPct = p["rawPct"] as? [String: Any] ?? [:]
            func share(_ v: Double, _ total: Double) -> Double? { total > 0 ? (v / total) * 100 : nil }
            let gold = normPct(rawPct["gold"], share(ToolsUtil.dbl(tot["golds"]), t["golds"] ?? 0))
            let dmg = normPct(rawPct["dmg"], share(ToolsUtil.dbl(tot["damage"]), t["dmg"] ?? 0))
            let taken = normPct(rawPct["dmgTaken"], share(ToolsUtil.dbl(tot["damageTaken"]), t["taken"] ?? 0))
            let attend = normPct(rawPct["attend"],
                                 share(ToolsUtil.dbl(tot["kills"]) + ToolsUtil.dbl(tot["assists"]),
                                       (t["kills"] ?? 0) + (t["assists"] ?? 0)))
            let lanes = weightedTop(p["pool"] as? [[String: Any]] ?? [], "lanes")
            let types = weightedTop(p["pool"] as? [[String: Any]] ?? [], "types")
            var shaped = p
            shaped.removeValue(forKey: "rawPct")   // 上游原始占比串仅在构建期用于兜底，不下发
            shaped["goldPercent"] = gold.text
            shaped["goldPercentNum"] = gold.num
            shaped["dmgPercent"] = dmg.text
            shaped["dmgPercentNum"] = dmg.num
            shaped["dmgTakenPercent"] = taken.text
            shaped["dmgTakenPercentNum"] = taken.num
            shaped["attendRate"] = attend.text
            shaped["attendRateNum"] = attend.num
            shaped["lane"] = lanes.first ?? "未知"
            shaped["lanes"] = lanes
            shaped["types"] = types
            shaped["durationMin"] = Int(round(ToolsUtil.dbl(p["durationSec"]) / 60))
            shaped["rank"] = 0
            shaped["poolSize"] = (p["pool"] as? [Any])?.count ?? 0
            return shaped
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

    func players(_ eid: String) async throws -> [Any] {
        let key = "players-\(eid).json"
        if let cached = ToolsCache.get(key, ttlMs: Self.ttlStats) {
            // 兼容两种形状：玩加/官方运行时缓存（裸数组）/ Score 种子（{ list: [...] }）
            if let arr = cached as? [Any], !arr.isEmpty { return arr }
            if let d = cached as? [String: Any], let arr = d["list"] as? [Any], !arr.isEmpty { return arr }
            // 空缓存（如旧版把 0 行结果落盘）→ 直接删掉，让下面的种子/官方通道有机会接管
            ToolsCache.remove(key)
        }
        /* 优先级：KPL 官方统计接口 → 玩加 → Score 种子。
           官方（getSeasonPlayerPerf + 逐小局英雄选择）随赛事实时更新、口径最权威；
           官网无该赛季数据时回落玩加（2016~2022 有完整逐选手统计），
           再回落 Score 种子（离线可用；不经 cacheSet 回写——种子含元信息，回写会破坏形状）。 */
        if let kpl = try? await playersFromOfficial(eid), !kpl.isEmpty {
            ToolsCache.set(key, kpl)
            return kpl
        }
        if let wp = try? await buildPlayers(eid), !wp.isEmpty {
            ToolsCache.set(key, wp)
            return wp
        }
        if let seed = ToolsCache.getAny(key) {
            if let arr = seed as? [Any], !arr.isEmpty { return arr }
            if let d = seed as? [String: Any], let arr = d["list"] as? [Any], !arr.isEmpty { return arr }
        }
        return []
    }

    func teams(_ eid: String) async throws -> [Any] {
        let key = "teams-\(eid).json"
        if let cached = ToolsCache.get(key, ttlMs: Self.ttlStats) as? [Any], !cached.isEmpty { return cached }
        return try await withStaleFallback(key, {
            let rows = try await self.wpStatsAll(eid, "team")
            let out: [[String: Any]] = rows.filter { !ToolsUtil.str($0["teamname"]).isEmpty }
                .map { r -> [String: Any] in
                    ["id": ToolsUtil.str(r["teamid"]),
                     "name": ToolsUtil.str(r["teamname"]),
                     "games": ToolsUtil.int(r["appearedTimes"]),
                     "wins": ToolsUtil.int(r["winnum"]),
                     "losses": ToolsUtil.int(r["losenum"]),
                     "winRate": ToolsUtil.r2(r["winrate"]),
                     "kda": ToolsUtil.r1(r["kda"]),
                     "kills": ToolsUtil.r1(r["killsPergame"]),
                     "deaths": ToolsUtil.r1(r["deathsPergame"]),
                     "assists": ToolsUtil.r1(r["assistsPergame"]),
                     "goldPerMin": ToolsUtil.dbl(r["goldsPermin"]),
                     "dmgPerMin": ToolsUtil.dbl(r["damagetoheroPermin"]),
                     "baronPerGame": ToolsUtil.r1(r["baronkillsPergame"]),
                     "dragonPerGame": ToolsUtil.r1(r["dragonkillsPergame"]),
                     "duration": ToolsUtil.int(r["totalDuration"])]
                }
            return ToolsUtil.stableSorted(out) { ToolsUtil.dbl($0["kda"]) > ToolsUtil.dbl($1["kda"]) }
        }) as? [Any] ?? []
    }

    // MARK: - 梯度榜

    private func buildGradient(_ eid: String) async throws -> [String: Any] {
        let ps = try await players(eid)
        let byName = try await heroIndexByName()
        let byId = try await heroIndexById()

        /* JS 的 Set 保持插入顺序，Swift 的 Set 无序 —— 用「数组 + 伴随 Set」
           复现插入序，否则 userList 每次刷新顺序都会变。 */
        final class Agg {
            var name = ""; var heroId = 0; var games = 0; var wins = 0; var losses = 0
            var kdaW = 0.0
            var userList: [String] = []
            var userSeen = Set<String>()
            var icon = ""; var types: [String] = []; var lanes: [String] = []
            var users: Int { userList.count }
            func addUser(_ u: String) {
                if userSeen.contains(u) { return }
                userSeen.insert(u); userList.append(u)
            }
        }
        // JS 用 Map（保持插入顺序），Swift 字典无序 —— 用伴随的 order 数组复现插入序，
        // 否则同分英雄的排列每次刷新都会变。
        var agg: [String: Agg] = [:]
        var order: [String] = []
        for item in ps {
            guard let p = item as? [String: Any] else { continue }
            for hh in p["pool"] as? [[String: Any]] ?? [] {
                let name = ToolsUtil.str(hh["name"])
                let games = ToolsUtil.int(hh["games"])
                if name.isEmpty || games == 0 { continue }
                let isNew = agg[name] == nil
                let cur = agg[name] ?? {
                    let a = Agg()
                    a.name = name
                    a.heroId = ToolsUtil.int(hh["heroId"])
                    a.icon = ToolsUtil.str(hh["icon"])
                    a.types = hh["types"] as? [String] ?? []
                    a.lanes = hh["lanes"] as? [String] ?? []
                    return a
                }()
                if isNew { order.append(name) }
                cur.games += games
                cur.wins += ToolsUtil.int(hh["wins"])
                cur.losses += ToolsUtil.int(hh["losses"])
                cur.kdaW += ToolsUtil.dbl(hh["kda"]) * Double(games)
                if cur.icon.isEmpty { cur.icon = ToolsUtil.str(hh["icon"]) }
                if cur.heroId == 0 { cur.heroId = ToolsUtil.int(hh["heroId"]) }
                cur.addUser("\(ToolsUtil.str(p["name"]))（\(ToolsUtil.str(p["team"]))）")
                agg[name] = cur
            }
        }

        let totalPicks = agg.values.reduce(0) { $0 + $1.games }
        let denom = max(totalPicks, 1)

        var list: [[String: Any]] = order.compactMap { agg[$0] }.map { h -> [String: Any] in
            let games = h.games
            let winRate = games > 0 ? Double(h.wins) / Double(games) : 0
            let smooth = Double(h.wins + 2) / Double(games + 4)   // 贝叶斯平滑，抑制小样本
            // 双保险：按 id 再补一次，避免上游改名导致图标 / 定位 / 分路缺失
            let official = byId[h.heroId] ?? byName[h.name] ?? [:]
            let icon = h.icon.isEmpty ? (ToolsUtil.str(official["icon"]).isEmpty
                                         ? (h.heroId > 0 ? ToolsUtil.heroIconUrl(h.heroId) : "")
                                         : ToolsUtil.str(official["icon"])) : h.icon
            let types = h.types.isEmpty ? (official["types"] as? [String] ?? ["未分类"]) : h.types
            let lanes = h.lanes.isEmpty ? (official["lanes"] as? [String] ?? ["未知"]) : h.lanes
            return [
                "name": ToolsUtil.str(official["name"]).isEmpty ? h.name : ToolsUtil.str(official["name"]),
                "heroId": h.heroId > 0 ? h.heroId : ToolsUtil.int(official["id"]),
                "icon": icon,
                "types": types,
                "lanes": lanes,
                "title": ToolsUtil.str(official["title"]),
                "games": games,
                "wins": h.wins,
                "losses": h.losses,
                "winRate": ToolsUtil.r2(winRate),
                "smooth": ToolsUtil.r2(smooth),
                "kda": games > 0 ? ToolsUtil.r1(h.kdaW / Double(games)) : 0,
                "users": h.users,
                "userList": Array(h.userList.prefix(8)),
                "share": ToolsUtil.r1(Double(games) / Double(denom) * 100),
            ]
        }

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

        var totalPlayerGames = 0
        for item in ps {
            if let p = item as? [String: Any] { totalPlayerGames += ToolsUtil.int(p["games"]) }
        }
        var teamSet = Set<String>()
        for item in ps {
            if let p = item as? [String: Any] { teamSet.insert(ToolsUtil.str(p["team"])) }
        }
        return [
            "eventId": eid,
            "totalPlayers": ps.count,
            "totalTeams": teamSet.count,
            "totalHeroPicks": list.reduce(0) { $0 + ToolsUtil.int($1["games"]) },
            "totalPlayerGames": totalPlayerGames,
            "updatedAt": Int(Date().timeIntervalSince1970 * 1000),
            "list": list,
        ]
    }

    func gradient(_ eid: String) async throws -> [String: Any] {
        let key = "gradient-\(eid).json"
        // 注意判空：空列表也算「有值」，否则会一直命中一份空数据、永远轮不到兜底
        if let c = ToolsCache.get(key, ttlMs: Self.ttlStats) as? [String: Any],
           let l = c["list"] as? [Any], !l.isEmpty { return c }
        // 空缓存（如旧版把 0 行结果落盘）→ 删掉，否则 getAny 会让种子永远轮空
        if let c = ToolsCache.getAny(key) as? [String: Any],
           let l = c["list"] as? [Any], l.isEmpty {
            ToolsCache.remove(key)
        }
        let v = try await withStaleFallback(key, {
            /* 优先级：KPL 官方统计接口 → 玩加 → 种子。
               官方通道（getHeroRankList）随赛事实时更新、口径最权威，优先采用；
               官网无该赛季数据（接口失败 / 未收录）时回落玩加（2016~2022 有
               逐英雄 KDA / 使用人数），再回落 Score 种子（离线可用、含禁用数据）。 */
            if let kpl = try? await self.gradientFromOfficial(eid),
               let l = kpl["list"] as? [Any], !l.isEmpty { return kpl }
            let wp = try? await self.buildGradient(eid)
            if let wp, let l = wp["list"] as? [Any], !l.isEmpty { return wp }
            if let seed = ToolsCache.getAny(key) as? [String: Any],
               let l = seed["list"] as? [Any], !l.isEmpty { return seed }
            return wp ?? ["eventId": eid, "list": [Any](), "totalPlayers": 0, "totalTeams": 0]
        })
        return v as? [String: Any] ?? ["eventId": eid, "list": [], "totalPlayers": 0, "totalTeams": 0]
    }

    // MARK: - KPL 官方统计通道（2023 年及以后的梯度榜 / 选手榜）

    /// 走官方通道聚合梯度榜。失败返回 nil，由调用方继续回落。
    private func gradientFromOfficial(_ eid: String) async throws -> [String: Any]? {
        guard let season = KPLStatsSource.seasonId(of: eid) else { return nil }
        let byId = try await heroIndexById()
        var out = try await KPLStatsSource.buildGradient(seasonId: season, heroIndex: byId)
        // 人数 / 队伍数用官方选手接口补齐（官方英雄榜不含这两个口径）
        if let perf = try? await KPLStatsSource.playerPerf(seasonId: season) {
            out["totalPlayers"] = perf.count
            out["totalTeams"] = Set(perf.map { ToolsUtil.str($0["team_id"]) }.filter { !$0.isEmpty }).count
        }
        // 回写缓存时用 App 赛事 id 作键，与玩加 / 种子通道一致
        out["eventId"] = eid
        return out
    }

    /// 走官方通道聚合选手榜（含英雄池）。失败返回 nil。
    private func playersFromOfficial(_ eid: String) async throws -> [[String: Any]]? {
        guard let season = KPLStatsSource.seasonId(of: eid) else { return nil }
        let byId = try await heroIndexById()
        let byName = try await heroIndexByName()
        let list = try await KPLStatsSource.buildPlayers(seasonId: season,
                                                         heroIndex: byId,
                                                         heroNameIndex: byName)
        return list.isEmpty ? nil : list
    }

    // MARK: - Score 电竞补充通道

    func scoreSource() -> [String: Any] {
        (ToolsCache.getAny("score-source.json") as? [String: Any]) ?? ["events": [:]]
    }

    func scoreMetaOf(_ eid: String) -> [String: Any]? {
        let ev = scoreSource()["events"] as? [String: Any] ?? [:]
        return ev[eid] as? [String: Any]
    }

    /// Score 覆盖的赛季清单（与玩加赛季混排，前端据此渲染梯度榜下拉）
    func scoreEvents() -> [[String: Any]] {
        let ev = scoreSource()["events"] as? [String: Any] ?? [:]
        let local = Dictionary(uniqueKeysWithValues: localEvents().map { (ToolsUtil.str($0["id"]), $0) })
        return ev.keys.sorted().map { id -> [String: Any] in
            let l = local[id] ?? [:]
            let m = ev[id] as? [String: Any] ?? [:]
            return [
                "id": id,
                "name": ToolsUtil.str(l["name"]).isEmpty ? ToolsUtil.str(m["scoreName"]) : ToolsUtil.str(l["name"]),
                "short": ToolsUtil.str(l["short"]).isEmpty ? ToolsUtil.str(m["scoreName"]) : ToolsUtil.str(l["short"]),
                "year": ToolsUtil.int(l["year"]) == 0 ? ToolsUtil.int(m["year"]) : ToolsUtil.int(l["year"]),
                "category": ToolsUtil.str(l["category"]),
                "start": ToolsUtil.str(l["start"]),
                "end": ToolsUtil.str(l["end"]),
                "players": ToolsUtil.int(m["players"]),
                "teams": ToolsUtil.int(m["teams"]),
                "scoreId": ToolsUtil.int(m["scoreId"]),
                "hasPlayers": (m["playersData"] as? Bool) ?? false,
                "pending": (m["pending"] as? Bool) ?? false,
                "source": "score",
            ]
        }
    }

    /// KPL 官方统计覆盖、但 Score 通道**没有**数据的赛季（典型：2026 KPL 年度总决赛）。
    ///
    /// 这些赛季此前在下拉里带着「收录中」标记、选中后是空态——实际上官方
    /// `getSeasonPlayerPerf` / `getHeroRankList` 早已收录完整数据（实测 73 名选手、
    /// 83 个出场英雄、97 个小局）。这里把它们并入赛季清单并去掉 pending，
    /// 使「梯度榜 / 选手详情」能正常选中并展示。
    ///
    /// 只读本地缓存推算人数（不发起网络请求）——coverage 是高频接口，
    /// 真实人数会在用户首次选中该赛季时由官方通道拉取并写入缓存。
    private func kplEvents() -> [[String: Any]] {
        let score = scoreSource()["events"] as? [String: Any] ?? [:]
        let local = Dictionary(uniqueKeysWithValues: localEvents().map { (ToolsUtil.str($0["id"]), $0) })
        var out: [[String: Any]] = []
        for id in KPLStatsSource.coveredEventIds.sorted() {
            let m = score[id] as? [String: Any] ?? [:]
            if (m["playersData"] as? Bool) == true { continue }   // Score 有数据 → 沿用 Score 条目
            let l = local[id] ?? [:]
            guard !l.isEmpty else { continue }

            // 已缓存的实际条数（首次经官方通道拉取后会落盘，此处即可显示真实人数）
            func cachedCount(_ name: String) -> Int {
                let v = ToolsCache.getAny(name)
                if let a = v as? [Any] { return a.count }
                if let d = v as? [String: Any], let a = d["list"] as? [Any] { return a.count }
                return 0
            }
            let playerCnt = cachedCount("players-\(id).json")

            // 队伍数：优先用缓存的真实条数；未抓取时按官方 seasonid 尾号推算
            //（S3=年度总决赛 12 队，S1/S2=春/夏季赛 18 队——实测 2023~2026 全部如此）。
            // 注意：seasonid 尾号必须查映射表拿，不能对 App 赛事 id（如 "1201"）做字符串判断。
            let season = KPLStatsSource.seasonId(of: id) ?? ""
            let fixedTeams = season.hasSuffix("S3") ? 12 : 18
            let cachedTeams = cachedCount("teams-\(id).json")
            let teamsCnt = cachedTeams > 0 ? cachedTeams : fixedTeams

            out.append([
                "id": id,
                "name": ToolsUtil.str(l["name"]),
                "short": ToolsUtil.str(l["short"]),
                "year": ToolsUtil.int(l["year"]),
                "category": ToolsUtil.str(l["category"]),
                "start": ToolsUtil.str(l["start"]),
                "end": ToolsUtil.str(l["end"]),
                "players": playerCnt,       // 未抓取时为 0 → 前端标「收录中」，拉完自动变真实人数
                "teams": teamsCnt,
                "scoreId": 0,
                "hasPlayers": true,         // 官方通道可提供逐选手统计
                "pending": false,           // 不再是「收录中」（Score 通道的旧标记不适用官方）
                "source": "kpl",
            ])
        }
        return out
    }

    // MARK: - 赛季清单与覆盖度

    /// 赛季清单来自随包分发的 events.json；`KPL_EVENTS_FILE` 供命令行验证覆盖
    private func eventsFileURL() -> URL? {
        if let p = ProcessInfo.processInfo.environment["KPL_EVENTS_FILE"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return Bundle.main.url(forResource: "events", withExtension: "json")
    }

    func localEvents() -> [[String: Any]] {
        guard let url = eventsFileURL(),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let list = (obj["events"] as? [Any]) ?? []
        return list.compactMap { e -> [String: Any]? in
            guard let d = e as? [String: Any] else { return nil }
            let name = ToolsUtil.str(d["name"])
            return ["id": ToolsUtil.str(d["id"]),
                    "name": name,
                    "short": ToolsUtil.str(d["short"]).isEmpty ? name : ToolsUtil.str(d["short"]),
                    "year": ToolsUtil.int(d["year"]),
                    "category": ToolsUtil.str(d["category"]),
                    "start": ToolsUtil.str(d["start"]),
                    "end": ToolsUtil.str(d["end"])]
        }
    }

    /// 用 events.json 的赛期补齐清单里缺日期的条目
    private func withEventDates(_ items: [Any]) -> [Any] {
        var byId: [String: [String: Any]] = [:]
        for e in localEvents() { byId[ToolsUtil.str(e["id"])] = e }
        return items.compactMap { item -> [String: Any]? in
            guard var e = item as? [String: Any] else { return nil }
            guard let l = byId[ToolsUtil.str(e["id"])] else { return e }
            if ToolsUtil.str(e["start"]).isEmpty { e["start"] = ToolsUtil.str(l["start"]) }
            if ToolsUtil.str(e["end"]).isEmpty { e["end"] = ToolsUtil.str(l["end"]) }
            if ToolsUtil.str(e["short"]).isEmpty { e["short"] = ToolsUtil.str(l["short"]) }
            if ToolsUtil.int(e["year"]) == 0 { e["year"] = ToolsUtil.int(l["year"]) }
            return e
        }
    }

    private func coverageWanplus() async -> [String: Any] {
        if let c = ToolsCache.get("coverage.json") as? [String: Any],
           let items = c["items"] as? [Any], !items.isEmpty {
            return ["updatedAt": ToolsUtil.int(c["updatedAt"]), "events": withEventDates(items)]
        }
        let local = localEvents().map { e -> [String: Any] in
            var o = e; o["players"] = 0; o["teams"] = 0; return o
        }
        /* 覆盖度是「离线探测出来的静态清单」，运行时不会重新生成。
           即使超过 TTL，也必须继续沿用其中的 players / teams，
           否则默认赛季会退化成最旧的一年。 */
        if let any = ToolsCache.getAny("coverage.json") as? [String: Any],
           let items = any["items"] as? [Any], !items.isEmpty {
            var byId: [String: [String: Any]] = [:]
            for i in items {
                if let d = i as? [String: Any] { byId[ToolsUtil.str(d["id"])] = d }
            }
            return ["updatedAt": ToolsUtil.int(any["updatedAt"]),
                    "events": local.map { e -> [String: Any] in
                        guard let hit = byId[ToolsUtil.str(e["id"])] else { return e }
                        var o = e
                        o["players"] = ToolsUtil.int(hit["players"])
                        o["teams"] = ToolsUtil.int(hit["teams"])
                        return o
                    }]
        }
        return ["updatedAt": 0, "events": local]
    }

    func coverage() async -> [String: Any] {
        var wan = await coverageWanplus()
        // 官方通道（KPLStatsSource）覆盖的赛季并入 scoreEvents：
        // ① Score 清单里没有的 id → 直接追加；
        // ② Score 里有但只是 pending 占位（playersData 缺失，如 2026 年度总决赛）
        //    → **替换**成官方条目（hasPlayers=true / pending=false）。
        // 只追加不去重替换的话，占位条目会按 id 挤掉官方条目，
        // 导致「选手详情」下拉（按 hasPlayers 过滤）看不到该赛季——
        // 梯度榜不过滤 pending 所以能显示，两页表现不一致就是这个原因。
        var score = scoreEvents()
        let kpl = kplEvents()
        let kplIds = Set(kpl.map { ToolsUtil.str($0["id"]) })
        score.removeAll { kplIds.contains(ToolsUtil.str($0["id"])) }
        score.append(contentsOf: kpl)
        wan["scoreEvents"] = score
        return wan
    }

    /// 默认赛事：优先取「最近年份」中样本最多的赛季（联赛样本比杯赛完整）
    func pickDefaultEvent(_ cov: [String: Any]) -> [String: Any] {
        var ok = (cov["events"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            .filter { ToolsUtil.int($0["players"]) > 0 }
        ok.sort { a, b in
            let ya = ToolsUtil.int(a["year"]), yb = ToolsUtil.int(b["year"])
            if ya != yb { return ya > yb }
            return ToolsUtil.int(a["players"]) > ToolsUtil.int(b["players"])
        }
        if let first = ok.first { return first }
        let all = (cov["events"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            .sorted { ToolsUtil.int($0["year"]) < ToolsUtil.int($1["year"]) }
        return all.first ?? ["id": "1062", "name": "", "short": "", "year": 0, "players": 0]
    }

    /// 单个赛季的元信息（断网、只读缓存时也能完整渲染「基础资料」）
    func eventMeta(_ eid: String) async -> [String: Any] {
        let cov = await coverage()
        if let one = (cov["events"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] })
            .first(where: { ToolsUtil.str($0["id"]) == eid }) { return one }
        if let l = localEvents().first(where: { ToolsUtil.str($0["id"]) == eid }) {
            var o = l; o["players"] = 0; o["teams"] = 0; return o
        }
        return ["id": eid, "name": "", "short": "", "year": 0, "players": 0, "teams": 0]
    }

    func defaultEventId() async -> String {
        ToolsUtil.str(pickDefaultEvent(await coverage())["id"])
    }

    // MARK: - 带兜底的对外入口（对应 JS 导出层的 staleSafe）

    func heroesSafe() async throws -> Any {
        try await staleSafe("heroes.json", { try await self.heroes() })
    }
    func itemsSafe() async throws -> Any {
        try await staleSafe("items.json", { try await self.items() })
    }
    func runesSafe() async throws -> Any {
        try await staleSafe("runes.json", { try await self.runes() })
    }
    func skinsSafe() async throws -> Any {
        try await staleSafe("skins.json", {
            let v = try await self.skinsCatalog()
            // 数据源真正重抓过 → 记忆化的高清图索引随之失效
            self.invalidateMemoCaches()
            return v
        })
    }
    func heroDetailSafe(_ id: String) async throws -> Any {
        try await staleSafe("hero-\(id).json", { try await self.heroDetail(id) })
    }
}

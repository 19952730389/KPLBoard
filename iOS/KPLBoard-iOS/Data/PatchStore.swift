import Foundation

/// KPL 工具箱 · 版本动态数据源（王者荣耀官网）。逐行移植自桌面版 patch-sources.js。
///
/// 数据来自腾讯官方内容中台，与官网「新闻列表 / 新闻详情」同源：
///   - 列表 `apps.game.qq.com/wmp/v3.1/?p0=18&p1=searchNewsKeywordsList&…`（p0=18 即王者荣耀）
///   - 详情 `apps.game.qq.com/wmp/v3.1/public/searchNews.php?p0=18&id=<公告 id>`
///
/// 接口返回的是 `var NewsObj1={...};` 形式的 JS literal，需先剥壳再解析。
/// 职责：拉取更新公告 → 解析「调整小节 → 实体名 → 改动明细」→ 与本地英雄/装备/铭文库做名字对齐。
actor PatchStore {
    static let shared = PatchStore()

    private static let gameId = 18
    private static let listApi = "https://apps.game.qq.com/wmp/v3.1/"
    private static let detailApi = "https://apps.game.qq.com/wmp/v3.1/public/searchNews.php"
    private static let officialSite = "https://pvp.qq.com/"

    private static let ttlList: TimeInterval = 30 * 60 * 1000      // 公告列表 30 分钟
    private static let ttlDetail: TimeInterval = 24 * 3600 * 1000  // 公告正文基本不再变更，缓存 1 天

    private static func newsUrl(_ id: String) -> String {
        "\(officialSite)web201706/newsdetail.shtml?tid=\(id)"
    }

    // MARK: - 网络

    private func getText(_ url: String, timeout: TimeInterval = 15) async throws -> String {
        try await Net.getText(url, headers: ["Referer": Self.officialSite], timeout: timeout)
    }

    /// 接口返回 `var NewsObj1={...};` 形式的 JS literal，剥壳后解析
    private func parseJsLiteral(_ text: String) throws -> [String: Any] {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"^var\s+[A-Za-z0-9_$]+\s*=\s*"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        if s.hasSuffix(";") { s.removeLast() }
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Net.NetError.notJSON
        }
        return obj
    }

    // MARK: - HTML → 结构化行

    private func htmlToBlocks(_ html: String) -> [String] {
        // 保留标题层级：@@H<level>@@
        let marked = html
            .re(#"<h([1-6])[^>]*>"#, "\n@@H$1@@")
            .re(#"</h[1-6]>"#, "\n")
            .re(#"<br\s*/?>"#, "\n")
            .re(#"</(p|div|li|tr|td)>"#, "\n")
            .re(#"<li[^>]*>"#, "\n· ")
            .re(#"<[^>]+>"#, "")
            .re("&nbsp;", " ")
            .re("&amp;", "&")
            .re("&lt;", "<")
            .re("&gt;", ">")
            .re("&quot;", "\"")
            .re("&rarr;|&ndash;|&mdash;", "→")
        // &#123; 形式的数字实体需按码位还原。
        // 原来是「反复 range(of:) + decoded += 」→ 每次都从 idx 重新扫描剩余串、
        // 且 += 是 O(n) 拷贝，长公告（几十 KB、几百个实体）呈 O(n²)。
        // 改为一次正则遍历 + 一次性拼接。
        let out = marked
        var decoded = ""
        decoded.reserveCapacity(out.utf8.count)
        var idx = out.startIndex
        let entity = try? NSRegularExpression(pattern: #"&#(\d+);"#)
        let nsRange = NSRange(out.startIndex..., in: out)
        if let entity {
            for m in entity.matches(in: out, range: nsRange) {
                guard let full = Range(m.range, in: out),
                      let g = Range(m.range(at: 1), in: out) else { continue }
                decoded += out[idx..<full.lowerBound]
                if let code = UInt32(out[g]), let scalar = Unicode.Scalar(code) {
                    decoded.append(Character(scalar))
                }
                idx = full.upperBound
            }
        }
        decoded += out[idx...]
        return decoded.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func stripTags(_ line: String) -> String {
        line.re(#"@@H\d@@"#, "").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 实体字典（名字 → 条目）

    private struct DictEntry {
        let kind: String; let name: String; let id: String
        let icon: String; let title: String; let type: String
    }
    private var dictCache: [String: (keys: [String], map: [String: DictEntry])]?

    private func loadDict() -> [String: (keys: [String], map: [String: DictEntry])] {
        if let c = dictCache { return c }
        func mk(_ kind: String, _ list: [Any], _ iconOf: ([String: Any]) -> String)
            -> (keys: [String], map: [String: DictEntry]) {
            var keys: [String] = []
            var map: [String: DictEntry] = [:]
            for item in list {
                guard let e = item as? [String: Any] else { continue }
                let name = ToolsUtil.str(e["name"]).trimmingCharacters(in: .whitespaces)
                if name.isEmpty || map[name] != nil { continue }
                keys.append(name)
                map[name] = DictEntry(kind: kind, name: name,
                                      id: ToolsUtil.str(e["id"]),
                                      icon: ToolsUtil.str(e["icon"]).isEmpty ? iconOf(e) : ToolsUtil.str(e["icon"]),
                                      title: ToolsUtil.str(e["title"]),
                                      type: ToolsUtil.str(e["type"]).isEmpty ? ToolsUtil.str(e["colorName"]) : ToolsUtil.str(e["type"]))
            }
            return (keys, map)
        }
        // 种子优先：离线时也能完成名字对齐
        let heroes = ToolsCache.getAny("heroes.json")
        let items = ToolsCache.getAny("items.json")
        let runesRaw = ToolsCache.getAny("runes.json")
        let hl = ToolsJSON.array(heroes)
        let il = ToolsJSON.array(items)
        let rl = ToolsJSON.array(runesRaw)

        let d: [String: (keys: [String], map: [String: DictEntry])] = [
            "hero": mk("hero", hl, { e in
                let id = ToolsUtil.str(e["id"])
                return "https://game.gtimg.cn/images/yxzj/img201606/heroimg/\(id)/\(id).jpg"
            }),
            "item": mk("item", il, { e in
                "https://game.gtimg.cn/images/yxzj/img201606/itemimg/\(ToolsUtil.str(e["id"])).jpg"
            }),
            "rune": mk("rune", rl, { e in
                "https://game.gtimg.cn/images/yxzj/img201606/mingwen/\(ToolsUtil.str(e["id"])).png"
            }),
        ]
        dictCache = d
        return d
    }

    // MARK: - 方向判定

    private static let upWords = ["增强", "加强", "提升", "提高", "上调", "增加", "加长", "扩大", "缩短冷却", "优化"]
    private static let downWords = ["削弱", "降低", "下调", "减少", "减弱", "变慢", "加长冷却"]

    /// 数值型改动（old → new）优先用数值比较，其次用关键词
    private func dirOfLines(_ lines: [String]) -> String {
        var up = 0, down = 0
        for raw in lines {
            let l = String(raw)
            /* 只认「旧 → 新」箭头，避免把「320~640」这类区间误判为数值变化。
               JS 取第一个匹配（String.match 非全局），这里同样只取首条。 */
            if let g = ToolsUtil.allMatches(l, #"(-?\d+(?:\.\d+)?)\s*(?:→|->)\s*(-?\d+(?:\.\d+)?)"#).first,
               g.count > 2, let a = Double(g[1]), let b = Double(g[2]),
               a.isFinite, b.isFinite, a != b {
                if b > a { up += 1 } else { down += 1 }
                continue
            }
            for w in Self.upWords where l.contains(w) { up += 1 }
            for w in Self.downWords where l.contains(w) { down += 1 }
        }
        if up > down { return "buff" }
        if down > up { return "nerf" }
        return "adjust"
    }

    // MARK: - 公告分类

    private static let patchRe = try! NSRegularExpression(
        pattern: "(版本更新|不停机更新|停机更新|体验服|平衡性调整|英雄调整|装备调整|铭文调整|问题修复|技能调整|数值调整)")
    private static let kindRe: [String: NSRegularExpression] = [
        "hero": try! NSRegularExpression(pattern: "(英雄(平衡性)?调整|英雄平衡|英雄数值)"),
        "item": try! NSRegularExpression(pattern: "(装备调整|装备平衡|装备案|道具调整)"),
        "rune": try! NSRegularExpression(pattern: "(铭文调整|铭文平衡)"),
    ]

    private func test(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// 公告标题里直接点名的分类（如「英雄平衡性调整 | 马超、海月平衡」）
    private func kindOfTitle(_ title: String) -> [String] {
        if test(Self.kindRe["rune"]!, title) { return ["rune"] }
        if test(Self.kindRe["item"]!, title) { return ["item"] }
        if test(Self.kindRe["hero"]!, title) { return ["hero"] }
        if title.contains("平衡性调整") { return ["hero"] }
        return []
    }

    // MARK: - 公告正文 → 调整条目

    /**
     解析策略：
       1. 抽出所有标题行（@@Hn@@ 标记 + 形如「【xxx】」的短行）
       2. 遇到「调整类」小节的标题 → 进入该分类语境
       3. 小节内下一个层级的标题若命中实体字典 → 记为一条调整，正文行归到它名下
       4. 若正文里没有显式标题，退化为「行首命中实体名」的扫描
     */
    private func parseContent(_ html: String) -> [[String: Any]] {
        parseContent(blocks: htmlToBlocks(html))
    }

    /// 接受已解析好的 blocks，避免调用方重复解析同一篇 HTML。
    private func parseContent(blocks: [String]) -> [[String: Any]] {
        let dict = loadDict()
        var out: [[String: Any]] = []
        var seen = Set<String>()

        func push(_ kind: String, _ name: String, _ lines: [String], _ section: String) {
            let body = lines.map { stripTags($0) }.filter { !$0.isEmpty }
            if body.isEmpty { return }
            let key = "\(kind):\(name):\(section)"
            if seen.contains(key) { return }
            seen.insert(key)
            let ent = dict[kind]?.map[name]
            out.append([
                "kind": kind,
                "name": name,
                "id": ent?.id ?? "",
                "icon": ent?.icon ?? "",
                "title": ent?.title ?? "",
                "type": ent?.type ?? "",
                "section": section,
                "dir": dirOfLines(body),
                "lines": Array(body.prefix(12)),
                "summary": body.joined(separator: " / ").count > 200
                    ? String(body.joined(separator: " / ").prefix(200))
                    : body.joined(separator: " / "),
            ])
        }

        // ---- 第一遍：标题驱动 ----
        var context = ""            // 当前所在调整小节名（如「英雄调整」）
        var contextKind: String? = nil
        var cur: (kind: String, name: String, lines: [String])? = nil
        func flush() {
            if let c = cur { push(c.kind, c.name, c.lines, context) }
            cur = nil
        }

        let headRe = try! NSRegularExpression(pattern: #"^@@H(\d)@@(.*)$"#)
        let bracketRe = try! NSRegularExpression(pattern: #"^【[^】]{2,20}】$"#)

        for raw in blocks {
            let isHead = test(headRe, raw)
            let text = stripTags(raw)
            if text.isEmpty { continue }

            if isHead || test(bracketRe, text) {
                flush()
                var t = text.replacingOccurrences(of: "【", with: "").replacingOccurrences(of: "】", with: "")
                t = t.trimmingCharacters(in: .whitespaces)
                // 小节标题：命中「…调整」
                if let hitKind = Self.kindRe.first(where: { test($0.value, t) })?.key {
                    context = t
                    contextKind = hitKind
                    continue
                }
                // 实体标题：命中字典
                let pool = contextKind.map { [$0] } ?? ["hero", "item", "rune"]
                var matched: (String, String)? = nil
                for k in pool {
                    guard let d = dict[k] else { continue }
                    if d.map[t] != nil { matched = (k, t); break }
                    // 允许「海月 平衡」这类带后缀的写法
                    if let alt = d.keys.first(where: { t.hasPrefix($0) && t.count <= $0.count + 6 }) {
                        matched = (k, alt); break
                    }
                }
                if let m = matched {
                    cur = (m.0, m.1, [])
                    continue
                }
                // 未命中：可能是普通小节（如皮肤上架），清空实体语境
                if !t.contains("调整") && !t.contains("平衡") { context = ""; contextKind = nil }
                continue
            }
            if cur != nil { cur!.lines.append(text) }
        }
        flush()

        // ---- 第二遍：行首实体名（标题结构化缺失时的兜底） ----
        if out.isEmpty {
            for raw in blocks {
                let text = stripTags(raw)
                if text.isEmpty || text.count > 60 { continue }
                for kind in ["hero", "item", "rune"] {
                    guard let d = dict[kind] else { continue }
                    let hit = d.keys.first {
                        text == $0 || text.hasPrefix("\($0)：") || text.hasPrefix("\($0):") || text.hasPrefix("\($0) ")
                    }
                    if let name = hit {
                        push(kind, name, [text], context.isEmpty ? "正文" : context)
                        break
                    }
                }
            }
        }
        return out
    }

    // MARK: - 对外接口

    /// 官网公告列表。
    /// `force=true`：绕过内嵌磁盘缓存直打上游（用户点「立即同步 / 刷新」时必须
    /// 能看到最新公告——否则 30 分钟 TTL 内 feed 每次返回完全相同的 JSON，
    /// 前端缓存层 revalidate 判定「内容无变化」不派发更新，页面就永远停在旧数据上）。
    func newsList(page: Int = 1, pageSize: Int = 20, force: Bool = false) async throws -> [String: Any] {
        let page = max(1, page)
        let pageSize = min(50, max(1, pageSize))
        let cacheName = "patch-list-\(page)-\(pageSize).json"
        if !force, let cached = ToolsCache.getForPatch(cacheName, ttlMs: Self.ttlList) as? [String: Any] {
            var o = cached; o["cached"] = true; return o
        }
        let url = "\(Self.listApi)?p0=\(Self.gameId)&p1=searchNewsKeywordsList&page=\(page)&pagesize=\(pageSize)" +
                  "&order=sIdxTime&r0=script&r1=KplNewsObj&source=web_pc"
        let j = try await parseJsLiteral(getText(url))
        let msg = j["msg"] as? [String: Any] ?? [:]
        let result = msg["result"] as? [Any] ?? []
        let items: [[String: Any]] = result.compactMap { x -> [String: Any]? in
            guard let d = x as? [String: Any] else { return nil }
            // 原来是 `iNewsId` 与 `iNewsId` 两个分支完全相同（复制粘贴 bug），
            // 导致 iNewsId 缺失时拿到空 id → url 变成 tid=（死链），
            // 且被 feed() 的 !isEmpty 过滤悄悄丢弃、用户看到公告条数变少。
            // 改为按优先级回退：iNewsId → id → sIdxTime。
            let id = ToolsUtil.str(d["iNewsId"]).isEmpty
                ? (ToolsUtil.str(d["id"]).isEmpty ? ToolsUtil.str(d["sIdxTime"]) : ToolsUtil.str(d["id"]))
                : ToolsUtil.str(d["iNewsId"])
            let title = ToolsUtil.str(d["sTitle"]).trimmingCharacters(in: .whitespaces)
            let covers = (d["sCoverList"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            var cover = ToolsUtil.str(covers.first?["url"])
            if cover.isEmpty { cover = ToolsUtil.str(d["sIMG"]) }
            return [
                "id": id,
                "title": title,
                "time": String(ToolsUtil.str(d["sIdxTime"]).isEmpty ? ToolsUtil.str(d["sCreated"]).prefix(19)
                                                                   : ToolsUtil.str(d["sIdxTime"]).prefix(19)),
                "author": ToolsUtil.str(d["sAuthor"]),
                "desc": String(ToolsUtil.str(d["sDesc"]).prefix(120)),
                "cover": cover,
                "tags": ToolsUtil.str(d["sTagIds"]).components(separatedBy: ",").filter { !$0.isEmpty },
                "url": Self.newsUrl(id),
                "patch": test(Self.patchRe, title),
                "kinds": kindOfTitle(title),
            ]
        }
        let total = ToolsUtil.int(msg["total"])
        let data: [String: Any] = [
            "ok": true,
            "total": total > 0 ? total : items.count,
            "page": page,
            "pageSize": pageSize,
            "updatedAt": Int(Date().timeIntervalSince1970 * 1000),
            "source": ["name": "王者荣耀官方网站", "url": Self.officialSite],
            "items": items,
        ]
        ToolsCache.set(cacheName, data)
        var o = data; o["cached"] = false; return o
    }

    /// 官网公告正文（含结构化调整条目）。`force=true` 绕过内嵌磁盘缓存（同 newsList）。
    func newsDetail(_ id: String, force: Bool = false) async throws -> [String: Any] {
        let key = id.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy({ $0.isNumber }) else { throw Net.NetError.upstream("公告 id 非法") }
        let cacheName = "patch-detail-\(key).json"
        if !force, let cached = ToolsCache.getForPatch(cacheName, ttlMs: Self.ttlDetail) as? [String: Any] {
            var o = cached; o["cached"] = true; return o
        }
        let url = "\(Self.detailApi)?p0=\(Self.gameId)&source=web_pc&id=\(key)"
        let j = try await parseJsLiteral(getText(url))
        let m = j["msg"] as? [String: Any] ?? [:]
        let title = ToolsUtil.str(m["sTitle"]).trimmingCharacters(in: .whitespaces)
        let content = ToolsUtil.str(m["sContent"])
        // 解析一次复用：htmlToBlocks 是重活（11 条正则），
        // 此前 parseContent 内部调一次、下面又调一次 → 同一篇 HTML 解析两遍。
        let blocks = htmlToBlocks(content)
        let data: [String: Any] = [
            "ok": true,
            "id": key,
            "title": title,
            "time": String((ToolsUtil.str(m["sIdxTime"]).isEmpty ? ToolsUtil.str(m["sCreated"]) : ToolsUtil.str(m["sIdxTime"])).prefix(19)),
            "version": ToolsUtil.str(m["sGameVersion"]),
            "author": ToolsUtil.str(m["sAuthor"]),
            "url": Self.newsUrl(key),
            "patch": test(Self.patchRe, title),
            "kinds": kindOfTitle(title),
            // 原先这里对同一篇 HTML 解析了**两遍**：parseContent 内部已调
            // htmlToBlocks，下面又调一次。htmlToBlocks 是 11 次正则替换的重活，
            // feed() 默认 8 条 → 16 遍。改为解析一次、两处复用。
            "changes": parseContent(blocks: blocks),
            "text": blocks.map { stripTags($0) },
            "updatedAt": Int(Date().timeIntervalSince1970 * 1000),
        ]
        ToolsCache.set(cacheName, data)
        var o = data; o["cached"] = false; return o
    }

    /// 版本动态总览：最近 N 条更新公告 + 合并后的调整条目。
    /// `force=true`：整条链路（列表 + 详情）都绕过内嵌缓存。
    func feed(limit: Int = 8, scan: Int? = nil, force: Bool = false) async throws -> [String: Any] {
        let limit = min(30, max(1, limit))
        let scan = min(60, max(limit * 2, scan ?? 30))

        let list = try await newsList(page: 1, pageSize: scan, force: force)
        let items = list["items"] as? [Any] ?? []
        let notes = items.compactMap { $0 as? [String: Any] }
            .filter { ($0["patch"] as? Bool) == true && !ToolsUtil.str($0["id"]).isEmpty }
            .prefix(limit)

        var changes: [[String: Any]] = []
        var perNote: [[String: Any]] = []
        for n in notes {
            let d = try? await newsDetail(ToolsUtil.str(n["id"]), force: force)
            let cs = d?["changes"] as? [[String: Any]] ?? []
            perNote.append([
                "id": ToolsUtil.str(n["id"]),
                "title": ToolsUtil.str(n["title"]),
                "time": ToolsUtil.str(n["time"]),
                "version": ToolsUtil.str(d?["version"]),
                "url": ToolsUtil.str(n["url"]),
                "kinds": n["kinds"] as? [String] ?? [],
                "changeCount": cs.count,
                "offline": d == nil,
            ])
            for c in cs {
                var o = c
                o["newsId"] = ToolsUtil.str(n["id"])
                o["newsTitle"] = ToolsUtil.str(n["title"])
                o["newsTime"] = ToolsUtil.str(n["time"])
                o["newsUrl"] = ToolsUtil.str(n["url"])
                o["version"] = ToolsUtil.str(d?["version"])
                changes.append(o)
            }
        }

        // 同一实体在多条公告里出现时，只保留最新一条。
        // JS 的 Map 保持插入顺序，最终的 sort 又不稳定 —— 用 keys 数组固定插入序。
        var latestKeys: [String] = []
        var latest: [String: [String: Any]] = [:]
        for c in changes {
            let k = "\(ToolsUtil.str(c["kind"])):\(ToolsUtil.str(c["name"]))"
            if let prev = latest[k] {
                if ToolsUtil.str(prev["newsTime"]) >= ToolsUtil.str(c["newsTime"]) { continue }
            } else {
                latestKeys.append(k)
            }
            latest[k] = c
        }

        var counts: [String: Int] = ["hero": 0, "item": 0, "rune": 0]
        for c in latest.values {
            let k = ToolsUtil.str(c["kind"])
            counts[k] = (counts[k] ?? 0) + 1
        }

        return [
            "ok": true,
            "updatedAt": Int(Date().timeIntervalSince1970 * 1000),
            "source": ["name": "王者荣耀官方网站", "url": Self.officialSite, "listApi": Self.listApi],
            "offline": perNote.isEmpty ? false : perNote.allSatisfy { ($0["offline"] as? Bool) == true },
            "notes": perNote,
            "changes": ToolsUtil.stableSorted(latestKeys.compactMap { latest[$0] }) {
                ToolsUtil.str($0["newsTime"]) > ToolsUtil.str($1["newsTime"])
            },
            "counts": counts,
            "latestVersion": perNote.first(where: { !ToolsUtil.str($0["version"]).isEmpty })?["version"] ?? "",
            "latestTime": perNote.first?["time"] ?? "",
        ]
    }

    /// 把最新调整按实体名索引，供英雄 / 装备 / 铭文详情展示「近期调整」
    func changesByName(force: Bool = false) async throws -> [String: Any] {
        let key = "patch-changes.json"
        if !force, let cached = ToolsCache.getForPatch(key, ttlMs: Self.ttlList) as? [String: Any] { return cached }
        let f = try await feed(limit: 8, force: force)
        var map: [String: Any] = [:]
        for c in f["changes"] as? [[String: Any]] ?? [] {
            map["\(ToolsUtil.str(c["kind"])):\(ToolsUtil.str(c["name"]))"] = c
        }
        let data: [String: Any] = ["ok": true, "updatedAt": Int(Date().timeIntervalSince1970 * 1000), "map": map]
        ToolsCache.set(key, data)
        return data
    }

    /// 手动同步（清空缓存后重新抓取）。
    /// feed(force: true)：refresh 已删光缓存文件，抓取时也不再命中任何内嵌缓存；
    /// 此前 feed 不带 force 时虽有删缓存兜底，但 seed 目录（安装包内只读）里的
    /// 同名条目仍可能被 getForPatch 命中——force 一并绕过，保证同步后一定是最新数据。
    func refresh() async throws -> [String: Any] {
        guard let dir = ToolsCache.writeDir else {
            return ["ok": false, "error": "未配置可写缓存目录，无法落盘缓存"]
        }
        var removed = 0
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            if f.hasPrefix("patch-list") || f.hasPrefix("patch-detail") || f.hasPrefix("patch-changes"),
               f.hasSuffix(".json") {
                try? fm.removeItem(at: dir.appendingPathComponent(f))
                removed += 1
            }
        }
        let f = try await feed(limit: 8, force: true)
        return ["ok": true, "removed": removed,
                "updatedAt": f["updatedAt"] ?? 0,
                "notes": (f["notes"] as? [Any])?.count ?? 0,
                "changes": (f["changes"] as? [Any])?.count ?? 0,
                "counts": f["counts"] ?? [:]]
    }
}

// MARK: - String 正则替换糖

private extension String {
    /// 大小写不敏感的正则替换（对齐 JS 的 /…/gi）。
    /// 正则**按 pattern 缓存**：htmlToBlocks 有 11 条规则、newsDetail 还会跑两遍，
    /// feed() 默认 8 条公告 ≈ 176 次编译。NSRegularExpression 编译代价不低，
    /// 缓存后只在首次命中时编译一次。
    func re(_ pattern: String, _ with: String) -> String {
        guard let regex = Self.cachedRegex(pattern) else { return self }
        return regex.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: with)
    }

    private static let regexCacheLock = NSLock()
    private static var regexCache: [String: NSRegularExpression] = [:]

    private static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        regexCacheLock.lock()
        if let hit = regexCache[pattern] { regexCacheLock.unlock(); return hit }
        regexCacheLock.unlock()
        guard let made = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        regexCacheLock.lock()
        regexCache[pattern] = made
        regexCacheLock.unlock()
        return made
    }
}

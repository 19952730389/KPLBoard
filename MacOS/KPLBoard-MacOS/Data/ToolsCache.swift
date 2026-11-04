import Foundation

/// 工具箱 / 版本公告的磁盘缓存。对应桌面版 tools-sources.js 与 patch-sources.js 顶部的缓存段。
///
/// 两级目录，语义与桌面版一致：
///   - **种子目录** `seed`：安装包自带的离线数据（`Resources/data/tools`，299 个 JSON、约 12 MB）。
///     只读、随版本更新，用于「断网也能完整查看」——梯度榜 2023~2026 的赛季、选手榜、
///     英雄详情等上游拿不到的部分全靠它。
///   - **可写目录** `write`：`~/Library/Application Support/KPLBoard-MacOS/tools`。
///     App Sandbox 下程序目录不可写，运行时抓到的数据落这里，下次启动直接命中。
///
/// 读取顺序：可写目录（受 TTL）→ 种子目录（受 TTL）；忽略 TTL 的 `getAny` 走同样顺序。
enum ToolsCache {

    /// 安装包自带种子（folder reference 引入，保留目录结构）。
    /// `KPL_SEED_DIR` 用于命令行验证（脱离 Bundle 跑真实接口时指向种子目录）。
    static var seedDir: URL? {
        if let p = ProcessInfo.processInfo.environment["KPL_SEED_DIR"], !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return Bundle.main.resourceURL?.appendingPathComponent("data/tools", isDirectory: true)
    }

    /// 用户级可写缓存目录（`KPL_WRITE_DIR` 同理，供命令行验证覆盖）
    static var writeDir: URL? {
        if let p = ProcessInfo.processInfo.environment["KPL_WRITE_DIR"], !p.isEmpty {
            let dir = URL(fileURLWithPath: p, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir = base?.appendingPathComponent("KPLBoard-MacOS/tools", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func read(_ dir: URL?, _ name: String) -> Any? {
        guard let dir else { return nil }
        let f = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: f) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func mtime(_ dir: URL?, _ name: String) -> TimeInterval {
        guard let dir else { return 0 }
        let f = dir.appendingPathComponent(name)
        let attrs = try? FileManager.default.attributesOfItem(atPath: f.path)
        return (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }

    private static func fresh(_ dir: URL?, _ name: String, ttlMs: TimeInterval?) -> Bool {
        guard let ttlMs, ttlMs > 0 else { return true }
        let mt = mtime(dir, name)
        guard mt > 0 else { return false }
        return Date().timeIntervalSince1970 * 1000 - mt * 1000 <= ttlMs
    }

    /// 受 TTL 约束的读取：可写目录 → 种子目录，都不新鲜返回 nil
    static func get(_ name: String, ttlMs: TimeInterval? = nil) -> Any? {
        if let hit = read(writeDir, name), fresh(writeDir, name, ttlMs: ttlMs) { return hit }
        if let hit = read(seedDir, name), fresh(seedDir, name, ttlMs: ttlMs) { return hit }
        return nil
    }

    /// 版本公告专用缓存读取（对齐 patch-sources.js 的 cacheGet）：
    /// 可写目录受 TTL，**种子不判 TTL** —— 离线环境下宁可展示旧数据，也不留空面板。
    static func getForPatch(_ name: String, ttlMs: TimeInterval?) -> Any? {
        if let hit = read(writeDir, name), fresh(writeDir, name, ttlMs: ttlMs) { return hit }
        return read(seedDir, name)
    }

    /// 忽略 TTL 的读取：上游不可用时用它兜底，保证断网也能出内容
    static func getAny(_ name: String) -> Any? {
        if let hit = read(writeDir, name) { return hit }
        return read(seedDir, name)
    }

    /// 写入可写目录；未配置可写目录时静默失败（不污染程序目录）
    @discardableResult
    static func set(_ name: String, _ value: Any) -> Bool {
        guard let dir = writeDir else { return false }
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return false }
        do {
            try data.write(to: dir.appendingPathComponent(name))
            return true
        } catch {
            return false
        }
    }

    /// 删除可写目录里的缓存（种子目录只读、不受影响）。
    /// 用于清掉旧版本落盘的空结果——它们会遮蔽种子与官方通道，形成永久空态。
    static func remove(_ name: String) {
        guard let dir = writeDir else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }

    /// 是否具备可写目录（/api/patch?what=refresh 与公告落盘依赖它）
    static var writable: Bool { writeDir != nil }
}

// MARK: - JSON 小工具（对齐 tools-sources.js 的同名函数）

enum ToolsJSON {

    /// `Any` → 数组，非数组返回空
    static func array(_ v: Any?) -> [Any] {
        if let a = v as? [Any] { return a }
        if let d = v as? [String: Any] {
            for k in ["items", "list", "heroes", "data", "events"] { if let a = d[k] as? [Any] { return a } }
        }
        return []
    }

    static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }

    static func dicts(_ v: Any?) -> [[String: Any]] {
        array(v).compactMap { $0 as? [String: Any] }
    }
}

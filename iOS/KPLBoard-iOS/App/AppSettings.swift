import SwiftUI

// MARK: - 应用设置（外观 / 悬浮玻璃 / 底部导航）

/// 外观三档——与前端 `theme.js` 的 `auto / light / dark` 一一对应。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    var note: String {
        switch self {
        case .system: return "随系统深浅色自动切换"
        case .light:  return "固定使用浅色主题"
        case .dark:   return "固定使用深色主题"
        }
    }

    /// 传给 `window.KPLTheme.set(...)` 的值（前端约定就是 auto/light/dark）
    var webValue: String { rawValue }

    /// 原生侧同步用 `.preferredColorScheme`：
    /// 既让导航栏 / 底栏 / 设置页一起换肤，也会改写 WKWebView 的
    /// `prefers-color-scheme`，使前端 auto 档跟着走。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// 悬浮玻璃档位——对应 Apple「透明度」设置的强/均衡/弱。
/// 材质决定模糊强度，着色层决定不透明度，两者叠加出三档观感。
enum GlassLevel: String, CaseIterable, Identifiable {
    /// 更透：接近 iOS 26 Liquid Glass 默认观感
    case clear
    /// 均衡：默认值
    case balanced
    /// 更实：内容对比度更高
    case solid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .clear:    return "更透"
        case .balanced: return "均衡"
        case .solid:    return "更实"
        }
    }

    var note: String {
        switch self {
        case .clear:    return "模糊弱、着色少，透出更多内容"
        case .balanced: return "模糊与着色适中（推荐）"
        case .solid:    return "提升底栏与内容的对比度"
        }
    }

    /// 系统材质（iOS 官方提供的三档模糊）—— 用于悬浮玻璃底栏
    var material: Material {
        switch self {
        case .clear:    return .ultraThinMaterial
        case .balanced: return .thinMaterial
        case .solid:    return .regularMaterial
        }
    }

    /// 在材质之上叠加的着色不透明度（`Color.primary` 会随深浅色自动取黑/白）
    var tintAlpha: Double {
        switch self {
        case .clear:    return 0.08
        case .balanced: return 0.18
        case .solid:    return 0.32
        }
    }
}

/// 跨启动的界面偏好。单例 + ObservableObject：设置页与外壳同时订阅，
/// 改动即时生效（无需重启，也不需要重建 WKWebView）。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let appearance = "kplbar.appearance"
        static let glass      = "kplbar.glass"
        static let tabs       = "kplbar.tabs"
    }

    /// 底栏最多放 4 个模块（第 5 个固定是「更多」——Apple 人机规范页签 ≤ 5）
    static let maxTabs = 4
    /// 默认底栏：比分看板 / 梯度榜 / 选手详情 / 版本动态
    /// 英雄、装备、铭文、原画画廊默认收进「更多」，可在设置里调回来。
    static let defaultTabIDs = ["board", "gradient", "player", "patch"]

    @Published private(set) var appearance: AppearanceMode
    @Published private(set) var glass: GlassLevel
    /// 显示在底栏的模块 id（最多 4 个）
    @Published private(set) var tabIDs: [String]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        glass = GlassLevel(rawValue: defaults.string(forKey: Key.glass) ?? "") ?? .balanced

        let saved = (defaults.string(forKey: Key.tabs) ?? "")
            .split(separator: ",")
            .map(String.init)
            .filter { ModuleCatalog.byID($0) != nil }
        var ids = Array(saved.uniqued.prefix(Self.maxTabs))
        if ids.isEmpty { ids = Self.defaultTabIDs }
        tabIDs = ids
    }

    func setAppearance(_ mode: AppearanceMode) {
        guard mode != appearance else { return }
        appearance = mode
        defaults.set(mode.rawValue, forKey: Key.appearance)
    }

    func setGlass(_ level: GlassLevel) {
        guard level != glass else { return }
        glass = level
        defaults.set(level.rawValue, forKey: Key.glass)
    }

    /// 整体替换底栏模块（设置页批量提交时用）
    func setTabIDs(_ ids: [String]) {
        let valid = Array(ids.filter { ModuleCatalog.byID($0) != nil }.uniqued.prefix(Self.maxTabs))
        guard !valid.isEmpty, valid != tabIDs else { return }
        tabIDs = valid
        defaults.set(valid.joined(separator: ","), forKey: Key.tabs)
    }

    /// 开关一个模块；关闭时保证至少剩 1 个
    func toggleTab(_ id: String, on: Bool) {
        guard ModuleCatalog.byID(id) != nil else { return }
        var ids = tabIDs
        if on {
            guard ids.count < Self.maxTabs, !ids.contains(id) else { return }
            // 保持与 ModuleCatalog.all 一致的展示顺序
            ids = ModuleCatalog.all.map(\.id).filter { ids.contains($0) || $0 == id }
        } else {
            guard ids.count > 1 else { return }
            ids.removeAll { $0 == id }
        }
        setTabIDs(ids)
    }
}

private extension Sequence where Element: Hashable {
    /// 去重并保序（Swift 标准库没有现成的 unique）
    var uniqued: [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

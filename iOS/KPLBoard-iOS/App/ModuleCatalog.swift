import SwiftUI

/// 应用的功能模块清单。
///
/// `id` **必须与前端 `Resources/web/shell.js` 的 `NAV` 完全一致**——
/// 原生侧栏 / 底栏只负责选中态，真正的内容切换由 `KPLShell.setView(id)` 在页面内完成，
/// 因此这里的 id 就是前后端之间的唯一契约。
struct KPLModule: Identifiable, Hashable {
    /// 前端视图 id（board / gradient / player / items / runes / hero / gallery / patch）
    let id: String
    /// 短名（iPhone 底栏两字标签 / iPad 侧栏行标题）
    let name: String
    /// 副标题（iPad 侧栏的 note）
    let note: String
    /// SF Symbols 名称（系统内置，随 iOS 提供，不需要图片资源）
    let symbol: String

    var displayName: String { name }
}

enum ModuleCatalog {

    /// 八个功能模块（顺序与前端默认顺序一致）
    static let all: [KPLModule] = [
        KPLModule(id: "board",    name: "比分看板", note: "实时比分 · 战绩榜 · 赛程", symbol: "trophy.fill"),
        KPLModule(id: "gradient", name: "梯度榜",   note: "职业赛场英雄梯度",        symbol: "chart.bar.fill"),
        KPLModule(id: "player",   name: "选手详情", note: "KDA · 经济 · 英雄池",     symbol: "person.fill"),
        KPLModule(id: "items",    name: "装备",     note: "官方装备图鉴",            symbol: "bag.fill"),
        KPLModule(id: "runes",    name: "铭文",     note: "红蓝绿铭文图鉴",          symbol: "sparkles"),
        KPLModule(id: "hero",     name: "英雄详情", note: "技能 · 属性 · 皮肤",      symbol: "shield.fill"),
        KPLModule(id: "gallery",  name: "原画画廊", note: "皮肤原画与品质",          symbol: "photo.fill"),
        KPLModule(id: "patch",    name: "版本动态", note: "官网更新公告与调整",      symbol: "newspaper.fill"),
    ]

    /// 按显示顺序取底栏模块
    static func modules(withIDs ids: [String]) -> [KPLModule] {
        all.filter { ids.contains($0.id) }
    }

    /// 未显示在底栏的模块（收进「更多」）
    static func modules(excludingIDs ids: [String]) -> [KPLModule] {
        all.filter { !ids.contains($0.id) }
    }

    static func byID(_ id: String) -> KPLModule? { all.first { $0.id == id } }

    static func title(of id: String) -> String { byID(id)?.name ?? "KPL 比分看板" }

    /// 默认模块
    static let fallback = all[0]
}

/// 「更多」这一项本身不是前端模块，单独建模避免与 `KPLModule.id` 混淆
enum MoreItem {
    static let symbol = "ellipsis"
    static let name = "更多"
}

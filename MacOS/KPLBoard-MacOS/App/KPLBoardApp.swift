import SwiftUI

@main
struct KPLBoardApp: App {
    /// 提到 App 层持有：macOS 的菜单栏命令（.commands）在视图层级之外，
    /// 必须能直接访问同一个 WebViewModel 才能触发刷新。
    @StateObject private var model = WebViewModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                // macOS 窗口：给一个比窗口默认更大的初始尺寸，并限制最小尺寸。
                // 最小宽度 900pt 是单列布局的下限；宽度 ≥1024pt 时自动切回双窗格。
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1440, height: 900)
        // macOS 统一工具栏样式：工具栏并入标题栏，与 Safari 等原生应用一致
        .windowToolbarStyle(.unified)
        .commands {
            // 「关于」：macOS 有标准关于面板，这里替换系统默认组，
            // 与 iOS 版「无自定义关于面板，走系统默认」保持同一表现。
            CommandGroup(replacing: .appInfo) {
                Button("关于 KPL 比分看板") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [:])
                }
            }

            // 「看板」菜单：把 iOS 版挂在工具栏上的动作同时挂到菜单栏。
            // macOS 惯例是快捷键由菜单栏提供，工具栏只保留鼠标点击入口，
            // 因此 ⌘R 只在这里声明一次，避免与工具栏重复注册。
            CommandMenu("看板") {
                Button("刷新数据") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)

                Divider()

                // 侧栏显隐：macOS 标准快捷键（⌘⌥S）。
                // 左侧导航栏现在是前端 `.sidebar`，不再是 NavigationSplitView 的原生侧栏，
                // 所以这里直接调前端注入，而不是走 NSSplitViewController.toggleSidebar。
                Button("显示/隐藏侧边栏") { model.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
            }
        }
    }
}

import SwiftUI

/// 根布局：整个窗口只放一个 WKWebView，左侧导航即前端自己的 `.sidebar`。
///
/// 1.3.0 起不再用 `NavigationSplitView`——原生赛季侧栏与前端导航栏是两套并排的导航，
/// 屏幕最左被重复占了两列。现在统一为：**前端 `.sidebar`（KPL Agent 导航）就是唯一的左侧栏**，
/// 原生赛季列表（`EventSidebar`）已移除；赛季切换改由看板顶部的赛季下拉完成
/// （窄窗口另在工具栏保留「赛季」菜单，行为与原项目一致）。
///
/// 侧栏显隐：工具栏最左的按钮 / 菜单栏 ⌘⌥S，状态由 `WebViewModel.sidebarCollapsed` 持有。
///
/// 宽度阈值 1024pt 仍保留，但它不再决定「分栏还是单列」——现在只用来告诉前端
/// 套 `mac-wide` 还是 `mac-narrow` 那套间距与栅格（见 `Resources/web/mac.css`）。
struct RootView: View {
    /// 由 App 层注入：菜单栏命令需要访问同一个 model
    @ObservedObject var model: WebViewModel
    @State private var events: [KBEvent] = []

    private let wideThreshold: CGFloat = 1024

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= wideThreshold
            NavigationStack {
                BoardWebView(model: model)
                    // macOS：窗口标题取导航标题，标题栏才不会空着
                    .navigationTitle("KPL 比分看板")
                    .toolbar { toolbarContent(wide: wide) }
            }
            // 与 iPad 版一致的底色（#0b0e17），关掉 WebView 底色后由这里兜底，避免首帧闪白
            .background(Color(red: 0.043, green: 0.055, blue: 0.090))
            .onAppear { model.applyLayoutMode(landscape: wide) }
            .onChangeCompat(of: wide) { v in model.applyLayoutMode(landscape: v) }
        }
        .task { await boot() }
    }

    // MARK: - 工具栏（导航栏显隐 + 窄窗口赛季切换 + 刷新）

    @ToolbarContentBuilder
    private func toolbarContent(wide: Bool) -> some ToolbarContent {
        // 导航栏显隐：macOS 惯例放在工具栏最左（即原 NavigationSplitView 自带按钮的位置）。
        // 快捷键统一由菜单栏「看板 → 显示/隐藏侧边栏」提供（⌘⌥S），这里只留鼠标入口。
        ToolbarItem(placement: .navigation) {
            Button {
                model.toggleSidebar()
            } label: {
                Label("显示/隐藏导航栏", systemImage: "sidebar.left")
            }
            .help(model.sidebarCollapsed ? "显示左侧导航栏（⌘⌥S）" : "隐藏左侧导航栏（⌘⌥S）")
        }

        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 12) {
                // 窄窗口下前端导航栏会变成顶部横条、赛季下拉也被挤走，
                // 这里补一个原生赛季菜单，保证单列下也能切换
                if !wide {
                    Menu {
                        Section("进行中") {
                            ForEach(events.filter { $0.isActive() }) { ev in
                                Button(ev.name) { model.selectEvent(ev.id) }
                            }
                        }
                        Section("全部赛季") {
                            ForEach(events) { ev in
                                Button(ev.name) { model.selectEvent(ev.id) }
                            }
                        }
                    } label: {
                        Label("赛季", systemImage: "list.bullet")
                    }
                    .keyboardShortcut("l", modifiers: .command)
                }

                // ⌘R 由菜单栏「看板 → 刷新数据」统一提供，这里只保留鼠标点击入口
                Button {
                    model.refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }
        }
    }

    // MARK: - 启动

    private func boot() async {
        await BoardStore.shared.bootstrap()
        let list = await BoardStore.shared.allEvents
        await MainActor.run {
            events = list
        }
    }
}

// MARK: - onChange 兼容封装（macOS 13 单参数 / macOS 14+ 双参数）

extension View {
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, perform: @escaping (V) -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onChange(of: value) { _, newValue in perform(newValue) }
        } else {
            self.onChange(of: value, perform: perform)
        }
    }
}

extension KBEvent: Identifiable {}

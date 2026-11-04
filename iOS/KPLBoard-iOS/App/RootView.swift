import SwiftUI
import UIKit

/// 根布局：一套代码两种形态，按**设备类型**分流
/// （iPhone → 悬浮玻璃底栏；iPad → 原生侧栏 + 详情）。
///
/// 为什么按「设备类型」而不是「宽度尺寸类别」分流：
///   分流会重建视图树，而视图树里挂着唯一的 `WKWebView`——
///   一旦因旋转 / 分屏触发切换，页面就会重新加载、滚动位置与赛季状态全丢。
///   iPad 竖屏 834pt 与横屏 1194pt 都属于 regular 宽度，`NavigationSplitView`
///   自己就能在 Split View / Slide Over 下折叠成单列，无需外部切换；
///   iPhone 12 Pro Max 横屏 926pt 虽然也是 regular 宽度，但屏幕只有 428pt 高，
///   侧栏会挤掉正文，因此固定用底部页签。
///
/// 沉浸式毛玻璃（对齐系统「设置」的观感）：
///   网页内容只忽略上下安全区：向上滚进导航栏、向下滚进悬浮底栏、
///   左右交给系统避让（刘海 / 常驻侧栏），
///   两条栏都走系统材质（`Material`），强度由设置的「悬浮玻璃」档位控制；
///   网页自身用 `--sat / --sab` 留出被栏盖住的区域，滚动到底不会被永久遮挡。
struct RootView: View {
    /// 每个窗口（Scene）独立持有：iPadOS 多窗口下两个窗口各有一个 WKWebView，
    /// 模块切换与刷新不会互相串台。
    @StateObject private var model = WebViewModel()
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    /// 详情区当前页面：网页模块 或 设置页（由侧栏直接切换，WebView 常驻不销毁）
    private enum DetailPane { case web, settings }

    @State private var showMore = false
    @State private var detailPane: DetailPane = .web
    @State private var moreSelection: String? = nil
    /// iPad 侧栏开合（顶部导航栏移除后，开关在侧栏右上角 / 收起后的悬浮按钮里）。
    /// 注意：不使用 NavigationSplitView 的 columnVisibility——iPadOS 26/27 上
    /// 程序化写入会被系统忽略（状态变了但侧栏不动），改为自绘侧栏手动收起。
    @State private var sidebarOn: Bool = true
    @Environment(\.horizontalSizeClass) private var hSizeClass
    /// 侧栏是否显示：用户开关 + 宽度档位（Split View 窄列下自动收起）
    private var sidebarVisible: Bool { sidebarOn && hSizeClass == .regular }
    /// 设置页右滑返回的跟手位移（pt；0 = 在位，屏宽 = 已滑走）
    @State private var settingsOffset: CGFloat = 0
    /// 翻页拖动：旧页快照（拖动期间盖在网页上层跟手滑走）
    @State private var pagingSnapshot: UIImage? = nil
    /// 翻页拖动：快照的跟手位移（带方向：左滑为负 / 右滑为正）
    @State private var pagingSlide: CGFloat = 0
    /// 翻页拖动：滑动方向（-1 = 前进/左滑，+1 = 返回/右滑）
    @State private var pagingDir: CGFloat = 0
    /// 翻页拖动：目标模块 / 原模块 id
    @State private var pagingTargetID: String? = nil
    @State private var pagingOriginID: String? = nil
    /// 翻页拖动：启动时的手势位移（跟手位移以此为基准）
    @State private var pagingStartW: CGFloat = 0
    /// 翻页流程进行中（截图 / 转场）：屏蔽新手势
    @State private var pagingBusy: Bool = false
    /// iPad 侧栏当前显示宽度（pt）：0 = 收起，240 = 展开。
    /// 拖动时按手指位移 1:1 直接写入（跟手），松手后由**一条** easeOut 动画收敛到目标值。
    /// 全程只改这一个值、且不增删视图——侧栏常驻视图树。
    /// 这正是「自然、无跳变」的关键：上一版的 offset 位移 + if 增删视图 +
    /// .move transition 是三套机制衔接，衔接处必然卡顿。
    @State private var sidebarWidth: CGFloat = Self.sidebarFullWidth
    /// 侧栏滑动进行中：屏蔽网页翻页手势，避免两个手势叠加打架
    @State private var sidebarGestureBusy: Bool = false
    /// 顶部导航栏总高（状态栏 + 导航栏，窗口坐标实测）。
    /// 自绘渐隐毛玻璃条用它定高，保证与系统栏底沿严格对齐。
    @State private var topBarHeight: CGFloat = 0

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        Group {
            if isPad { padShell } else { phoneShell }
        }
        // 外观三档：同时作用于原生界面与 WKWebView 的 prefers-color-scheme
        .preferredColorScheme(settings.appearance.colorScheme)
        // 与前端 --bg 一致的深色底：WebView 关掉白底后由这里兜底，避免首帧闪白
        .background(KPLPalette.swiftUIBackground)
        .sheet(item: $model.externalLink) { SafariViewer(url: $0.url) }
        .sheet(isPresented: $showMore) { MoreSheet(model: model, moreSelection: $moreSelection) }
        .task { await BoardStore.shared.bootstrap() }
        // 切回前台立刻拉一次：比分看板时效性最强，回到应用就该看到最新数据
        .onChangeCompat(of: scenePhase) { phase in
            if phase == .active, !model.isLoading { model.refresh() }
        }
        .onChangeCompat(of: settings.appearance) { model.applyAppearance($0) }
        // 「更多」浮层里选了模块 → 详情区切回网页页
        .onChangeCompat(of: moreSelection) { sel in
            if sel != nil { detailPane = .web }
        }
        // 底栏模块调整后：若当前模块已回到底栏则取消「更多」高亮，
        // 并把新的页签顺序推给前端（滑动切页要用）
        .onChangeCompat(of: settings.tabIDs) { _ in
            syncMoreSelection()
            model.pushTabs(settings.tabIDs)
        }
        // 宽度档位变化（Split View 拉窄 / 旋转）：窄列下侧栏不可用，
        // 同步宽度状态，避免恢复宽布局时宽度与 sidebarOn 不一致
        .onChangeCompat(of: hSizeClass) { cls in
            if cls != .regular {
                sidebarWidth = 0
            } else if sidebarOn {
                sidebarWidth = Self.sidebarFullWidth
            }
        }
        .onAppear {
            model.applyAppearance(settings.appearance)
            // 与 macOS/iPad 版一致：不接管屏幕常亮（看板自带轮询，无需阻止熄屏）
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - iPad：原生侧栏 + 详情

    private var padShell: some View {
        HStack(spacing: 0) {
            // 侧栏**常驻视图树**，只改宽度、绝不增删。
            // 增删视图（if sidebarVisible）会让 SwiftUI 重建整棵子树，并叠加
            // .move transition——与拖动位移衔接时会出现跳变，这是卡顿的根因。
            padSidebar
                .frame(width: max(0, min(Self.sidebarFullWidth, sidebarWidth)))
                .clipped()
                .background { Rectangle().fill(.bar).ignoresSafeArea(.container, edges: .top) }
                .overlay(alignment: .trailing) {
                    // 与旧版 NavigationSplitView 一致的细分隔线
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5).ignoresSafeArea()
                }
                // 侧栏绘制在详情层之上：设置页拖动返回时，详情区网页层
                // 做视差左移，不能盖到侧栏上面
                .zIndex(1)

            padDetail
                // 侧栏开关手势：整页生效，横向占优才介入（与设置页返回同范式）
                .simultaneousGesture(sidebarSwipeGesture)
        }
    }

    // MARK: - iPad 侧栏左右滑开关

    /// 与设置页右滑返回同款范式：**全程只驱动 sidebarWidth 一个值**。
    /// · 侧栏在位：从左缘起手左滑 → 宽度跟手减小（网页内容实时重排适配）
    /// · 侧栏收起：从左缘起手右滑 → 宽度跟手增大（网页内容实时让位）
    /// 松手后把同一个值用**一条** easeOut 动画收敛到 0 或 240，全程单一机制、无跳变。
    /// 起手热区限定左缘 40pt：看板页战绩榜表格（.table-wrap）本身横向可滚，
    /// 全页生效会把横滑表格误判成收侧栏。
    private var sidebarSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                guard !pagingBusy, !sidebarGestureBusy, detailPane == .web else { return }
                guard hSizeClass == .regular else { return }   // 窄列（Split View）下无侧栏
                let w = v.translation.width
                let h = v.translation.height
                guard abs(w) > abs(h) * PageSwipe.ratio else { return }
                // 起手点：详情区局部坐标的左缘 40pt 内
                guard v.startLocation.x <= 40 else { return }

                sidebarGestureBusy = true
                // 起点宽度：在位 240 / 收起 0；手指位移 1:1 叠加（直接跟手，不加阻尼——
                // 加阻尼会让宽度落后于手指，视觉上像"拖不动"）
                let base: CGFloat = sidebarOn ? Self.sidebarFullWidth : 0
                sidebarWidth = max(0, min(Self.sidebarFullWidth, base + w))
            }
            .onEnded { v in
                guard sidebarGestureBusy else { return }
                sidebarGestureBusy = false
                let w = v.translation.width
                let far = abs(w) >= PageSwipe.distance
                let quick = abs(v.predictedEndTranslation.width) >= PageSwipe.velocity
                // 过阈值按意图翻转；未过阈值按"是否过半"就近吸附
                let open = (far || quick) ? !sidebarOn : sidebarWidth > Self.sidebarFullWidth / 2
                withAnimation(.easeOut(duration: PageSwipe.duration)) {
                    sidebarOn = open
                    sidebarWidth = open ? Self.sidebarFullWidth : 0
                }
            }
    }

    /// iPad 侧栏：功能导航 + 设置（右上角带收起开关）
    private var padSidebar: some View {
        List {
            Section("功能") {
                ForEach(ModuleCatalog.all) { m in
                    sidebarRow(symbol: m.symbol, title: m.name,
                               selected: detailPane == .web && model.moduleID == m.id) {
                        detailPane = .web
                        moreSelection = nil
                        model.setModule(m.id)
                    }
                }
            }
            // 顶部导航栏已整体移除（用户要求去掉顶部灰色框）。
            // 刷新已移到每个页面右上角（网页自带按钮）；「关于与设备信息」
            // 在设置页内已有入口（用户要求侧栏不再重复提供），侧栏只保留设置。
            // 「设置」与功能模块同级：点击即把详情区整体切换成设置页（非悬浮）。
            Section {
                sidebarRow(symbol: "gearshape.fill", title: "设置",
                           selected: detailPane == .settings) {
                    detailPane = .settings
                }
            }
        }
        .listStyle(.sidebar)
        .overlay(alignment: .topTrailing) {
            // 收起侧栏的开关：置于侧栏右上角；
            // 侧栏收起后由详情右下角的悬浮按钮唤回
            Button {
                // 与滑动手势同一套动画参数，观感一致
                withAnimation(.easeOut(duration: PageSwipe.duration)) {
                    sidebarOn = false
                    sidebarWidth = 0
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起侧栏")
            .padding(.trailing, 10)
        }
    }

    /// iPad 详情区：网页 / 设置页二选一（网页常驻保活、始终可见）。
    /// 设置页拖动返回时，网页层做视差跟随——不再用 opacity 0（那会在滑开
    /// 设置页时露出黑屏）。视差位移以详情区实际宽度为基准。
    private var padDetail: some View {
        GeometryReader { geo in
            ZStack {
                // 网页详情常驻视图树，设置页在位时被其完全覆盖
                webDetail
                    .allowsHitTesting(detailPane == .web)
                    .accessibilityHidden(detailPane != .web)
                    // 仅在设置页在位 / 拖动返回期间做视差跟随；
                    // 设置页退出后必须归零，否则网页会永久左移 30%（状态泄漏）
                    .offset(x: detailPane == .settings
                            ? -PageSwipe.parallax * max(0, geo.size.width - settingsOffset)
                            : 0)

                // 设置页：与网页平级的一等页面，由侧栏直接切换。
                // 是 webDetail 的兄弟视图（不在 toolbar(.hidden) 子树内），
                // 自带 NavigationStack 的导航栏（标题 + 返回 + 完成）正常显示。
                if detailPane == .settings {
                    settingsPanel
                }
            }
        }
    }

    /// iPad 详情区的网页内容（含顶部渐隐毛玻璃与侧栏收起时的悬浮按钮）。
    /// GeometryReader 持续向外壳下发安全区 / 布局档位，因此**不能**随页面切换销毁。
    private var webDetail: some View {
        GeometryReader { geo in
            BoardWebView(model: model)
                // 只忽略上下（见 phoneShell 注释），左右由系统避让侧栏
                .ignoresSafeArea(edges: [.top, .bottom])
                .overlay(alignment: .top) { TopGlassFade(height: topBarHeight) }
                .overlay(alignment: .topLeading) {
                    // 侧栏收起后，唤回开关单独固定在左上角（用户要求从右下角悬浮组移出）；
                    // 玻璃圆底与右下角悬浮按钮组同一观感。
                    // 尺寸 30 / 顶部 2：整体压到状态栏条带内，不遮网页品牌区图标
                    if !sidebarVisible {
                        Button {
                            // 与滑动手势同一套动画参数，观感一致
                            withAnimation(.easeOut(duration: PageSwipe.duration)) {
                                sidebarOn = true
                                sidebarWidth = Self.sidebarFullWidth
                            }
                        } label: {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(.ultraThinMaterial))
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("显示侧栏")
                        .padding(.leading, 16)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // 只在侧栏收起（Split View 窄列 / 用户手动收起）时浮出，
                    // 平时不遮挡正文。
                    if !sidebarVisible {
                        FloatingActions(onSettings: { detailPane = .settings },
                                        onRefresh: { model.refresh() })
                            .padding(16)
                    }
                }
                .onAppear { pushEnvironment(geo, bottomReserve: 0) }
                // WebView 实际宽度 = 窗口宽 − 侧栏宽，必须以它为准判断布局档位，
                // 否则 iPad 竖屏（834pt）会被误判成宽布局。
                .onChangeCompat(of: geo.size.width) { _ in pushEnvironment(geo, bottomReserve: 0) }
                .onChangeCompat(of: geo.size.height) { _ in pushEnvironment(geo, bottomReserve: 0) }
                .onChangeCompat(of: geo.safeAreaInsets.top) { _ in pushEnvironment(geo, bottomReserve: 0) }
                .onChangeCompat(of: geo.safeAreaInsets.bottom) { _ in pushEnvironment(geo, bottomReserve: 0) }
        }
    }

    // MARK: - iPhone：全屏内容 + 悬浮玻璃底栏

    private var phoneShell: some View {
        ZStack {
            NavigationStack {
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        BoardWebView(model: model)
                            // 只忽略上下：内容向上滚进状态栏、向下滚进悬浮底栏，
                            // 被盖住的区域由网页侧的 --sat / --sab 留白兜底；
                            // 左右交给系统避让（iPhone 刘海），正文不应钻到侧栏下面。
                            .ignoresSafeArea(edges: [.top, .bottom])
                            // 翻页拖动：阶段一旧页跟手，阶段二下层目标页视差跟随
                            .offset(x: webPagingOffset)
                            .simultaneousGesture(pagingGesture)

                        // 旧页快照：拖动期间盖在网页上层跟手滑走（原理同系统 pop）
                        if let img = pagingSnapshot {
                            GeometryReader { geo in
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .clipped()
                                    .offset(x: pagingSlide)
                                    .shadow(color: .black.opacity(0.16), radius: 10)
                            }
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                        }

                        TopGlassFade(height: topBarHeight)
                            .frame(maxHeight: .infinity, alignment: .top)

                        // 设置 / 刷新悬浮按钮固定在右上角（用户要求从底栏上方移过来）
                        FloatingActions(onSettings: { detailPane = .settings },
                                        onRefresh: { model.refresh() })
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(.top, 6)
                            .padding(.trailing, 12)

                        GlassTabBar(model: model,
                                    moreSelection: $moreSelection,
                                    onMore: { showMore = true },
                                    onModuleTap: {
                                        detailPane = .web
                                        moreSelection = nil
                                    })
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                    }
                    .onAppear { pushEnvironment(geo, bottomReserve: Self.bottomReserve(geo)) }
                    .onChangeCompat(of: geo.size.width) { _ in pushEnvironment(geo, bottomReserve: Self.bottomReserve(geo)) }
                    .onChangeCompat(of: geo.size.height) { _ in pushEnvironment(geo, bottomReserve: Self.bottomReserve(geo)) }
                    .onChangeCompat(of: geo.safeAreaInsets.top) { _ in pushEnvironment(geo, bottomReserve: Self.bottomReserve(geo)) }
                    .onChangeCompat(of: geo.safeAreaInsets.bottom) { _ in pushEnvironment(geo, bottomReserve: Self.bottomReserve(geo)) }
                }
                // 顶部导航栏整体移除（同 iPad），标题与按钮分别由页面头部与底栏承担。
                // 只作用于网页子树：设置页在 NavigationStack 之外，导航栏不受影响。
                .toolbar(.hidden, for: .navigationBar)
            }

            // 设置页：与网页平级的一等页面（底栏 / 右上角齿轮直接切换，非悬浮）。
            // 放在 NavigationStack **之外**，避免外壳的 toolbar(.hidden) 泄漏进来
            // 把设置页自己的导航栏（标题 + 返回 + 完成）也藏掉。
            if detailPane == .settings {
                settingsPanel
                    .transition(.opacity)
                    .zIndex(3)
            }
        }
    }

    /// 底栏为网页内容预留的高度：栏高 + 底部间距 + Home 指示条 + 呼吸空间
    private static func bottomReserve(_ geo: GeometryProxy) -> CGFloat {
        tabBarHeight + 10 + geo.safeAreaInsets.bottom + 8
    }

    @ViewBuilder
    private func sidebarRow(symbol: String, title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 22)
                    // 未选中图标用 primary（此前 .secondary 偏灰暗，用户反馈太暗）
                    .foregroundStyle(selected ? KPLPalette.accent(colorScheme) : Color.primary.opacity(0.85))
                Text(title)
                    .foregroundStyle(selected ? KPLPalette.accent(colorScheme) : .primary)
                Spacer(minLength: 0)
            }
            // Apple 人机规范：最小触控目标 44pt
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? KPLPalette.accent(colorScheme).opacity(0.16) : Color.clear)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - 环境下发

    private func pushEnvironment(_ geo: GeometryProxy, bottomReserve: CGFloat) {
        var insets = geo.safeAreaInsets
        // NavigationSplitView 的 detail 列 safeAreaInsets.top 只含状态栏、不含导航栏
        // （NavigationStack 则两者都含），这里用内容区的真实布局位置修正，
        // 保证 --sat 恒等于「状态栏 + 导航栏」，网页正文不会被顶栏盖住。
        let contentTop = geo.frame(in: .global).minY
        if contentTop > insets.top { insets.top = contentTop }
        topBarHeight = contentTop
        model.applyEnvironment(idiom: UIDevice.current.userInterfaceIdiom,
                               isRegularWidth: geo.size.width >= ScreenSnapshot.sidebarMinWidth,
                               safeArea: insets,
                               bottomReserve: bottomReserve)
    }

    private func syncMoreSelection() {
        if settings.tabIDs.contains(model.moduleID) { moreSelection = nil }
    }

    // MARK: - 滑动转场参数（与前端 shell.js 的 SWIPE 保持一致）

    /// 与系统导航「右滑返回」对齐的手势参数。
    /// 前端 shell.js 里的 `SWIPE` 常量与此一一对应，
    /// 保证「设置页返回」与「功能页左右切换」的手感、判定完全一致。
    private enum PageSwipe {
        /// 跟手阻尼系数（pt）：位移 = damp·x/(x+damp)
        static let damp: CGFloat = 1200
        /// 完成切换所需最小位移（pt）
        static let distance: CGFloat = 90
        /// 完成切换所需最小横向速度（pt/s）
        static let velocity: CGFloat = 300
        /// 完成动画时长（s）——设置页返回与功能页翻页共用
        static let duration: Double = 0.30
        /// 回弹动画时长（s）
        static let backDuration: Double = 0.20
        /// 横向/纵向判定倍率：横向位移需超过纵向 ×1.4 才算翻页
        static let ratio: CGFloat = 1.4
        /// 背景页（下层目标页）视差系数
        static let parallax: CGFloat = 0.30
    }

    /// 手指位移 → 阻尼跟手位移（与前端 swipeDamp 同公式）
    private func swipeDamped(_ x: CGFloat) -> CGFloat {
        let a = abs(x)
        let m = PageSwipe.damp
        return (x < 0 ? -1 : 1) * m * (a / (a + m))
    }

    /// 目标页：forward = true 取下一个页签，false 取上一个
    private func pagingTarget(forward: Bool) -> String? {
        let tabs = ModuleCatalog.modules(withIDs: settings.tabIDs)
        guard let idx = tabs.firstIndex(where: { $0.id == model.moduleID }) else {
            // 当前不在底栏页签里（从「更多」进入）：只允许左滑进入第一个页签
            return forward ? tabs.first?.id : nil
        }
        let next = idx + (forward ? 1 : -1)
        return tabs.indices.contains(next) ? tabs[next].id : nil
    }

    // MARK: - 设置（一等页面）

    /// 设置页容器：与网页模块平级，由侧栏 / 底栏直接切换显示，不是弹窗也不是覆盖层。
    /// 包一层 NavigationStack 以支持页内的「关于与设备信息」push；
    /// 所在容器已按安全区布局，导航栏与状态栏自然对齐，无需手动让位。
    /// 右滑返回（整页可触发，与「关于」页的系统返回手感一致）：
    /// 跟手位移 + 阈值/速度判定 + 回弹，与功能页左右切换共用 PageSwipe 参数。
    private var settingsPanel: some View {
        NavigationStack {
            SettingsView(onClose: dismissSettings)
        }
        .background(KPLPalette.pageBackground(colorScheme))
        .offset(x: settingsOffset)
        // simultaneous：与列表纵向滚动并存，只有横向占优的手势才跟手移动
        .simultaneousGesture(settingsBackGesture)
    }

    /// 设置页右滑返回的跟手手势（整页生效，横向位移占优才介入）
    private var settingsBackGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                let w = v.translation.width
                let h = v.translation.height
                // 只响应「向右且横向占优」的拖动，纵向滚动交给列表
                guard w > 0, w > abs(h) * 1.3 else { return }
                settingsOffset = swipeDamped(w)
            }
            .onEnded { v in
                guard settingsOffset > 0 else { return }
                let w = v.translation.width
                let far = w >= PageSwipe.distance
                let quick = v.predictedEndTranslation.width >= PageSwipe.velocity
                if far || quick {
                    dismissSettings()
                } else {
                    // 回弹：未过阈值 → 回到原位
                    withAnimation(.easeOut(duration: PageSwipe.backDuration)) {
                        settingsOffset = 0
                    }
                }
            }
    }

    // MARK: - 功能页左右滑动切换（快照方案）

    /// 拖动期间网页层的位移：
    /// · 阶段一（快照截取中，约几十毫秒）：网页（旧页）自身跟手——从第一帧就跟手，无等待；
    /// 拖动期间网页层的位移：
    /// · 阶段一（快照截取中，约几十毫秒）：网页（原页）自身跟手——从第一帧就跟手，无等待；
    /// · 阶段二（快照已就绪）：网页**保持不动**（0）。
    ///
    /// 此前阶段二会让网页按视差反向滑入，那是基于「网页已切到目标页」的设计；
    /// 现改为「取消时网页从未动过」，所以快照底下始终是当前原页，
    /// 网页不应再位移——否则取消后网页的位移残留会让内容错位。
    /// 视觉上：旧页快照跟手滑走露出下面静止的原页（就是自己），
    /// 确认切换时网页在快照掩护下无缝换成目标页。
    private var webPagingOffset: CGFloat {
        guard pagingTargetID != nil else { return 0 }
        guard pagingSnapshot != nil else { return pagingSlide }
        return 0
    }

    /// 左右滑动切换功能页：拖动启动瞬间截取旧页快照盖在顶层跟手滑走，
    /// **确认（过阈值）后**网页才切到目标模块——取消时网页全程不动，
    /// 因此原表的滚动位置完整保留（不会「自动跑到最上面」）。
    private var pagingGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { v in
                guard detailPane == .web, !pagingBusy, !sidebarGestureBusy else { return }
                // 手指落在「可横向滚动的表格」内（战绩榜 / 选手榜宽表）→ 让行，
                // 交给网页横向滚动查看被截掉的列；否则横滑会被切页手势吃掉。
                guard !model.horizontalScrollActive else { return }
                let w = v.translation.width
                let h = v.translation.height

                if pagingTargetID == nil {
                    // 启动判定：横向占优 + 存在相邻页；网页从第一帧就跟手（不等快照）
                    guard abs(w) > 14, abs(w) > abs(h) * PageSwipe.ratio else { return }
                    let forward = w < 0
                    guard let target = pagingTarget(forward: forward) else { return }
                    pagingBusy = true
                    pagingDir = forward ? -1 : 1       // 快照滑动方向（跟手）
                    pagingTargetID = target
                    pagingOriginID = model.moduleID
                    pagingSlide = swipeDamped(w)
                    /* 只截快照贴到顶层跟手，**不切换网页模块**。
                       此前这里会 peekModule(target) 把网页切到目标页——
                       一旦用户滑一半松手取消，网页已经是被切过的目标页，
                       pagingCancel 再切回原模块时会重新渲染、滚动位置丢失，
                       表现为「取消后自动跑到最上面」。
                       现在取消 = 快照滑回原位 + 网页从未动过 → 滚动位置原封不动。 */
                    model.captureSnapshot { img in
                        guard pagingTargetID == target else {
                            pagingBusy = false
                            return
                        }
                        pagingSnapshot = img
                    }
                } else {
                    // 快照已就绪：快照跟手滑走
                    pagingSlide = swipeDamped(w)
                }
            }
            .onEnded { v in
                guard let target = pagingTargetID else {
                    pagingBusy = false
                    return
                }
                // 表格横滑期间不应触发切页（onChanged 已让行，这里兜底：
                // 手指在表格内快速轻扫时 onChanged 可能只跑了几帧）
                guard !model.horizontalScrollActive else {
                    pagingCancel()
                    return
                }
                let slide = abs(pagingSlide)
                let far = slide >= PageSwipe.distance
                let quick = abs(v.predictedEndTranslation.width) >= PageSwipe.velocity
                if far || quick {
                    pagingFinish(target)
                } else {
                    pagingCancel()
                }
            }
    }

    /// 回弹：未过阈值 → 快照滑回原位。
    /// 拖动期间网页**从未被切换过**（只在 pagingFinish 里才切），
    /// 因此这里不需要、也**绝不能**去还原模块——否则网页会被重新渲染、
    /// 滚动位置丢失（表现为「取消后自动跑到最上面」）。
    private func pagingCancel() {
        withAnimation(.easeOut(duration: PageSwipe.backDuration)) {
            pagingSlide = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + PageSwipe.backDuration) {
            pagingSnapshot = nil
            pagingTargetID = nil
            pagingOriginID = nil
            pagingSlide = 0
            pagingBusy = false
        }
    }

    /// 完成切页：快照滑出屏外（与设置页返回同款 0.30s 缓动）→ 此时才切模块 → 清理快照。
    /// 切换动作发生在快照完全盖住屏幕之后，用户看不到「闪一下」。
    private func pagingFinish(_ target: String) {
        let w = Self.windowWidth
        withAnimation(.easeOut(duration: PageSwipe.duration)) {
            pagingSlide = pagingDir * w
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // 先切模块，让网页在快照底下完成渲染（切换过程被快照遮住）
        model.peekModule(target)
        model.confirmModule(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + PageSwipe.duration) {
            pagingSnapshot = nil
            pagingTargetID = nil
            pagingOriginID = nil
            pagingSlide = 0
            pagingBusy = false
        }
    }

    /// 完成返回：沿手势方向滑出 → 切回网页页
    private func dismissSettings() {
        let w = Self.windowWidth
        withAnimation(.easeOut(duration: PageSwipe.duration)) {
            settingsOffset = w
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + PageSwipe.duration) {
            detailPane = .web
            settingsOffset = 0
        }
    }

    /// 当前窗口宽度（多场景安全）。
    /// 不能用 `UIScreen.main.bounds.width`：iPad 分屏 / Slide Over / Stage Manager
    /// 下窗口宽 ≠ 屏幕宽，会让翻页与设置页返回滑出错误距离。
    /// 优先取 foregroundActive 场景的 keyWindow；取不到再退回屏幕宽。
    private static var windowWidth: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        if let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first {
            let w = window.bounds.width
            if w > 0 { return w }
        }
        return UIScreen.main.bounds.width
    }

    /// iPad 自绘侧栏宽度（侧栏手势热区以此定位）
    private static let sidebarFullWidth: CGFloat = 240
    private static let tabBarHeight: CGFloat = 54
}

// MARK: - iPhone 悬浮玻璃底栏

/// 悬浮胶囊式玻璃底栏（对齐 iOS 26 Liquid Glass 观感）：
/// 圆角胶囊 + 系统材质 + 可调着色层，内容从它下方穿过。
/// 显示哪些模块由设置决定，未勾选的收进「更多」。
private struct GlassTabBar: View {
    @ObservedObject var model: WebViewModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @Binding var moreSelection: String?
    let onMore: () -> Void
    /// 任一模块页签被点按时的回调（用于把详情区从设置页切回网页）
    var onModuleTap: () -> Void = {}

    private var tabs: [KPLModule] { ModuleCatalog.modules(withIDs: settings.tabIDs) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { m in
                item(symbol: m.symbol, title: m.name, selected: model.moduleID == m.id) {
                    onModuleTap()
                    model.setModule(m.id)
                }
            }
            item(symbol: MoreItem.symbol, title: MoreItem.name,
                 selected: moreSelection != nil) { onMore() }
        }
        .padding(.vertical, 5)
        .frame(height: 54)
        .background { glass }
    }

    /// 玻璃背板：系统材质（模糊）+ 着色层（不透明度）+ 高光描边 + 投影。
    /// 着色层分深浅色：浅色下用白色提亮、与页面底色衔接（此前黑色着色偏灰、
    /// 用户反馈与页面不匹配）；深色下维持半透明黑压住内容。
    private var tint: Color {
        colorScheme == .dark
            ? Color.primary.opacity(settings.glass.tintAlpha)
            : Color.white.opacity(min(settings.glass.tintAlpha * 2.4, 0.6))
    }

    private var glass: some View {
        ZStack {
            Rectangle().fill(settings.glass.material)
            Rectangle().fill(tint)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 5)
    }

    private func item(symbol: String, title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? KPLPalette.accent(colorScheme) : .secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 4)
            .background {
                if selected {
                    // 选中态：Apple 页签的浅色药丸
                    Capsule().fill(KPLPalette.accent(colorScheme).opacity(0.18))
                }
            }
        }
        .buttonStyle(.plain)
        // Apple 人机规范：最小触控目标 44pt
        .frame(minHeight: 44)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - 顶部渐隐毛玻璃

/// 顶栏的渐隐毛玻璃条（对齐系统「设置」的顶部观感）：
/// 系统材质提供模糊，页面主题色提供着色，mask 让它向下渐隐到 0——
/// 没有硬边，正文从它下面滚过时呈「半透明渐隐」效果。
/// 高度取「状态栏 + 导航栏」实测值，底沿与系统栏严格对齐；
/// 系统导航栏本身透明，标题与右上角按钮仍然可点。
private struct TopGlassFade: View {
    @Environment(\.colorScheme) private var colorScheme
    let height: CGFloat

    private var tint: Color { KPLPalette.pageBackground(colorScheme) }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(colors: [tint.opacity(0.92), tint.opacity(0.55), tint.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
        }
        .mask(LinearGradient(colors: [.black, .black.opacity(0)],
                             startPoint: .top, endPoint: .bottom))
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 悬浮操作按钮

/// 悬浮玻璃胶囊：设置 / 刷新按钮。
/// iPhone：固定在右上角；iPad：仅侧栏收起时浮出在详情右下角
/// （侧栏唤回开关已单独移到左上角）。
private struct FloatingActions: View {
    @Environment(\.colorScheme) private var colorScheme
    let onSettings: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            circleButton("gearshape", "设置") { onSettings() }
            circleButton("arrow.clockwise", "刷新") { onRefresh() }
        }
        .padding(5)
        .background { glass }
    }

    /// 与底栏同一套玻璃背板，视觉上是一组。
    /// 着色层分深浅色：浅色下用白色提亮（此前黑色着色偏灰暗、与页面不匹配），
    /// 深色下维持半透明黑压住内容。
    private var glass: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(colorScheme == .dark
                ? Color.primary.opacity(0.14)
                : Color.white.opacity(0.42))
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 4)
    }

    private func circleButton(_ symbol: String, _ name: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

// MARK: - 「更多」浮层

/// 用浮层而不是 push：push 会把唯一的 WKWebView 移出视图层级导致页面重载，
/// 浮层则在保留页面的前提下完成模块切换。
private struct MoreSheet: View {
    @ObservedObject var model: WebViewModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @Binding var moreSelection: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("更多模块") {
                    ForEach(ModuleCatalog.modules(excludingIDs: settings.tabIDs)) { m in
                        Button {
                            moreSelection = m.id
                            model.setModule(m.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: m.symbol)
                                    .frame(width: 24)
                                    .foregroundStyle(moreSelection == m.id ? KPLPalette.accent(colorScheme) : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.name)
                                    Text(m.note).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if moreSelection == m.id {
                                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                                }
                            }
                            // 关键修复：List 行内的 .plain Button 默认只有文字区域可点，
                            // 图标与空白处的点击会被 List 的行手势吞掉（表现为「点不动」）。
                            // contentShape(Rectangle()) 把可点区域扩展到整行。
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    // 设置 / 关于都是纯原生视图，push 不会动到 WKWebView
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("设置", systemImage: "gearshape.fill")
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("关于与设备信息", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("更多")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 兼容封装

extension View {
    /// onChange 兼容封装（iOS 16 单参数 / iOS 17+ 双参数）
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, perform: @escaping (V) -> Void) -> some View {
        if #available(iOS 17.0, *) {
            self.onChange(of: value) { _, newValue in perform(newValue) }
        } else {
            self.onChange(of: value, perform: perform)
        }
    }
}

extension KBEvent: Identifiable {}

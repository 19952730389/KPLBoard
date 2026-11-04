import SwiftUI
import WebKit
import SafariServices

/// 需要在应用外（或应用内 Safari）打开的链接包装，供 `.sheet(item:)` 使用
struct KPLExternalLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// WebView 的控制中心：持有 WKWebView 引用，向前端下发「设备档位 + 安全区 + 当前模块」。
@MainActor
final class WebViewModel: ObservableObject {

    weak var webView: WKWebView?

    @Published var isLoading = true
    @Published var lastError: String? = nil

    /// 当前模块（前端视图 id）。原生侧栏 / 底栏只改这个值，由 `syncModule()` 推给前端。
    @Published private(set) var moduleID: String = ModuleCatalog.fallback.id

    /// 页面内点击的外链：交给 SafariViewController 打开，不让页面自己跳走
    @Published var externalLink: KPLExternalLink? = nil

    /// 前端还没准备好时先记下，等 `didFinish` 再补发（首帧注入时 shell.js 尚未执行）
    private var pendingModule: String? = nil
    /// 外观注入与模块切换同理：`onAppear` 时 theme.js 可能还没执行，
    /// `window.KPLTheme` 不存在会让 `KPLTheme.set(...)` 抛 ReferenceError
    /// （控制台表现为「主题切换失败： A JavaScript exception occurred」）。
    /// 这里记下来，`pageDidFinish` 里重放。
    private var pendingAppearance: AppearanceMode? = nil

    // MARK: 外壳状态（设备档位 + 安全区）

    private var isPadIdiom = false
    private var isRegularWidth = true
    private var safeInsets: EdgeInsets = EdgeInsets()
    /// 底栏（悬浮玻璃页签）为内容预留的高度：CSS 用 --sab 做页面底部留白，
    /// 保证滚动到底时最后一行不会被底栏永久遮住。
    private var bottomReserve: CGFloat = 0

    static var homeURL: URL? {
        URL(string: "\(KPLSchemeHandler.scheme)://\(KPLSchemeHandler.host)/index.html")
    }

    // MARK: - 模块切换

    func setModule(_ id: String) {
        guard ModuleCatalog.byID(id) != nil else { return }
        moduleID = id
        guard let webView else { pendingModule = id; return }
        // 前端 shell.js 暴露的全局入口：window.KPLShell.setView(id)
        webView.evaluateJavaScript("KPLShell.setView('\(id)')") { _, err in
            if let err {
                print("[KPL] setView 失败：\(err.localizedDescription)")
                self.pendingModule = id
            }
        }
    }

    // MARK: - 看板动作

    /// 切换赛季：前端 app.js 的 switchEvent() 是全局函数
    func selectEvent(_ id: String) {
        webView?.evaluateJavaScript("switchEvent('\(id)')") { _, err in
            if let err { print("[KPL] switchEvent 失败：\(err.localizedDescription)") }
        }
    }

    /// 刷新：按当前页面分流——
    /// · 比分看板：KPLBoardRefresh(true) 强制走网络；
    /// · 工具页：触发页头右上角的刷新按钮（tools.js 内统一处理重验证 + 重渲染）。
    func refresh() {
        let js = """
        (function(){
          if (document.querySelector('#view-tool.on')) {
            var b = document.querySelector('.page-head .head-refresh');
            if (b) { b.click(); return; }
          }
          if (window.KPLBoardRefresh) KPLBoardRefresh(true);
        })();
        """
        webView?.evaluateJavaScript(js) { _, err in
            if let err { print("[KPL] refresh 失败：\(err.localizedDescription)") }
        }
    }

    // MARK: - 设备适配下发

    /// 由 RootView 在尺寸类别 / 安全区变化时调用。
    ///
    /// 为什么要把安全区数值传进 CSS：`WKWebView` 虽然支持 `env(safe-area-inset-*)`，
    /// 但它反映的是 WebView 自身的 viewport insets，在 SwiftUI 容器（含 `.safeAreaInset`
    /// 自定义底栏、NavigationStack 导航栏）里并不总是等于系统安全区。
    /// 这里由原生侧统一算好再写进 CSS 变量，前端只认变量，行为在任何容器下都确定。
    func applyEnvironment(idiom: UIUserInterfaceIdiom,
                          isRegularWidth: Bool,
                          safeArea: EdgeInsets,
                          bottomReserve: CGFloat) {
        self.isPadIdiom = (idiom == .pad)
        self.isRegularWidth = isRegularWidth
        // 横向不再由网页让位：WebView 只忽略上下安全区，左右由系统避让
        // （iPhone 刘海 / iPad 常驻侧栏）。这里强制归零，避免布局过程中的
        // 瞬态值（如侧栏出现前的 240pt）被「最后一次推送生效」残留下来。
        self.safeInsets = EdgeInsets(top: safeArea.top, leading: 0,
                                     bottom: safeArea.bottom, trailing: 0)
        self.bottomReserve = bottomReserve
        applyShellState()
    }

    // MARK: - 外观（跟随系统 / 浅色 / 深色）

    /// 把外观档位推给前端 `window.KPLTheme.set(...)`。
    /// 前端 localStorage 是持久化的，原生是唯一事实来源——
    /// 所以除了用户改设置时调用，页面每次加载完成也要重放一次。
    /// theme.js 未就绪（页面还在加载）时不报错，记为 pending 等加载完补发。
    func applyAppearance(_ mode: AppearanceMode) {
        guard let webView else { pendingAppearance = mode; return }
        webView.evaluateJavaScript("KPLTheme.set('\(mode.webValue)')") { [weak self] _, err in
            if let err {
                // ReferenceError（KPLTheme 未定义）= theme.js 还没执行，等页面就绪重放
                let isNotReady = (err as? WKError)?.code == .javaScriptResultTypeIsUnsupported
                    || err.localizedDescription.contains("JavaScript exception")
                if isNotReady {
                    self?.pendingAppearance = mode
                } else {
                    print("[KPL] 主题切换失败：\(err.localizedDescription)")
                }
            }
        }
    }

    /// 把底栏模块顺序推给前端，供「左右滑动切页」定位相邻页。
    /// 前端：window.KPLShell.setTabs([...])。
    func pushTabs(_ ids: [String]? = nil) {
        let list = ids ?? AppSettings.shared.tabIDs
        guard let wv = webView, !list.isEmpty else { return }
        let arg = list.map { "'\($0)'" }.joined(separator: ",")
        wv_shell_js(wv, "if(window.KPLShell&&window.KPLShell.setTabs){KPLShell.setTabs([\(arg)])}")
    }

    /// 统一的 JS 注入入口（便于集中排错）
    private func wv_shell_js(_ wv: WKWebView, _ js: String) {
        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - 滑动翻页：快照 + 预览

    /// 截取当前网页快照（滑动翻页时作为「旧页贴图」跟手滑走）
    func captureSnapshot(_ completion: @escaping (UIImage?) -> Void) {
        guard let wv = webView else {
            completion(nil)
            return
        }
        wv.takeSnapshot(with: nil) { image, _ in
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// 拖动期间预览目标页：只切网页显示，不改 moduleID（取消时可无痕还原）
    func peekModule(_ id: String) {
        guard let webView, ModuleCatalog.byID(id) != nil else { return }
        webView.evaluateJavaScript("KPLShell.setView('\(id)')", completionHandler: nil)
    }

    /// 拖动提交：确认目标模块（更新底栏高亮）
    func confirmModule(_ id: String) {
        guard ModuleCatalog.byID(id) != nil else { return }
        moduleID = id
    }

    // MARK: - 横向滚动让行（表格左右滑动）

    /// 手指是否落在「可横向滚动且确实溢出」的容器内（战绩榜 / 选手榜等宽表）。
    ///
    /// 由页面在 `touchstart` 时通过 `kplscroll` 消息上报——Swift 的手势回调里
    /// **无法同步执行 JS**（evaluateJavaScript 是异步的），所以命中判定必须放在
    /// 网页侧、提前一步告知。原生「左右滑动切页」手势在它为 true 时让行，
    /// 否则表格永远滑不动（iPhone 上横滑被翻页手势吃掉，右侧列看不到）。
    /// 触摸结束后页面会再上报一次 false。
    @Published var horizontalScrollActive = false

    /// 把「设备档位 + 原生导航标记 + 安全区数值」一次性推给前端。
    /// 放在同一次注入里，避免多次 JS 调用之间出现「一半生效」的中间态。
    func applyShellState(to target: WKWebView? = nil) {
        guard let wv = target ?? webView else { return }
        let device = isPadIdiom ? "kpl-pad" : "kpl-phone"
        let width = isRegularWidth ? "kpl-regular" : "kpl-compact"
        let sat = f(safeInsets.top), sab = f(safeInsets.bottom + bottomReserve)
        let sal = f(safeInsets.leading), sar = f(safeInsets.trailing)
        // 幂等：重复执行结果一致。CSS 变量同时写到 html 与 body，
        // 保证 ios.css 里 :root 的 0 值声明被可靠覆盖。
        let js = """
        (function(){
          var b = document.body;
          if (!b) return 'no-body';
          var cl = b.classList;
          cl.remove('kpl-phone','kpl-pad','kpl-compact','kpl-regular');
          cl.add('\(device)', '\(width)');
          cl.add('native-nav');
          var hs = document.documentElement.style, s = b.style;
          var vars = [['--sat','\(sat)px'],['--sab','\(sab)px'],['--sal','\(sal)px'],['--sar','\(sar)px']];
          for (var i = 0; i < vars.length; i++) {
            s.setProperty(vars[i][0], vars[i][1]);
            hs.setProperty(vars[i][0], vars[i][1]);
          }
          return 'ok';
        })();
        """
        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    private func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }

    /// 页面加载完成后补发：布局档位 + 安全区 + 外观，以及尚未生效的模块切换
    func pageDidFinish() {
        isLoading = false
        applyShellState()
        pushTabs()
        // 页面重载后 viewport 覆盖会丢失，重放一次禁缩放
        webView?.disableZoom()
        // theme.js 此时已执行（theme.js 在 <head> 同步加载），补发加载期间记下的外观。
        // 注意顺序：先清 pending 再调用，避免 applyAppearance 失败时又把自己记回去。
        if let pending = pendingAppearance {
            pendingAppearance = nil
            applyAppearance(pending)
        }
        if let pending = pendingModule {
            pendingModule = nil
            setModule(pending)
        } else {
            setModule(moduleID)
        }
    }
}

// MARK: - UIViewRepresentable（iOS / iPadOS 对应 macOS 版的 NSViewRepresentable）

struct BoardWebView: UIViewRepresentable {
    @ObservedObject var model: WebViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let handler = KPLSchemeHandler()
        let config = WKWebViewConfiguration()
        // handler 必须被强引用持有，否则页面发起请求时会因 handler 已释放而崩溃
        coordinator.handler = handler
        config.setURLSchemeHandler(handler, forURLScheme: KPLSchemeHandler.scheme)

        // 拉取式外壳注入：页面每次加载/重载完成后主动向原生「要」一次外壳状态。
        // 之前是原生单向推送，实测 iPad 上页面会被 WebKit 重置一次（内容进程重建），
        // 推送进去的布局类与安全区变量随之丢失；改成页面就绪后拉取，
        // 无论加载几次、何时加载，状态都能正确落上。
        let boot = """
        (function(){
          var post = function(){ try {
            window.webkit.messageHandlers.kplshell.postMessage('ready');
          } catch (e) {} };
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', post);
          } else { post(); }
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: boot, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        config.userContentController.add(coordinator, name: "kplshell")
        config.userContentController.add(coordinator, name: "kplscroll")

        // 横向滚动让行：手指按下时判断是否在「可横向滚动且确实溢出」的容器内
        //（战绩榜 7 列 / 选手榜 18 列在 iPhone 上必然溢出），结果异步上报给原生。
        // 原生 pagingGesture 据此让行，否则横滑被切页手势吃掉、表格滑不动。
        // 用 capture 阶段监听，确保不被页面的 stopPropagation 拦掉。
        let scrollProbe = """
        (function(){
          var SEL='.table-wrap,.player-table,.schedule,.skin-strip,.pool-grid,[data-hscroll]';
          var post=function(v){try{
            window.webkit.messageHandlers.kplscroll.postMessage(v?'1':'0');
          }catch(e){}};
          var inside=function(t){
            var el=(t&&t.closest)?t:null;
            if(!el)return false;
            var c=el.closest(SEL);
            return !!c && (c.scrollWidth-c.clientWidth)>4;
          };
          document.addEventListener('touchstart',function(e){post(inside(e.target));},true);
          document.addEventListener('touchend',function(e){post(false);},true);
          document.addEventListener('touchcancel',function(e){post(false);},true);
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: scrollProbe, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = coordinator
        wv.uiDelegate = coordinator
        coordinator.observeKeyboard()

        // 触控缩放：禁用捏合缩放（用户反馈：双指向内捏会把页面内容缩小，
        // 缩放态还会残留、与原生布局冲突）。min = max = 1 锁死缩放比例。
        // viewport 层的 user-scalable=no 在 pageDidFinish 里注入 disableZoom()——
        // 此刻页面还没加载，注入 meta 会在 head 建立前插到 documentElement 上，
        // 与页面自己的 viewport meta 冲突，所以只在这里锁 scrollView。
        wv.scrollView.minimumZoomScale = 1.0
        wv.scrollView.maximumZoomScale = 1.0
        wv.scrollView.bouncesZoom = false
        // iOS 专有：边缘滑动前进/后退。前端用 history.replaceState 切模块，不产生历史栈，
        // 因此这个手势只会在页面内的真实跳转（外链已被拦下）时生效，不存在误触。
        wv.allowsBackForwardNavigationGestures = true

        // iOS 专有：长按链接预览（3D Touch / Haptic Touch）
        wv.allowsLinkPreview = true

        // 关掉 WebView 白底，底色由 SwiftUI 侧的 .background(#0b0e17) 兜底，避免首帧闪白
        wv.isOpaque = false
        wv.backgroundColor = KPLPalette.background
        wv.scrollView.backgroundColor = KPLPalette.background

        model.webView = wv
        if let url = WebViewModel.homeURL { wv.load(URLRequest(url: url)) }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 关键：SwiftUI 可能重建 UIViewRepresentable 的底层 UIView（iPad 上
        // 加入 TopGlassFade 覆盖层后实测会触发）。model 里的 weak 引用若仍指向
        // 被丢弃的旧实例，所有 JS 注入都会打到一块看不见的 WebView 上——
        // 表现为「布局类与安全区变量全部失效」。这里每次更新都重新绑定到
        // 当前可见的实例，并补发一次外壳状态（幂等）。
        if model.webView !== uiView {
            model.webView = uiView
            uiView.navigationDelegate = context.coordinator
            uiView.uiDelegate = context.coordinator
            if let url = WebViewModel.homeURL, uiView.url == nil {
                uiView.load(URLRequest(url: url))
            }
            model.applyShellState()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let model: WebViewModel
        var handler: KPLSchemeHandler?
        init(model: WebViewModel) { self.model = model }

        /// 修复「键盘收起后页面缩放不还原」：
        /// iOS 聚焦 font-size < 16px 的输入框时，WKWebView 会通过 scrollView 缩放
        /// 放大视口以便输入；但键盘收起后缩放不会自动还原，只有旋转屏幕触发
        /// 重新布局才恢复。这里监听键盘通知，在收起时把缩放还原到 1
        /// （minimumZoomScale）。用户平时的手动捏合缩放不受影响——
        /// 只有「聚焦输入框引发的那次缩放」会在键盘收起时被还原。
        ///
        /// 用 selector 版注册（而非 @Sendable 闭包）：键盘通知固定在主线程投递，
        /// 处理方法标记 @MainActor，避免闭包里引用 MainActor 隔离属性的并发告警；
        /// iOS 9+ 会随 Coordinator 释放自动移除监听，无需手动清理令牌。
        func observeKeyboard() {
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardWillHide),
                name: UIResponder.keyboardWillHideNotification, object: nil
            )
        }

        @objc private func keyboardWillHide(_ note: Notification) {
            guard let wv = model.webView else { return }
            let minScale = wv.scrollView.minimumZoomScale
            if abs(wv.scrollView.zoomScale - minScale) > 0.01 {
                wv.scrollView.setZoomScale(minScale, animated: true)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in model.pageDidFinish() }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                model.isLoading = false
                model.lastError = error.localizedDescription
            }
        }

        /// 外链拦到系统 Safari（应用内 SFSafariViewController），页面本身不跳走。
        /// 这是 iOS 版的必要处理：macOS 版的 WebView 跳外链会开新窗口，iOS 上则会把
        /// 整个 App 内容替换成网页，且无法回到看板。
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow); return
            }
            // 自定义 scheme = 本应用的页面与接口，放行
            if url.scheme == KPLSchemeHandler.scheme { decisionHandler(.allow); return }

            let isNewWindow = navigationAction.targetFrame == nil
            let isLinkTap = navigationAction.navigationType == .linkActivated
            if isNewWindow || isLinkTap {
                decisionHandler(.cancel)
                Task { @MainActor in model.externalLink = KPLExternalLink(url: url) }
            } else {
                decisionHandler(.allow)
            }
        }

        /// `target="_blank"` 的链接不会走 decidePolicy，必须在这里拦下并外部打开
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                Task { @MainActor in model.externalLink = KPLExternalLink(url: url) }
            }
            return nil
        }

        // MARK: 页面拉取外壳状态

        /// 页面就绪（DOMContentLoaded 之后）会通过 `kplshell` messageHandler 主动要一次
        /// 外壳状态。谁发消息就把状态注入给谁——即使 SwiftUI 重建过 WebView、
        /// 或 WebKit 重置过页面，也不会把状态打丢。
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "kplscroll" {
                let on = (message.body as? String) == "1"
                Task { @MainActor in self.model.horizontalScrollActive = on }
                return
            }
            guard message.name == "kplshell" else { return }
            let target = message.webView
            Task { @MainActor in
                // 页面就绪：旧一次加载的 scheme task 此时都已被 WebKit stop，
                // 可以安全清空「已停止」记录——防止集合无界增长，且避免
                // 释放后的 ObjectIdentifier 地址被复用时把新 task 误判成已停止
                //（响应会被静默丢弃，表现为偶发图片/接口加载失败）。
                self.handler?.resetStopped()
                self.model.applyShellState(to: target)
                self.model.pageDidFinish()
            }
        }
    }
}

// MARK: - SafariViewController（官方推荐的应用内打开外链方式）

struct SafariViewer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = KPLPalette.gold
        return vc
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - 配色（与前端 theme.css 的深色底保持一致）

enum KPLPalette {
    /// #0b0e17 —— 前端 --bg 的深色值，用作首帧兜底底色
    static let background = UIColor(red: 0.043, green: 0.055, blue: 0.090, alpha: 1)
    /// #f5c451 —— 前端 --gold
    static let gold = UIColor(red: 0.961, green: 0.769, blue: 0.318, alpha: 1)

    static var swiftUIBackground: Color { Color(background) }
    /// #f5c451
    static var swiftUIGold: Color { Color(gold) }

    /// 选中态强调色：金色在浅色底上对比度不足（#f5c451 对白底 ≈ 1.6:1），
    /// 浅色模式改用加深的琥珀金（对白底 ≈ 5.4:1），深色模式维持品牌金。
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? swiftUIGold : Color(red: 0.60, green: 0.45, blue: 0.06)
    }

    /// 网页主题底色（theme.css 的 --bg 两档）：浅 #f2f5fb / 深 #0b0e17。
    /// 顶部的渐隐毛玻璃条用页面同色着色，才能与内容无缝衔接、不出现「灰带」。
    static func pageBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(background)
            : Color(red: 0.949, green: 0.961, blue: 0.984)
    }
}

// MARK: - 禁用捏合缩放

extension WKWebView {
    /// 彻底关闭双指捏合缩放：
    /// 1. scrollView 的 min/max 缩放都锁在 1（在 makeUIView 里设置）；
    /// 2. 向页面注入 user-scalable=no + maximum-scale=1 的 viewport meta——
    ///    WKWebView 的捏合缩放由网页 viewport 与 scrollView 共同决定，
    ///    只锁 scrollView 在部分 iOS 版本上仍会被 WebKit 内部的
    ///    「输入聚焦自动放大」路径突破；viewport 层面禁掉才是根。
    /// 页面无缩放需求（布局已按 iPhone / iPad 两档适配），无障碍放大
    /// 由系统级「逐字缩放 / 缩放」功能覆盖，不受此影响。
    func disableZoom() {
        let js = """
        (function(){
          var m = document.querySelector('meta[name="viewport"]');
          if (!m) {
            m = document.createElement('meta');
            m.name = 'viewport';
            (document.head || document.documentElement).appendChild(m);
          }
          m.setAttribute('content',
            'width=device-width, initial-scale=1, maximum-scale=1, minimum-scale=1, user-scalable=no, viewport-fit=cover');
        })();
        """
        // atDocumentEnd 注入一次 + DOMContentLoaded 后由 kplshell 拉取路径再兜一次
        evaluateJavaScript(js, completionHandler: nil)
    }
}
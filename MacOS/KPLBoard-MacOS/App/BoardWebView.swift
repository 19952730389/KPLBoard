import SwiftUI
import WebKit
import AppKit   // NSWorkspace.open（target="_blank" 链接交给默认浏览器）

/// WebView 的控制中心：承载 WKWebView 引用，向前端注入指令。
@MainActor
final class WebViewModel: ObservableObject {
    weak var webView: WKWebView?

    @Published var isLoading = true
    /// 最近一次页面加载错误。目前仅记录（诊断用），UI 未绑定；
    /// 如需在界面上展示，请在 RootView 里观察它。
    @Published var lastError: String? = nil
    /// 左侧导航栏是否收起（前端 `.sidebar`）。由工具栏按钮 / 菜单栏 ⌘⌥S 控制，跨启动记忆。
    @Published private(set) var sidebarCollapsed: Bool

    /// 最近一次的布局模式，用于页面加载完成后重放（见 applyShellState）
    private var isWideLayout = true

    private static let sidebarKey = "kplboard.macos.sidebarCollapsed"

    init() {
        sidebarCollapsed = UserDefaults.standard.bool(forKey: Self.sidebarKey)
    }

    static var homeURL: URL? {
        URL(string: "\(KPLSchemeHandler.scheme)://\(KPLSchemeHandler.host)/index.html")
    }

    func load() {
        guard let url = Self.homeURL else { return }
        isLoading = true
        webView?.load(URLRequest(url: url))
    }

    /// 切换赛季：前端 app.js 的 switchEvent() 是全局 async 函数。
    /// id 经 JSON 字符串编码后再拼接（防注入），并捕获前端执行错误。
    func selectEvent(_ id: String) {
        let data = (try? JSONEncoder().encode([id])) ?? Data("[]".utf8)
        let quoted = String(data: data, encoding: .utf8)
            .map { $0.dropFirst().dropLast() }   // ["1201"] → "1201"
            .map(String.init) ?? "null"
        webView?.evaluateJavaScript("(async () => { try { await switchEvent(\(quoted)); return true; } catch (e) { return String(e); } })()") { _, err in
            if let err { print("[KPL] switchEvent 失败: \(err.localizedDescription)") }
        }
    }

    /// 刷新：前端暴露的 window.KPLBoardRefresh()
    func refresh() {
        webView?.evaluateJavaScript("KPLBoardRefresh()") { _, err in
            if let err { print("[KPL] refresh 失败: \(err.localizedDescription)") }
        }
    }

    /// 收起 / 展开左侧导航栏（前端 `.sidebar`）
    func toggleSidebar() {
        sidebarCollapsed.toggle()
        UserDefaults.standard.set(sidebarCollapsed, forKey: Self.sidebarKey)
        applyShellState()
    }

    /// 把当前布局模式告诉前端：宽窗口走 `mac-wide` 的间距与双栏栅格，窄窗口走 `mac-narrow`。
    /// （iOS 版注入的是 ipad-landscape / ipad-portrait，macOS 版换成 mac-wide / mac-narrow，
    ///   由 Resources/web/mac.css 承接，作用完全对应。）
    func applyLayoutMode(landscape: Bool) {
        isWideLayout = landscape
        applyShellState()
    }

    /// 把外壳状态（布局模式 + 导航栏显隐）一次性推给前端。
    ///
    /// 前端用 `body.mac-wide / mac-narrow` 切栅格与间距，用 `body.sidebar-off` 收起导航栏
    /// （规则在 mac.css 里）。两件事放同一次注入，避免两次 JS 调用之间出现「半边状态」。
    ///
    /// 之所以在 didFinish 里还要再调一次：窗口首次出现时页面正文尚未解析完，
    /// 那次注入会打在空 document 上（`document.body` 为 nil）后静默返回，
    /// 不重放的话 mac-wide 与 sidebar-off 都会丢。
    func applyShellState() {
        let cls = isWideLayout ? "mac-wide" : "mac-narrow"
        let js = """
        (function(){
          var b = document.body;
          if (!b) return;
          b.classList.remove('mac-wide','mac-narrow');
          b.classList.add('\(cls)');
          b.classList.toggle('sidebar-off', \(sidebarCollapsed ? "true" : "false"));
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

// MARK: - NSViewRepresentable（iOS 版为 UIViewRepresentable）

struct BoardWebView: NSViewRepresentable {
    @ObservedObject var model: WebViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let handler = KPLSchemeHandler()
        let config = WKWebViewConfiguration()
        // handler 必须被强引用持有，否则页面发起请求时会因 handler 已释放而崩溃
        context.coordinator.handler = handler
        config.setURLSchemeHandler(handler, forURLScheme: KPLSchemeHandler.scheme)

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator   // target="_blank" 链接经 createWebViewWith 交给默认浏览器

        // iOS 版的 scrollView.minimumZoomScale/maximumZoomScale + 禁用双击缩放
        // → macOS 对应项是 allowsMagnification（触控板捏合缩放），同样保留缩放能力。
        // （iOS 上禁用「双击缩放」是为了防误触；macOS 没有双击缩放手势，无需处理。）
        wv.allowsMagnification = true
        wv.magnification = 1.0

        // iOS 版的 isOpaque = false + backgroundColor = #0b0e17
        // → macOS 没有这两个属性，用 WebKit 的 drawsBackground 关掉白底，
        //   底色由 SwiftUI 侧的 .background(#0b0e17) 兜底，表现与 iOS 版一致。
        if wv.responds(to: NSSelectorFromString("setDrawsBackground:")) {
            wv.setValue(false, forKey: "drawsBackground")
        }

        // macOS 上 WKWebView 不支持 allowsBackForwardNavigationGestures（iOS 专有），
        // 且鼠标/触控板没有边缘滑动手势，本应用也无前进/后退栈，故不设置。

        model.webView = wv
        if let url = WebViewModel.homeURL { wv.load(URLRequest(url: url)) }
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // 布局变化由 RootView 通过 model.applyLayoutMode 通知前端，这里无需处理
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: WebViewModel
        var handler: KPLSchemeHandler?

        init(model: WebViewModel) { self.model = model }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                model.isLoading = false
                // 页面就绪后重放布局模式与导航栏显隐（首帧注入时 document.body 还不存在）
                model.applyShellState()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                model.isLoading = false
                model.lastError = error.localizedDescription
            }
        }

        /// 前端有大量 `target="_blank"` 链接（公告原文 / 官网 / 查看原图）。
        /// 没有实现这个方法时 WKWebView 对它们**静默不响应**——点击没有任何反应。
        /// macOS 惯例：外部链接交给默认浏览器打开。
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url,
               url.scheme != KPLSchemeHandler.scheme,             // 站内链接仍由本视图处理
               NSWorkspace.shared.open(url) {
                return nil
            }
            return nil
        }
    }
}

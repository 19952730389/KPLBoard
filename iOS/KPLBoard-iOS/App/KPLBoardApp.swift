import SwiftUI

@main
struct KPLBoardApp: App {
    /// 走 `UIApplicationDelegateAdaptor` 挂一个系统 AppDelegate：
    /// SwiftUI App 生命周期下，`UIApplication` 级的设置（屏幕常亮策略等）
    /// 只能在 AppDelegate 里做，这也是 Apple 官方推荐的桥接方式。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // iPadOS 开启多窗口（Info.plist 的 UIApplicationSupportsMultipleScenes）。
        // 每个窗口一棵视图树、`WebViewModel` 由 RootView 用 @StateObject 持有，
        // 因此各窗口状态互相独立，不会串到同一个 WKWebView 上。
        WindowGroup {
            RootView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 与 macOS / iPad 版一致：不接管屏幕常亮。看板自带轮询，无需阻止系统熄屏，
        // 强行常亮只会白白耗电。
        UIApplication.shared.isIdleTimerDisabled = false
        return true
    }

    /// 支持的屏幕方向由 Info.plist 的 `UISupportedInterfaceOrientations` 声明
    ///（iPhone 三向、iPad 四向），这里不做额外限制，保证 iPad 分屏与外接显示器正常。
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }
}

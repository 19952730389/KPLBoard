import SwiftUI
import UIKit

// MARK: - 设备档案（iPhone 12 Pro Max / iPad Pro 11 英寸 M2）

/// 目标设备的官方规格常量表。
///
/// 这些数值有两个用途：
///   1. **文档价值**——把「两台设备到底差在哪」写死在代码里，避免口头对齐出现偏差；
///   2. **兜底价值**——模拟器、`hw.machine` 无法识别的新机型、外接显示器等场景，
///      用「屏幕点数 + 缩放倍数」反查最接近的一档，保证布局档位始终有值。
///
/// ⚠️ 真正参与布局的**运行时**数值（安全区、屏幕尺寸、尺寸类别）一律实时读取，
///    绝不写死——Apple 要求适配必须响应 Split View / Slide Over / Stage Manager / 旋转 / 多场景，
///    任何硬编码都会在 iPad 分屏或 iPhone 横屏时出错。
enum DeviceProfile {

    /// 支持的设备档位
    enum Kind: String, CaseIterable, Identifiable {
        case iPhone12ProMax
        case iPadPro11InchM2
        case iPhoneOther
        case iPadOther
        case unknown

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .iPhone12ProMax:  return "iPhone 12 Pro Max"
            case .iPadPro11InchM2: return "iPad Pro 11 英寸（M2）"
            case .iPhoneOther:     return "iPhone（其他机型）"
            case .iPadOther:       return "iPad（其他机型）"
            case .unknown:         return "未知设备"
            }
        }
    }

    /// 一档设备的官方规格（点数 / 物理像素 / 缩放倍数 / 竖屏安全区）
    struct Spec {
        let kind: Kind
        /// 机型标识符（`hw.machine`），用于精确识别
        let identifiers: [String]
        /// 竖屏逻辑分辨率（pt）
        let pointsPortrait: CGSize
        /// 原生物理分辨率（px）
        let pixelsPortrait: CGSize
        /// 缩放倍数（`UIScreen.nativeScale`）
        let scale: CGFloat
        /// 竖屏安全区（pt）：上 / 下 / 左 / 右
        let safeArea: (top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat)
        /// 备注（来源与说明）
        let note: String
    }

    /// 规格表：
    /// - iPhone 12 Pro Max：6.7″，428×926 pt / 1284×2778 px，@3x，458 ppi；
    ///   刘海屏，竖屏 safeAreaInsets = (top 47, bottom 34, left 0, right 0)。
    /// - iPad Pro 11″（第 4 代 / M2）：1194×834 pt / 2388×1668 px，@2x，264 ppi；
    ///   圆角全面屏，竖屏 safeAreaInsets = (top 24（状态栏显示时）, bottom 20（Home 指示条）, left 0, right 0)。
    ///   数据来源：Apple《Designing for iPad Pro and Apple Pencil》官方技术讲座
    ///   ——「bottom inset is 20 points in portrait orientation and in landscape」、
    ///   「when a status bar is displayed, the top inset value is 24 points」。
    static let specs: [Spec] = [
        Spec(kind: .iPhone12ProMax,
             identifiers: ["iPhone13,4"],
             pointsPortrait: CGSize(width: 428, height: 926),
             pixelsPortrait: CGSize(width: 1284, height: 2778),
             scale: 3,
             safeArea: (top: 47, bottom: 34, left: 0, right: 0),
             note: "6.7″ 刘海屏 · 458 ppi · A14"),

        Spec(kind: .iPadPro11InchM2,
             identifiers: ["iPad14,3", "iPad14,4"],
             pointsPortrait: CGSize(width: 834, height: 1194),
             pixelsPortrait: CGSize(width: 1668, height: 2388),
             scale: 2,
             safeArea: (top: 24, bottom: 20, left: 0, right: 0),
             note: "Liquid 视网膜 · 264 ppi · M2 · Face ID"),
    ]

    // MARK: 机型识别

    /// `hw.machine` 原始字符串（模拟器返回宿主架构，需配合尺寸兜底）
    static var machineIdentifier: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    /// 精确匹配机型表；未命中再按「屏幕点数 + 缩放倍数」反查，最后按设备类型归类
    static func kind(screenPoints: CGSize, scale: CGFloat, idiom: UIUserInterfaceIdiom) -> Kind {
        let id = machineIdentifier
        if let hit = specs.first(where: { $0.identifiers.contains(id) }) { return hit.kind }

        // 反查：点数与缩放倍数同时命中才算（避免把 iPad mini 当成 11″）
        let w = min(screenPoints.width, screenPoints.height)
        let h = max(screenPoints.width, screenPoints.height)
        for s in specs {
            let sw = min(s.pointsPortrait.width, s.pointsPortrait.height)
            let sh = max(s.pointsPortrait.width, s.pointsPortrait.height)
            if abs(w - sw) < 1, abs(h - sh) < 1, abs(scale - s.scale) < 0.01 { return s.kind }
        }

        switch idiom {
        case .pad:   return .iPadOther
        case .phone: return .iPhoneOther
        default:     return .unknown
        }
    }

    static func spec(for kind: Kind) -> Spec? { specs.first { $0.kind == kind } }
}

// MARK: - 运行时屏幕信息（一律实时读取，不硬编码）

/// 当前窗口的屏幕与安全区快照。
///
/// 取值全部走官方 API：
///   - 屏幕：`UIWindowScene.screen`（iOS 15 起 `UIScreen.main` 已不推荐用于多场景）
///   - 安全区：SwiftUI 的 `GeometryProxy.safeAreaInsets`（随旋转 / 分屏 / 键盘实时变化）
struct ScreenSnapshot: Equatable {
    /// 逻辑分辨率（pt）
    var points: CGSize = .zero
    /// 原生物理分辨率（px）
    var pixels: CGSize = .zero
    /// 缩放倍数
    var scale: CGFloat = 2
    /// 安全区（pt）
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat = 0
    var safeLeft: CGFloat = 0
    var safeRight: CGFloat = 0
    /// 设备类型与机型
    var idiom: UIUserInterfaceIdiom = .phone
    var kind: DeviceProfile.Kind = .unknown

    /// 是否「宽布局」：iPad 竖屏 (834pt) / 横屏 (1194pt)，以及 iPhone 大屏横屏 (926pt)
    /// 都会进入 regular 宽度类别，此时启用原生侧栏。
    static let sidebarMinWidth: CGFloat = 700

    var idiomName: String {
        switch idiom {
        case .pad:     return "iPad"
        case .phone:   return "iPhone"
        case .tv:      return "Apple TV"
        case .carPlay: return "CarPlay"
        case .vision:  return "Apple Vision Pro"
        default:       return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        }
    }

    var resolutionText: String {
        String(format: "%.0f × %.0f pt · %.0f × %.0f px · @%.0fx",
               points.width, points.height, pixels.width, pixels.height, scale)
    }

    var safeAreaText: String {
        String(format: "上 %.0f · 下 %.0f · 左 %.0f · 右 %.0f",
               safeTop, safeBottom, safeLeft, safeRight)
    }
}

/// 从当前活动窗口场景读取屏幕信息（官方推荐：按场景取 screen，而非 `UIScreen.main`）
enum ScreenReader {
    static func current() -> ScreenSnapshot {
        var snap = ScreenSnapshot()

        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        let screen = scene?.screen ?? .main
        let bounds = screen.bounds.size
        let native = screen.nativeBounds.size

        snap.points = bounds
        snap.pixels = native
        snap.scale = screen.nativeScale > 0 ? screen.nativeScale : screen.scale
        snap.idiom = UIDevice.current.userInterfaceIdiom
        snap.kind = DeviceProfile.kind(screenPoints: bounds, scale: snap.scale, idiom: snap.idiom)

        // 安全区：优先取当前 keyWindow（SwiftUI 的 GeometryReader 会在视图层再覆盖一次）
        if let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first {
            let i = window.safeAreaInsets
            snap.safeTop = i.top
            snap.safeBottom = i.bottom
            snap.safeLeft = i.left
            snap.safeRight = i.right
        }
        return snap
    }
}

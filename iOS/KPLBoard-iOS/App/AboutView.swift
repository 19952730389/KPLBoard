import SwiftUI

/// 「关于与设备信息」：既是应用说明，也是**设备适配的自检面板**——
/// 在 iPhone 12 Pro Max 与 iPad Pro 11″（M2）上分别打开，
/// 可以直接核对屏幕点数、物理像素、缩放倍数与安全区是否与官方规格一致。
struct AboutView: View {
    @State private var snap = ScreenReader.current()

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v)（\(b)）"
    }

    private var spec: DeviceProfile.Spec? { DeviceProfile.spec(for: snap.kind) }

    /// 说明：`navigationTitle` / `toolbar` 由外层容器提供——
    /// iPad 侧栏入口用 `.sheet { NavigationStack { AboutView() } }` 包一层，
    /// iPhone「更多」里则是 `NavigationLink { AboutView() }` 直接进栈，
    /// 因此本视图自身不再套 NavigationStack，避免双层导航栏。
    var body: some View {
        List {
                Section("应用") {
                    row("名称", "KPL 比分看板")
                    row("版本", version)
                    row("运行平台", "\(snap.idiomName) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                    row("支持形态", snap.idiom == .pad ? "iPad：原生侧栏 + 详情" : "iPhone：底部页签")
                }

                Section {
                    row("机型", snap.kind.displayName)
                    row("机型标识", DeviceProfile.machineIdentifier)
                    row("逻辑分辨率", String(format: "%.0f × %.0f pt", snap.points.width, snap.points.height))
                    row("物理分辨率", String(format: "%.0f × %.0f px", snap.pixels.width, snap.pixels.height))
                    row("缩放倍数", String(format: "@%.0fx", snap.scale))
                } header: {
                    Text("屏幕")
                } footer: {
                    if let s = spec {
                        Text("官方规格：\(String(format: "%.0f × %.0f", s.pointsPortrait.width, s.pointsPortrait.height)) pt / \(String(format: "%.0f × %.0f", s.pixelsPortrait.width, s.pixelsPortrait.height)) px @\(String(format: "%.0f", s.scale))x · \(s.note)")
                    }
                }

                Section {
                    row("上", String(format: "%.0f pt", snap.safeTop))
                    row("下", String(format: "%.0f pt", snap.safeBottom))
                    row("左", String(format: "%.0f pt", snap.safeLeft))
                    row("右", String(format: "%.0f pt", snap.safeRight))
                } header: {
                    Text("安全区（实时读取）")
                } footer: {
                    Text("数值取自当前窗口的 safeAreaInsets，随旋转、分屏、Stage Manager 实时变化。"
                         + "iPhone 12 Pro Max 竖屏约为 上 47 / 下 34；iPad Pro 11″ 竖屏约为 上 24 / 下 20（Home 指示条）。")
                }

                Section {
                    row("赛程与实时比分", "玩加赛事 wanplus.cn")
                    row("实时比分", "KPL 官方 / PandaScore")
                    row("英雄 · 装备 · 铭文", "王者荣耀官方资料库")
                    row("职业统计", "玩加赛事职业赛场数据")
                    row("版本公告", "王者荣耀官网")
                } header: {
                    Text("数据来源")
                } footer: {
                    Text("全部请求走 HTTPS；离线时展示安装包内的种子数据与上次缓存。")
                }
            }
            .navigationTitle("关于与设备信息")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { snap = ScreenReader.current() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.subheadline)
    }
}

#Preview {
    NavigationStack { AboutView() }
}

import SwiftUI

/// 界面设置：外观（跟随系统/浅色/深色）、悬浮玻璃档位、底部导航模块显隐。
/// 不再以弹窗（sheet）呈现：iPad 内嵌在详情区、iPhone 全屏内嵌，
/// 由外部传入 `onClose` 关闭；未传入时（如「更多」浮层里 push 进入）走系统 dismiss。
struct SettingsView: View {
    /// 内嵌展示时的关闭回调
    var onClose: (() -> Void)? = nil
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            Section {
                ForEach(AppearanceMode.allCases) { mode in
                    optionRow(title: mode.label, note: mode.note,
                              selected: settings.appearance == mode) {
                        settings.setAppearance(mode)
                    }
                }
            } header: {
                Text("外观")
            } footer: {
                Text("跟随系统时，原生界面与网页内容都会随系统深浅色切换。")
            }

            Section {
                ForEach(GlassLevel.allCases) { level in
                    optionRow(title: level.label, note: level.note,
                              selected: settings.glass == level) {
                        settings.setGlass(level)
                    }
                }
            } header: {
                Text("悬浮玻璃")
            } footer: {
                Text("作用于底部导航栏与顶部导航栏的毛玻璃强度，"
                     + "对应系统「透明度」设置的强/均衡/弱。")
            }

            Section {
                ForEach(ModuleCatalog.all) { m in
                    toggleRow(module: m)
                }
            } header: {
                Text("底部导航")
            } footer: {
                Text("底栏最多显示 \(AppSettings.maxTabs) 个模块（另有固定的「更多」入口），"
                     + "未勾选的模块收进「更多」浮层，仍可正常访问。")
            }

            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    Label("关于与设备信息", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 内嵌为一等页面时提供返回（用户要求去掉「完成」，有返回即可）；
            // 未传入 onClose（如「更多」浮层里 push 进入）时由系统提供返回。
            if onClose != nil {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        onClose?()
                    } label: {
                        Image(systemName: "chevron.left")
                            .accessibilityLabel("返回")
                    }
                }
            }
        }
    }

    // MARK: 行组件

    /// 单选行：独立成 `View`（而非 @Builder）保证选中态即时刷新
    private func optionRow(title: String, note: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(KPLPalette.accent(colorScheme))
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 模块开关行
    private func toggleRow(module: KPLModule) -> some View {
        let isOn = settings.tabIDs.contains(module.id)
        let canTurnOn = settings.tabIDs.count < AppSettings.maxTabs
        return Toggle(isOn: Binding(get: { isOn },
                                    set: { settings.toggleTab(module.id, on: $0) })) {
            HStack(spacing: 12) {
                Image(systemName: module.symbol)
                    .frame(width: 22)
                    .foregroundStyle(isOn ? KPLPalette.accent(colorScheme) : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.name)
                    Text(module.note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!isOn && !canTurnOn)
    }
}

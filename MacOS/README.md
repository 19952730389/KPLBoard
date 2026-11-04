# KPLBoard for macOS

在 KPLBoard for iPadOS 基础上产出的 **macOS 原生版**（Swift + SwiftUI）。
数据模型、业务逻辑、视图层级、交互流程与原项目**逐行对齐**，不新增也不删减功能，
只做 macOS 必要适配：窗口尺寸与布局、菜单栏与快捷键、鼠标/键盘交互、iOS 专有 API 的 macOS 对等实现。

> **与 iPad 版的关系**：同一个前端（`Resources/web/`）+ 同一套 Swift 数据层（`Data/`）。
> 前端通过 `WKWebView` + 自定义 scheme（`kplboard://app/`）与 Swift 拼成「同源站点」，
> 数据来自玩加赛事 / KPL 官方 / PandaScore 三条通道，与桌面 Electron 版逻辑一致。

---

## 一、构建配置

| 项目 | 值 |
|---|---|
| Product / Target | `KPLBoard-MacOS` |
| Bundle Identifier | `com.local.kplboard.macos`（可在 Xcode → Target → Signing & Capabilities 改） |
| Version（`CFBundleShortVersionString`） | **1.4.0**（1.2.0 接入工具箱 / 版本公告；1.3.0 左侧导航统一为前端侧栏；1.3.1 两栏等高；1.4.0 接入 KPL 官方统计通道，补齐 2023+ 赛季梯度榜 / 选手榜） |
| Build（`CFBundleVersion`） | `1` |
| 最低系统版本 | **macOS 13.0 Ventura**（`MACOSX_DEPLOYMENT_TARGET = 13.0`，`NavigationStack` 与 `WKWebView` 同代 API 的门槛） |
| SDK / 平台 | `SDKROOT = macosx`，`SUPPORTED_PLATFORMS = macosx` |
| 架构 | 标准架构（arm64 + x86_64，未写死 `ARCHS`） |
| Swift 版本 | 5.0（`SWIFT_STRICT_CONCURRENCY = minimal`） |
| 依赖框架 | `WebKit.framework`（系统内置，无第三方依赖、无 CocoaPods/SPM） |
| 签名 | `CODE_SIGN_STYLE = Automatic` + Hardened Runtime |
| 沙盒 | App Sandbox 开启，`KPLBoard-MacOS.entitlements` 声明 `app-sandbox` + `network.client` |
| 高分屏 | `NSHighResolutionCapable = true`（macOS 必须显式声明，Retina 才会取 @2x 位图） |
| 分类 | `LSApplicationCategoryType = public.app-category.sports` |
| 网络 | 全部走 HTTPS，`NSAllowsArbitraryLoads = false`；仅 WebView 内网页放开 `NSAllowsArbitraryLoadsInWebContent` |

---

## 二、目录结构

```
KPLBoard-MacOS/
├── KPLBoard-MacOS.xcodeproj/
│   ├── project.pbxproj                          # Xcode 工程（双击即可打开）
│   └── xcshareddata/xcschemes/KPLBoard-MacOS.xcscheme
└── KPLBoard-MacOS/
    ├── App/                                     # UI 层（SwiftUI + WebKit）
    │   ├── KPLBoardApp.swift                    # @main 入口 + 窗口尺寸 + 菜单栏命令
    │   ├── RootView.swift                       # 全宽度 WebView + 工具栏（导航栏显隐 / 赛季 / 刷新）
    │   ├── BoardWebView.swift                   # WKWebView 封装（NSViewRepresentable）+ 与前端互调
    │   └── KPLSchemeHandler.swift               # 自定义 scheme：静态资源 + /api/* 路由
    ├── Data/                                    # 数据层
    │   ├── Models.swift                         # Match / Team / Event / RealtimeEntry + 北京时间工具
    │   ├── Net.swift                            # HTTP 封装（form / json / text / raw / GBK）
    │   ├── WanplusSource.swift                  # 玩加主源：live（按周）+ archive（HTML 正则解析）
    │   ├── KPLOfficialSource.swift              # KPL 官方 kplshop-op/kplow/getScheduleList
    │   ├── PandaScoreSource.swift               # esportsresults.com（补逐小局 + 兜底）
    │   ├── Aggregator.swift                     # 双通道合并 / 状态推断 / 积分榜 / 概览
    │   ├── BoardStore.swift                     # actor 仓储：缓存、刷新、看板组装
    │   ├── ImgProxy.swift                       # ← 1.2.0：图片代理（白名单 + Referer + 缓存）
    │   ├── ToolsCache.swift                     # ← 1.2.0：工具箱两级缓存（种子 + 可写目录）
    │   ├── ToolsUtil.swift                      # ← 1.2.0：HTML 清洗 / time33 签名 / 稳定排序
    │   ├── ToolsDict.swift                      # ← 1.2.0：皮肤徽章表等常量字典（脚本生成）
    │   ├── ToolsStore.swift                     # ← 1.2.0：英雄 / 装备 / 铭文 / 皮肤 / 选手 / 战队 / 梯度
    │   └── PatchStore.swift                     # ← 1.2.0：官网更新公告与调整条目解析
    ├── Resources/
    │   ├── events.json                          # 77 个赛季清单（2016–2026，原样复用）
    │   ├── data/tools/                          # ← 1.2.0：299 个种子 JSON（12 MB，断网兜底）
    │   └── web/                                 # 前端静态资源（folder reference，保留目录结构）
    │       ├── index.html  app.js  style.css  shell.css  theme.css  tools.css
    │       ├── img.js  store.js  theme.js  tools.js  shell.js
    │       └── mac.css                          # ← 本次新增：macOS 适配层（接替 ipad.css）
    ├── Assets.xcassets/AppIcon.appiconset/      # macOS 图标十档
    │   ├── icon_16x16.png / icon_16x16@2x.png
    │   ├── icon_32x32.png / icon_32x32@2x.png
    │   ├── icon_128x128.png / icon_128x128@2x.png
    │   ├── icon_256x256.png / icon_256x256@2x.png
    │   └── icon_512x512.png / icon_512x512@2x.png
    ├── Info.plist
    └── KPLBoard-MacOS.entitlements
```

---

## 三、为适配 macOS 所做的改动（逐处说明）

### 1. 工程与配置（pbxproj / Info.plist / entitlements）

| 项 | iPad 版 | macOS 版 | 原因 |
|---|---|---|---|
| SDK / 部署目标 | `SDKROOT = iphoneos`，`IPHONEOS_DEPLOYMENT_TARGET = 16.0` | `SDKROOT = macosx`，`MACOSX_DEPLOYMENT_TARGET = 13.0` | 平台切换；13.0 是 `NavigationStack` 的 macOS 门槛 |
| 版本号 | `MARKETING_VERSION = 1.0.0` | **`MARKETING_VERSION = 1.4.0`** | 需求指定 |
| Bundle ID | `com.local.kplboard.ipad` | `com.local.kplboard.macos` | 与 iPad 版共存，不冲突 |
| 架构 | 写死 `ARCHS = arm64` | 去掉 `ARCHS`，走标准架构（arm64 + x86_64） | macOS 需同时支持 Apple 芯片与 Intel |
| Info.plist | `LSRequiresIPhoneOS` / `UIDeviceFamily` / `UISupportedInterfaceOrientations` / `UIApplicationSceneManifest` / `UILaunchScreen` / `UIRequiredDeviceCapabilities` | 全部移除 | 这些键在 macOS 上无意义 |
| Info.plist 新增 | — | `LSMinimumSystemVersion`、`NSHighResolutionCapable`、`LSApplicationCategoryType`、`NSHumanReadableCopyright` | macOS 必需/惯例声明 |
| 签名 | 仅 `CODE_SIGN_STYLE = Automatic` | 追加 `ENABLE_HARDENED_RUNTIME = YES`、`ENABLE_APP_SANDBOX = YES`、`CODE_SIGN_ENTITLEMENTS` | macOS 分发要求；沙盒下只放行出网 |
| entitlements | 无 | 新增 `KPLBoard-MacOS.entitlements`（`app-sandbox` + `network.client`） | 三个上游数据源与队标 CDN 需要出网 |
| 图标 | iPad 四档（76/152/167/1024） | macOS 十档（16→512，含 @2x）+ `Contents.json` 的 `idiom: mac` | macOS 图标尺寸规范不同；由 `icon-1024.png` 用 `sips` 重采样生成 |
| scheme | 无共享 scheme | 新增 `xcshareddata/xcschemes/KPLBoard-MacOS.xcscheme` | 便于命令行构建与 CI |

### 2. App 生命周期入口（`App/KPLBoardApp.swift`）

| iPad 版 | macOS 版 | 说明 |
|---|---|---|
| `.onAppear { UIApplication.shared.isIdleTimerDisabled = false }` | 删除 | `UIApplication` 是 UIKit(iOS) 专有；macOS 没有「闲置熄屏计时器」，该调用本身也是设成系统默认值，删掉无功能变化 |
| 无窗口设置 | `.defaultSize(width: 1440, height: 900)` + `.frame(minWidth: 900, minHeight: 600)` | macOS 窗口可缩放，需给出初始尺寸与下限；最小宽 900pt 是单列布局的可用下限 |
| 无 | `.windowToolbarStyle(.unified)` | macOS 统一工具栏样式（工具栏并入标题栏），与原生应用一致 |
| `CommandGroup(replacing: .appInfo)` 里是空 Button | `Button("关于 KPL 比分看板") { NSApplication.shared.orderFrontStandardAboutPanel(options: [:]) }` | iOS 版注释写「走系统默认」但无法触发；macOS 用 `orderFrontStandardAboutPanel` 真正调出系统关于面板，行为与注释一致 |
| 快捷键只挂在工具栏 | 新增 `CommandMenu("看板")`：刷新 ⌘R、显示/隐藏侧边栏 ⌘⌥S | macOS 惯例：快捷键由菜单栏提供。⌘R 只在菜单声明一次，避免与工具栏重复注册。1.3.0 起 ⌘⌥S 不再走 `NSSplitViewController.toggleSidebar`（原生侧栏已移除），改为直接调 `WebViewModel.toggleSidebar()` |
| `WebViewModel` 在 `RootView` 内 `@StateObject` | 上提到 `App` 层持有并注入 `RootView` | `.commands` 在视图层级之外，菜单命令必须能访问同一个 model 才能触发刷新 |

### 3. 布局（`App/RootView.swift`）

| iPad 版 | macOS 版 | 说明 |
|---|---|---|
| 阈值 1024pt 判横竖屏，宽 → `NavigationSplitView`，窄 → `NavigationStack` | **阈值不变，但两种宽度都走同一个 `NavigationStack`**（1.3.0 起） | 原生赛季侧栏与前端 `.sidebar` 是两套并排的导航，屏幕最左被重复占了两列。1.3.0 移除原生侧栏，左侧导航统一为前端 `.sidebar`；阈值现在只决定前端套 `mac-wide` 还是 `mac-narrow` |
| `.navigationBarTitleDisplayMode(.inline)` | 删除 | iOS 专有 API，macOS 不存在 |
| 分栏 detail 无 `navigationTitle` | 补 `.navigationTitle("KPL 比分看板")` | macOS 窗口标题栏取导航标题，否则标题为空 |
| `EventSidebar`（原生赛季列表：按年份分组 + 进行中置顶，行 `minHeight: 44`→`28`） | **整块移除**（1.3.0 起） | 与前端侧栏重复。赛季切换改由看板顶部的赛季下拉（前端）与窄窗口「赛季」菜单（原生）完成 |
| `onChangeCompat` 判 `#available(iOS 17.0, *)` | 判 `#available(macOS 14.0, *)` | 双参数 `onChange` 的 macOS 版本号 |
| 无底色处理 | `Group.background(Color(#0b0e17))` | 关掉 WebView 底色后由 SwiftUI 兜底，避免首帧闪白（iPad 版是在 WebView 上涂同色 `UIColor`，作用相同） |
| 工具栏刷新按钮带 ⌘R | 去掉该按钮的 `.keyboardShortcut`，保留鼠标点击与 `.disabled(model.isLoading)` | ⌘R 已由菜单栏提供，避免重复注册；按钮行为不变 |
| 窄布局「赛季」菜单 ⌘L | **保留** ⌘L（仍只在窄窗口出现） | 宽窗口下看板顶部的赛季下拉够用，窄窗口把它挤走了，靠这个菜单兜底 |
| 无 | 工具栏最左新增「显示/隐藏导航栏」按钮（`sidebar.left`） | 原生侧栏移除后，前端侧栏的显隐需要一个原生入口；位置沿用原 `NavigationSplitView` 自带按钮的位置，快捷键仍由菜单栏 ⌘⌥S 提供 |

### 4. WebView（`App/BoardWebView.swift`）

| iPad 版 | macOS 版 | 说明 |
|---|---|---|
| `UIViewRepresentable` / `makeUIView` / `updateUIView` | `NSViewRepresentable` / `makeNSView` / `updateNSView` | AppKit 对应协议 |
| `scrollView.minimumZoomScale = 1.0`、`maximumZoomScale = 3.0`（保留捏合、禁用双击缩放） | `allowsMagnification = true`、`magnification = 1.0` | macOS `WKWebView` 没有 `scrollView`；触控板捏合缩放的对等开关是 `allowsMagnification`。macOS 没有「双击缩放」手势，故无需对应处理 |
| `allowsBackForwardNavigationGestures = true` | 删除 | iOS 专有属性；macOS 无边缘滑动手势，应用也无前进/后退栈 |
| `isOpaque = false` + `backgroundColor = UIColor(#0b0e17)` | `setValue(false, forKey: "drawsBackground")`（先 `responds(to:)` 判存） | macOS 无 `isOpaque`/`backgroundColor`；用 WebKit 的 `drawsBackground` 关掉白底，表现与 iPad 版一致；`responds` 守卫保证万一不可用也只是不生效，不会崩 |
| 注入 `ipad-landscape` / `ipad-portrait` | 注入 `mac-wide` / `mac-narrow` | `applyLayoutMode(landscape:)` 的函数名与调用时机不变，仅 CSS 类名随平台改名，由 `mac.css` 承接 |
| — | 新增 `toggleSidebar()` / `applyShellState()`，`sidebarCollapsed` 记在 `UserDefaults` | 前端侧栏的显隐：一次 JS 注入同时下发布局类与 `sidebar-off`，避免两次调用之间出现「半边状态」；并在 `didFinish` 里重放一次（首帧注入时 `document.body` 还不存在，会静默丢失） |

### 5. 前端适配层（`Resources/web/mac.css`，接替 `ipad.css`）

| 规则 | iPad 版 | macOS 版 | 原因 |
|---|---|---|---|
| 安全区 | `padding-left/right: env(safe-area-inset-*)`；`padding-bottom: env(...) + 40px` | 全部置 0，底部只留 `24px` | Mac 没有刘海 / 圆角 / Home 指示条 |
| 首帧底色 | 由原生侧涂色 | `html { background: var(--bg, #0b0e17) }` | 绑主题变量，深浅主题都不闪白（`theme.js` 在 `<head>` 同步写入 `data-theme`，早于渲染） |
| 命中目标 | 统一 `min-height/min-width: 44px` | `32px` | 鼠标是精细指针，无需触控尺寸 |
| hover 反馈 | 包在 `@media (hover:hover) and (pointer:fine)` 内 | 直接生效 | macOS 恒为精细指针 |
| 指针反馈 | 无 | 新增 `cursor: pointer` + `:active { transform: translateY(1px) }` | 鼠标交互需要指针形态与按下反馈 |
| 布局断点 | `body.ipad-landscape` / `body.ipad-portrait` | `body.mac-wide` / `body.mac-narrow`（规则内容一一对应） | 类名随原生侧注入改名 |
| 滚动条 | 无 | 新增 `::-webkit-scrollbar` 描边样式 | macOS 覆盖式滚动条在深色底上几乎不可见 |
| 表格高度 | 横屏 620px / 竖屏 460px | 宽窗口 720px / 窄窗口 520px | Mac 窗口普遍比 iPad 高 |
| 左侧导航栏收起 | 无 | `body.sidebar-off .app { grid-template-columns: minmax(0,1fr) }` + `.sidebar { display: none }` | 只 `display:none` 的话 `.content` 会被自动放进第一列（236px）被挤成一条，必须同时把栅格改回单列 |
| 两栏等高 | 无 | `.grid > section.panel` 改纵向 flex；`.schedule` 由 `max-height: 560px` 改为 `flex: 1 1 auto` + `height: 560px` + `max-height: none`；`.standings-zone > .panel:last-child` 加 `flex: 1 1 auto` | 两列被 grid 拉伸到同一行高，但日历列表写死 560px，列表在卡片中部截断、下面空出约 200pt 卡片底色，与左栏仍在继续的表格形成「中间隔断」。用 `height` 而非 `max-height` 保留固有高度，行高计算逻辑不变（详见第三章 7.2） |
| 其余（图片不拉伸、`:focus-visible` 金色描边、`-webkit-text-size-adjust`） | — | 保留/沿用 | 与 iPad 版一致 |

`index.html` 只改了两处：适配层引用 `ipad.css` → `mac.css`（版本号 `?v=20261008b`），以及对应注释；
1.3.0 起 `mac.css` 内新增「左侧导航栏收起」规则（见上表），这是 macOS 版独有的文件，不影响其余前端文件。
其余 13 个前端文件（`app.js` / `store.js` / `shell.js` / `tools.js` / `theme.js` / `img.js` / 五个 CSS / `tools.html` / `favicon.ico`）**字节级原样复用**，前端 JS 零改动。

### 6. 数据层（`Data/`）

| 改动 | 说明 |
|---|---|
| `Net.swift` 的 UA：iPad Safari UA → Mac Safari UA | 上游据此返回桌面版页面结构；超时、错误处理、四个请求方法（`postForm`/`postFormText`/`postJSON`/`getJSON`）完全不变 |
| `KPLSchemeHandler.swift` 路由表 | 在原有 `/api/board`、`/api/events`、`/api/health`、`/api/refresh` 之外，**新增 `/api/tools/*`（heroes / items / runes / skins / coverage / gradient / players / teams / hero / img）与 `/api/patch`（feed / news / detail / changes / refresh）** |
| 其余 6 个文件（`Models` / `WanplusSource` / `KPLOfficialSource` / `PandaScoreSource` / `Aggregator` / `BoardStore`） | 与 iPad 版逐行一致，零改动；`BoardStore` 的磁盘缓存目录 `~/Library/Application Support/KPLBoard/data` 在沙盒下自动落到容器路径，无需改代码 |

### 7. 布局微调（1.3.0 / 1.3.1，全部落在 `mac.css`）

两次调整都只动 macOS 专属的 `mac.css`，共有前端 13 个文件仍然字节级未改。

**7.1 左侧导航唯一化（1.3.0）**

原生 `NavigationSplitView` 的赛季侧栏与前端 `.sidebar` 是两套并排导航，屏幕最左被重复占了两列。
移除原生侧栏后，`.sidebar` 成为唯一左侧栏；随之删掉 `EventSidebar`，⌘⌥S 改为直接调
`WebViewModel.toggleSidebar()`（不再是 `NSSplitViewController.toggleSidebar`）。
收起状态记在 `UserDefaults`，并在页面 `didFinish` 时重放一次（首帧注入时 `document.body` 尚不存在）。

**7.2 两栏等高（1.3.1）**

现象：右栏「赛程日历」的列表在卡片中部就截断，下面空出约 200pt 卡片底色，
而左栏战绩表仍在继续 —— 形成一条「中间隔断」。

根因分三层：

1. `.grid` 两列被 grid 默认的 `align-items: stretch` 拉伸到同一行高，
   行高取两列内容高度的大者（实测左栏战绩榜撑到 850pt）；
2. 右栏列表写死 `max-height: 560px`，于是面板被拉伸后多出的高度无处安放，
   全部变成列表下方的空白（实测空 216pt）；
3. 反向情形（某赛季分组表行数少、左栏更矮）同理，空白出现在左栏底部。

改法（关键在**用 `height` 而不是删掉 `max-height`**）：

```css
.grid > section.panel { display: flex; flex-direction: column; }   /* 右栏面板转纵向 flex */
.grid > section.panel .schedule {
  flex: 1 1 auto;
  height: 560px;      /* 仅作 flex-basis：决定面板「固有高度」 */
  max-height: none;   /* 取消硬截断，由面板高度兜底 */
  min-height: 0;
}
.standings-zone > .panel:last-child { flex: 1 1 auto; }            /* 反向兜底：左栏最后一张卡片吃掉余量 */
```

`height: 560px` 保留 560pt 作为 flex-basis，因此面板对 `.grid` 行高的**贡献值不变**，
列宽与行高逻辑完全不受影响；多出来的高度由列表自己吃掉。实测：列表 560 → 775pt，
卡片底部零留白，两栏底边都落在 1411pt。反向用例（左栏裁到 490pt）也验证过：
行高仍由右栏固有高度 635pt 决定，左栏末张卡片 230 → 375pt，底边同样对齐 1196pt。

> 该问题桌面 Electron 版同样存在（`style.css` 的 `.schedule { max-height: 560px }`）。
> 本次只改 macOS 层，是为了保住「前端 13 个文件字节级复用」这条约束；
> 若要上游一起修，把上面三条规则搬进 `style.css` 即可。

---

## 四、功能边界（iPad 版全集 + 工具箱）

- 双通道实时合并顺序不变：`applyOfficial` → `applyRealtime` → `decorate`，含双向匹配自动换边、BO 到赛点状态滞后兜底、逐小局反推比分校正。
- 实时源配准按「归一化队名 + 北京日期键」（1.3.2）：年度总决赛这类赛制里同一对战队会在不同阶段多次交手（如 重庆狼队 vs 深圳DYG 既有 10-16 擂台赛也有 10-20 突围赛），只按队名配准会让旧比赛的结果覆盖进行中的新比赛。实时源缺日期字段时退回纯队名兜底，保证不丢数据。
- 缓存策略不变：进行中 20s 轮询、已结束 600s、实时通道 TTL 20s、赛季 JSON 落盘缓存。
- **工具箱与版本公告已接入（1.2.0）**：桌面版 `tools-sources.js` / `patch-sources.js` 已逐行移植为 Swift，前端 14 个文件零改动即可直接使用（详见第五章）。
- **左侧导航唯一化（1.3.0）**：原生赛季侧栏移除，`Resources/web/` 的 `.sidebar`（KPL Agent 导航：比分看板 / 天梯榜 / 选手详情 / 装备 / 铭文 / 英雄详情 / 原画画廊 / 版本动态）成为唯一左侧栏，可由工具栏按钮或 ⌘⌥S 收起 / 展开，状态跨启动记忆。
- **两栏等高（1.3.1）**：赛程日历列表吃满卡片高度，不再在卡片中部截断留白；左栏最后一张分组卡片反向兜底，两栏底边始终对齐（详见第三章 7.2）。

---

## 五、工具箱与版本公告移植（1.2.0）

桌面版 `tools-sources.js`（1504 行）/ `patch-sources.js`（473 行）已完整移植为 Swift，
前端 14 个文件（含 `tools.js`、`tools.css`、`tools.html`、`img.js`）**零改动**即可使用。

### 新增文件

| 文件 | 对应桌面版 | 职责 |
|---|---|---|
| `Data/ToolsDict.swift` | `SKIN_TAG` / `QUALITY_ORDER` / `HERO_TYPE` / `LANE` / `ITEM_TYPE` / `RUNE_COLOR` | 常量字典（皮肤徽章表 200+ 项由脚本从源文件生成，避免手抄出错） |
| `Data/ToolsUtil.swift` | 「小工具」段 | HTML 清洗、`fmtDate` / `cleanQuality`、玩加 time33 签名、**稳定排序** |
| `Data/ToolsStore.swift` | `tools-sources.js` 主体 | 英雄 / 装备 / 铭文 / 皮肤图鉴 / 英雄详情 / 选手 / 战队 / 梯度榜 / 覆盖度 |
| `Data/PatchStore.swift` | `patch-sources.js` | 官网公告列表与详情、「调整条目」结构化解析、版本动态总览 |
| `Data/ToolsCache.swift` | 两文件顶部的缓存段 | 两级缓存：随包种子（只读）+ 用户可写目录 |
| `Data/ImgProxy.swift` | `/api/tools/img` | 图片代理（白名单 + Referer + 内存缓存 + 备用地址链） |

### 缓存策略

- **种子** `Resources/data/tools`：299 个 JSON、12 MB，随安装包分发。
  2023~2026 赛季的梯度榜、选手榜上游（玩加）已无数据，全靠这批种子在**断网时**兜底。
- **可写** `~/Library/Application Support/KPLBoard-MacOS/tools`：App Sandbox 下程序目录不可写，运行时抓取的数据落这里。
- 读取顺序、TTL、`withStaleFallback` / `staleSafe` 语义与桌面版一致。

### 逐字段对齐验证

数据层只依赖 Foundation，可编译成命令行程序跑真实接口；再用 Node 直接调用桌面版同名函数产出基准，做规范化对比（排序 key、整数/小数归一）：

```
12 项接口中 9 项完全一致，3 项仅 updatedAt 时间戳不同（两次抓取时刻差异，属预期）
```

### 移植踩坑（JS → Swift 语义差异）

| 现象 | 根因 | 处理 |
|---|---|---|
| 选手英雄池全空 | 上游 `herojson` 是 **JSON 字符串**不是对象，JS 靠 `safeJSON()` 解析 | `poolOf()` 三分支：对象 / 字符串 / 数组 |
| 选手占比差 100 倍（`0.1%` vs `20.1%`） | `firstMatch` 返回**捕获组**，JS 的 `match()[0]` 是**整段匹配** | 新增 `firstMatchWhole` |
| 皮肤列表整段错位 | JS `skins.sort` 的 `localeCompare` **未传 locale**（中文按码位），误按 zh_CN（拼音）排 | 区分 `cmp`（无 locale）与 `zhCompare`（zh_CN） |
| 列表项随机错位 | V8 的 `Array.sort` **稳定**，Swift 的 `sort` 不稳定 | 统一走 `stableSorted`，用原始下标做 tie-breaker |
| 同权重项顺序乱 | JS `Map` / `Object.keys` 保持**插入序**，Swift 字典无序 | 用伴随的 keys 数组复现插入序 |
| `dmgPerMin` 被取整 | JS 是 `Number()` 保留小数，误用 `Int` | 改用 `dbl` |
| `NSLock` 编译告警 | Swift 6 语言模式下 async 上下文禁用阻塞锁 | 缓存改为 actor |
| 图片代理返回 403 | `HTTPURLResponse.allHeaderFields` 的 value 可能是数组，`as? [String: String]` 整体失败 | 改用 `value(forHTTPHeaderField:)` |

---

## 六、构建、运行与验证

### 已验证状态（Xcode 27.0 / macOS 27.0 SDK，2026-10-08 本机实测）

| 项目 | 结果 |
|---|---|
| Debug（`generic/platform=macOS`） | ✅ BUILD SUCCEEDED |
| Release（`generic/platform=macOS`） | ✅ BUILD SUCCEEDED |
| 产物架构 | ✅ `x86_64 arm64`（通用二进制） |
| 产物完整性 | ✅ `web/`（14 个前端文件）、`events.json`、`data/tools`（**299 个种子 JSON，12 MB**）、`Assets.car`、`AppIcon.icns` 均已打进 `.app` |
| 版本号 | ✅ `CFBundleShortVersionString = 1.2.0`、`CFBundleVersion = 1`、`LSMinimumSystemVersion = 13.0` |
| 沙盒 entitlements | ✅ 已嵌入 `app-sandbox` + `network.client` |
| 启动冒烟 | ✅ 可正常启动并保持运行（无崩溃） |
| dmg 产物 | ✅ `build/KPLBoard-MacOS-1.4.0.dmg`（5.0 MB，UDZO；内含 .app + Applications 替身），挂载校验通过，1201 赛季 83 英雄 / 73 选手数据已补齐 |
| 签名身份 | ⚠️ 当前机器 `security find-identity` 无有效身份，构建使用 `Sign to Run Locally`（ad-hoc，会临时关闭 Hardened Runtime）。登录 Apple ID 后选 Team 即可正常签名分发 |

> **Gatekeeper 提示**：本 dmg 内的 .app 是 ad-hoc 签名。首次打开若提示「无法验证开发者」，
> 右键点击 .app →「打开」即可运行；对外分发建议在 Xcode 里选 Developer ID 团队重新签名并公证。

### 步骤

1. 双击 `KPLBoard-MacOS.xcodeproj` 打开（或 `open KPLBoard-MacOS.xcodeproj`）。
2. 登录 Apple ID：`Xcode → Settings… → Accounts → 左下 + → Apple ID`。
   **不登录也能本地跑**：Xcode 会以 `Sign to Run Locally`（ad-hoc）运行。
3. 选中 `KPLBoard-MacOS` target → **Signing & Capabilities**：
   - `Automatically manage signing`（已默认开启）
   - Team 选你的 Apple ID / 付费账号
   - 如需改 Bundle ID，改 `com.local.kplboard.macos`
4. `⌘R` 运行。导出 dmg：`./build-dmg.sh [-t TEAM_ID] [-n]`；也可 `Product → Archive`。

### 真机验证清单

| 项 | 预期 |
|---|---|
| 启动 | 金色 K 图标，无白屏闪烁，直接进入看板 |
| 默认窗口 | 1440×900，单列布局：左侧是前端导航（KPL Agent），右侧是看板，内容区左右两栏 |
| 拖窄窗口 | 宽度 <1024pt 前端切 `mac-narrow`（内容区单列、导航栏变顶部横条），工具栏出现「赛季」菜单（⌘L 可开） |
| 菜单栏 | 「看板 → 刷新数据」⌘R 生效；「显示/隐藏侧边栏」⌘⌥S 收起 / 展开左侧导航；「关于 KPL 比分看板」弹出系统面板 |
| 鼠标 | 按钮/导航有 pointer 光标、hover 抬升、按下位移；滚动条可见 |
| 键盘 | Tab 聚焦有金色描边；⌘R / ⌘L / ⌘⌥S 生效 |
| 左侧导航 | 工具栏最左按钮（或 ⌘⌥S）收起 / 展开；收起后正文吃满窗口宽度；重启后保持上次状态 |
| 两栏底边 | 战队战绩榜与赛程日历两张卡片的下边框在同一水平线上；日历列表一直排到卡片底部，卡片内无成片留白 |
| 实时性 | 进行中比赛比分随官方源刷新（约 20s 一轮） |
| 离线 | 断网后显示已缓存数据（`~/Library/Application Support/KPLBoard/data/`） |
| 工具箱入口 | 英雄库 / 装备库 / 铭文库 / 皮肤图鉴 / 梯度榜 / 选手榜 / 战队榜 / 版本动态均可正常加载 |

---

## 七、常见问题

**Q：为什么还要 `kplboard://` 自定义 scheme？**
macOS 上虽可起本地 HTTP 服务，但用自定义 scheme 能零配置获得「页面与接口同源」，
`WKURLSchemeHandler` 直接把 Swift 组装好的 JSON 回给前端，前端 JS 无需任何改动，也免了端口占用与防火墙弹窗。

**Q：数据层能脱离 Xcode 验证吗？**
能。`Data/` 下文件只依赖 Foundation，可直接命令行编译成 macOS 程序跑真实接口；
工具箱 / 公告还支持 `KPL_SEED_DIR`、`KPL_WRITE_DIR`、`KPL_EVENTS_FILE` 三个环境变量指向种子、缓存与赛季清单。

**Q：想改缓存目录/轮询间隔？**
`Data/BoardStore.swift` 顶部：`pollMs`（进行中 20s）、`historyMs`（已结束 600s）、`rtTTL`（实时通道 20s）。

**Q：与已安装的 Electron 桌面版（`/Applications/KPLBoard.app`）冲突吗？**
不冲突：Bundle ID 不同（`com.local.kplboard.macos`），缓存目录也独立。本版是原生重写外壳，
本版在 iPad 版基础上**额外接入了工具箱与版本公告**，功能范围已与 Electron 桌面版对齐。

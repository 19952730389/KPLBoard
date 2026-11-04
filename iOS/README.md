# KPLBoard for iOS / iPadOS

在 KPLBoard for macOS 与 HarmonyOS 端基础上产出的 **iOS / iPadOS 原生版**（Swift + SwiftUI + WebKit），
一套代码同时适配 **iPhone 12 Pro Max** 与 **iPad Pro 11 英寸（M2 芯片）**。

数据模型、业务逻辑与前端页面与 macOS 版**逐字节复用**，不新增也不删减功能；
只做 iOS / iPadOS 必要适配：设备形态与导航范式、屏幕尺寸与分辨率、安全区、触控交互、
外链处理、iOS 专有 API 的对等实现。

> **与 macOS 版的关系**：同一个前端（`Resources/web/`，13 个文件字节级原样复用）+ 同一套 Swift 数据层（`Data/`，13 个文件字节级原样复用）。
> 前端通过 `WKWebView` + 自定义 scheme（`kplboard://app/`）与 Swift 拼成「同源站点」，
> 数据来自玩加赛事 / KPL 官方 / PandaScore 三条通道，与桌面 Electron 版、macOS 版逻辑一致。

---

## 一、应用用途与核心功能

**用途**：王者荣耀职业联赛（KPL）的一站式数据台——看实时比分、查赛程、查战队战绩，
并配套官方英雄/装备/铭文图鉴、职业赛场梯度榜与选手榜、官网版本公告。

### 1. 比分看板（核心）
- 实时比分与状态：进行中（LIVE）/ 即将开赛 / 已结束，官方通道约 20 秒一轮刷新。
- 赛季切换：覆盖 2016 年首届 KPL 至今 **78 项赛事**，支持阶段筛选。
- 战队战绩榜：按积分 → 净胜小局排序，大师组 / 精英组分组，含胜率、近况。
- 赛程日历：周视图（周一起始）、上一周 / 下一周 / 本周、今天与 LIVE 行高亮。
- 概览指标：六项 KPI（比赛数、进行中、战队数、小局数等）。

### 2. 工具箱（7 个模块）
| 模块 | 内容 |
|---|---|
| 梯度榜 | 职业赛场英雄 T0–T3 分桶（贝叶斯平滑） |
| 选手详情 | KDA / 经济 / 场均伤害 / 英雄池 |
| 英雄详情 | 技能、属性评分、背景故事、历史上的 TA |
| 装备 | 官方装备图鉴，可看详情 |
| 铭文 | 红蓝绿铭文图鉴，可看详情 |
| 原画画廊 | 皮肤原画与品质 |
| 版本动态 | 官网更新公告 + 英雄/装备/铭文「调整条目」结构化解析 |

### 3. 端内直连与离线
- 三个上游通道端内直连，不需要自建服务。
- 缓存：进行中 20s 轮询、已结束 600s、赛季 JSON 落盘；
  安装包内附 **299 个种子 JSON（约 12 MB）**，断网也能完整查看历史赛季与资料库。

---

## 二、界面布局与交互

一套代码两种形态，按**设备类型**（`UIDevice.current.userInterfaceIdiom`）分流：

```
iPhone（含 12 Pro Max）              iPad Pro 11″（M2）
┌──────────────────────┐   ┌────────┬─────────────────────────┐
│ 原生导航栏（标题+赛季+刷新）│   │ 原生侧栏 │ 原生导航栏（标题+刷新+关于）│
│                      │   │ 比分看板 │                         │
│  网页内容区（单列）    │   │ 梯度榜   │     网页内容区            │
│                      │   │ 选手详情 │   竖屏单列 / 横屏双栏     │
│                      │   │ … 8 项   │                         │
│                      │   │ 关于与…  │                         │
├──────────────────────┤   └────────┴─────────────────────────┘
│ 底栏：看板英雄装备版本更多│
└──────────────────────┘
```

| 项 | iPhone | iPad |
|---|---|---|
| 导航容器 | `NavigationStack`（**无原生导航栏**）+ 悬浮玻璃底栏 | `NavigationSplitView`（**无原生导航栏**） |
| 顶部 | 无原生栏：页面自身的品牌区 + 状态/时钟块（已左移）承担头部 | 同左 |
| 底栏 / 侧栏项 | 底栏 4 个模块 + 「更多」，**显示哪些可在设置里勾选** | 侧栏 8 个模块全展开；**刷新 / 设置 / 关于在侧栏底部** |
| 设置 / 刷新入口 | 右下角悬浮玻璃胶囊（底栏上方） | 侧栏底部；侧栏收起时右下角浮现入口（含侧栏开关） |
| 外观 | 跟随系统 / 浅色 / 深色（设置里切换，原生与网页同步换肤） | 同左 |
| 悬浮玻璃 | 更透 / 均衡 / 更实 三档（设置里切换） | 同左 |
| 刷新快捷键 | — | 外接键盘 **⌘R**（侧栏刷新行） |
| 外链 | `SFSafariViewController` 应用内打开 | 同左 |
| 旋转 | 竖屏单列 / 横屏单列（内容变宽） | 竖屏单列 / 横屏双栏 |
| 多窗口 | — | 支持（Stage Manager / Split View） |

**为什么按设备类型而不是宽度尺寸类别分流**：分流会重建视图树，而树里挂着唯一的 `WKWebView`；
一旦因旋转或分屏触发切换，页面就会重新加载、滚动位置与赛季状态全丢。
iPad 竖屏 834pt 与横屏 1194pt 都是 regular 宽度，`NavigationSplitView` 自己会在
Split View / Slide Over 下折叠，无需外部切换。

**导航唯一化**：原生已提供侧栏 / 底栏，前端自己的 `.sidebar` 一律隐藏
（`ios.css` 的 `body.native-nav` 规则），页面内重复的刷新按钮也隐藏，避免两套入口。

### 2.1 界面设置（2026-10-10 增补）

新增 `App/AppSettings.swift` + `App/SettingsView.swift`，三项配置跨启动记忆（`UserDefaults`）：

| 配置 | 选项 | 默认 | 生效方式 |
|---|---|---|---|
| **外观** | 跟随系统 / 浅色 / 深色 | 跟随系统 | 原生走 `.preferredColorScheme`（导航栏、底栏、设置页一起换肤），网页走 `window.KPLTheme.set(auto/light/dark)`；两路同时改，页面加载完成时还会重放一次（原生是唯一事实来源） |
| **悬浮玻璃** | 更透 / 均衡 / 更实 | 均衡 | 系统材质 `ultraThin/thin/regularMaterial` + `Color.primary` 着色层（0.08 / 0.18 / 0.32），同时作用于顶部导航栏与底部悬浮栏 |
| **底部导航** | 8 个模块任意勾选，**最多 4 个**（第 5 个固定是「更多」） | 比分看板 / 梯度榜 / 选手详情 / 版本动态 | 未勾选的模块（默认为英雄、装备、铭文、原画画廊）收进「更多」浮层，仍可正常访问；改动即时生效，无需重启 |

### 2.2 沉浸式毛玻璃（对齐系统「设置」的观感）

- 网页内容 `.ignoresSafeArea(edges: [.top, .bottom])`：向上滚进导航栏、向下滚进悬浮底栏，
  左右交给系统避让（iPhone 刘海 / iPad 常驻侧栏）——正文不会钻到侧栏下面。
- 顶部毛玻璃由 `TopGlassFade` **自绘**：系统材质提供模糊、页面主题色（`--bg` 两档）提供着色、
  mask 让它向下渐隐到 0——没有系统材质那条硬边与「灰带」，
  高度取「状态栏 + 导航栏」实测值（`geo.frame(in: .global).minY`），底沿与系统栏严格对齐。
- 被盖住的区域由网页侧 `--sat / --sab` 留白兜底（`ios.css` 第 0 节），
  保证滚动到顶 / 到底时正文不会被永久遮挡。
- 底栏为**悬浮胶囊**（圆角 24 + 高光描边 + 投影），选中项带浅色药丸，切换有轻触觉反馈。

> **实测坑 1**：`NavigationSplitView` 详情列的 `safeAreaInsets.top` 只含状态栏（24pt）、
> 不含导航栏，而 `NavigationStack` 两者都含——已用内容区在窗口坐标里的真实 `minY` 修正。
>
> **实测坑 2**：单向推送注入会被「页面重置」吞掉——iPad 上 WebKit 会重建内容进程，
> 推送进去的布局类与安全区变量随之丢失。已改为**拉取式**：页面通过 `WKUserScript`
> （atDocumentEnd）+ `kplshell` messageHandler 在每次加载完成后主动向原生要一次状态，
> 原生把状态注入给「发消息的那个」WebView，无论加载几次、何时加载都不会丢。
>
> **实测坑 3**：在 `GeometryReader` 的异步闭包（如延迟补发）里读取 `GeometryProxy`
> 会拿到失效值（全 0），反而覆盖正确值——已移除延迟补发，只保留 onAppear/onChange。

### 2.3 本地缓存提示条改造（悬浮小胶囊）

旧版是吸顶通栏（`position: sticky; top: 0`），占满一行、盖住页面标题区，移动端还会推移正文。
现改为**右下角悬浮小胶囊**，涉及 `shell.css` / `shell.js` / `index.html` / `ios.css` 四处：

| 调整 | 参数 | 效果 |
|---|---|---|
| 脱离文档流 | `position: fixed; right: 16px; bottom: 16px; z-index: 80` | 不再占位、不再推移正文，遮挡面积缩小到一行以内 |
| 尺寸收紧 | 字号 12px、内边距 8×10px、`max-width: min(92vw, 480px)`、`border-radius: 12px` | 从「通栏横幅」变成「一行小胶囊」 |
| 层次感 | `var(--panel-solid)` 底 + `backdrop-filter: blur(14px)` + `box-shadow: 0 10px 30px` | 悬浮于内容之上但可透出底层 |
| 严重度着色 | 离线=红渐变、数据异常=金渐变（保留原语义） | 一眼分辨严重程度 |
| **手动关闭** | 新增 `#cacheClose`（×）按钮 → `is-min` 收起态 | 用户主动收起 |
| **自动收起** | 8s 无操作 → `is-min`（状态等级变化时自动重新展开并重新计时） | 不遮挡、不阻断交互，信息仍可达 |
| 收起态 | 整条缩成 34×34 小圆钮（只留状态图标），点击展开 | 常驻但不打扰 |
| 移动端适配 | `ios.css`：`right: 12px; bottom: calc(var(--sab) + 10px)`（悬浮在玻璃底栏之上）；`max-width: calc(100vw - 24px)`；`flex-wrap: wrap` 防长文案溢出 | 手机上不遮底栏与页签 |
| 桌面端 | 右下角 16px 边距，与 macOS/Electron 共用同一套 `shell.css` | 三端一致 |

---

## 三、需要参考的具体代码 / 模块

### 3.1 来自 macOS 版（逐字节复用，零改动）

| 文件 | 说明 |
|---|---|
| `Data/Models.swift` | `KBEvent` / `KBMatch` / `TeamSide` / `RealtimeEntry` + 北京时间工具 |
| `Data/Net.swift` | HTTP 封装（form / json / text / raw / GBK） |
| `Data/WanplusSource.swift` | 玩加主源：live（按周）+ archive（HTML 正则解析） |
| `Data/KPLOfficialSource.swift` | KPL 官方 `kplshop-op/kplow/getScheduleList` |
| `Data/PandaScoreSource.swift` | esportsresults.com（补逐小局 + 兜底） |
| `Data/Aggregator.swift` | 双通道合并 / 状态推断 / 积分榜 / 概览 |
| `Data/BoardStore.swift` | actor 仓储：缓存、刷新、看板组装 |
| `Data/ImgProxy.swift` | 图片代理（白名单 + Referer + 缓存） |
| `Data/ToolsCache.swift` `ToolsUtil.swift` `ToolsDict.swift` `ToolsStore.swift` `PatchStore.swift` | 工具箱与版本公告 |
| `App/KPLSchemeHandler.swift` | 自定义 scheme 路由（仅把注释里的「macOS 的 WebKit」改为通用表述） |
| `Resources/events.json` | 78 个赛季清单 |
| `Resources/data/tools/` | 299 个种子 JSON（12 MB） |
| `Resources/web/` 除 `index.html` 外的 13 个文件 | `app.js` `store.js` `shell.js` `tools.js` `theme.js` `img.js` `style.css` `tools.css` `shell.css` `theme.css` `tools.html` `favicon.ico` |

> **一处刻意的取舍**：`Data/ToolsCache.swift` 的可写目录名仍是 `KPLBoard-MacOS/tools`。
> iOS 应用沙盒是容器隔离的，与其他平台不会冲突，改名字会破坏「13 个文件字节级复用」这条约束，故保留。

### 3.2 来自 macOS 版（按 iOS 语义改写）

| macOS 版 | iOS 版 | 关键差异 |
|---|---|---|
| `App/BoardWebView.swift`（`NSViewRepresentable`） | 同名，`UIViewRepresentable` | `makeUIView/updateUIView`；`scrollView.minimumZoomScale = 1.0 / maximumZoomScale = 3.0` 保留捏合；`isOpaque = false` + `backgroundColor` 关白底；新增 `allowsLinkPreview`、`allowsBackForwardNavigationGestures` |
| `App/RootView.swift`（窗口 + 工具栏） | 同名，双形态外壳 | iPhone 底栏 vs iPad `NavigationSplitView`；`.safeAreaInset` 并入安全区 |
| `App/KPLBoardApp.swift`（菜单栏命令） | 同名 + `AppDelegate` | iOS 无菜单栏，改用 `@UIApplicationDelegateAdaptor` 管 `UIApplication` 级设置 |
| `Resources/web/mac.css` | `Resources/web/ios.css` | 见第四章 |
| — | `App/DeviceProfile.swift` **新增** | 机型识别 + 官方规格表 + 运行时屏幕与安全区读取 |
| — | `App/ModuleCatalog.swift` **新增** | 8 个模块的 id / 名称 / SF Symbol（id 与前端 `shell.js` 的 `NAV` 一致） |
| — | `App/AboutView.swift` **新增** | 关于 + **设备适配自检面板**（实时显示点数/像素/缩放/安全区） |

### 3.3 来自 HarmonyOS 端（设计参照）

| HarmonyOS 端 | iOS 版对应实现 |
|---|---|
| `common/DeviceEnv.ets` 三段式断点 sm/md/lg | `DeviceProfile.swift` 的 700pt 阈值 + `kpl-compact/kpl-regular` 双档 |
| `pages/Index.ets` 窄屏底部胶囊 / 宽屏左侧导航条 | iPhone `PhoneTabBar` / iPad `NavigationSplitView` 侧栏 |
| `pages/Index.ets` 七模块页签 | `ModuleCatalog` 八个模块，iPhone 收 4 + 「更多」 |
| `common/TopBar.ets` 标题 + 状态 + 刷新 + 外观 | 原生导航栏（标题 + 赛季 + 刷新）+ 页内状态行 |
| `data/LiveBoard.ets` 端内直连上游 | Swift 数据层同构实现（`WanplusSource` / `KPLOfficialSource` / `PandaScoreSource`） |
| `common/Ui.ets` 44vp 触控热区 | `ios.css` 的 44pt 最小命中目标 + SwiftUI `frame(minHeight: 44)` |

---

## 四、两台设备的适配（尺寸 / 分辨率 / 安全区）

### 4.1 官方规格对照表

| | iPhone 12 Pro Max | iPad Pro 11″（M2，第 4 代） |
|---|---|---|
| 机型标识 | `iPhone13,4` | `iPad14,3` / `iPad14,4` |
| 逻辑分辨率（竖屏） | **428 × 926 pt** | **834 × 1194 pt** |
| 物理分辨率 | **1284 × 2778 px** | **1668 × 2388 px** |
| 缩放倍数 | **@3x**（458 ppi） | **@2x**（264 ppi） |
| 安全区 上 | **47 pt**（刘海 / 状态栏） | **24 pt**（状态栏显示时） |
| 安全区 下 | **34 pt**（Home 指示条） | **20 pt**（Home 指示条） |
| 安全区 左 / 右（竖屏） | 0 / 0 | 0 / 0 |
| 缩放位图 | 自动取 @3x | 自动取 @2x |

iPad 的安全区数值来自 Apple 官方技术讲座《Designing for iPad Pro and Apple Pencil》：
「bottom inset is 20 points in portrait orientation and in landscape」、
「when a status bar is displayed, the top inset value is 24 points」。

### 4.2 适配策略

1. **绝不硬编码**：所有参与布局的数值都在运行时读取——
   `GeometryProxy.safeAreaInsets`（SwiftUI）、`UIWindowScene.screen`（按场景取屏幕，
   iOS 15 起 `UIScreen.main` 已不推荐用于多场景）、`UIDevice.current.userInterfaceIdiom`。
   硬编码会在 iPad 分屏、Slide Over、Stage Manager、iPhone 横屏下全部失效。
2. **安全区交给系统**：不调用 `ignoresSafeArea`，网页内容由 SwiftUI 的 safe area 布局
   自动避开状态栏、Home 指示条、导航栏与自定义底栏。
   底栏用官方 API `.safeAreaInset(edge: .bottom)` 并入安全区，内容自动在其上方结束。
3. **原生另把实测值注入 CSS 变量** `--sat/--sab/--sal/--sar`：
   `WKWebView` 虽支持 `env(safe-area-inset-*)`，但它反映的是 WebView 自身的 viewport insets，
   在 SwiftUI 容器里并不总等于系统安全区；注入的数值用于排查与前端后续扩展。
4. **分辨率**：位图资源按 Xcode 资源目录的 @2x / @3x 自动取用；AppIcon 提供
   iPhone 120/180、iPad 76/152/**167**、App Store 1024 共 18 档。

### 4.3 `ios.css` 分层规则

| 规则 | 作用 |
|---|---|
| `body { padding: --sat --sar --sab --sal }` | 沉浸式毛玻璃的四边让位（导航栏 / 底栏 / 侧栏 / 刘海） |
| `.cache-bar { top: var(--sat) }` | 离线状态条吸顶停在导航栏下沿 |
| `body.native-nav .app { grid-template-columns: minmax(0,1fr) }` + `.sidebar { display:none }` | 隐藏前端侧栏并把栅格改回单列（只 `display:none` 会让正文被挤进 236px 第一列） |
| `body.native-nav #refreshBtn { display:none }` | 隐藏页面内重复刷新按钮 |
| 44pt `min-height/min-width` + `touch-action: manipulation` | Apple 触控目标下限，去掉 300ms 点击延迟 |
| `:active` 位移反馈（替代 `:hover`） | 触摸设备没有悬停态 |
| `-webkit-text-size-adjust: 100%` | 禁止横屏自动放大文字 |
| `body.kpl-phone .grid { 1fr } / .live-cards { 1fr } / .stats-row { 2 列 }` | iPhone 单列、两列 KPI |
| `body.kpl-phone .topbar .brand { display:none }` | 标题让位给原生导航栏 |
| `body.kpl-phone.kpl-regular .content { padding-left/right: max(12px, var(--sal/--sar)) }` | iPhone 横屏（926 × 428pt）左右内缩避开刘海 |
| `body.kpl-pad.kpl-regular .grid { 1.05fr / 1fr }` | iPad 横屏双栏（内容宽 ≈ 954pt） |
| `body.kpl-pad.kpl-compact .grid { 1fr }` | iPad 竖屏（内容宽 ≈ 594pt）或 Split View 窄列回退单列 |
| `.grid > section.panel` 纵向 flex + `.schedule { flex:1 1 auto; height:560px }` | 沿用 macOS 1.3.1 的「两栏等高」修正 |
| `prefers-reduced-motion` / `:focus-visible` | 减弱动效、键盘可达性 |

### 4.4 布局档位实测

| 设备 / 姿态 | 窗口宽 | WebView 实际宽 | 注入的类 | 栅格 |
|---|---|---|---|---|
| iPhone 12 Pro Max 竖屏 | 428 | 428 | `kpl-phone kpl-compact` | 单列 |
| iPhone 12 Pro Max 横屏 | 926 | 926 | `kpl-phone kpl-regular` | 单列 + 左右避让刘海 |
| iPad Pro 11″ 竖屏 | 834 | ≈594（侧栏 240） | `kpl-pad kpl-compact` | 单列 |
| iPad Pro 11″ 横屏 | 1194 | ≈954 | `kpl-pad kpl-regular` | 双栏 |
| iPad Split View 窄列 | <540 | <300 | `kpl-pad kpl-compact` | 单列（侧栏自动折叠） |

---

## 五、工程配置

| 项目 | 值 |
|---|---|
| Product / Target | `KPLBoard-iOS` |
| Bundle Identifier | `com.local.kplboard.ios` |
| Version / Build | `1.3.1` / `1` |
| 最低系统版本 | **iOS / iPadOS 16.0**（`NavigationSplitView` 的门槛） |
| SDK | `SDKROOT = iphoneos`，`SUPPORTED_PLATFORMS = iphoneos iphonesimulator` |
| 架构 | arm64（标准架构，未写死 `ARCHS`） |
| 设备族 | `TARGETED_DEVICE_FAMILY = 1,2`（iPhone + iPad） |
| Swift 版本 | 5.0（`SWIFT_STRICT_CONCURRENCY = minimal`） |
| 依赖框架 | `WebKit.framework`、`SafariServices.framework`（系统内置，无第三方依赖） |
| 签名 | `CODE_SIGN_STYLE = Automatic` |
| 方向 | iPhone 竖屏 + 左右横屏；iPad 四向全支持 |
| iPadOS 多窗口 | `UIApplicationSupportsMultipleScenes = true` |
| 启动屏 | `UILaunchScreen`（`UIColorName = LaunchBackground`，#0b0e17，无需 storyboard） |
| 网络 | 全部 HTTPS，`NSAllowsArbitraryLoads = false`；仅 WebView 内网页放开 `NSAllowsArbitraryLoadsInWebContent` |
| 图标 | AppIcon 18 档（iPhone 20/29/40/60pt 各 @2x@3x + iPad 20/29/40/76/83.5 + 1024） |

---

## 六、目录结构

```
iOS/
├── KPLBoard-iOS.xcodeproj/
│   ├── project.pbxproj
│   └── xcshareddata/xcschemes/KPLBoard-iOS.xcscheme
└── KPLBoard-iOS/
    ├── App/                                   # 原生外壳（SwiftUI + WebKit）
    │   ├── KPLBoardApp.swift                  # @main 入口 + AppDelegate 桥接
    │   ├── RootView.swift                     # 双形态外壳（iPhone 玻璃底栏 / iPad 侧栏）
    │   ├── BoardWebView.swift                 # WKWebView 封装（UIViewRepresentable）+ 与前端互调 + SFSafariViewController
    │   ├── KPLSchemeHandler.swift             # 自定义 scheme：静态资源 + /api/* 路由
    │   ├── DeviceProfile.swift                # 机型识别 + 官方规格表 + 运行时屏幕/安全区
    │   ├── ModuleCatalog.swift                # 8 个模块（id 与前端 shell.js 对齐）
    │   ├── AppSettings.swift                  # 外观 / 悬浮玻璃 / 底部导航 三项配置（跨启动记忆）
    │   ├── SettingsView.swift                 # 设置页
    │   └── AboutView.swift                    # 关于 + 设备适配自检面板
    ├── Data/                                  # 数据层（13 个文件，与 macOS 版逐字节一致）
    ├── Resources/
    │   ├── events.json                        # 78 个赛季清单
    │   ├── data/tools/                        # 299 个种子 JSON（12 MB）
    │   └── web/                               # 前端（14 个文件）
    │       ├── index.html  app.js  store.js  shell.js  tools.js  theme.js  img.js
    │       ├── style.css  tools.css  shell.css  theme.css  favicon.ico  tools.html
    │       └── ios.css                        # iOS / iPadOS 适配层
    ├── Assets.xcassets/
    │   ├── AppIcon.appiconset/                # 18 档图标
    │   └── LaunchBackground.colorset/         # #0b0e17
    └── Info.plist
```

---

## 七、构建、运行与验证

### 已验证状态（Xcode 27.0 / iOS 27.0 SDK，2026-10-09 本机实测）

| 项目 | 结果 |
|---|---|
| Debug（`iphonesimulator`，arm64） | ✅ BUILD SUCCEEDED（0 error / 0 warning） |
| Release（`iphonesimulator`，arm64） | ✅ BUILD SUCCEEDED |
| Release（`iphoneos`，`generic/platform=iOS`） | ✅ BUILD SUCCEEDED |
| 产物架构 | ✅ `arm64` |
| 产物完整性 | ✅ `web/`（14 个前端文件含 `ios.css`）、`events.json`、`data/tools`（299 个种子 JSON）、`Assets.car`、AppIcon 均已打进 `.app` |
| Info.plist | ✅ `LSRequiresIPhoneOS = true`、`UIDeviceFamily = [1,2]`、`MinimumOSVersion = 16.0`、iPhone 三向 / iPad 四向、`UIApplicationSupportsMultipleScenes = true`、`UILaunchScreen` |
| iPad Pro 11″ 模拟器启动 | ✅ 正常启动，侧栏 + 双栏/单栏切换、数据加载（36 场、LIVE 行、战绩榜）均正常 |
| iPhone 模拟器启动 | ✅ 正常启动，底部 5 页签、原生标题栏、页面数据加载均正常 |
| 深浅色 | ✅ 跟随系统（`theme.js` 在 `<head>` 同步写入 `data-theme`，不闪屏） |

> 签名：本机 `security find-identity` 无有效身份时用 `Sign to Run Locally`（ad-hoc）即可在模拟器/已信任设备上运行；
> 真机分发需在 Xcode → Signing & Capabilities 选 Team。

### 步骤

1. 双击 `KPLBoard-iOS.xcodeproj` 打开（或 `open KPLBoard-iOS.xcodeproj`）。
2. 登录 Apple ID：`Xcode → Settings… → Accounts → 左下 + → Apple ID`。不登录也能在模拟器上跑。
3. 选中 `KPLBoard-iOS` target → **Signing & Capabilities**：Team 选你的账号（Bundle ID 可改为自己的）。
4. `⌘R` 运行。命令行构建：
   ```
   # 模拟器
   xcodebuild -project KPLBoard-iOS.xcodeproj -scheme KPLBoard-iOS \
     -configuration Debug -sdk iphonesimulator27.0 -arch arm64 \
     -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
   # 真机
   xcodebuild -project KPLBoard-iOS.xcodeproj -scheme KPLBoard-iOS \
     -configuration Release -sdk iphoneos27.0 -destination 'generic/platform=iOS' \
     -derivedDataPath build-device build
   ```
5. 归档导出：`Product → Archive`。

### 真机验证清单

| 项 | iPhone 12 Pro Max | iPad Pro 11″（M2） |
|---|---|---|
| 启动 | 金色 K 图标，无白屏闪烁，直接进入看板 | 同左，左侧为原生侧栏 |
| 安全区 | 内容不被刘海 / Home 指示条遮挡；悬浮玻璃底栏浮在指示条之上 | 内容不被圆角 / Home 指示条 / 侧栏遮挡 |
| 沉浸毛玻璃 | 列表滚动时正文从导航栏与底栏之下穿过并透出模糊 | 同左（含侧栏） |
| 导航 | 底部 5 页签；「更多」浮层可切未勾选模块 | 左侧 8 项；竖屏单列、横屏双栏 |
| 设置 | 右上角齿轮：外观三档 / 玻璃三档 / 底部导航勾选 | 侧栏「设置」或右上角齿轮 |
| 旋转 | 竖屏 ↔ 横屏，页面**不重载**（同一 WKWebView） | 同左 |
| 外观切换 | 设置里选深色 → 原生界面与网页同时变深，重启后保持 | 同左 |
| 刷新 | 导航栏右上角 ↻ | 导航栏 ↻，外接键盘 **⌘R** |
| 外链 | 点击官网原文 → 应用内 Safari 打开，返回即回到看板 | 同左 |
| 缩放 | 双指捏合 1x–3x | 同左 |
| 关于页 | 「机型 / 逻辑分辨率 / 物理分辨率 / 缩放倍数 / 安全区」应为
  iPhone 12 Pro Max · 428×926 pt · 1284×2778 px · @3x · 上 47 下 34 | iPad Pro 11 英寸（M2）· 834×1194 pt · 1668×2388 px · @2x · 上 24 下 20 |
| 离线 | 断网后显示已缓存数据 | 同左 |

---

## 八、常见问题

**Q：为什么还用 `kplboard://` 自定义 scheme？**
iOS 上虽可起本地 HTTP 服务，但自定义 scheme 能零配置获得「页面与接口同源」，
`WKURLSchemeHandler` 直接把 Swift 组装好的 JSON 回给前端，前端 JS 无需任何改动，
也免了端口占用、后台运行与本地网络权限弹窗。

**Q：为什么 iOS 上不能像 macOS 那样用 `List(selection:)` 做侧栏？**
`List` 的单选初始化器（`init(selection:content:)`、`init(_:selection:rowContent:)`）
全部标注 `@available(iOS, unavailable)`，iOS 侧只保留多选 `Set` 版本——
这是 SwiftUI 的平台差异，不是写法问题。iOS 版因此改为「List + Button 行 + 手动选中态」，
行为与 macOS 版完全一致。

**Q：为什么「更多」用浮层而不是 push 一个新页面？**
push 会把唯一的 `WKWebView` 移出视图层级，`UIViewRepresentable` 的视图被销毁后返回会重建并重新加载页面。
浮层保持页面常驻，切换模块只是调一次 `KPLShell.setView(id)`。

**Q：iPhone 横屏（926pt，regular 宽度）为什么不用侧栏？**
横屏只有 428pt 高，侧栏会挤掉正文；且按设备类型分流可以避免旋转时重建 WebView。
Apple 对 iPhone 的推荐范式本来就是页签栏。

**Q：想改缓存目录 / 轮询间隔？**
`Data/BoardStore.swift` 顶部：`pollMs`（进行中 20s）、`historyMs`（已结束 600s）、`rtTTL`（实时通道 20s）。

**Q：与已安装的 macOS 版 / Electron 桌面版冲突吗？**
不冲突：Bundle ID 不同（`com.local.kplboard.ios` / `.macos`），各自缓存目录独立。

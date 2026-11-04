# 鸿蒙（HarmonyOS）原生版打包说明

目标设备：**华为 Mate 60 Pro+**（6.82 英寸 / 2720×1260 / ≈440 ppi / 顶部挖孔 + 底部手势条）
同时自适应：**任意尺寸鸿蒙设备**（手机 / 平板 / 折叠屏 / 分屏 / 横竖屏）
构建环境：**DevEco Studio 26.0.0.851（Windows）**，已实测 `BUILD SUCCESSFUL`
实现形态：**纯 ArkTS 原生 UI**（无 WebView、无内嵌网页、无本地 HTTP 服务）

---

## 0. 与上一版（WebView 壳）的区别

| 维度 | 旧版（已废弃） | 现在（原生） |
| --- | --- | --- |
| 渲染 | ArkWeb 加载 `rawfile/www/index.html` | ArkUI 组件（`Column/Row/Grid/Scroll/Image`）直接绘制 |
| 数据 | 前端 `fetch` → `onInterceptRequest` 拦截供字节 | `BundleStore` 用 `resourceManager.getRawFileContentSync` 直读 rawfile JSON |
| 图片 | 前端 `devicePixelRatio` 取档 + 拦截 | `ImageRepo` 按 `densityPixels` 取档 + 懒拷贝到 `cacheDir` + `fileUri` |
| 适配 | CSS 媒体查询 + `rem` | 鸿蒙官方 sm/md/lg 断点 + `AppStorage` + `windowSizeChange` |
| 包内残留 | `rawfile/www/` 48 MB 网页 | 已删除，只留 `rawfile/bundle/`（数据 15 MB + 图片 33 MB） |
| 安装包 | `entry-default-signed.hap` 51.3 MB | `dist/KPLBoard-HarmonyOS-1.0.0-native.hap` 50 MB |

> 旧版的 `common/LocalResourceServer.ets` 已删除；`mobile/mobile-bridge.js`、
> `mobile-ui.js`、`mobile.css` 只服务于网页版，鸿蒙包不再引用。

---

## 1. 本机已验证的工具链

| 组件 | 版本 / 路径 |
| --- | --- |
| DevEco Studio | `26.0.0.851`（build 261.23567.138.36.2600851） |
| 安装目录 | `C:\Program Files\Huawei\DevEco Studio` |
| HarmonyOS SDK | **HarmonyOS 26.0.0（API 26）**，位于 `…\DevEco Studio\sdk\default\hms` |
| hvigor / hvigor-ohos-plugin | `6.26.8`（IDE 内置，位于 `…\tools\hvigor`） |
| Node | `v24.14.1`（`…\tools\node`） |
| JDK | `JBR 25.0.2`（`…\jbr`，**不需要另外装 JDK**） |
| ohpm | `26.0.0.630`（`…\tools\ohpm`） |
| hdc | `…\sdk\default\openharmony\toolchains\hdc.exe` |

---

## 2. 构建配置（本工程实际值）

| 项 | 值 | 位置 |
| --- | --- | --- |
| 应用标识（bundleName） | `com.ccgo.kplboard` | `AppScope/app.json5` |
| 版本名 / 版本号 | `1.0.0` / `10000` | `AppScope/app.json5` |
| minAPIVersion / targetAPIVersion | **26 / 26** | `AppScope/app.json5` |
| compatibleSdkVersion / targetSdkVersion | **`26.0.0`** | `build-profile.json5 → products` |
| 运行时 | `HarmonyOS`（非 OpenHarmony） | `build-profile.json5` |
| 目标设备类型 | `phone` + `tablet` | `entry/src/main/module.json5` |
| 目标架构 | 纯 ArkTS → 方舟字节码（`ets/modules.abc`），**arm64 通用**，无需 `abiFilters` | 产物自检 |
| 屏幕方向 | `auto_rotation_restricted`（跟随系统） | `module.json5 → abilities.orientation` |
| 权限 | `INTERNET`、`GET_NETWORK_INFO`（原生版离线运行，保留仅为后续联网扩展） | `module.json5` |
| 签名 | DevEco 自动签名（调试证书） | `build-profile.json5 → signingConfigs` |

> **关于 API 26**：本机只装了 HarmonyOS 26.0.0 一套 SDK，所以版本只能写 26。
> 想让更老系统的手机也能装，需先在 DevEco 的 `Settings > SDK` 里下载对应 SDK，
> 再同时改 `app.json5` 的 `minAPIVersion` 与 `build-profile.json5` 的两处 SDK 版本。

---

## 3. 一键构建（不用打开 IDE）

```bash
bash harmony/build-hap.sh          # debug（默认，已签名）
bash harmony/build-hap.sh release  # release
```

脚本把 DevEco 的 Node / JDK / SDK 路径全部设好，直接跑即可。手动等价于：

```bash
export JAVA_HOME="/c/Program Files/Huawei/DevEco Studio/jbr"
export NODE_HOME="/c/Program Files/Huawei/DevEco Studio/tools/node"
export PATH="$JAVA_HOME/bin:$NODE_HOME:$PATH"
export DEVECO_SDK_HOME="C:/Program Files/Huawei/DevEco Studio/sdk"

cd harmony
"$NODE_HOME/node.exe" \
  "/c/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js" \
  assembleHap --no-daemon
```

**产物**

```
harmony/entry/build/default/outputs/default/entry-default-signed.hap    ← 真机可装
harmony/entry/build/default/outputs/default/entry-default-unsigned.hap ← 未签名
dist/KPLBoard-HarmonyOS-1.0.0-native.hap                               ← 已交付副本
```

---

## 4. 源码与资源目录划分（原生版）

```
harmony/
├─ AppScope/
│  ├─ app.json5                             应用级配置（包名 / 版本 / API）
│  └─ resources/base/media/app_icon.png     分层图标
├─ entry/src/main/
│  ├─ ets/
│  │  ├─ entryability/EntryAbility.ets      沉浸全屏 + 窗口/安全区/密度测量 → AppStorage
│  │  ├─ common/
│  │  │  ├─ DeviceEnv.ets                   断点体系 sm/md/lg + 留白/间距/触控热区/列宽
│  │  │  ├─ Ui.ets                          配色、圆角、字号、百分比/数值格式化
│  │  │  └─ EventPicker.ets                 年份 + 赛事两级联动选择器（共用组件）
│  │  ├─ data/
│  │  │  ├─ Models.ets                      全部接口响应的 interface 定义
│  │  │  ├─ BundleStore.ets                 rawfile → JSON / 字节 的离线数据层
│  │  │  └─ ImageRepo.ets                   按屏幕密度挑档 + 懒拷贝 + fileUri
│  │  └─ pages/
│  │     ├─ Index.ets                       外壳：宽屏导航条 / 窄屏底部 7 页签
│  │     ├─ BoardPage.ets                   比分看板（总览 KPI / 直播 / 赛程 / 积分榜）
│  │     ├─ GradientPage.ets                英雄梯度榜（分层 + 可展开使用者）
│  │     ├─ PlayerPage.ets                  选手详情（搜索 / 排序 / 宽屏列表+详情）
│  │     ├─ ItemsPage.ets                   装备（类型筛选 + 可展开）
│  │     ├─ RunesPage.ets                   铭文（颜色 + 等级筛选）
│  │     ├─ HeroPage.ets                    英雄详情（网格 + 详情 + 皮肤全屏预览）
│  │     └─ PatchPage.ets                   版本动态（超宽屏限制阅读宽度）
│  ├─ resources/
│  │  ├─ base/element/{string,color}.json   文案、启动窗口底色
│  │  ├─ base/media/                        startIcon / 分层图标
│  │  ├─ base/profile/main_pages.json       路由表（仅 pages/Index）
│  │  └─ rawfile/bundle/                    离线数据与图片仓库（2406 个文件 / 48.2 MB）
│  └─ module.json5                          ability / 设备类型 / 权限 / 旋转
├─ build-profile.json5                      签名 / SDK 版本 / 构建模式
├─ local.properties                         sdk.dir = C:/Program Files/Huawei/DevEco Studio/sdk
└─ build-hap.sh                             一键构建脚本
```

**`rawfile/bundle/` 内容**（由 `node tools/build-mobile-bundle.js` + `node tools/sync-mobile-assets.js --native` 生成）

| 路径 | 内容 | 规模 |
| --- | --- | --- |
| `bundle/api/index.json` + `api_*.json` | 全部 `/api/*` 接口快照（静态 JSON） | 369 个 / 15.1 MB |
| `bundle/img/resolve.json` + 图片文件 | 队标、英雄、装备、皮肤（**多档宽度**：`-0`/`-64`/`-288`…） | 2036 张 / 33.1 MB |

**离线原理**：`BundleStore.api<T>('/api/xxx')` 先读 `bundle/api/index.json` 拿到 key →
文件名映射，再用 `getRawFileContentSync` 读字节 → `TextDecoder` 解码 → `JSON.parse`。
**全程零网络请求**，飞行模式下也能完整浏览。

---

## 5. 屏幕适配规则（任意尺寸鸿蒙设备）

### 5.1 为什么不再需要手写 DPR 换算

鸿蒙的长度单位 **vp / fp 已由系统按屏幕密度自动换算**：

```
物理像素 = vp × (屏幕 PPI / 160)
```

Mate 60 Pro+（≈440 ppi，`densityPixels ≈ 2.75`）和 MatePad（≈264 ppi）上，
同一个 `16vp` 的字在物理世界里**一样大**。所以代码里不存在 `px × dpr` 的写法，
也就不会出现高密屏发糊、低密屏元素过粗的问题。

代码只需要处理**布局分档**：窗口有多宽决定几列、是否分栏。

### 5.2 官方三段式断点（`common/DeviceEnv.ets`）

| 断点 | 窗口宽度（vp） | 典型形态 | 布局 |
| --- | --- | --- | --- |
| `sm` | `< 600` | 手机竖屏（Mate 60 Pro+ 竖屏 ≈ 458vp） | 单列 + 底部页签 |
| `md` | `600 – 839` | 手机横屏 / 平板竖屏 / 分屏 | 多列，仍单页 |
| `lg` | `>= 840` | 平板横屏 / 折叠屏展开（Mate 60 Pro+ 横屏 ≈ 989vp） | **左右分栏（列表 + 详情）** |

派生值（都按断点取值，页面只调方法）：

| 用途 | sm | md | lg |
| --- | --- | --- | --- |
| 左右留白 `padOf()` | 12vp | 18vp | 24vp |
| 栅格间距 `gutOf()` | 8vp | 12vp | 16vp |
| 卡片最小宽 `cardMinOf()` | 150vp | 168vp | 190vp |
| 触控热区 `tapMinOf()` | 44vp | 40vp | 40vp |
| 装备网格列数 | 2 | 3 | 4 |
| 英雄网格列数 | 4 | 5 | 6 |

### 5.3 数据来源：`EntryAbility` 测量 → `AppStorage` → 页面订阅

```
setWindowLayoutFullScreen(true)              // 沉浸式：内容铺到状态栏与手势条之下
  ↓
measure()
  ├─ display.getDefaultDisplaySync().densityPixels           → dpr
  ├─ window.getWindowProperties().windowRect  ÷ dpr          → dev.widthVp / dev.heightVp
  ├─ DeviceEnv.bpOf(widthVp)                                 → dev.bp ('sm'|'md'|'lg')
  ├─ AvoidArea(TYPE_SYSTEM).topRect ⊕ TYPE_CUTOUT.topRect     → dev.safeTop（挖孔/状态栏）
  ├─ AvoidArea(TYPE_NAVIGATION_INDICATOR).bottomRect          → dev.safeBottom（手势条）
  └─ AvoidArea(TYPE_SYSTEM).left/rightRect                    → dev.safeLeft / safeRight
  ↓ AppStorage.setOrCreate
页面 @StorageLink('dev.widthVp') … 自动重排
```

监听 `windowSizeChange` + `avoidAreaChange`：**旋转、分屏、折叠屏开合、
手势条显隐**都会重新测量，页面无需重启即自动重排。

### 5.4 具体到 Mate 60 Pro+ 的验证点

| 维度 | 处理 | 预期 |
| --- | --- | --- |
| 2720×1260 / ≈440 ppi | 全 vp，系统按 ppi 换算 | 元素物理尺寸与低密屏一致，不拉伸不过粗 |
| 顶部挖孔 | `safeTop` = `max(状态栏, 挖孔)` ÷ dpr，写进根容器 `padding.top` | 内容不被挖孔遮住 |
| 底部手势条 | `safeBottom` 写进根容器 `padding.bottom`；页签高度 `56 + safeBottom` | 列表末行/页签不被压住 |
| 竖屏（≈458vp → sm） | 单列 + 底部 7 页签 + 2 列装备网格 | 无横向滚动 |
| 横屏（≈989vp → lg） | 看板：左（总览+直播+赛程）/ 右（积分榜）；选手：左列表/右详情；英雄：左网格/右详情 | 双窗格，不出现元素拉伸 |
| 字号随系统「显示大小」 | 全用 `fp`，跟随系统缩放 | 调到最大/最小都不崩、不截断 |
| 图片清晰度 | `ImageRepo` 取 `min(densityPixels, 3)` 向上挑最接近的档位；无更高档时取最大档，**绝不反向降质** | 440 ppi 下队标/英雄头像锐利不糊 |
| 首屏性能 | 图片首次使用才从 rawfile 懒拷贝到 `cacheDir`，不拖慢启动 | 冷启动无长白屏 |

---

## 6. 签名（真机安装的硬门槛）

鸿蒙**不允许安装未签名包**。两种方式二选一：

### 方式 A：DevEco 自动签名（本工程当前采用）

1. DevEco 打开 `harmony` 目录（作为工程根目录）
2. ☰（或 `File`）→ `Project Structure` → `Signing Configs` → 登录华为账号 → 勾选 **Automatically generate signature**
   （DevEco 26 把菜单藏进了左上角 ☰；快捷键 `Ctrl+Alt+Shift+S`）
3. IDE 把证书路径写回 `build-profile.json5` 的 `signingConfigs`
4. **关键**：还要确认 `products[0]` 里的 `"signingConfig": "default"` **不是注释**，
   否则会构建出「没挂签名」的包，真机安装报 `9568320 no signature file`
5. `bash harmony/build-hap.sh` 或点 Run → 出 `entry-default-signed.hap`

> 前提：系统时间必须与北京时间一致；每个华为账号最多 2 个调试证书名额。

### 方式 B：命令行手动签名

1. 华为开发者账号实名认证 → AppGallery Connect 建应用，包名 `com.ccgo.kplboard`
2. 生成密钥库与 CSR：
   ```bash
   keytool -genkeypair -alias kplboard -keyalg EC -sigalg SHA256withECDSA \
     -dname "CN=ccgo,O=ccgo,C=CN" -keystore kplboard.p12 -storetype PKCS12 -validity 9125
   keytool -certreq -alias kplboard -keystore kplboard.p12 -file kplboard.csr
   ```
3. AGC 用 `.csr` 换 `.cer`；`hdc shell bm get --udid` 取 UDID → 添加设备 → 申请 `.p7b`
4. 放开 `build-profile.json5` 里注释掉的 `signingConfigs` 段并填 4 个路径，
   同时放开 `products[0]` 的 `"signingConfig": "default"`
5. `bash harmony/build-hap.sh`

> 系统会校验 Profile 里的 UDID 与手机一致，**换手机要重新申请 Profile**。

---

## 7. 真机安装与验证（Mate 60 Pro+）

**手机端准备**

1. 设置 → 关于本机 → 连点「软件版本」7 次开启开发者模式
2. 设置 → 系统和更新 → 开发人员选项 → 打开 **USB 调试**；NEXT 上还要开「允许通过 HDB 连接设备」
3. 用**能传数据的数据线**（很多线只能充电，`hdc` 会找不到设备）

**安装**

```bash
export HDC="/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe"
"$HDC" list targets                       # 应看到设备序列号
"$HDC" install dist/KPLBoard-HarmonyOS-1.0.0-native.hap
"$HDC" shell aa start -a EntryAbility -b com.ccgo.kplboard
```

**验收清单**

| # | 检查项 | 期望 |
| --- | --- | --- |
| 1 | 冷启动 | 无白屏 >2s，直接进入「比分看板」 |
| 2 | 开飞行模式后重启 App | **七个页面全部照常显示**，队标/英雄图不空白 |
| 3 | 顶部挖孔 | 内容不被挖孔遮住 |
| 4 | 底部手势条 | 底部页签/列表末行不被手势条压住 |
| 5 | 竖屏 → 横屏 | 看板/选手/英雄 自动变左右分栏，不拉伸不留白 |
| 6 | 横屏 → 竖屏 | 回到单列 + 底部页签，间距正常无横向滚动 |
| 7 | 系统「显示大小」最大/最小 | 布局不崩、文字不截断 |
| 8 | 图片清晰度 | 队标、英雄头像在 440 ppi 下边缘锐利 |
| 9 | 长列表滚动 | 无卡顿（离线直供，无网络等待） |
| 10 | 赛事切换 | 年份/赛事两级联动，只列出有数据的赛事 |

---

## 8. 产物格式说明

| 场景 | 产物 | 说明 |
| --- | --- | --- |
| 调试 / 验证 / 单设备分发 | `.hap`（HarmonyOS Ability Package） | 本工程出 `entry-default-signed.hap` |
| 上架 / 多设备分发 | `.app`（App Pack） | DevEco：`Build > Build Hap(s)/APP(s) > Build APP`，内含多个 `.hap` |

当前仓内已交付：`dist/KPLBoard-HarmonyOS-1.0.0-native.hap`（50 MB，含全部离线资源，已签名）。

---

## 9. 踩坑记录（本机实测，按顺序踩过来的）

### 9.1 工具链 / 签名

| 报错 | 原因 | 解法 |
| --- | --- | --- |
| `00303217 Invalid value of 'DEVECO_SDK_HOME'` | `sdk.dir` 指到了 `…\sdk\default\openharmony` | 应指向**组名的父级** `…\DevEco Studio\sdk` |
| `00303312 Cannot find the corresponding SDK version` | `sdk.dir` 少一层 / 工程要求的 SDK 没装 | 用 `…\sdk`；`compatibleSdkVersion` 必须是本机已装版本 |
| `00308018 api version parameter is illegal` | 版本号写了老格式 `26.0.0(26)` | hvigor 6.x 只接受 `26.0.0` |
| `spawn java ENOENT` | Git Bash 里 PATH 写成 `C:/Program Files/...` | 必须用 POSIX 形式 `/c/Program Files/...` |
| `Unknown mode 'debug'` | hvigor 6.x 不接受 `--mode debug` | debug 是默认值，不要传；release 才传 `--mode release` |
| `00303107 Invalid storeFile value` | `products[0]` 写了 `signingConfig` 但 `signingConfigs` 空 | 两者同步 |
| 安装报 `9568320 no signature file` | 自动签名只填了 `signingConfigs`，`products[0]."signingConfig"` 仍是注释 | 放开那行引用 |
| `File > Project Structure > Signing Configs` 找不到 | DevEco 26 新 UI 把菜单藏进左上角 ☰ | ☰ → File → Project Structure；或 `Ctrl+Alt+Shift+S` |
| `hdc list targets` 返回 `[Empty]` | 数据线只能充电 / 未授权 USB 调试 | 换数据线，选「传输文件」，手机上确认授权 |

### 9.2 ArkTS 严格模式（原生重写时新踩的）

| 报错 | 原因 | 解法 |
| --- | --- | --- |
| `arkts-no-untyped-obj-literals` | 返回 `{text, color}` 这类无归属对象字面量 | 声明 `class StatusTag` / `class Kpi` 后 `new` 出来 |
| `arkts-no-any-unknown` / `arkts-no-structural-typing` | 用 interface 做「鸭子类型」传参 | 只传原始类型，或让参数类实现同一 interface |
| `Property 'kind' is private and can not be initialized through the component constructor` | 父子组件传的字段标了 `private` | 去掉 `private`（`EventPicker.kind` / `.onPick`） |
| `Cannot find name 'File'` / `Argument of type 'File' is not assignable to 'number'` | ArkTS 里没有 DOM 的 `File` 类型 | `const f = fileIo.openSync(...); fileIo.writeSync(f.fd, ...)` |
| **`Only UI component syntax can be written here`** | 在 `@Builder` 体内写 `const` / `return;` | `@Builder` 体内**只能有 UI 语法**；局部变量改到成员方法里算，提前 `return` 改成两个互斥 `if` 块 |
| **`build() can have only one root node`** + Rollup `Unexpected token` | 在 `build()` 里写了 `const bp = ...` 等语句 —— build 的函数体只允许「一个根容器语句」 | 所有适配值改成**成员方法**（`pad()` / `gut()` / `wide()` / `empty()`…），`DeviceEnv` 提供 `padOf(widthVp)` 等按宽度直取的入口 |
| `Object is possibly 'null'`（方法返回值） | `if (this.cur()) { this.cur().name }` —— 方法调用结果**不会**被收窄 | 用**成员属性**承载（`this.picked`），属性访问才会被收窄 |
| `Argument of type 'X \| null' is not assignable` | 同上 | 同上（或在函数入口一次性取值） |

> 经验：**`build()` 里不要出现任何非 UI 语句**，`@Builder` 里不要出现 `const` 和 `return`。
> 需要计算就写成 `private xxx(): T` 成员方法，在 UI 表达式里调用。

---

## 10. 数据/图片更新后怎么重新出包

```bash
# 1) 重新生成离线资源包（接口快照 + 多档图片）
node tools/build-mobile-bundle.js

# 2) 同步进鸿蒙工程（--native：只拷 bundle/，并清理旧的 rawfile/www）
node tools/sync-mobile-assets.js --native

# 3) 重新构建
bash harmony/build-hap.sh
```

---

## 11. 增量修改提示

- 改布局分档阈值/留白/列数 → `ets/common/DeviceEnv.ets`
- 改配色/字号/格式化 → `ets/common/Ui.ets`
- 加接口字段 → `ets/data/Models.ets`
- 加页面 → 新建 `ets/pages/XxxPage.ets`，在 `ets/pages/Index.ets` 的 `tabs` 与 `content()` 里登记
- 改外壳（导航条 ↔ 底部页签阈值）→ `Index.ets` 的 `DeviceEnv.MD_MAX` 判断

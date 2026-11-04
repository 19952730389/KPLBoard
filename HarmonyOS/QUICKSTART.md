# 换一台电脑：连手机安装 / 调试（快速上手）

本目录是一个**完整的、自包含的 HarmonyOS 原生工程**（纯 ArkTS，无 WebView），
离线数据（369 个接口快照 + 2036 张图片，48 MB）已经放在 `entry/src/main/resources/rawfile/bundle/`，
**拷贝到任何一台装了 DevEco Studio 的电脑上都能直接构建**，不需要联网拉数据。

---

## 路线一：只想把 App 装到手机上（最快，5 分钟）

如果那台手机**已经在你的华为开发者账号里注册过 UDID**（也就是之前在这台电脑上装过），
那么签名好的 `KPLBoard-HarmonyOS-1.0.0-native.hap` **跟电脑无关，可以直接装**：

```bash
# 1) 新电脑装 DevEco Studio（只为拿到 hdc 工具），或用华为官方 Command Line Tools
# 2) 手机：设置 → 关于本机 → 连点「软件版本」7 次开开发者模式
#    设置 → 系统和更新 → 开发人员选项 → 打开「USB 调试」+「允许通过 HDB 连接设备」
# 3) 用能传数据的数据线连上，手机上点「允许调试」
hdc list targets                                   # 应看到设备序列号
hdc install KPLBoard-HarmonyOS-1.0.0-native.hap
hdc shell aa start -a EntryAbility -b com.ccgo.kplboard
```

> ⚠️ 换了一台**没注册过 UDID 的手机** → 必须用路线二重新签名（调试 Profile 绑定设备 UDID）。

---

## 路线二：在新电脑上从源码构建 + 调试（推荐）

### 1. 装环境

| 组件 | 版本要求 | 说明 |
| --- | --- | --- |
| DevEco Studio | **26.0.0.851** 或同大版本 | all-in-one 安装，自带 SDK / Node / JDK / hvigor，**不用另装 JDK** |
| HarmonyOS SDK | **HarmonyOS 26.0.0（API 26）** | 打开 IDE 时若提示下载，勾选 API 26；本工程 `minAPIVersion = 26` |
| hdc | SDK 自带 | `DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe` |

> 若没装 DevEco（只要命令行构建），可装 Huawei 官方 **Command Line Tools for HarmonyOS**，
> 然后把 `build-hap.sh` 的 `DEVECOROOT` 指到它的安装目录。

### 2. 打开工程

DevEco → `File > Open` → **选中本 `harmony` 目录作为工程根**（不要选它的父目录）。
首次打开会 `Sync Now` / 自动 `ohpm install`，等它跑完。

### 3. 签名（真机安装的硬门槛）

`File > Project Structure > Signing Configs`
（DevEco 26 把菜单收进了左上角 **☰**；快捷键 `Ctrl+Alt+Shift+S`）
→ 登录**同一个华为开发者账号** → 勾选 **Automatically generate signature** → `Apply` / `OK`。

**然后务必检查一件事**（这是本机踩过的坑，会直接导致装不上）：

打开 `build-profile.json5`，确认 `products[0]` 里这行**不是注释**：

```json5
"signingConfig": "default",
```

IDE 自动签名只把证书填进 `signingConfigs`，这行引用常常还是被注释的状态 ——
结果是构建出「没挂签名」的包，真机安装报 **`9568320 no signature file`**。

如果那台手机没在你的 AGC 设备列表里，还需要：
`hdc shell bm get --udid` 拿到 UDID → AppGallery Connect 添加设备 → 重新申请 `.p7b` Profile。

### 4. 构建

**方式 A：命令行（不用开 IDE）**

```bash
bash build-hap.sh            # debug
bash build-hap.sh release    # release
```

脚本会自动探测 DevEco 安装目录；探测不到就手动指：

```bash
DEVECOROOT="/d/Huawei/DevEco Studio" bash build-hap.sh     # Windows 其他盘
DEVECOROOT="/Applications/DevEco-Studio.app/Contents" bash build-hap.sh   # macOS
```

**方式 B：IDE**

`Build > Build Hap(s)/APP(s) > Build Hap(s)`，或直接点 ▶ Run（先选中手机）。

产物：

```
entry/build/default/outputs/default/entry-default-signed.hap
```

### 5. 安装 / 调试

```bash
hdc install entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.ccgo.kplboard
hdc shell hilog | grep KPLBoard        # 看日志
```

或在 DevEco 里直接点 ▶ Run，断点、Layout Inspector、ArkUI Inspector 都能正常用。

---

## 常见问题（换电脑专属）

| 现象 | 原因 | 解法 |
| --- | --- | --- |
| `00303217 Invalid value of 'DEVECO_SDK_HOME'` | `local.properties` 里 `sdk.dir` 还是旧电脑的路径 | `build-hap.sh` 会自动改写；IDE 打开时也会自行纠正。确认指向 **`…\DevEco Studio\sdk`**（组名的父级，不是 `…\sdk\default\openharmony`） |
| `00303312 Cannot find the corresponding SDK version` | 那台电脑没装 API 26 | DevEco `Settings > SDK` 下载 HarmonyOS 26.0.0(26) |
| `00308018 api version parameter is illegal` | 有人把版本号改回了 `26.0.0(26)` 老格式 | 必须是 `26.0.0` |
| `9568320 no signature file` | `products[0]."signingConfig"` 仍是注释 | 放开该行 |
| `spawn java ENOENT` | Git Bash 里 PATH 写成 `C:/Program Files/...` | 用 POSIX 形式 `/c/Program Files/...`（脚本已处理） |
| `hdc list targets` 返回 `[Empty]` | 数据线只能充电 / 没授权调试 | 换数据线，手机选「传输文件」，确认授权弹窗 |
| 装完打开是空的 | rawfile 没打进包 | 确认 `entry/src/main/resources/rawfile/bundle/` 存在（2406 个文件 / 48 MB），本压缩包已带齐 |

---

## 目录速查

```
harmony/
├─ AppScope/app.json5              包名 com.ccgo.kplboard / 版本 1.0.0 / API 26
├─ entry/src/main/ets/
│  ├─ entryability/EntryAbility.ets    窗口测量 + 安全区 → AppStorage
│  ├─ common/DeviceEnv.ets             断点 sm/md/lg 与适配取值（改适配看这里）
│  ├─ common/Ui.ets                    配色 / 字号 / 格式化
│  ├─ common/EventPicker.ets           赛事两级联动选择器
│  ├─ data/BundleStore.ets             离线数据读取
│  ├─ data/ImageRepo.ets               按屏幕密度挑图 + 懒拷贝
│  ├─ data/Models.ets                  接口数据结构
│  └─ pages/*.ets                      7 个页面 + Index.ets 外壳
├─ entry/src/main/resources/rawfile/bundle/   离线数据（已打进包）
├─ build-profile.json5              签名 + SDK 版本
├─ local.properties                 sdk.dir（换电脑会自动纠正）
├─ build-hap.sh                     一键构建（自动探测 DevEco）
├─ QUICKSTART.md                    本文件
└─ PACKAGING.md                     完整打包 / 适配 / 踩坑文档
```

---

## 换设备形态要验证什么

| 形态 | 断点 | 期望 |
| --- | --- | --- |
| 手机竖屏（Mate 60 Pro+ ≈458vp） | `sm` | 单列 + 底部 7 页签，2 列装备网格 |
| 手机横屏（≈989vp） | `lg` | 看板 / 选手 / 英雄 变左右分栏 |
| 平板竖屏 | `md` | 多列，仍单页 |
| 平板横屏 / 折叠展开 | `lg` | 左侧导航条 + 右侧分栏 |
| 分屏 / 悬浮窗 | 随宽度 | 自动降级到对应断点，不拉伸不留白 |

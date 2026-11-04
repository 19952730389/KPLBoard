/* 设置页（全屏浮层）
 * ---------------------------------------------------------------------------
 * 入口：顶部栏右上角齿轮按钮（写 AppStorage['ui.settingsOpen']），
 * Index 根部 Stack 监听后整体覆盖在最上层（连底部胶囊一起盖住）。
 * 三个分区：
 *   ① 外观主题：跟随系统 / 浅色 / 深色（复用 ThemeSwitch）；
 *   ② 悬浮层材质：毛玻璃 / 半透明 / 透明 —— 控制顶部页头与底部导航
 *      胶囊的底色透明度与背板模糊（Ui.GLASS / Ui.BLUR 实时读取）；
 *   ③ 关于应用：名称、版本、更新时间、数据来源与说明。
 * 悬浮层材质与主题一样走 PersistentStorage 落盘（EntryAbility 注册），冷启动保持。
 */
import { DeviceEnv } from './DeviceEnv';
import { Theme } from './Theme';
import { ThemeSwitch } from './ThemeSwitch';
import { Ui } from './Ui';

class AboutRow {
  label: string;
  value: string;

  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

/** 单选行子组件：@Prop 与父组件状态建立同步，选中态变化即时刷新
 * （@Builder 按值传参不响应状态变化，曾导致切换材质/光感后圆点不动） */
@Component
struct OptionRow {
  @Prop label: string = '';
  @Prop sub: string = '';
  @Prop active: boolean = false;
  onPick: () => void = (): void => {};

  build() {
    Row() {
      Column() {
        Text(this.label)
          .fontSize(Ui.FS_BODY)
          .fontWeight(this.active ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.active ? Ui.GOLD : Ui.TEXT)
        if (this.sub.length > 0) {
          Text(this.sub)
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.MUTED)
            .margin({ top: 2 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Row() {}
        .width(18)
        .height(18)
        .borderRadius(9)
        .backgroundColor(this.active ? Ui.GOLD : Color.Transparent)
        .border({ width: 1.5, color: this.active ? Ui.GOLD : Ui.LINE })
        .margin({ left: 10 })
    }
    .width('100%')
    .padding(12)
    .borderRadius(Ui.R_MD)
    .backgroundColor(this.active ? Ui.PANEL_2 : Ui.PANEL)
    .border({ width: 1, color: this.active ? Ui.GOLD : Ui.LINE })
    .margin({ bottom: 8 })
    .onClick(() => {
      this.onPick();
    })
  }
}

@Component
export struct SettingsPanel {
  @StorageLink('ui.themeMode') themeMode: string = 'dark';
  @StorageLink('ui.navMaterial') mat: string = 'glass';
  @StorageLink('ui.navLevel') level: string = 'balanced';
  @StorageLink('dev.widthVp') wVp: number = 360;
  @StorageLink('dev.safeTop') safeTop: number = 0;
  @StorageLink('dev.safeBottom') safeBottom: number = 0;
  onClose: () => void = (): void => {};

  private matLabel(): string {
    if (this.mat === 'transparent') {
      return '透明';
    }
    if (this.mat === 'translucent') {
      return '半透明';
    }
    return '毛玻璃';
  }

  private matHint(): string {
    if (this.mat === 'transparent') {
      return '仅保留极淡的底色，内容几乎直接透出，不加模糊';
    }
    if (this.mat === 'translucent') {
      return '较高不透明度底色，透出内容轮廓但不加模糊';
    }
    if (this.level === 'strong') {
      return '当前光感：强 —— 底色最透、模糊最大，光效最显著';
    }
    if (this.level === 'weak') {
      return '当前光感：弱 —— 底色稍实、模糊较轻，利于文字辨识';
    }
    return '当前光感：均衡 —— 通透感与可读性折中（推荐）';
  }

  private themeHint(): string {
    if (this.themeMode === 'system') {
      return '当前跟随系统：系统切深浅色时 App 自动同步';
    }
    if (this.themeMode === 'light') {
      return '当前浅色：始终使用浅色配色';
    }
    return '当前深色：始终使用深色配色';
  }

  @Builder
  private sectionTitle(t: string) {
    Text(t)
      .fontSize(Ui.FS_SMALL)
      .fontWeight(FontWeight.Medium)
      .fontColor(Ui.MUTED)
      .width('100%')
      .margin({ top: 18, bottom: 8 })
  }

  /** 悬浮层材质单选 */
  @Builder
  private matOption(label: string, key: string, sub: string) {
    OptionRow({
      label: label,
      sub: sub,
      active: this.mat === key,
      onPick: (): void => {
        this.mat = key;
      }
    })
  }

  /** 沉浸光感单选（仅毛玻璃档显示，对齐系统三档） */
  @Builder
  private levelOption(label: string, key: string, sub: string) {
    OptionRow({
      label: label,
      sub: sub,
      active: this.level === key,
      onPick: (): void => {
        this.level = key;
      }
    })
  }

  @Builder
  private aboutRow(r: AboutRow, last: boolean) {
    Row() {
      Text(r.label)
        .fontSize(Ui.FS_BODY)
        .fontColor(Ui.MUTED)
      Blank()
      Text(r.value)
        .fontSize(Ui.FS_BODY)
        .fontColor(Ui.TEXT)
        .textAlign(TextAlign.End)
        .layoutWeight(1)
        .margin({ left: 12 })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  build() {
    Column() {
      /* 头部：返回 + 标题 */
      Row() {
        Text('←')
          .fontSize(20)
          .fontColor(Ui.GOLD)
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .borderRadius(20)
          .backgroundColor(Ui.PANEL)
          .border({ width: 1, color: Ui.LINE })
          .onClick(() => {
            this.onClose();
          })
        Text('设置')
          .fontSize(Ui.FS_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.TEXT)
          .margin({ left: 12 })
        Blank()
      }
      .width('100%')
      .margin({ bottom: 4 })

      Scroll() {
        Column() {
          this.sectionTitle('外观主题')
          Column() {
            ThemeSwitch()
            Text(this.themeHint())
              .fontSize(Ui.FS_TINY)
              .fontColor(Ui.MUTED)
              .width('100%')
              .margin({ top: 8 })
          }
          .width('100%')
          .padding(12)
          .borderRadius(Ui.R_MD)
          .backgroundColor(Ui.PANEL)
          .border({ width: 1, color: Ui.LINE })

          this.sectionTitle('悬浮层材质')
          this.matOption('毛玻璃', 'glass', '底色半透明 + 背板模糊（推荐）')
          this.matOption('半透明', 'translucent', '底色较实，透出内容轮廓')
          this.matOption('透明', 'transparent', '近乎全透，不加模糊')

          /* 沉浸光感：仅毛玻璃档显示，对齐系统「强 / 均衡 / 弱」三档 */
          if (this.mat === 'glass') {
            this.sectionTitle('沉浸光感')
            this.levelOption('强', 'strong', '底色最透、模糊最大，光效最显著')
            this.levelOption('均衡', 'balanced', '通透感与可读性折中（推荐）')
            this.levelOption('弱', 'weak', '底色稍实、模糊较轻，利于文字辨识')
          }
          Text(this.matHint())
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.MUTED)
            .width('100%')
            .margin({ top: 2, bottom: 4 })

          this.sectionTitle('关于应用')
          Column() {
            this.aboutRow(new AboutRow('应用名称', 'KPL 看板'), false)
            this.aboutRow(new AboutRow('版本', '1.0.0 (10000)'), false)
            this.aboutRow(new AboutRow('更新时间', '2026-10-09'), false)
            this.aboutRow(new AboutRow('运行平台', 'HarmonyOS'), false)
            this.aboutRow(new AboutRow('数据来源', '玩加电竞 · KPL官方 · 王者荣耀官网'), false)
            this.aboutRow(new AboutRow('网络策略', '端内直连公网，失败自动回退本地缓存'), true)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 4, bottom: 4 })
          .borderRadius(Ui.R_MD)
          .backgroundColor(Ui.PANEL)
          .border({ width: 1, color: Ui.LINE })

          Text('悬浮层指顶部页头与底部导航胶囊；材质与光感修改全局生效并自动保存，页头内的筛选控件会随材质一同呈现玻璃质感。')
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.MUTED)
            .width('100%')
            .margin({ top: 16 })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .margin({ top: 8 })
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({
      top: this.safeTop + 12,
      left: DeviceEnv.padOf(this.wVp),
      right: DeviceEnv.padOf(this.wVp),
      bottom: this.safeBottom + 12,
    })
    .backgroundColor(Ui.BG)
  }
}

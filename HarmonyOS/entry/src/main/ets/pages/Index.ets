/* 主框架（原生实现）
 * ---------------------------------------------------------------------------
 * 一套代码三种形态，全部由窗口宽度（vp）自动决定：
 *   sm（<600vp，手机竖屏） 底部页签，7 个模块
 *   md（600–839vp，横屏/平板竖屏）同上，页面内部网格变多列
 *   lg（>=840vp，平板/折叠展开）左侧导航条 + 右侧内容，页面内部再分双窗格
 *
 * 窗口尺寸与安全区由 EntryAbility 写进 AppStorage，横竖屏切换、
 * 分屏、折叠屏开合都会触发这里重排（@StorageLink）。
 *
 * 导航规范（本次重做）：
 *   · 窄屏底部为「悬浮胶囊」导航——高透毛玻璃底（backgroundBlurStyle），
 *     七项常显「上图标下文字」，选中金色 / 未选中灰；
 *   · 滑动切页过程中 onGestureSwipe 实时推进导航高亮，不迟滞；
 *   · 宽屏侧栏用同一套图标与配色，竖排导航条，底部挂外观切换器；
 */
import { common } from '@kit.AbilityKit';
import { AppIcon } from '../common/AppIcon';
import { DeviceEnv } from '../common/DeviceEnv';
import { SettingsPanel } from '../common/SettingsPanel';
import { ThemeSwitch } from '../common/ThemeSwitch';
import {
  ICON_BOARD,
  ICON_HERO,
  ICON_ITEM,
  ICON_PATCH,
  ICON_PLAYER,
  ICON_RUNE,
  ICON_TIER,
  Ui
} from '../common/Ui';
import { BundleStore } from '../data/BundleStore';
import { ImageRepo } from '../data/ImageRepo';
import { LiveBoard } from '../data/LiveBoard';
import { NetStore } from '../data/NetStore';
import { BoardPage } from './BoardPage';
import { GradientPage } from './GradientPage';
import { PlayerPage } from './PlayerPage';
import { ItemsPage } from './ItemsPage';
import { RunesPage } from './RunesPage';
import { HeroPage } from './HeroPage';
import { PatchPage } from './PatchPage';

class NavEntry {
  short: string; // 页签文字（两字）
  title: string; // 完整模块名（宽屏侧栏 / 无障碍朗读用）
  icon: string; // 图标名（见 Ui.ets 的 ICON_*，对应 ic_<name>.svg）

  constructor(short: string, title: string, icon: string) {
    this.short = short;
    this.title = title;
    this.icon = icon;
  }
}

@Entry
@Component
struct Index {
  @StorageLink('dev.widthVp') widthVp: number = 360;
  @StorageLink('dev.safeTop') safeTop: number = 0;
  @StorageLink('dev.safeBottom') safeBottom: number = 0;
  /* 主题键订阅 + @Watch：Ui.X 颜色是 build 时静态取值，ArkUI 的最小化更新
   * 只会重算「绑定了状态变量」的属性——纯靠订阅无法让整页换肤。
   * 因此主题（或系统深浅色）一变就 epoch++，build 里用 if/else 双分支
   * 强制销毁并重建整棵 UI 树（页签、侧栏、页面、顶部栏全部重新取色）。
   * BundleStore 有缓存且页面很轻，重建开销可忽略。 */
  @StorageLink('ui.themeMode') @Watch('onThemeChange') themeMode: string = 'dark';
  @StorageLink('sys.colorMode') @Watch('onThemeChange') sysMode: string = '';
  /* 悬浮层材质（毛玻璃/半透明/透明）：变化时同样整树重建，
   * 页头与胶囊在 build 时重新读 Ui.GLASS / Ui.BLUR */
  @StorageLink('ui.navMaterial') @Watch('onThemeChange') navMaterial: string = 'glass';
  /* 沉浸光感强度（强/均衡/弱，仅毛玻璃档生效） */
  @StorageLink('ui.navLevel') @Watch('onThemeChange') navLevel: string = 'balanced';
  /* 设置浮层开合：TopBar 齿轮按钮写入，根部整体覆盖 */
  @StorageLink('ui.settingsOpen') settingsOpen: boolean = false;
  @State epoch: number = 0;
  @State index: number = 0;
  /* 胶囊高亮独立状态：滑动过程中由 onGestureSwipe 实时推进（event.toIndex
   * 是系统预测的目标页），不等 onChange——解决「滑完了导航才反应」的迟滞感 */
  @State navIdx: number = 0;
  private tabs: NavEntry[] = [
    new NavEntry('看板', '比分看板', ICON_BOARD),
    new NavEntry('梯度', '梯度榜', ICON_TIER),
    new NavEntry('选手', '选手详情', ICON_PLAYER),
    new NavEntry('英雄', '英雄详情', ICON_HERO),
    new NavEntry('装备', '装备', ICON_ITEM),
    new NavEntry('铭文', '铭文', ICON_RUNE),
    new NavEntry('版本', '版本动态', ICON_PATCH),
  ];

  onThemeChange(): void {
    this.epoch++;
  }

  aboutToAppear(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      BundleStore.init(ctx);
      ImageRepo.init(ctx);
      NetStore.init(ctx);
      LiveBoard.init(ctx);
    } catch (e) {
      /* 拿不到上下文时页面会显示空态，不至于崩溃 */
    }
  }

  /** 返回手势（边缘侧滑 / 返回键）：设置浮层打开时先关浮层回到主页，
   *  返回 true 表示自行处理、不退出 App；已回主页则放行让系统退出 */
  onBackPress(): boolean {
    if (this.settingsOpen) {
      this.settingsOpen = false;
      return true;
    }
    return false;
  }

  @Builder
  private content(i: number) {
    if (i === 0) {
      BoardPage()
    } else if (i === 1) {
      GradientPage()
    } else if (i === 2) {
      PlayerPage()
    } else if (i === 3) {
      HeroPage()
    } else if (i === 4) {
      ItemsPage()
    } else if (i === 5) {
      RunesPage()
    } else {
      PatchPage()
    }
  }

  /** 宽屏左侧导航条：与胶囊页签同一套图标 / 配色 / 选中态 */
  @Builder
  private rail() {
    Column() {
      Text('KPL')
        .fontSize(Ui.FS_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.GOLD)
        .width('100%')
        .margin({ top: this.safeTop + 12, bottom: 16 })

      ForEach(this.tabs, (t: NavEntry, i: number) => {
        Row() {
          Row() {}
            .width(3)
            .height(20)
            .borderRadius(2)
            .backgroundColor(this.index === i ? Ui.GOLD : Color.Transparent)
            .margin({ right: 8 })
          AppIcon({
            name: t.icon,
            px: 22,
            color: this.index === i ? Ui.GOLD : Ui.MUTED
          })
          Text(t.short)
            .fontSize(Ui.FS_SMALL)
            .fontColor(this.index === i ? Ui.GOLD : Ui.MUTED)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: 6 })
        }
        .width('100%')
        .height(44)
        .padding({ left: 8, right: 8 })
        .borderRadius(Ui.R_SM)
        .backgroundColor(this.index === i ? Ui.PANEL_2 : Color.Transparent)
        .margin({ bottom: 4 })
        .onClick(() => {
          this.index = i;
        })
      }, (t: NavEntry, i: number) => `nav-${i}-${t.short}`)

      Blank()

      Column() {
        Text('外观')
          .fontSize(Ui.FS_TINY)
          .fontColor(Ui.MUTED)
          .width('100%')
          .margin({ bottom: 6 })
        ThemeSwitch()
      }
      .width('100%')
      .padding({ left: 8, right: 8 })
      .margin({ bottom: this.safeBottom + 12 })
    }
    .width(116)
    .height('100%')
    .backgroundColor(Ui.BAR)
    .border({ width: 0, color: Color.Transparent })
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 4, right: 4 })
  }

  /** 悬浮胶囊项：常显「上图标下文字」，选中金色 / 未选中灰 */
  @Builder
  private capItem(t: NavEntry, i: number) {
    Column() {
      AppIcon({ name: t.icon, px: 20, color: this.navIdx === i ? Ui.GOLD : Ui.MUTED })
      Text(t.short)
        .fontSize(Ui.FS_TINY)
        .fontWeight(this.navIdx === i ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.navIdx === i ? Ui.GOLD : Ui.MUTED)
        .maxLines(1)
        .margin({ top: 2 })
    }
    .width(42)
    .height(46)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.index = i;
      this.navIdx = i;
    })
  }

  /** 悬浮胶囊本体：高透毛玻璃底 + 描边 + 投影，距底部避开手势安全区 */
  @Builder
  private capsule() {
    Row() {
      ForEach(this.tabs, (t: NavEntry, i: number) => {
        this.capItem(t, i)
      }, (t: NavEntry, i: number) => `cap-${i}-${t.short}`)
    }
    .padding({ left: 3, right: 3, top: 4, bottom: 4 })
    .borderRadius(28)
    .backgroundColor(Ui.GLASS)
    .backgroundEffect({ radius: Ui.BLUR, saturation: 1.5 })
    .border({ width: 0.5, color: Ui.LINE })
    .shadow({ radius: 20, color: Ui.SHADOW, offsetY: 5 })
    .constraintSize({ maxWidth: '97%' })
    .margin({ bottom: this.safeBottom + 12 })
  }

  /** 导航外壳：宽屏（>=840vp）走「导航条 + 内容」，窄屏走「悬浮胶囊页签」
   * 条件直接读 @StorageLink 状态，窗口一变就自动重排 */
  @Builder
  private shell() {
    if (this.widthVp >= DeviceEnv.MD_MAX) {
      Row() {
        this.rail()
        Column() {
          this.content(this.index)
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')
    } else {
      /* Stack 底部对齐：Tabs 全屏铺内容（内建页签 barHeight(0) 隐藏），
       * 胶囊浮在内容上方、内容从其下方穿过（毛玻璃透出）；
       * 页面滚动内容末尾自带 bottomGap() 预留胶囊高度，滚动到底不被遮挡 */
      Stack({ alignContent: Alignment.Bottom }) {
        Tabs({ barPosition: BarPosition.End, index: this.index }) {
          ForEach(this.tabs, (t: NavEntry, i: number) => {
            TabContent() {
              this.content(i)
            }
          }, (t: NavEntry, i: number) => `tab-${i}-${t.short}`)
        }
        .barMode(BarMode.Fixed)
        .barHeight(0)
        .animationDuration(150)
        .scrollable(true)
        .backgroundColor(Ui.BG)
        .onGestureSwipe((idx: number, event: TabsAnimationEvent) => {
          /* 滑动过程中就推进高亮：currentOffset 为当前内容相对 Tabs 起点的
           * 偏移，除以页宽四舍五入即预测目标页，导航不再等 onChange */
          const w: number = this.widthVp > 0 ? this.widthVp : 360;
          let t: number = Math.round(event.currentOffset / w);
          const max: number = this.tabs.length - 1;
          if (t < 0) { t = 0; }
          if (t > max) { t = max; }
          this.navIdx = t;
        })
        .onAnimationStart((idx: number, target: number, event: TabsAnimationEvent) => {
          /* 松手后补间动画一开始就把高亮切到目标页 */
          this.navIdx = target;
        })
        .onChange((idx: number) => {
          this.index = idx;
          this.navIdx = idx;
        })
        .width('100%')
        .height('100%')

        this.capsule()
      }
      .width('100%')
      .height('100%')
    }
  }

  build() {
    // 根容器唯一。epoch 奇偶互斥的 if/else 两个分支是不同的节点树，
    // 主题切换（epoch++）时旧分支整体销毁、新分支整体重建 → 全量换肤
    Stack() {
      if (this.epoch % 2 === 0) {
        Column() {
          this.shell()
        }
        .width('100%')
        .height('100%')
      } else {
        Column() {
          this.shell()
        }
        .width('100%')
        .height('100%')
      }

      /* 设置浮层：盖在一切之上（含底部胶囊），关闭即回到原页面状态 */
      if (this.settingsOpen) {
        SettingsPanel({
          onClose: () => {
            this.settingsOpen = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Ui.BG)
  }
}

/* 页面顶部条（统一入口）：标题 + 数据状态 + 手动刷新 + 设置入口
 * ---------------------------------------------------------------------------
 * 所有页面共用同一条顶部栏，保证：
 *   · 视觉规范一致（标题 20fp、状态 10fp、按钮 40vp 圆形描边）
 *   · 「刷新」和「设置」两个入口在每个模块都在同一位置，不用到处找
 *
 * 设置入口：写 AppStorage['ui.settingsOpen']，由 Index 根部渲染全屏设置
 * 浮层（外观主题 / 悬浮层材质 / 关于应用），见 common/SettingsPanel.ets。
 */
import { AppIcon } from './AppIcon';
import { ICON_GEAR, ICON_REFRESH, Ui } from './Ui';

@Component
export struct TopBar {
  @Prop title: string = '';
  /** 数据状态文案，例如「实时 · 10:24 更新」/「离线包 · 09-29 快照」 */
  @Prop status: string = '';
  /** true = 数据来自网络（状态点显示绿色） */
  @Prop live: boolean = false;
  @Prop loading: boolean = false;
  /** 是否给出手动刷新按钮（纯静态页可关） */
  @Prop canRefresh: boolean = true;
  onRefresh: () => void = (): void => {};

  private openSettings(): void {
    AppStorage.setOrCreate<boolean>('ui.settingsOpen', true);
  }

  @Builder
  private refreshButton() {
    Row() {
      if (this.loading) {
        LoadingProgress()
          .width(24)
          .height(24)
          .color(Ui.GOLD)
      } else {
        AppIcon({ name: ICON_REFRESH, px: 24, color: Ui.GOLD })
      }
    }
    .width(40)
    .height(40)
    .borderRadius(20)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Ui.CONTROL)
    .border({ width: 1, color: Ui.LINE })
    .opacity(this.loading ? 0.6 : 1)
    .onClick(() => {
      if (!this.loading) {
        this.onRefresh();
      }
    })
  }

  @Builder
  private settingsButton() {
    Row() {
      AppIcon({ name: ICON_GEAR, px: 24, color: Ui.TEXT })
    }
    .width(40)
    .height(40)
    .borderRadius(20)
    .margin({ left: 8 })
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Ui.CONTROL)
    .border({ width: 1, color: Ui.LINE })
    .onClick(() => {
      this.openSettings();
    })
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text(this.title)
            .fontSize(Ui.FS_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row() {
            Row() {}
              .width(6)
              .height(6)
              .borderRadius(3)
              .backgroundColor(this.live ? Ui.GREEN : Ui.MUTED)
            Text(this.status)
              .fontSize(Ui.FS_TINY)
              .fontColor(this.live ? Ui.GREEN : Ui.MUTED)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ left: 5 })
          }
          .alignItems(VerticalAlign.Center)
          .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.canRefresh) {
          this.refreshButton()
        }
        this.settingsButton()
      }
      .width('100%')
      .height(44)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .margin({ bottom: 8 })
  }
}

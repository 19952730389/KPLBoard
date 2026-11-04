/* 外观切换器：跟随系统 / 浅色 / 深色
 * ---------------------------------------------------------------------------
 * 顶部栏的外观面板、宽屏左侧导航条底部共用同一个组件，
 * 保证「同一功能、同一套视觉」，不会出现两处样式对不上的情况。
 */
import { Theme } from './Theme';
import { Ui } from './Ui';

@Component
export struct ThemeSwitch {
  @StorageLink('ui.themeMode') themeMode: string = 'dark';

  private setMode(m: string): void {
    if (m === 'light') {
      Theme.apply('light');
      return;
    }
    if (m === 'system') {
      Theme.apply('system');
      return;
    }
    Theme.apply('dark');
  }

  @Builder
  private chip(label: string, key: string) {
    Text(label)
      .fontSize(Ui.FS_SMALL)
      .fontColor(this.themeMode === key ? Ui.ON_GOLD : Ui.MUTED)
      .padding({ left: 6, right: 6, top: 5, bottom: 5 })
      .borderRadius(Ui.R_SM)
      .backgroundColor(this.themeMode === key ? Ui.GOLD : Ui.PANEL_2)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .onClick(() => this.setMode(key))
  }

  build() {
    Row() {
      this.chip('跟随系统', 'system')
      Text('')
        .width(4)
      this.chip('浅色', 'light')
      Text('')
        .width(4)
      this.chip('深色', 'dark')
    }
    .width('100%')
  }
}

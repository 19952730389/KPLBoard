/* 赛事选择器（看板 / 梯度榜 / 选手详情共用）
 * 两级联动：先选年份，再选该年份下的赛事；只列出「离线包里真有数据」的赛事，
 * 避免选了之后空白一片。
 */
import { BundleStore } from '../data/BundleStore';
import { DeviceEnv } from '../common/DeviceEnv';
import { MENU_MATERIAL_OFF, Ui } from '../common/Ui';
import { EventItem, EventsResp } from '../data/Models';

@Component
export struct EventPicker {
  @StorageLink('dev.widthVp') widthVp: number = 360;
  @StorageLink('ui.themeMode') themeMode: string = 'dark';
  @Prop eventId: number = 0;
  kind: string = 'board'; // board | gradient | players
  onPick: (id: number) => void = (): void => {};
  @State private events: EventItem[] = [];
  @State private years: number[] = [];
  @State private year: number = 0;

  aboutToAppear(): void {
    const resp = BundleStore.api<EventsResp>('/api/events');
    const list = resp ? resp.events : [];
    const sorted = list.slice().sort((a: EventItem, b: EventItem) => {
      const sa = a.start ? a.start : '';
      const sb = b.start ? b.start : '';
      if (sa === sb) {
        return (b.year || 0) - (a.year || 0);
      }
      return sa < sb ? 1 : -1;
    });
    // 只保留当前模块真有数据的赛事
    const usable: EventItem[] = [];
    for (let i = 0; i < sorted.length; i++) {
      const ev: EventItem = sorted[i];
      if (this.kind === 'board') {
        usable.push(ev);
      } else if (BundleStore.has(`/api/tools/${this.kind}?event=${ev.id}`)) {
        usable.push(ev);
      }
    }
    this.events = usable;
    const ys: number[] = [];
    for (let i = 0; i < usable.length; i++) {
      const y: number = usable[i].year;
      if (ys.indexOf(y) < 0) {
        ys.push(y);
      }
    }
    this.years = ys;
    if (this.eventId > 0) {
      for (let i = 0; i < usable.length; i++) {
        if (usable[i].id === this.eventId) {
          this.year = usable[i].year;
          break;
        }
      }
    }
    if (this.year === 0 && ys.length > 0) {
      this.year = ys[0];
    }
  }

  private ofYear(): EventItem[] {
    const out: EventItem[] = [];
    for (let i = 0; i < this.events.length; i++) {
      if (this.events[i].year === this.year) {
        out.push(this.events[i]);
      }
    }
    return out;
  }

  private name(): string {
    for (let i = 0; i < this.events.length; i++) {
      if (this.events[i].id === this.eventId) {
        return this.events[i].name;
      }
    }
    const list = this.ofYear();
    return list.length > 0 ? list[0].name : '无数据赛事';
  }

  private yearOpts(): SelectOption[] {
    const out: SelectOption[] = [];
    for (let i = 0; i < this.years.length; i++) {
      const o: SelectOption = { value: String(this.years[i]) };
      out.push(o);
    }
    return out;
  }

  private eventOpts(): SelectOption[] {
    const out: SelectOption[] = [];
    const list = this.ofYear();
    for (let i = 0; i < list.length; i++) {
      const o: SelectOption = { value: list[i].name };
      out.push(o);
    }
    return out;
  }

  private emit(name: string): void {
    const list = this.ofYear();
    for (let i = 0; i < list.length; i++) {
      if (list[i].name === name) {
        this.onPick(list[i].id);
        return;
      }
    }
  }

  build() {
    Row() {
      Column() {
        Text('年份')
          .fontSize(Ui.FS_TINY)
          .fontColor(Ui.MUTED)
        Select(this.yearOpts())
          .value(String(this.year))
          .font({ size: Ui.FS_SMALL })
          .fontColor(Ui.TEXT)
          .optionFontColor(Ui.TEXT)
          .selectedOptionFontColor(Ui.GOLD)
          .optionBgColor(Color.Transparent)
          .selectedOptionBgColor(Ui.PANEL_2)
          .menuBackgroundColor(Ui.PANEL)
          .menuSystemMaterial(MENU_MATERIAL_OFF)
          .menuBackgroundBlurStyleOptions({ colorMode: Ui.MENU_CM })
          .divider({ strokeWidth: 1, color: Ui.LINE, startMargin: 12, endMargin: 12 })
          .backgroundColor(Ui.CONTROL)
          .borderRadius(Ui.R_SM)
          .height(DeviceEnv.tapMinOf(this.widthVp))
          .width('100%')
          .onSelect((index: number, value: string) => {
            this.year = Number(value);
            const list = this.ofYear();
            if (list.length > 0) {
              this.onPick(list[0].id);
            }
          })
      }
      .layoutWeight(1)

      Column() {
        Text('赛事')
          .fontSize(Ui.FS_TINY)
          .fontColor(Ui.MUTED)
        Select(this.eventOpts())
          .value(this.name())
          .font({ size: Ui.FS_SMALL })
          .fontColor(Ui.TEXT)
          .optionFontColor(Ui.TEXT)
          .selectedOptionFontColor(Ui.GOLD)
          .optionBgColor(Color.Transparent)
          .selectedOptionBgColor(Ui.PANEL_2)
          .menuBackgroundColor(Ui.PANEL)
          .menuSystemMaterial(MENU_MATERIAL_OFF)
          .menuBackgroundBlurStyleOptions({ colorMode: Ui.MENU_CM })
          .divider({ strokeWidth: 1, color: Ui.LINE, startMargin: 12, endMargin: 12 })
          .backgroundColor(Ui.CONTROL)
          .borderRadius(Ui.R_SM)
          .height(DeviceEnv.tapMinOf(this.widthVp))
          .width('100%')
          .margin({ left: 8 })
          .onSelect((index: number, value: string) => this.emit(value))
      }
      .layoutWeight(3)
    }
    .width('100%')
  }
}

/* 通用筛选标签行（英雄类型 / 分路 / 装备分类 / 铭文颜色 共用）
 * ---------------------------------------------------------------------------
 * 横向可滑动，选中项用主题金（或指定强调色）实心底，未选中用面板色描边感。
 * 右侧可挂一个小「数量」提示，方便一眼看出每个分类下有多少条数据。
 */
import { Ui } from './Ui';

/** 标签项（ArkTS 不允许无归属对象字面量，用类承载） */
export class ChipOpt {
  key: string;
  label: string;
  /** 选中底色，空 = 主题金 */
  accent: string;
  /** 选中文字色，空 = 金底文字色 */
  on: string;
  /** 标签右侧小字（如命中数量），空 = 不显示 */
  hint: string;

  constructor(key: string, label: string, accent: string, on: string, hint: string) {
    this.key = key;
    this.label = label;
    this.accent = accent;
    this.on = on;
    this.hint = hint;
  }
}

/**
 * 按「预置顺序」排序候选键：order 里出现的先排，其余按数据原序追加在后。
 * 用于让「战士 / 法师 / 刺客 …」这类固定分类每次都同一顺序，不随数据抖动。
 */
export function orderedKeys(present: string[], order: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < order.length; i++) {
    if (present.indexOf(order[i]) >= 0) {
      out.push(order[i]);
    }
  }
  for (let i = 0; i < present.length; i++) {
    if (out.indexOf(present[i]) < 0) {
      out.push(present[i]);
    }
  }
  return out;
}

/** 「全部」标签：统一用 all 作为 key，避免各页各写一套 */
export const CHIP_ALL: string = 'all';

/** 造一个普通标签（选中 = 金底） */
export function chipOf(key: string, label: string, hint: string = ''): ChipOpt {
  return new ChipOpt(key, label, '', '', hint);
}

/** 造一个带强调色的标签（铭文三色等，选中底 = accent，文字 = 白） */
export function chipAccent(key: string, label: string, accent: string, hint: string = ''): ChipOpt {
  return new ChipOpt(key, label, accent, '#ffffff', hint);
}

@Component
export struct ChipRow {
  @StorageLink('ui.themeMode') themeMode: string = 'dark';
  @Prop opts: ChipOpt[] = [];
  @Prop active: string = CHIP_ALL;
  onPick: (key: string) => void = (): void => {};

  private bgOf(c: ChipOpt): string {
    if (this.active !== c.key) {
      return Ui.CONTROL;
    }
    return c.accent.length > 0 ? c.accent : Ui.GOLD;
  }

  private fgOf(c: ChipOpt): string {
    if (this.active !== c.key) {
      return Ui.MUTED;
    }
    return c.on.length > 0 ? c.on : Ui.ON_GOLD;
  }

  @Builder
  private chip(c: ChipOpt) {
    Row() {
      Text(c.label)
        .fontSize(Ui.FS_SMALL)
        .fontColor(this.fgOf(c))
      if (c.hint.length > 0) {
        Text(c.hint)
          .fontSize(Ui.FS_TINY)
          .fontColor(this.fgOf(c))
          .margin({ left: 4 })
      }
    }
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    .borderRadius(14)
    .backgroundColor(this.bgOf(c))
    .margin({ right: 8 })
    .onClick(() => {
      this.onPick(c.key);
    })
  }

  build() {
    Scroll() {
      Row() {
        ForEach(this.opts, (c: ChipOpt) => {
          this.chip(c)
        }, (c: ChipOpt) => `co-${c.key}`)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }
}

/* 视觉基线：配色 + 通用小组件
 * ---------------------------------------------------------------------------
 * 颜色全部走 getter，从 Theme.palette 实时取值——这样深色/浅色切换时，
 * 所有 `Ui.XXX` 的调用点不用改一行就跟着变。
 *
 * 尺寸统一用 vp / fp，由系统按屏幕密度换算，天然适配任意鸿蒙设备。
 */
import { Theme } from './Theme';
import uiMaterial from '@ohos.arkui.uiMaterial';

/* Select 弹出菜单：关闭 API 26 的沉浸系统材质（其样式优先于 backgroundColor，
 * 且跟随系统深浅色而非应用主题——深色应用+浅色系统时会白底白字看不见），
 * 并按应用主题强制菜单材质色模式 */
export const MENU_MATERIAL_OFF: uiMaterial.Material = uiMaterial.Material.empty;

export class Ui {
  /* ---------- 配色（动态，跟随主题） ---------- */
  static get BG(): string { return Theme.palette.bg; }
  static get PANEL(): string { return Theme.palette.panel; }
  static get PANEL_2(): string { return Theme.palette.panel2; }
  static get LINE(): string { return Theme.palette.line; }
  static get TEXT(): string { return Theme.palette.text; }
  static get MUTED(): string { return Theme.palette.muted; }
  static get GOLD(): string { return Theme.palette.gold; }
  static get ON_GOLD(): string { return Theme.palette.onGold; }
  static get RED(): string { return Theme.palette.red; }
  static get GREEN(): string { return Theme.palette.green; }
  static get BLUE(): string { return Theme.palette.blue; }
  static get ORANGE(): string { return Theme.palette.orange; }
  static get BAR(): string { return Theme.palette.bar; }
  static get LIVE_BG(): string { return Theme.palette.liveBg; }
  static get SCRIM(): string { return Theme.palette.scrim; }

  /* 悬浮层（顶部页头 + 底部胶囊）材质：毛玻璃 / 半透明 / 透明
   * 由设置页写 AppStorage['ui.navMaterial']，Index 监听后整树重建；
   * GLASS 提供着色（backgroundColor），BLUR>0 时叠加背板模糊（backgroundEffect），
   * 两者只取其一，避免叠加后不透明度相乘接近实心 */
  static readonly K_MAT: string = 'ui.navMaterial';

  static mat(): string {
    const v = AppStorage.get<string>(Ui.K_MAT);
    if (v === 'translucent' || v === 'transparent') {
      return v;
    }
    return 'glass';
  }

  /* 毛玻璃档下的「沉浸光感」强度：强 / 均衡 / 弱（对齐系统三档）
   * 越强 → 底色越透、模糊半径越大，光感越显著 */
  static readonly K_LEVEL: string = 'ui.navLevel';

  static level(): string {
    const v = AppStorage.get<string>(Ui.K_LEVEL);
    if (v === 'strong' || v === 'weak') {
      return v;
    }
    return 'balanced';
  }

  static get GLASS(): string {
    const d = Theme.isDark();
    const m = Ui.mat();
    if (m === 'transparent') {
      return d ? '#2e141a26' : '#2effffff';
    }
    if (m === 'translucent') {
      return d ? '#b3141a26' : '#d9ffffff';
    }
    /* glass：按光感档位取底色着色透明度（深/浅）
     * 弱 30%/30%（较实）→ 均衡 15%/15% → 强 0%/0%（全透，只剩模糊光效） */
    const lv = Ui.level();
    if (lv === 'strong') {
      return d ? '#00141a26' : '#00ffffff';
    }
    if (lv === 'weak') {
      return d ? '#4d141a26' : '#4dffffff';
    }
    return d ? '#26141a26' : '#26ffffff';
  }

  /** 下拉弹出菜单材质的色模式：跟随应用主题而非系统 */
  static get MENU_CM(): ThemeColorMode {
    return Theme.isDark() ? ThemeColorMode.DARK : ThemeColorMode.LIGHT;
  }

  /** 背板模糊半径：仅毛玻璃档启用，随光感强度变化；0 = 关闭（[0,+∞) 合法）
   *  取系统毛玻璃的常用区间（弱 15 / 均衡 30 / 强 50）：再大已不产生可辨差异，
   *  只增加渲染开销 */
  static get BLUR(): number {
    if (Ui.mat() !== 'glass') {
      return 0;
    }
    const lv = Ui.level();
    if (lv === 'strong') {
      return 50;
    }
    if (lv === 'weak') {
      return 15;
    }
    return 30;
  }

  /** 悬浮层内控件（下拉框 / 输入框 / 标签 / 圆形按钮）的玻璃底：
   * 半透明，让背板模糊透出来；内容区卡片仍用不透明的 PANEL */
  static get CONTROL(): string {
    return Theme.isDark() ? '#a61b2231' : '#b3ffffff';
  }

  static get GLASS_CLEAR(): string { return Theme.isDark() ? '#00141a26' : '#00ffffff'; }
  static get SHADOW(): string { return Theme.isDark() ? 'rgba(0,0,0,0.45)' : 'rgba(15,23,42,0.16)'; }

  /* ---------- 圆角 ---------- */
  static readonly R_SM: number = 8;
  static readonly R_MD: number = 12;
  static readonly R_LG: number = 16;

  /* ---------- 字号（fp） ---------- */
  static readonly FS_TITLE: number = 20;
  static readonly FS_SUB: number = 16;
  static readonly FS_BODY: number = 14;
  static readonly FS_SMALL: number = 12;
  static readonly FS_TINY: number = 10;

  /* ---------- 触控 ---------- */
  static readonly TAP: number = 40;
}

/* ---------------------------------------------------------------------------
 * 图标：内置 SVG 资源（resources/base/media/ic_<name>.svg，24×24 单色 fill），
 * 由 AppIcon 组件经 Image + fillColor 渲染——不再依赖 Shape+Path 的
 * viewPort 缩放（真机上会按物理像素渲染导致图标极小）。
 * ------------------------------------------------------------------------- */
export const ICON_BOARD: string = 'board';
export const ICON_TIER: string = 'tier';
export const ICON_PLAYER: string = 'player';
export const ICON_HERO: string = 'hero';
export const ICON_ITEM: string = 'item';
export const ICON_RUNE: string = 'rune';
export const ICON_PATCH: string = 'patch';
export const ICON_REFRESH: string = 'refresh';
export const ICON_MOON: string = 'moon';
export const ICON_SUN: string = 'sun';
export const ICON_AUTO: string = 'auto';
export const ICON_GEAR: string = 'gear';

/** 百分比 → 展示串（0.917 → 91.7%）；null = 上游未提供（如官方通道无该项）→ 「-」 */
export function pctText(v: number | null | undefined): string {
  if (v === undefined || v === null) {
    return '-';
  }
  const n = v <= 1 ? v * 100 : v;
  return `${n.toFixed(n >= 100 ? 0 : 1)}%`;
}

/** 数字 → 展示串（保留一位小数，整数不加 .0）；null = 上游未提供 → 「-」 */
export function numText(v: number | null | undefined, digits: number = 1): string {
  if (v === undefined || v === null || isNaN(v)) {
    return '-';
  }
  if (Number.isInteger(v)) {
    return String(v);
  }
  return v.toFixed(digits);
}

/** 数值字段 → 展示串：null/undefined → 「-」（官方通道未提供的分均经济等字段） */
export function valText(v: number | null | undefined): string {
  if (v === undefined || v === null || isNaN(v)) {
    return '-';
  }
  return String(v);
}

/** 小局序列 ['A','A','B',null] → 每局胜方标记 */
export function legMark(v: string | null | undefined): string {
  if (v === 'A') return '胜';
  if (v === 'B') return '负';
  return '';
}

/** 状态标签（ArkTS 不允许返回无归属的对象字面量，用类承载） */
export class StatusTag {
  text: string;
  color: string;

  constructor(text: string, color: string) {
    this.text = text;
    this.color = color;
  }
}

/** 赛事状态 → 中文 + 配色 */
export function statusOf(liveFlag: boolean | undefined, over: boolean | undefined): StatusTag {
  if (liveFlag) {
    return new StatusTag('进行中', Ui.RED);
  }
  if (over) {
    return new StatusTag('已结束', Ui.MUTED);
  }
  return new StatusTag('未开始', Ui.BLUE);
}

/** 版本调整方向 → 中文 + 配色（增强绿 / 削弱红 / 调整蓝） */
export function dirOf(dir: string | undefined): StatusTag {
  if (dir === 'buff') {
    return new StatusTag('增强', Ui.GREEN);
  }
  if (dir === 'nerf') {
    return new StatusTag('削弱', Ui.RED);
  }
  if (dir === 'adjust') {
    return new StatusTag('调整', Ui.BLUE);
  }
  return new StatusTag('改动', Ui.MUTED);
}

/** 概览指标（ArkTS 里用类承载复合数据，避免无归属的对象字面量） */
export class Kpi {
  key: string;
  value: string;

  constructor(key: string, value: string) {
    this.key = key;
    this.value = value;
  }
}

/** 时间戳 → HH:mm 展示串 */
export function clockText(ms: number | undefined): string {
  if (!ms || ms <= 0) {
    return '';
  }
  const d: Date = new Date(ms);
  const h: number = d.getHours();
  const m: number = d.getMinutes();
  const hs: string = h < 10 ? '0' + h : String(h);
  const ms2: string = m < 10 ? '0' + m : String(m);
  return `${hs}:${ms2}`;
}

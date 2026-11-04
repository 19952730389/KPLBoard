/* 外观主题：深色 / 浅色 / 跟随系统
 * ---------------------------------------------------------------------------
 * 设计思路（为了「一行不改老代码」）：
 *  ① Palette 是纯值对象，只有两套：PALETTE_DARK / PALETTE_LIGHT；
 *  ② Ui 里的颜色全部改写成 getter，实时从 Theme.palette 取值，
 *     所以 `Ui.BG` / `Ui.PANEL` 这些老写法不用动就能跟着换肤；
 *  ③ 切换时写 AppStorage['ui.themeMode']，凡是挂了
 *     @StorageLink('ui.themeMode') 的组件都会被动重渲染 → 重新取色 → 生效；
 *  ④ 选择结果走 PersistentStorage 落盘（EntryAbility.onCreate 里注册），
 *     冷启动保持上次选择；
 *  ⑤ 「跟随系统」读 EntryAbility 写进 AppStorage['sys.colorMode'] 的值，
 *     系统深浅色变化由 onConfigurationUpdate 回写。
 */
export type ThemeMode = 'dark' | 'light' | 'system';

/** 一套完整配色 */
export class Palette {
  bg: string;        // 页面底色
  panel: string;     // 卡片/面板
  panel2: string;    // 内层块（标签底、展开区）
  line: string;      // 分割线 / 描边
  text: string;      // 主文字
  muted: string;     // 次要文字
  gold: string;      // 品牌金（强调）
  onGold: string;    // 金色底上的文字色（保证对比度）
  red: string;
  green: string;
  blue: string;
  orange: string;
  bar: string;       // 底部导航条 / 侧栏底色
  liveBg: string;    // 「进行中」这类高亮卡的底色
  scrim: string;     // 遮罩

  constructor(
    bg: string,
    panel: string,
    panel2: string,
    line: string,
    text: string,
    muted: string,
    gold: string,
    onGold: string,
    red: string,
    green: string,
    blue: string,
    orange: string,
    bar: string,
    liveBg: string,
    scrim: string
  ) {
    this.bg = bg;
    this.panel = panel;
    this.panel2 = panel2;
    this.line = line;
    this.text = text;
    this.muted = muted;
    this.gold = gold;
    this.onGold = onGold;
    this.red = red;
    this.green = green;
    this.blue = blue;
    this.orange = orange;
    this.bar = bar;
    this.liveBg = liveBg;
    this.scrim = scrim;
  }
}

/* 深色：与桌面端一致的深空蓝 + 品牌金 */
export const PALETTE_DARK: Palette = new Palette(
  '#0b0e17',
  '#141a26',
  '#1b2231',
  '#26303f',
  '#e8edf7',
  '#8a97ad',
  '#f5c451',
  '#0b0e17',
  '#ff5f57',
  '#3ddc84',
  '#5aa9ff',
  '#ff9f43',
  '#101623',
  '#2a1c22',
  '#000000'
);

/* 浅色：白底 + 压暗的品牌金（金色在白底上必须降明度才够对比度） */
export const PALETTE_LIGHT: Palette = new Palette(
  '#f2f4f9',
  '#ffffff',
  '#eef1f8',
  '#dde3ee',
  '#111827',
  '#5c6879',
  '#a8680c',
  '#ffffff',
  '#d92d20',
  '#067647',
  '#175cd3',
  '#b54708',
  '#ffffff',
  '#fdeceb',
  '#0b0e17'
);

export class Theme {
  /** AppStorage 键：当前模式（dark / light / system） */
  static readonly K_MODE: string = 'ui.themeMode';
  /** AppStorage 键：系统当前深浅色（由 EntryAbility 写入） */
  static readonly K_SYS: string = 'sys.colorMode';

  static mode: ThemeMode = 'dark';
  static palette: Palette = PALETTE_DARK;

  /** 冷启动：把落盘的选择恢复出来 */
  static init(): void {
    Theme.apply(Theme.saved());
  }

  private static saved(): ThemeMode {
    const v = AppStorage.get<string>(Theme.K_MODE);
    if (v === 'light' || v === 'system') {
      return v;
    }
    return 'dark';
  }

  /** 当前「实际生效」的深浅（system 会被解析成具体值） */
  static isDark(): boolean {
    if (Theme.mode === 'system') {
      const s = AppStorage.get<string>(Theme.K_SYS);
      return s !== 'light'; // 未取到时按深色处理，与 App 默认一致
    }
    return Theme.mode === 'dark';
  }

  /** 切换并广播：写 AppStorage 触发所有订阅者重渲染 */
  static apply(mode: ThemeMode): void {
    Theme.mode = mode;
    Theme.palette = Theme.isDark() ? PALETTE_DARK : PALETTE_LIGHT;
    AppStorage.setOrCreate<string>(Theme.K_MODE, mode);
  }

  /** 系统深浅色变化时（仅 system 模式需要重算） */
  static syncSystem(): void {
    if (Theme.mode === 'system') {
      Theme.palette = Theme.isDark() ? PALETTE_DARK : PALETTE_LIGHT;
      AppStorage.setOrCreate<string>(Theme.K_MODE, 'system');
    }
  }

  static label(): string {
    if (Theme.mode === 'light') {
      return '浅色';
    }
    if (Theme.mode === 'system') {
      return '跟随系统';
    }
    return '深色';
  }

  /** 用于「点一下换一个」的循环顺序 */
  static next(): ThemeMode {
    if (Theme.mode === 'dark') {
      return 'light';
    }
    if (Theme.mode === 'light') {
      return 'system';
    }
    return 'dark';
  }
}

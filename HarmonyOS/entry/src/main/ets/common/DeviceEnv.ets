/* 屏幕适配基线（鸿蒙官方断点体系）
 * ---------------------------------------------------------------------------
 * 鸿蒙的长度单位 vp / fp 已经按屏幕密度自动换算：
 *   物理像素 = vp × (屏幕 PPI / 160)
 * 所以 Mate 60 Pro+（≈439 PPI，densityPixels≈2.75）与平板（≈264 PPI）上，
 * 同一个 16vp 的字在物理世界里是「一样大」的，不需要像 Web 那样手写 DPR 换算，
 * 也不会出现高密屏发糊 / 低密屏元素过粗的问题。
 *
 * 需要代码介入的只有「布局分档」：窗口有多宽决定几列、是否分栏。
 * 这里用鸿蒙官方三段式断点（单位 vp）：
 *     sm  < 600     手机竖屏           单列 + 底部页签
 *     md  600–839   手机横屏 / 平板竖屏  多列，仍单页
 *     lg  >= 840    平板横屏 / 折叠屏展开  左右分栏（列表 + 详情）
 *
 * 数值由 EntryAbility 在窗口尺寸变化 / 安全区变化时写进 AppStorage，
 * 页面用 @StorageLink 订阅，横竖屏切换、分屏、折叠屏开合都会自动重排。
 */
import { display } from '@kit.ArkUI';

export type BpName = 'sm' | 'md' | 'lg';

export class DeviceEnv {
  /** 断点阈值（单位 vp） */
  static readonly SM_MAX: number = 600;
  static readonly MD_MAX: number = 840;

  /* AppStorage 键名 */
  static readonly K_WIDTH: string = 'dev.widthVp';
  static readonly K_HEIGHT: string = 'dev.heightVp';
  static readonly K_BP: string = 'dev.bp';
  static readonly K_DPR: string = 'dev.dpr';
  static readonly K_PORTRAIT: string = 'dev.portrait';
  static readonly K_SAFE_TOP: string = 'dev.safeTop';
  static readonly K_SAFE_BOTTOM: string = 'dev.safeBottom';
  static readonly K_SAFE_LEFT: string = 'dev.safeLeft';
  static readonly K_SAFE_RIGHT: string = 'dev.safeRight';

  static bpOf(widthVp: number): BpName {
    if (widthVp < DeviceEnv.SM_MAX) {
      return 'sm';
    }
    if (widthVp < DeviceEnv.MD_MAX) {
      return 'md';
    }
    return 'lg';
  }

  /** 页面左右留白 */
  static pad(bp: BpName): number {
    return bp === 'sm' ? 12 : bp === 'md' ? 18 : 24;
  }

  /** 栅格间距 */
  static gutter(bp: BpName): number {
    return bp === 'sm' ? 8 : bp === 'md' ? 12 : 16;
  }

  /** 卡片最小宽度：配合 Grid 的 minCount 实现「不拉伸、不留白」的自适应列数 */
  static cardMin(bp: BpName): number {
    return bp === 'sm' ? 150 : bp === 'md' ? 168 : 190;
  }

  /** 触控热区最小尺寸（魅族/鸿蒙人机规范：不小于 40vp） */
  static tapMin(bp: BpName): number {
    return bp === 'sm' ? 44 : 40;
  }

  /** 当前屏幕密度（1 = 160 PPI）。高密屏取更清晰的图片档位时会用到 */
  static density(): number {
    try {
      const d = display.getDefaultDisplaySync().densityPixels;
      return d > 0 ? d : 1;
    } catch (e) {
      return 1;
    }
  }

  /** 是否宽屏（决定是否启用左右分栏） */
  static isWide(bp: BpName): boolean {
    return bp === 'lg';
  }

  /* 下面几个 *Of 是「给 build() 用」的快捷版：
   * ArkTS 的 build() 只允许一个根容器语句，不能在里面写 const 局部变量，
   * 所有适配值都必须通过成员方法/属性表达式取，所以统一提供按窗口宽度直接取值的入口。
   */
  static padOf(widthVp: number): number {
    return DeviceEnv.pad(DeviceEnv.bpOf(widthVp));
  }

  static gutOf(widthVp: number): number {
    return DeviceEnv.gutter(DeviceEnv.bpOf(widthVp));
  }

  static wideOf(widthVp: number): boolean {
    return DeviceEnv.isWide(DeviceEnv.bpOf(widthVp));
  }

  static tapMinOf(widthVp: number): number {
    return DeviceEnv.tapMin(DeviceEnv.bpOf(widthVp));
  }

  static cardMinOf(widthVp: number): number {
    return DeviceEnv.cardMin(DeviceEnv.bpOf(widthVp));
  }
}

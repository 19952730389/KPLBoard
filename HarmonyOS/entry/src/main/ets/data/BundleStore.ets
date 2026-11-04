/* 离线数据层：离线包为底 + 联网结果覆盖
 * ---------------------------------------------------------------------------
 * 离线包目录（由 tools/sync-mobile-assets.js --native 同步进 rawfile）：
 *   bundle/api/index.json      接口键 → 快照文件名
 *   bundle/api/*.json          368 个接口快照（赛事 / 看板 / 梯度 / 选手 / 英雄 …）
 *   bundle/img/resolve.json    图片基址 → 可选宽度档位
 *   bundle/img/*               2034 张本地图
 *
 * 读取用 resourceManager.getRawFileContentSync（同步），配合
 *  ① 文本缓存（同一份 JSON 不重复解码）
 *  ② 解析结果缓存
 * 保证大列表（133 英雄 / 200+ 选手）来回切换也不卡。
 *
 * 联网（NetStore）拉到新数据后调 putNet 写进「内存覆盖层」，
 * api() 会优先返回覆盖层里的数据——页面代码不用改就能显示实时数据。
 */
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { util } from '@kit.ArkTS';

export class BundleStore {
  private static resMgr: resourceManager.ResourceManager | null = null;
  private static decoder: util.TextDecoder | null = null;
  private static apiIndex: Record<string, string> | null = null;
  private static cache: Map<string, Object> = new Map<string, Object>();
  private static miss: Set<string> = new Set<string>();
  /** 联网覆盖层：接口键 → 最新数据（NetStore 拉到 / 本机缓存恢复时写入） */
  private static netCache: Map<string, Object> = new Map<string, Object>();

  static init(ctx: common.UIAbilityContext): void {
    try {
      BundleStore.resMgr = ctx.resourceManager;
    } catch (e) {
      BundleStore.resMgr = null;
    }
    try {
      BundleStore.decoder = new util.TextDecoder('utf-8');
    } catch (e) {
      BundleStore.decoder = null;
    }
  }

  /** 读 rawfile 里的文本文件 */
  static text(path: string): string {
    const rm = BundleStore.resMgr;
    if (!rm) {
      return '';
    }
    try {
      const raw: Uint8Array = rm.getRawFileContentSync(path);
      const dec = BundleStore.decoder;
      if (dec) {
        return dec.decodeToString(raw);
      }
      // 兜底：手工解码 UTF-8（正常走不到这里）
      let s: string = '';
      for (let i = 0; i < raw.length; i++) {
        s += String.fromCharCode(raw[i]);
      }
      return s;
    } catch (e) {
      return '';
    }
  }

  /** 读 rawfile 里的二进制（图片懒拷贝用） */
  static rawBytes(path: string): Uint8Array {
    const rm = BundleStore.resMgr;
    if (!rm) {
      return new Uint8Array(0);
    }
    try {
      return rm.getRawFileContentSync(path);
    } catch (e) {
      return new Uint8Array(0);
    }
  }

  /** 读并解析 JSON，带缓存 */
  static json<T>(path: string): T | null {
    if (BundleStore.miss.has(path)) {
      return null;
    }
    const hit = BundleStore.cache.get(path);
    if (hit !== undefined) {
      return hit as T;
    }
    const txt = BundleStore.text(path);
    if (!txt) {
      BundleStore.miss.add(path);
      return null;
    }
    try {
      const val = JSON.parse(txt) as T;
      BundleStore.cache.set(path, val as Object);
      return val;
    } catch (e) {
      BundleStore.miss.add(path);
      return null;
    }
  }

  /** 接口键 → 快照文件名 */
  private static index(): Record<string, string> {
    if (BundleStore.apiIndex) {
      return BundleStore.apiIndex;
    }
    const idx = BundleStore.json<Record<string, string>>('bundle/api/index.json');
    BundleStore.apiIndex = idx ? idx : {};
    return BundleStore.apiIndex;
  }

  /** 按网页版的接口键取数据，例：api('/api/board?event=1201')
   *  先取联网覆盖层（最新），再取包内离线快照。 */
  static api<T>(key: string): T | null {
    const netHit = BundleStore.netCache.get(key);
    if (netHit !== undefined) {
      return netHit as T;
    }
    const idx = BundleStore.index();
    const file = idx[key];
    if (!file) {
      return null;
    }
    return BundleStore.json<T>('bundle/api/' + file);
  }

  /** 写入联网结果（泛型版） */
  static putNet<T>(key: string, val: T): void {
    if (val === null || val === undefined) {
      return;
    }
    BundleStore.netCache.set(key, val as Object);
  }

  /** 写入联网结果（已解析成 Object 的场合，缓存恢复时用） */
  static putNetAsObject(key: string, val: Object): void {
    BundleStore.netCache.set(key, val);
  }

  /** 该接口是否已有联网数据 */
  static fromNet(key: string): boolean {
    return BundleStore.netCache.has(key);
  }

  /** 是否收录了某个接口（用于灰掉不可用的筛选项） */
  static has(key: string): boolean {
    const idx = BundleStore.index();
    return idx[key] !== undefined;
  }
}

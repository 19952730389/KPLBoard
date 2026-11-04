/* 图片仓库：把「远端图片地址」翻译成「本机可显示的本地文件」
 * ---------------------------------------------------------------------------
 * 网页版是靠 /api/tools/img?u=<远端地址> 走服务端代理 + 本地仓库；
 * 原生版没有服务端，改成三步：
 *   1) 查 bundle/img/resolve.json（基址 → 若干宽度档位），按屏幕密度挑最合适的一档
 *      —— 高密屏（Mate 60 Pro+ densityPixels≈2.75）会挑 2~3 倍宽度的图，清晰不发虚；
 *         没有更清晰的档位时取现存最大档，**绝不反向降质**。
 *   2) 首次用到时才从 rawfile 拷进应用缓存目录（懒拷贝，不拖慢启动）
 *   3) 用 fileUri 转成 Image 组件能吃的地址
 *
 * 另外：ArkUI 的 Image 会按组件的 vp 尺寸 × 屏幕密度取图，配合上面按密度挑档，
 * 两层保证「不拉伸变形、不模糊、也不浪费内存」。
 */
import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { display } from '@kit.ArkUI';
import { BundleStore } from './BundleStore';

interface ImgVar {
  w: number;
  f: string;
}

interface ImgEntry {
  vars: ImgVar[];
}

class ImgRef {
  base: string;
  want: number;

  constructor(base: string, want: number) {
    this.base = base;
    this.want = want;
  }
}

export class ImageRepo {
  private static dir: string = '';
  private static idx: Record<string, ImgEntry> | null = null;
  private static dpr: number = 2;
  private static ready: Set<string> = new Set<string>();
  private static failed: Set<string> = new Set<string>();

  static init(ctx: common.UIAbilityContext): void {
    ImageRepo.dir = ctx.cacheDir + '/kplimg';
    try {
      fileIo.mkdirSync(ImageRepo.dir);
    } catch (e) {
      /* 已存在或创建失败：懒拷贝时再试 */
    }
    try {
      const d = display.getDefaultDisplaySync().densityPixels;
      ImageRepo.dpr = d > 0 ? Math.min(d, 3) : 2;
    } catch (e) {
      ImageRepo.dpr = 2;
    }
  }

  private static index(): Record<string, ImgEntry> {
    if (ImageRepo.idx) {
      return ImageRepo.idx;
    }
    const j = BundleStore.json<Record<string, ImgEntry>>('bundle/img/resolve.json');
    ImageRepo.idx = j ? j : {};
    return ImageRepo.idx;
  }

  /** 从 .../thumbnail/288x/xxx.jpg 里拆出基址与目标宽度 */
  private static parse(url: string): ImgRef {
    const re = /^(.*?)\?imageMogr2\/thumbnail\/(\d+)x/i;
    const m = re.exec(url);
    if (m && m.length >= 3) {
      return new ImgRef(m[1], Number(m[2]));
    }
    return new ImgRef(url, 0);
  }

  private static pick(entry: ImgEntry, want: number): string {
    const target: number = Math.ceil(want * ImageRepo.dpr);
    let upW: number = -1;
    let upF: string = '';
    let maxW: number = -1;
    let maxF: string = '';
    for (let i = 0; i < entry.vars.length; i++) {
      const v: ImgVar = entry.vars[i];
      if (v.w >= target && (upW < 0 || v.w < upW)) {
        upW = v.w;
        upF = v.f;
      }
      if (v.w > maxW) {
        maxW = v.w;
        maxF = v.f;
      }
    }
    return upW >= 0 ? upF : maxF;
  }

  /** 懒拷贝：rawfile → cacheDir，只做一次 */
  private static materialize(file: string): string {
    const dst: string = ImageRepo.dir + '/' + file;
    if (ImageRepo.ready.has(dst)) {
      return dst;
    }
    if (ImageRepo.failed.has(dst)) {
      return '';
    }
    try {
      const data: Uint8Array = BundleStore.rawBytes('bundle/img/' + file);
      if (!data || data.length === 0) {
        ImageRepo.failed.add(dst);
        return '';
      }
      try {
        fileIo.mkdirSync(ImageRepo.dir);
      } catch (e) {
        /* 目录已存在 */
      }
      const f = fileIo.openSync(dst, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, data.buffer);
      fileIo.closeSync(f);
      ImageRepo.ready.add(dst);
      return dst;
    } catch (e) {
      ImageRepo.failed.add(dst);
      return '';
    }
  }

  /**
   * 远端地址 → 本地 URI（可直接喂给 Image）
   * @param remote 原始数据里的图片地址
   * @returns 本地文件 URI；找不到返回空串（页面应显示占位）
   */
  static src(remote: string | undefined, wantHint?: number): string {
    if (!remote) {
      return '';
    }
    const idx: Record<string, ImgEntry> = ImageRepo.index();
    const p = ImageRepo.parse(remote);
    if (p.want <= 0 && wantHint !== undefined && wantHint > 0) {
      p.want = wantHint;
    }
    if (p.want <= 0) {
      p.want = 120; // 地址里没写目标宽度时按常规缩略图尺寸取档
    }
    const entry: ImgEntry | undefined = idx[p.base];
    if (!entry || !entry.vars || entry.vars.length === 0) {
      return '';
    }
    const file: string = ImageRepo.pick(entry, p.want);
    if (!file) {
      return '';
    }
    const path: string = ImageRepo.materialize(file);
    if (!path) {
      return '';
    }
    try {
      return fileUri.getUriFromPath(path);
    } catch (e) {
      return path;
    }
  }
}

/* 联网数据层：实时拉取 + 三级回退
 * ---------------------------------------------------------------------------
 * 优先级：网络 → 本机缓存（上次联网成功的结果）→ 包内离线快照
 *
 *  ① 手动刷新 / 进入页面时调用 NetStore.refresh<T>('/api/xxx')；
 *  ② 成功：把结果写进 BundleStore 的内存覆盖层（这样页面里原有的
 *     `BundleStore.api<T>(key)` 一行都不用改，下次渲染自动用新数据），
 *     同时落盘到 cacheDir，冷启动也能先看到上次联网的结果；
 *  ③ 失败（没配地址 / 无网 / 超时 / 非 200）：静默回退到离线数据，
 *     并把错误原因返回给页面，显示在顶部状态行上，绝不弹错误框打断使用。
 *
 * 接口地址：AppStorage['api.baseUrl']，默认见 DEFAULT_BASE，
 * 可在任意页面的顶部条「外观 / 数据源」里改，改完立即生效并持久化。
 */
import { common } from '@kit.AbilityKit';
import { http, connection } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BundleStore } from './BundleStore';
import { ToolsUpstream } from './ToolsUpstream';

/** 拉取结果：ok 表示来自网络；data 永远尽量给一份（失败时给离线兜底） */
export class NetResult<T> {
  ok: boolean;
  data: T | null;
  from: string; // net | offline
  error: string;
  at: number; // 最近一次联网成功的时间戳（0 = 从未联网）

  constructor(ok: boolean, data: T | null, from: string, error: string, at: number) {
    this.ok = ok;
    this.data = data;
    this.from = from;
    this.error = error;
    this.at = at;
  }
}

export class NetStore {
  /** 预留的备用数据源基址（看板页已改为端内直连公网，不再依赖此配置；
   *  留空 = 工具类页面直接走离线包，不发无效请求） */
  static readonly DEFAULT_BASE: string = '';
  static readonly K_BASE: string = 'api.baseUrl';
  static readonly TIMEOUT: number = 8000;

  private static dir: string = '';
  private static stamp: Map<string, number> = new Map<string, number>();

  static init(ctx: common.UIAbilityContext): void {
    NetStore.dir = ctx.cacheDir + '/kplnet';
    try {
      fileIo.mkdirSync(NetStore.dir);
    } catch (e) {
      /* 已存在 */
    }
    NetStore.restore();
  }

  /** 当前生效的接口基址；空串 = 纯离线 */
  static base(): string {
    const v = AppStorage.get<string>(NetStore.K_BASE);
    if (v === undefined || v === null) {
      return NetStore.DEFAULT_BASE;
    }
    return v.trim();
  }

  static stampOf(key: string): number {
    const v = NetStore.stamp.get(key);
    return v === undefined ? 0 : v;
  }

  /** 设备是否联网（只用于决定要不要发请求，失败不打断） */
  static async online(): Promise<boolean> {
    try {
      const has: boolean = await connection.hasDefaultNet();
      return has;
    } catch (e) {
      return false;
    }
  }

  /**
   * 拉一次接口：成功走网络并落缓存，失败回退离线快照。
   * 数据源优先级：端内直连官方上游（工具页 / 版本动态）→ 自建服务基址 → 本机缓存 → 离线快照。
   * @param key 与离线包一致的接口键，例如 '/api/tools/items'
   * @param bust true = 绕过内存缓存强制重拉
   */
  static async refresh<T>(key: string, bust: boolean = false): Promise<NetResult<T>> {
    // ① 端内直连官方上游（pvp.qq.com 等）：不依赖任何自建服务
    const up: Object | null = await ToolsUpstream.fetch(key, bust);
    if (up !== null) {
      try {
        BundleStore.putNetAsObject(key, up);
        NetStore.persist(key, JSON.stringify(up));
        const at: number = Date.now();
        NetStore.stamp.set(key, at);
        return new NetResult<T>(true, up as T, 'net', '', at);
      } catch (e) {
        /* 落盘失败不影响本次结果 */
      }
    }
    // ② 自建服务基址（备用通道，默认关闭）
    const base: string = NetStore.base();
    if (base.length === 0) {
      return new NetResult<T>(false, BundleStore.api<T>(key), 'offline', '未配置数据源', NetStore.stampOf(key));
    }
    let url: string = base + key;
    if (bust) {
      url += (key.indexOf('?') >= 0 ? '&' : '?') + 't=' + String(Date.now());
    }
    const req: http.HttpRequest = http.createHttp();
    try {
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: { 'Accept': 'application/json' },
        connectTimeout: NetStore.TIMEOUT,
        readTimeout: NetStore.TIMEOUT,
      };
      const resp: http.HttpResponse = await req.request(url, opt);
      if (resp.responseCode === 200) {
        const txt: string = typeof resp.result === 'string' ? resp.result : '';
        if (txt.length > 0) {
          const data: T = JSON.parse(txt) as T;
          BundleStore.putNet<T>(key, data);
          NetStore.persist(key, txt);
          const at: number = Date.now();
          NetStore.stamp.set(key, at);
          return new NetResult<T>(true, data, 'net', '', at);
        }
      }
      return new NetResult<T>(
        false,
        BundleStore.api<T>(key),
        'offline',
        `HTTP ${resp.responseCode}`,
        NetStore.stampOf(key)
      );
    } catch (e) {
      return new NetResult<T>(false, BundleStore.api<T>(key), 'offline', '网络不可用', NetStore.stampOf(key));
    } finally {
      try {
        req.destroy();
      } catch (e) {
        /* 忽略 */
      }
    }
  }

  /* ---------------- 本机缓存（cacheDir） ---------------- */

  private static fileOf(key: string): string {
    let s: string = '';
    for (let i = 0; i < key.length; i++) {
      const c: string = key.charAt(i);
      if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
        s += c;
      } else {
        s += '_';
      }
    }
    return s + '.json';
  }

  private static readText(path: string): string {
    try {
      const f: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const st: fileIo.Stat = fileIo.statSync(path);
      const buf: ArrayBuffer = new ArrayBuffer(st.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const dec: util.TextDecoder = new util.TextDecoder('utf-8');
      return dec.decodeToString(new Uint8Array(buf));
    } catch (e) {
      return '';
    }
  }

  private static writeText(path: string, txt: string): boolean {
    try {
      const f: fileIo.File = fileIo.openSync(
        path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
      fileIo.writeSync(f.fd, txt);
      fileIo.closeSync(f);
      return true;
    } catch (e) {
      return false;
    }
  }

  private static persist(key: string, txt: string): void {
    if (!NetStore.dir) {
      return;
    }
    const file: string = NetStore.fileOf(key);
    if (!NetStore.writeText(NetStore.dir + '/' + file, txt)) {
      return;
    }
    // 索引：文件名 → 接口键（冷启动时靠它反查）
    let map: Record<string, string> = {};
    const idxTxt: string = NetStore.readText(NetStore.dir + '/index.json');
    if (idxTxt) {
      try {
        map = JSON.parse(idxTxt) as Record<string, string>;
      } catch (e) {
        map = {};
      }
    }
    map[file] = key;
    NetStore.writeText(NetStore.dir + '/index.json', JSON.stringify(map));
  }

  /** 冷启动：把上次联网成功的数据灌回内存覆盖层 */
  private static restore(): void {
    if (!NetStore.dir) {
      return;
    }
    const idxTxt: string = NetStore.readText(NetStore.dir + '/index.json');
    if (!idxTxt) {
      return;
    }
    let map: Record<string, string> = {};
    try {
      map = JSON.parse(idxTxt) as Record<string, string>;
    } catch (e) {
      return;
    }
    const files: string[] = Object.keys(map);
    for (let i = 0; i < files.length; i++) {
      const key: string = map[files[i]];
      const txt: string = NetStore.readText(NetStore.dir + '/' + files[i]);
      if (!txt) {
        continue;
      }
      try {
        const val: Object = JSON.parse(txt) as Object;
        BundleStore.putNetAsObject(key, val);
        const st: fileIo.Stat = fileIo.statSync(NetStore.dir + '/' + files[i]);
        NetStore.stamp.set(key, st.mtime);
      } catch (e) {
        /* 单条坏数据不影响其它 */
      }
    }
  }
}

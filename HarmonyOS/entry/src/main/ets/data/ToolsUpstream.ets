/* 工具页端内直连上游数据（无需桌面端中转）
 * ---------------------------------------------------------------------------
 * 上游与桌面端 KPLBoard 同源：
 *   · 王者荣耀官网 pvp.qq.com：英雄列表 / 装备 / 铭文 / 英雄详情（技能·属性·故事）
 *   · 王者荣耀官网公告 apps.game.qq.com：版本动态（公告列表 + 正文结构化解析）
 *   · KPL 官方统计 kplshop-op.timi-esports.qq.com（kpl.qq.com 同款 RPC）：
 *     2023 年及以后赛季的梯度榜 / 选手榜（含 2026 KPL 年度总决赛）
 *   · 玩加 wanplus.cn：2016~2022 赛季的逐选手英雄池（官方未收录的更早赛季）
 * 输出与离线包 /api/tools/*、/api/patch 同构，页面零改动。
 *
 * 缓存：内存 TTL + NetStore 落盘（刷新成功即写 cacheDir，冷启动可读）。
 * 梯度榜 / 选手详情优先级：KPL 官方 → 玩加 → 随包离线种子。
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BundleStore } from './BundleStore';
import {
  GradientItem,
  GradientResp,
  HeroAttr,
  HeroBrief,
  HeroDetail,
  HeroSkill,
  HeroesResp,
  HeroResp,
  ItemRow,
  ItemsResp,
  PatchChange,
  PatchDetail,
  PatchNote,
  PatchResp,
  PlayerItem,
  PlayerPoolItem,
  PlayersResp,
  RuneColor,
  RuneItem,
  RunesResp,
  SkinItem,
} from './Models';

const UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const TIMEOUT: number = 15000;

const URL_HERO_LIST: string = 'https://pvp.qq.com/web201605/js/herolist.json';
const URL_ITEM_LIST: string = 'https://pvp.qq.com/web201605/js/item.json';
const URL_MING_LIST: string = 'https://pvp.qq.com/web201605/js/ming.json';
const URL_PATCH_LIST: string = 'https://apps.game.qq.com/wmp/v3.1/';
const URL_PATCH_DETAIL: string = 'https://apps.game.qq.com/wmp/v3.1/public/searchNews.php';
const URL_WP_PAGE: string = 'https://wanplus.cn/kog/teamstats';
const URL_WP_REFERER: string = 'https://wanplus.cn/kog/teamstats';
const GAME_ID: number = 18;

/* KPL 官方统计接口（kpl.qq.com 官网同款 RPC，与 iOS 版 KPLStatsSource 同源） */
const URL_KPL_RPC: string = 'https://kplshop-op.timi-esports.qq.com/kplow/';
const KPL_HEADERS: Record<string, string> = {
  'User-Agent': UA,
  'Content-Type': 'application/json',
  'Accept': 'application/json, text/plain, */*',
  'Origin': 'https://kpl.qq.com',
  'Referer': 'https://kpl.qq.com/',
};

/** App 赛事 id → 官方 seasonid。
 *
 *  只收录 **KPL 正赛**：官方赛季清单里没有独立条目的赛事（预选赛 / 席位赛 /
 *  KGL / KRKPL / 甲级 / 资格赛 / 亚运 / 世冠 / 挑战者杯）不在此表——硬塞会张冠李戴。
 *  ⚠️ 官方 getHeroRankList / getSeasonPlayerPerf 只覆盖 **2023 年起**的赛季
 *  （2022 及更早返回空列表），更早赛季由玩加通道负责（其数据本就完整）。 */
const KPL_SEASON: Map<string, string> = new Map<string, string>([
  ['1201', 'KPL2026S3'],   // 2026 KPL年度总决赛
  ['1172', 'KPL2026S2'],   // 2026KPL夏季赛
  ['1167', 'KPL2026S1'],   // 2026KPL春季赛
  ['1162', 'KPL2025S3'],   // 2025KPL年度总决赛
  ['1158', 'KPL2025S2'],   // 2025KPL夏季赛
  ['1155', 'KPL2025S1'],   // 2025KPL春季赛
  ['1148', 'KPL2024S3'],   // 2024年王者荣耀KPL年度总决赛
  ['1144', 'KPL2024S2'],   // 2024 KPL 夏季赛
  ['1140', 'KPL2024S1'],   // 2024KPL春季赛
  ['1128', 'KPL2023S2'],   // 2023 KPL夏季赛
  ['1124', 'KPL2023S1'],   // 2023 KPL春季赛
]);

/** 官方 position → 分路。
 *  ⚠️ 与上面的 LANE **不是同一套编号**：官方是 2=中路 / 3=发育路 / 4=打野，
 *  而 LANE 是 2=打野 / 3=中路 / 4=发育路。混用会把选手分路整列标错
 *  （实测：妖刀 position=3 是射手/发育路，按 LANE 会标成「中路」）。 */
const KPL_LANE_OF_POSITION: Map<number, string> = new Map<number, string>([
  [1, '对抗路'], [2, '中路'], [3, '发育路'], [4, '打野'], [5, '游走'],
]);

/** 逐小局抓取上限：历史大赛季动辄上百场，逐场抓取既慢又无必要
 *  （那些赛季玩加 / 种子已有数据）。当前赛季场次有限，60 场足够覆盖。 */
const KPL_ROUND_LIMIT: number = 60;
/** 逐小局并发批大小（控制上游压力） */
const KPL_ROUND_BATCH: number = 6;

const heroDetailUrl = (e: string): string => `https://pvp.qq.com/web201605/herodetail/${e}.shtml`;
const heroIconUrl = (e: string): string => `https://game.gtimg.cn/images/yxzj/img201606/heroimg/${e}/${e}.jpg`;
const heroSkinUrl = (e: string, n: number): string =>
  `https://game.gtimg.cn/images/yxzj/img201606/skin/hero-info/${e}/${e}-bigskin-${n}.jpg`;
const skillIconUrl = (e: string, code: string): string =>
  `https://game.gtimg.cn/images/yxzj/img201606/heroimg/${e}/${code}.png`;
const itemIconUrl = (id: string): string => `https://game.gtimg.cn/images/yxzj/img201606/itemimg/${id}.jpg`;
const mingIconUrl = (id: string): string => `https://game.gtimg.cn/images/yxzj/img201606/mingwen/${id}.png`;
const newsUrl = (id: string): string => `https://pvp.qq.com/web201706/newsdetail.shtml?tid=${id}`;

const HERO_TYPE: Map<number, string> = new Map<number, string>([
  [1, '战士'], [2, '法师'], [3, '坦克'], [4, '刺客'], [5, '射手'], [6, '辅助'],
]);
const LANE: Map<number, string> = new Map<number, string>([
  [1, '对抗路'], [2, '打野'], [3, '中路'], [4, '发育路'], [5, '游走'],
]);
const ITEM_TYPE: Map<number, string> = new Map<number, string>([
  [1, '攻击'], [2, '法术'], [3, '防御'], [4, '移动'], [5, '打野'], [7, '游走'],
]);
const RUNE_COLORS: RuneColor[] = [
  { key: 'red', name: '红色', short: '红', accent: '#ff5f6d', desc: '攻击向：物理攻击 / 法术攻击 / 穿透 / 暴击 / 攻速' },
  { key: 'blue', name: '蓝色', short: '蓝', accent: '#4aa4ff', desc: '功能向：最大生命 / 吸血 / 移速 / 攻速 / 冷却' },
  { key: 'green', name: '绿色', short: '绿', accent: '#3ed08a', desc: '防御向：物理防御 / 法术防御 / 冷缩 / 韧性 / 法穿' },
];

/* 方向判定与公告分类（与桌面端 patch-sources.js 一致） */
const UP_WORDS: string[] = ['增强', '加强', '提升', '提高', '上调', '增加', '加长', '扩大', '缩短冷却', '优化'];
const DOWN_WORDS: string[] = ['削弱', '降低', '下调', '减少', '减弱', '变慢', '加长冷却'];
const PATCH_RE: RegExp = /(版本更新|不停机更新|停机更新|体验服|平衡性调整|英雄调整|装备调整|铭文调整|问题修复|技能调整|数值调整)/;

/* 玩加数值工具（与桌面端 r1/r2/normPct 口径一致） */
function r1(v: number): number {
  return Math.round(v * 10) / 10;
}

function r2(v: number): number {
  return Math.round(v * 100) / 100;
}

/** 百分比字段：上游可能是 "45.2%" / 45.2 / 空；空时用兜底数值（队伍小计占比） */
function pctStr(v: Object | undefined | null, fallbackNum: number): string {
  const s = J.str(v);
  let num = NaN;
  if (s.length > 0) {
    const re: RegExp = /-?\d+(\.\d+)?/;
    const m: RegExpExecArray | null = re.exec(s);
    if (m !== null) {
      num = Number(m[0]);
    }
  } else if (typeof v === 'number') {
    num = v as number;
  }
  if (isNaN(num) && isFinite(fallbackNum)) {
    num = fallbackNum;
  }
  if (isNaN(num)) {
    return '0%';
  }
  return `${r1(num)}%`;
}

/** 官方占比字段是「22.8」这种裸数字（含义为 22.8%），统一补成 "22.8%"；
 *  上游缺失时返回空串，页面走「—」分支。 */
function kplPctText(v: Object | undefined | null): string {
  const s = J.str(v).trim();
  if (s.length === 0) {
    return '';
  }
  if (s.indexOf('%') >= 0) {
    return s;
  }
  const n = Number(s);
  if (isNaN(n)) {
    return '';
  }
  return `${r1(n)}%`;
}

/** 玩加 herojson 字段：JSON 字符串 → { 随机键: 英雄统计对象 } */
function safeJsonObject(s: string): Map<string, Object> {
  const out: Map<string, Object> = new Map<string, Object>();
  if (s.length === 0) {
    return out;
  }
  try {
    const v: Object = JSON.parse(s) as Object;
    if (v !== null && !Array.isArray(v)) {
      const rec = v as Record<string, Object>;
      const keys = Object.keys(rec);
      for (let i = 0; i < keys.length; i++) {
        out.set(keys[i], rec[keys[i]]);
      }
    }
  } catch (e) {
    /* 非 JSON 时给空表 */
  }
  return out;
}

/** 梯度榜聚合条目（ArkTS 不允许无归属对象字面量，用类承载） */
class AggH {
  name: string = '';
  heroId: number = 0;
  games: number = 0;
  wins: number = 0;
  kdaW: number = 0;
  users: Set<string> = new Set<string>();
  icon: string = '';
  types: string[] = [];
  lanes: string[] = [];
}

/** 队伍合计（占比兜底） */
class Sum3 {
  golds: number = 0;
  dmg: number = 0;
  taken: number = 0;
}

/** 逐小局英雄选择记录（官方 getScheduleDetail 解析结果） */
class KplPick {
  playerId: string = '';
  playerName: string = '';
  teamId: string = '';
  heroId: number = 0;
  heroName: string = '';
  win: boolean = false;
}

/** 选手英雄池聚合条目（pid → 英雄名 → 场次 / 胜场） */
class KplPoolStat {
  games: number = 0;
  wins: number = 0;
}

/* ==================== 小工具 ==================== */

class J {
  static rec(v: Object | undefined | null): Record<string, Object> {
    if (v === undefined || v === null || Array.isArray(v)) {
      return {} as Record<string, Object>;
    }
    return v as Record<string, Object>;
  }

  static arr(v: Object | undefined | null): Array<Object> {
    if (v === undefined || v === null || !Array.isArray(v)) {
      return [] as Array<Object>;
    }
    return v as Array<Object>;
  }

  static str(v: Object | undefined | null): string {
    if (v === undefined || v === null) {
      return '';
    }
    return String(v);
  }

  static num(v: Object | undefined | null): number {
    const n = Number(v);
    return isNaN(n) ? 0 : n;
  }

  static bool(v: Object | undefined | null): boolean {
    return v === true || v === 1 || v === '1';
  }
}

function decodeEntities(s: string): string {
  return String(s ?? '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&rarr;|&ndash;|&mdash;/g, '→')
    .replace(/&#(\d+);/g, (m: string, d: string): string => String.fromCharCode(Number(d)));
}

function stripHtml(s: string): string {
  return decodeEntities(String(s ?? '')
    .replace(/<br\s*\/?>/gi, ' ')
    .replace(/<\/(p|div|li|tr|td|h[1-6])>/gi, ' ')
    .replace(/<[^>]+>/g, '')
    .replace(/\s+/g, ' ')
    .trim());
}

/** 属性/被动逐行（与桌面端 htmlLines 同策略：块级标签与 <br> 为行边界） */
function htmlLines(s: string): string[] {
  const marked = String(s ?? '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|li|tr|td|h[1-6])>/gi, '\n')
    .replace(/<li[^>]*>/gi, '\n· ');
  const text = decodeEntities(marked.replace(/<[^>]+>/g, ''));
  const out: string[] = [];
  const raws = text.split('\n');
  for (let i = 0; i < raws.length; i++) {
    const t = raws[i].trim();
    if (t.length > 0) {
      out.push(t);
    }
  }
  return out;
}

/** 公告正文 → 纯文本段落（\n 分隔，列表项保留 · 前缀），供详情页直接展示 */
function patchPlainText(html: string): string {
  const marked = String(html ?? '')
    .replace(/<h([1-6])[^>]*>/gi, '\n')
    .replace(/<\/h[1-6]>/gi, '\n')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|li|tr|td)>/gi, '\n')
    .replace(/<li[^>]*>/gi, '\n· ');
  const text = decodeEntities(marked.replace(/<[^>]+>/g, ''));
  const out: string[] = [];
  const raws = text.split('\n');
  for (let i = 0; i < raws.length; i++) {
    const t = raws[i].trim();
    if (t.length > 0) {
      out.push(t);
    }
  }
  return out.join('\n');
}

/** 数值型改动方向：旧 → 新箭头优先，其次关键词（与桌面端 dirOfLines 一致） */
function dirOfLines(lines: string[]): string {
  let up = 0;
  let down = 0;
  const arrow = /(-?\d+(?:\.\d+)?)\s*(?:→|->)\s*(-?\d+(?:\.\d+)?)/;
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    const m = arrow.exec(l);
    if (m !== null) {
      const a = parseFloat(m[1]);
      const b = parseFloat(m[2]);
      if (!isNaN(a) && !isNaN(b) && a !== b) {
        if (b > a) {
          up++;
        } else {
          down++;
        }
        continue;
      }
    }
    for (let k = 0; k < UP_WORDS.length; k++) {
      if (l.includes(UP_WORDS[k])) {
        up++;
      }
    }
    for (let k = 0; k < DOWN_WORDS.length; k++) {
      if (l.includes(DOWN_WORDS[k])) {
        down++;
      }
    }
  }
  if (up > down) {
    return 'buff';
  }
  if (down > up) {
    return 'nerf';
  }
  return 'adjust';
}

/** 公告标题分类 */
function kindOfTitle(title: string): string[] {
  const t = String(title ?? '');
  if (/铭文调整|铭文平衡/.test(t)) {
    return ['rune'];
  }
  if (/装备调整|装备平衡|装备案|道具调整/.test(t)) {
    return ['item'];
  }
  if (/英雄(平衡性)?调整|英雄平衡|英雄数值/.test(t)) {
    return ['hero'];
  }
  if (/平衡性调整/.test(t)) {
    return ['hero'];
  }
  return [];
}

/* ==================== HTTP ==================== */

async function httpGet(url: string, headers: Record<string, string>): Promise<string> {
  const req = http.createHttp();
  try {
    const opt: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: headers,
      connectTimeout: TIMEOUT,
      readTimeout: TIMEOUT,
      expectDataType: http.HttpDataType.STRING,
    };
    const resp = await req.request(url, opt);
    if (resp.responseCode !== 200) {
      throw new Error(`HTTP ${resp.responseCode}`);
    }
    return typeof resp.result === 'string' ? resp.result : '';
  } finally {
    try {
      req.destroy();
    } catch (e) {
      /* 忽略 */
    }
  }
}

/** 官网 herodetail 是 GBK 页面：优先 gb18030 解码，失败回退 utf-8 */
async function httpGetGbk(url: string): Promise<string> {
  const req = http.createHttp();
  try {
    const opt: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: { 'User-Agent': UA, 'Accept': 'text/html' },
      connectTimeout: TIMEOUT,
      readTimeout: TIMEOUT,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
    };
    const resp = await req.request(url, opt);
    if (resp.responseCode !== 200) {
      throw new Error(`HTTP ${resp.responseCode}`);
    }
    const buf: ArrayBuffer = resp.result as ArrayBuffer;
    try {
      const dec = util.TextDecoder.create('gb18030');
      return dec.decodeToString(new Uint8Array(buf));
    } catch (e) {
      const dec2 = new util.TextDecoder('utf-8');
      return dec2.decodeToString(new Uint8Array(buf));
    }
  } finally {
    try {
      req.destroy();
    } catch (e) {
      /* 忽略 */
    }
  }
}

async function fetchJson(url: string, headers: Record<string, string>): Promise<Record<string, Object> | Array<Object>> {
  const txt = await httpGet(url, headers);
  return JSON.parse(txt) as Record<string, Object>;
}

/** KPL 官方 RPC：POST JSON（无需签名），返回 data 字段。
 *  result !== 0 视为上游异常，抛出后由调用方回退下一级数据源。
 *  data 缺失时返回 null（ArkTS 不允许无归属的 `{}` 对象字面量）。 */
async function kplPost(name: string, body: Record<string, string>): Promise<Object | null> {
  const req = http.createHttp();
  try {
    const opt: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: KPL_HEADERS,
      extraData: JSON.stringify(body),
      connectTimeout: TIMEOUT,
      readTimeout: TIMEOUT,
      expectDataType: http.HttpDataType.STRING,
    };
    const resp = await req.request(URL_KPL_RPC + name, opt);
    if (resp.responseCode !== 200) {
      throw new Error(`HTTP ${resp.responseCode}`);
    }
    const obj = JSON.parse(String(resp.result ?? '')) as Record<string, Object>;
    if (J.num(obj['result']) !== 0) {
      const msg = J.str(obj['msg']);
      throw new Error(msg.length > 0 ? msg : '官方统计接口返回异常');
    }
    const data: Object | undefined = obj['data'];
    return data === undefined || data === null ? null : data;
  } finally {
    try {
      req.destroy();
    } catch (e) {
      /* 忽略 */
    }
  }
}

/** 官网 wmp 接口返回 `var xx = {...};` 形态 */
function parseJsLiteral(text: string): Record<string, Object> {
  const s = String(text ?? '').trim()
    .replace(/^var\s+[A-Za-z0-9_$]+\s*=\s*/, '')
    .replace(/;\s*$/, '');
  return JSON.parse(s) as Record<string, Object>;
}

/* ==================== 官网：英雄 / 装备 / 铭文 ==================== */

function heroBriefOf(h: Record<string, Object>): HeroBrief {
  const id = J.str(h['ename']);
  const skins: string[] = J.str(h['skin_name']).split('|').filter((s: string) => s.length > 0);
  const skinItems: SkinItem[] = [];
  for (let i = 0; i < skins.length; i++) {
    skinItems.push({ name: skins[i], big: heroSkinUrl(id, i + 1) });
  }
  ToolsUpstream.skinMap.set(id, skinItems);
  const typeIds: number[] = [J.num(h['hero_type'])];
  const types: string[] = [];
  for (let i = 0; i < typeIds.length; i++) {
    const t = HERO_TYPE.get(typeIds[i]);
    if (t !== undefined) {
      types.push(t);
    }
  }
  const laneIds = J.str(h['roles']).split('|').filter((s: string) => s.length > 0);
  const lanes: string[] = [];
  for (let i = 0; i < laneIds.length; i++) {
    const l = LANE.get(Number(laneIds[i]));
    if (l !== undefined) {
      lanes.push(l);
    }
  }
  const brief: HeroBrief = {
    id: Number(id),
    name: J.str(h['cname']),
    title: J.str(h['title']),
    pinyin: J.str(h['id_name']),
    types: types,
    lanes: lanes,
    skinCount: skins.length,
    icon: heroIconUrl(id),
  };
  return brief;
}

/* ==================== 主入口 ==================== */

export class ToolsUpstream {
  /** 内存缓存：key → { at, obj } */
  private static mem: Map<string, Record<string, Object>> = new Map<string, Record<string, Object>>();
  /** 英雄 id → 皮肤（名称 + 原画），拉英雄列表时顺便建好 */
  static skinMap: Map<string, SkinItem[]> = new Map<string, SkinItem[]>();

  private static memGet(key: string, ttlMs: number, bust: boolean): Object | null {
    if (bust) {
      return null;
    }
    const hit = ToolsUpstream.mem.get(key);
    if (hit === undefined) {
      return null;
    }
    const at = J.num(hit['at']);
    const obj: Object | undefined = hit['obj'];
    if (obj === undefined || obj === null || Date.now() - at > ttlMs) {
      return null;
    }
    return obj;
  }

  private static memSet(key: string, obj: object): void {
    const box: Record<string, Object> = { 'at': Date.now(), 'obj': obj };
    ToolsUpstream.mem.set(key, box);
  }

  /**
   * 按离线包接口键直连上游拉取。
   * @returns 与离线包同构的响应对象；不支持 / 失败返回 null（调用方回退下一级）
   */
  static async fetch(key: string, bust: boolean = false): Promise<Object | null> {
    try {
      if (key === '/api/tools/heroes') {
        return await ToolsUpstream.heroes(bust);
      }
      if (key === '/api/tools/items') {
        return await ToolsUpstream.items(bust);
      }
      if (key === '/api/tools/runes') {
        return await ToolsUpstream.runes(bust);
      }
      if (key.startsWith('/api/tools/hero?id=')) {
        return await ToolsUpstream.heroDetail(key.substring('/api/tools/hero?id='.length), bust);
      }
      if (key.startsWith('/api/patch')) {
        return await ToolsUpstream.patchFeed(bust);
      }
      if (key.startsWith('/api/tools/players?event=')) {
        const eid = key.substring('/api/tools/players?event='.length);
        // ① KPL 官方统计（2023+ 赛季，含 2026 年度总决赛）→ ② 玩加 → ③ 离线包
        const kpl = await ToolsUpstream.playersKpl(eid, bust);
        if (kpl !== null && (kpl.players ?? []).length > 0) {
          return kpl;
        }
        return await ToolsUpstream.playersWp(eid, bust);
      }
      if (key.startsWith('/api/tools/gradient?event=')) {
        const eid = key.substring('/api/tools/gradient?event='.length);
        // ① KPL 官方统计（2023+ 赛季，含 2026 年度总决赛）→ ② 玩加 → ③ 离线包
        const kpl = await ToolsUpstream.gradientKpl(eid, bust);
        if (kpl !== null && (kpl.list ?? []).length > 0) {
          return kpl;
        }
        return await ToolsUpstream.gradientWp(eid, bust);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /* ---------- 英雄列表 ---------- */
  static async heroes(bust: boolean): Promise<HeroesResp> {
    const hit = ToolsUpstream.memGet('heroes', 12 * 3600e3, bust);
    if (hit !== null) {
      return hit as HeroesResp;
    }
    const raw = await fetchJson(URL_HERO_LIST, { 'User-Agent': UA, 'Accept': 'application/json' });
    const rows = J.arr(raw);
    const out: HeroBrief[] = [];
    for (let i = 0; i < rows.length; i++) {
      out.push(heroBriefOf(J.rec(rows[i])));
    }
    out.sort((a: HeroBrief, b: HeroBrief) => {
      const pa = a.pinyin ?? '';
      const pb = b.pinyin ?? '';
      if (pa === pb) {
        return 0;
      }
      return pa < pb ? -1 : 1;
    });
    const resp: HeroesResp = { ok: true, heroes: out };
    ToolsUpstream.memSet('heroes', resp);
    return resp;
  }

  /* ---------- 装备 ---------- */
  static async items(bust: boolean): Promise<ItemsResp> {
    const hit = ToolsUpstream.memGet('items', 12 * 3600e3, bust);
    if (hit !== null) {
      return hit as ItemsResp;
    }
    const raw = await fetchJson(URL_ITEM_LIST, { 'User-Agent': UA, 'Accept': 'application/json' });
    const rows = J.arr(raw);
    const out: ItemRow[] = [];
    for (let i = 0; i < rows.length; i++) {
      const it = J.rec(rows[i]);
      const id = J.str(it['item_id']);
      const des1 = J.str(it['des1']);
      const des2 = J.str(it['des2']);
      out.push({
        id: id,
        name: J.str(it['item_name']),
        typeId: J.num(it['item_type']),
        type: ITEM_TYPE.get(J.num(it['item_type'])) ?? '其他',
        price: J.num(it['price']),
        total: J.num(it['total_price']) > 0 ? J.num(it['total_price']) : J.num(it['price']),
        desc: stripHtml(des1),
        lines: htmlLines(des1),
        passive: stripHtml(des2),
        passives: htmlLines(des2),
        hasPassive: des2.trim().length > 0,
        icon: itemIconUrl(id),
      });
    }
    const resp: ItemsResp = { ok: true, items: out };
    ToolsUpstream.memSet('items', resp);
    return resp;
  }

  /* ---------- 铭文 ---------- */
  static async runes(bust: boolean): Promise<RunesResp> {
    const hit = ToolsUpstream.memGet('runes', 12 * 3600e3, bust);
    if (hit !== null) {
      return hit as RunesResp;
    }
    const raw = await fetchJson(URL_MING_LIST, { 'User-Agent': UA, 'Accept': 'application/json' });
    const rows = J.arr(raw);
    const list: RuneItem[] = [];
    for (let i = 0; i < rows.length; i++) {
      const m = J.rec(rows[i]);
      const id = J.str(m['ming_id']);
      const head = id.length > 0 ? id.charAt(0) : '';
      const color = head === '1' ? 'red' : head === '2' ? 'blue' : 'green';
      const name = J.str(m['ming_name']).trim();
      if (name.length === 0) {
        continue;
      }
      const colorName = color === 'red' ? '红色' : color === 'blue' ? '蓝色' : '绿色';
      list.push({
        id: id,
        name: name,
        color: color,
        colorName: colorName,
        grade: J.num(m['ming_grade']) > 0 ? J.num(m['ming_grade']) : 1,
        desc: stripHtml(J.str(m['ming_des'])),
        lines: htmlLines(J.str(m['ming_des'])),
        officialType: J.str(m['ming_type']),
        icon: mingIconUrl(id),
      });
    }
    const cOrder: Map<string, number> = new Map<string, number>([['red', 0], ['blue', 1], ['green', 2]]);
    list.sort((a: RuneItem, b: RuneItem) => {
      const ca = cOrder.get(a.color ?? '') ?? 9;
      const cb = cOrder.get(b.color ?? '') ?? 9;
      if (ca !== cb) {
        return ca - cb;
      }
      if ((b.grade ?? 0) !== (a.grade ?? 0)) {
        return (b.grade ?? 0) - (a.grade ?? 0);
      }
      const na = a.name ?? '';
      const nb = b.name ?? '';
      if (na === nb) {
        return 0;
      }
      return na < nb ? -1 : 1;
    });
    const colors: RuneColor[] = [];
    for (let i = 0; i < RUNE_COLORS.length; i++) {
      const c = RUNE_COLORS[i];
      let count = 0;
      let level5 = 0;
      for (let k = 0; k < list.length; k++) {
        if (list[k].color === c.key) {
          count++;
          if ((list[k].grade ?? 0) === 5) {
            level5++;
          }
        }
      }
      const withCount: RuneColor = {
        key: c.key, name: c.name, short: c.short, accent: c.accent, desc: c.desc,
        count: count, level5: level5,
      };
      colors.push(withCount);
    }
    const resp: RunesResp = {
      ok: true,
      updatedAt: Date.now(),
      total: list.length,
      topLevel: 5,
      colors: colors,
      note: '铭文页共 30 个槽位：红、蓝、绿三色各 10 个。每色 10 种铭文，分 1~5 级（等级越高属性越强），' +
        '职业赛场与排位普遍使用整套 5 级铭文。属性数值为该等级下的单枚加成，凑满 10 枚即 ×10。',
      priceNote: '铭文通过铭文碎片合成（1 级 10 碎片 → 5 级 1600 碎片），官方未公开点券定价。',
      list: list,
    };
    ToolsUpstream.memSet('runes', resp);
    return resp;
  }

  /* ---------- 英雄详情（技能 / 属性评分 / 背景故事） ---------- */
  static async heroDetail(idText: string, bust: boolean): Promise<HeroResp> {
    const id = idText.trim();
    const cacheKey = 'hero-' + id;
    const hit = ToolsUpstream.memGet(cacheKey, 7 * 86400e3, bust);
    if (hit !== null) {
      return hit as HeroResp;
    }
    // 基础资料：优先刚拉过的英雄列表，回退离线快照
    let base: HeroBrief | undefined = undefined;
    const heroes = await ToolsUpstream.heroes(false);
    for (let i = 0; i < heroes.heroes.length; i++) {
      if (String(heroes.heroes[i].id) === id) {
        base = heroes.heroes[i];
        break;
      }
    }
    if (base === undefined) {
      const snap = BundleStore.api<HeroesResp>('/api/tools/heroes');
      const list = snap ? snap.heroes : [];
      for (let i = 0; i < list.length; i++) {
        if (String(list[i].id) === id) {
          base = list[i];
          break;
        }
      }
    }
    if (base === undefined) {
      base = { id: Number(id), name: '', title: '', icon: heroIconUrl(id) };
    }
    // 皮肤：优先离线详情快照（已换成图鉴高清图），回退列表接口的 skin_name
    let skins: SkinItem[] = [];
    if (skins.length === 0) {
      const snapDetail = BundleStore.api<HeroResp>('/api/tools/hero?id=' + id);
      if (snapDetail && snapDetail.hero.skins && snapDetail.hero.skins.length > 0) {
        skins = snapDetail.hero.skins;
      } else {
        skins = ToolsUpstream.skinMap.get(id) ?? [];
      }
    }

    // 官网详情页（新英雄可能 404 → 基础资料版）
    let html = '';
    let partial = false;
    try {
      html = await httpGetGbk(heroDetailUrl(id));
      if (html.includes('找不回来') || html.length < 5000) {
        html = '';
      }
    } catch (e) {
      html = '';
    }
    partial = html.length === 0;

    // 属性评分：生存能力 / 攻击伤害 / 技能效果 / 上手难度
    const attr: HeroAttr[] = [];
    const attrRe = /<em class="cover-list-text fl">([^<]+)<\/em>[\s\S]{0,260}?width:\s*(\d+)%/g;
    let m: RegExpExecArray | null = attrRe.exec(html);
    while (m !== null) {
      attr.push({ label: m[1].trim(), value: Number(m[2]) });
      m = attrRe.exec(html);
    }

    // 技能：名称 / 冷却 / 消耗 / 描述 + 图标（图标按页面出现顺序对应）
    const iconCodes: string[] = [];
    const iconRe = new RegExp(`heroimg/${id}/(\\d+)\\.png`, 'g');
    let im: RegExpExecArray | null = iconRe.exec(html);
    while (im !== null) {
      if (iconCodes.indexOf(im[1]) < 0) {
        iconCodes.push(im[1]);
      }
      im = iconRe.exec(html);
    }
    const skills: HeroSkill[] = [];
    // 官网结构：<p class="skill-name"><b>名</b><span>冷却</span><span>消耗</span></p>
    //          <p class="skill-desc">描述</p>
    const skRe2 = /<p class="skill-name">\s*<b>([^<]*)<\/b>\s*<span>([^<]*)<\/span>\s*<span>([^<]*)<\/span>\s*<\/p>\s*<p class="skill-desc">([\s\S]*?)<\/p>/g;
    let sm: RegExpExecArray | null = skRe2.exec(html);
    let si = 0;
    while (sm !== null && skills.length < 8) {
      const name = sm[1].trim();
      const desc = stripHtml(sm[4]);
      if (name.length === 0 && desc.length === 0) {
        sm = skRe2.exec(html);
        continue;
      }
      skills.push({
        name: name.length > 0 ? name : `技能${skills.length + 1}`,
        cd: sm[2].replace(/^冷却值[:：]?/, '').trim(),
        cost: sm[3].replace(/^消耗[:：]?/, '').trim(),
        desc: desc,
        icon: si < iconCodes.length ? skillIconUrl(id, iconCodes[si]) : '',
      });
      si++;
      sm = skRe2.exec(html);
    }

    // 背景故事：官网「英雄故事」弹层（整段纯文本，段落用 \n 分隔）
    const story = ToolsUpstream.storyOf(html, 'hero-story');
    const history = ToolsUpstream.storyOf(html, 'history');

    const detail: HeroDetail = {
      id: base.id,
      name: base.name,
      title: base.title ?? '',
      pinyin: base.pinyin ?? '',
      types: base.types ?? [],
      lanes: base.lanes ?? [],
      skinCount: base.skinCount ?? skins.length,
      icon: base.icon ?? heroIconUrl(id),
      skins: skins,
      attr: attr,
      skills: skills,
      story: story,
      history: history,
      partial: partial,
    };
    const resp: HeroResp = { ok: true, hero: detail };
    ToolsUpstream.memSet(cacheKey, resp);
    return resp;
  }

  /** 抽官网弹层文本：<div class="pop-story" id="xxx"> → .pop-bd 内所有 <p> 段落 */
  private static storyOf(html: string, sectionId: string): string {
    if (html.length === 0) {
      return '';
    }
    const anchor = 'id="' + sectionId + '"';
    const a = html.indexOf(anchor);
    if (a < 0) {
      return '';
    }
    const bd = html.indexOf('pop-bd', a);
    if (bd < 0) {
      return '';
    }
    const segStart = html.indexOf('>', bd) + 1;
    const segEnd = html.indexOf('</div>', segStart);
    if (segEnd <= segStart) {
      return '';
    }
    const seg = html.substring(segStart, segEnd);
    const paras: string[] = [];
    const pRe = /<p[^>]*>([\s\S]*?)<\/p>/g;
    let pm: RegExpExecArray | null = pRe.exec(seg);
    while (pm !== null) {
      const t = stripHtml(pm[1]);
      if (t.length > 0) {
        paras.push(t);
      }
      pm = pRe.exec(seg);
    }
    return paras.join('\n');
  }

  /* ---------- 公告详情（点开公告：正文纯文本 + 结构化调整条目） ---------- */

  /** 公告详情，按 id 直连官网；内存缓存 30 分钟。失败返回 ok=false 的空详情。 */
  static async patchDetail(id: string, bust: boolean = false): Promise<PatchDetail> {
    const key = `patch-detail-${id}`;
    const hit = ToolsUpstream.memGet(key, 30 * 60e3, bust);
    if (hit !== null) {
      return hit as PatchDetail;
    }
    let version = '';
    let text = '';
    let changes: PatchChange[] = [];
    try {
      const dj = parseJsLiteral(await httpGet(`${URL_PATCH_DETAIL}?p0=${GAME_ID}&source=web_pc&id=${id}`,
        { 'User-Agent': UA, 'Accept': '*/*' }));
      const msg = J.rec(dj['msg']);
      version = J.str(msg['sGameVersion']);
      const html = J.str(msg['sContent']);
      text = patchPlainText(html);
      changes = ToolsUpstream.parseContent(html);
    } catch (e) {
      /* 保持空文本，页面提示用官网链接兜底 */
    }
    const resp: PatchDetail = {
      ok: text.length > 0 || changes.length > 0,
      id: id,
      version: version,
      text: text,
      changes: changes,
    };
    ToolsUpstream.memSet(key, resp);
    return resp;
  }

  /* ---------- 版本动态（公告列表 + 正文结构化调整条目） ---------- */
  static async patchFeed(bust: boolean): Promise<PatchResp> {
    const hit = ToolsUpstream.memGet('patch-feed', 10 * 60e3, bust);
    if (hit !== null) {
      return hit as PatchResp;
    }
    const scan = 30;
    const limit = 8;
    // 1) 公告列表
    const listUrl = `${URL_PATCH_LIST}?p0=${GAME_ID}&p1=searchNewsKeywordsList&page=1&pagesize=${scan}` +
      `&order=sIdxTime&r0=script&r1=KplNewsObj&source=web_pc`;
    const lj = parseJsLiteral(await httpGet(listUrl, { 'User-Agent': UA, 'Accept': '*/*' }));
    const result = J.arr(lj['msg'] !== undefined ? J.rec(lj['msg'])['result'] : []);
    const all: PatchNote[] = [];
    for (let i = 0; i < result.length; i++) {
      const x = J.rec(result[i]);
      const title = J.str(x['sTitle']).trim();
      all.push({
        id: J.str(x['iNewsId']),
        title: title,
        time: J.str(x['sIdxTime'] ?? x['sCreated']).substring(0, 19),
        url: newsUrl(J.str(x['iNewsId'])),
        kinds: kindOfTitle(title),
        changeCount: 0,
      });
    }
    const notes: PatchNote[] = [];
    for (let i = 0; i < all.length && notes.length < limit; i++) {
      if (PATCH_RE.test(all[i].title ?? '') && (all[i].id ?? '').length > 0) {
        notes.push(all[i]);
      }
    }
    // 2) 逐条正文 → 结构化调整
    const changes: PatchChange[] = [];
    for (let i = 0; i < notes.length; i++) {
      const n = notes[i];
      let cs: PatchChange[] = [];
      let version = '';
      try {
        const dj = parseJsLiteral(await httpGet(`${URL_PATCH_DETAIL}?p0=${GAME_ID}&source=web_pc&id=${n.id}`,
          { 'User-Agent': UA, 'Accept': '*/*' }));
        const msg = J.rec(dj['msg']);
        version = J.str(msg['sGameVersion']);
        cs = ToolsUpstream.parseContent(J.str(msg['sContent']));
      } catch (e) {
        cs = [];
      }
      n.version = version;
      n.changeCount = cs.length;
      for (let k = 0; k < cs.length; k++) {
        const c = cs[k];
        c.newsId = n.id;
        c.newsTitle = n.title;
        c.newsTime = n.time;
        c.newsUrl = n.url;
        c.version = version;
        changes.push(c);
      }
    }
    // 3) 同一实体只留最新
    const latest: Map<string, PatchChange> = new Map<string, PatchChange>();
    for (let i = 0; i < changes.length; i++) {
      const c = changes[i];
      const k = `${c.kind ?? ''}:${c.name ?? ''}`;
      const prev = latest.get(k);
      if (prev === undefined || String(c.newsTime ?? '') > String(prev.newsTime ?? '')) {
        latest.set(k, c);
      }
    }
    const finalChanges: PatchChange[] = [];
    latest.forEach((c: PatchChange) => {
      finalChanges.push(c);
    });
    finalChanges.sort((a: PatchChange, b: PatchChange) => {
      const ta = String(a.newsTime ?? '');
      const tb = String(b.newsTime ?? '');
      if (ta === tb) {
        return 0;
      }
      return tb < ta ? -1 : 1;
    });
    const counts: Record<string, number> = { 'hero': 0, 'item': 0, 'rune': 0 };
    for (let i = 0; i < finalChanges.length; i++) {
      const k = finalChanges[i].kind ?? '';
      counts[k] = (counts[k] ?? 0) + 1;
    }
    let latestVersion = '';
    let latestTime = '';
    for (let i = 0; i < notes.length; i++) {
      if (latestVersion.length === 0 && (notes[i].version ?? '').length > 0) {
        latestVersion = notes[i].version ?? '';
      }
    }
    if (notes.length > 0) {
      latestTime = notes[0].time ?? '';
    }
    const resp: PatchResp = {
      ok: true,
      updatedAt: Date.now(),
      notes: notes,
      changes: finalChanges,
      counts: counts,
      latestVersion: latestVersion,
      latestTime: latestTime,
    };
    ToolsUpstream.memSet('patch-feed', resp);
    return resp;
  }

  /** 公告正文 → 结构化调整条目（与桌面端 parseContent 同策略：标题驱动 + 行首兜底） */
  private static parseContent(html: string): PatchChange[] {
    const blocks = ToolsUpstream.htmlToBlocks(html);
    const dict = ToolsUpstream.dict();
    const out: PatchChange[] = [];
    const seen: Set<string> = new Set<string>();

    const push = (kind: string, name: string, lines: string[], section: string): void => {
      const body: string[] = [];
      for (let i = 0; i < lines.length; i++) {
        const t = lines[i].replace(/@@H\d@@/g, '').trim();
        if (t.length > 0) {
          body.push(t);
        }
      }
      if (body.length === 0) {
        return;
      }
      const key = `${kind}:${name}:${section}`;
      if (seen.has(key)) {
        return;
      }
      seen.add(key);
      const ent = dict.get(`${kind}:${name}`);
      const change: PatchChange = {
        kind: kind,
        name: name,
        id: ent !== undefined ? ent.id : '',
        icon: ent !== undefined ? ent.icon : '',
        title: ent !== undefined ? ent.title : '',
        type: ent !== undefined ? ent.type : '',
        section: section,
        dir: dirOfLines(body),
        lines: body.slice(0, 12),
        summary: body.join(' / ').substring(0, 200),
      };
      out.push(change);
    };

    // 第一遍：标题驱动
    let context = '';
    let contextKind = '';
    let curKind = '';
    let curName = '';
    let curLines: string[] = [];
    for (let i = 0; i < blocks.length; i++) {
      const raw = blocks[i];
      const hm = /^@@H(\d)@@([\s\S]*)$/.exec(raw);
      const isHead = hm !== null;
      const text = raw.replace(/@@H\d@@/g, '').trim();
      if (text.length === 0) {
        continue;
      }
      const isBracket = /^【[^】]{2,20}】$/.test(text);
      if (isHead || isBracket) {
        if (curName.length > 0) {
          push(curKind, curName, curLines, context);
        }
        curName = '';
        curLines = [];
        const t = text.replace(/[【】]/g, '').trim();
        let hitKind = '';
        if (/英雄(平衡性)?调整|英雄平衡|英雄数值/.test(t)) {
          hitKind = 'hero';
        } else if (/装备调整|装备平衡|装备案|道具调整/.test(t)) {
          hitKind = 'item';
        } else if (/铭文调整|铭文平衡/.test(t)) {
          hitKind = 'rune';
        }
        if (hitKind.length > 0) {
          context = t;
          contextKind = hitKind;
          continue;
        }
        const pool: string[] = contextKind.length > 0 ? [contextKind] : ['hero', 'item', 'rune'];
        let matched = '';
        let matchedName = '';
        for (let k = 0; k < pool.length && matched.length === 0; k++) {
          if (dict.has(`${pool[k]}:${t}`)) {
            matched = pool[k];
            matchedName = t;
            break;
          }
          // 「海月 平衡」这类带后缀的写法
          const alt = ToolsUpstream.dictPrefix(pool[k], t);
          if (alt.length > 0) {
            matched = pool[k];
            matchedName = alt;
            break;
          }
        }
        if (matched.length > 0) {
          curKind = matched;
          curName = matchedName;
          continue;
        }
        if (!/调整|平衡/.test(t)) {
          context = '';
          contextKind = '';
        }
        continue;
      }
      if (curName.length > 0) {
        curLines.push(text);
      }
    }
    if (curName.length > 0) {
      push(curKind, curName, curLines, context);
    }

    // 第二遍：行首实体名（标题结构化缺失时的兜底）
    if (out.length === 0) {
      for (let i = 0; i < blocks.length; i++) {
        const text = blocks[i].replace(/@@H\d@@/g, '').trim();
        if (text.length === 0 || text.length > 60) {
          continue;
        }
        const kinds: string[] = ['hero', 'item', 'rune'];
        for (let k = 0; k < kinds.length; k++) {
          const name = ToolsUpstream.dictLineStart(kinds[k], text);
          if (name.length > 0) {
            push(kinds[k], name, [text], context.length > 0 ? context : '正文');
            break;
          }
        }
      }
    }
    return out;
  }

  /** HTML → 结构化行（保留 @@H<level>@@ 标题标记） */
  private static htmlToBlocks(html: string): string[] {
    const marked = String(html ?? '')
      .replace(/<h([1-6])[^>]*>/gi, '\n@@H$1@@')
      .replace(/<\/h[1-6]>/gi, '\n')
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<\/(p|div|li|tr|td)>/gi, '\n')
      .replace(/<li[^>]*>/gi, '\n· ');
    const text = decodeEntities(marked.replace(/<[^>]+>/g, ''));
    const raws = text.split('\n');
    const out: string[] = [];
    for (let i = 0; i < raws.length; i++) {
      const t = raws[i].trim();
      if (t.length > 0) {
        out.push(t);
      }
    }
    return out;
  }


  /* ---------- 实体字典（离线包英雄/装备/铭文名 → 图标等，供公告解析用） ---------- */
  private static dictCache: Map<string, DictEntry> | null = null;

  private static dict(): Map<string, DictEntry> {
    if (ToolsUpstream.dictCache !== null) {
      return ToolsUpstream.dictCache;
    }
    const m: Map<string, DictEntry> = new Map<string, DictEntry>();
    const heroes = BundleStore.api<HeroesResp>('/api/tools/heroes');
    const hl = heroes ? heroes.heroes : [];
    for (let i = 0; i < hl.length; i++) {
      const name = (hl[i].name ?? '').trim();
      if (name.length === 0 || m.has(`hero:${name}`)) {
        continue;
      }
      m.set(`hero:${name}`, {
        id: String(hl[i].id ?? ''),
        icon: hl[i].icon ?? heroIconUrl(String(hl[i].id ?? '')),
        title: hl[i].title ?? '',
        type: '',
      });
    }
    const items = BundleStore.api<ItemsResp>('/api/tools/items');
    const il = items ? items.items : [];
    for (let i = 0; i < il.length; i++) {
      const name = (il[i].name ?? '').trim();
      if (name.length === 0 || m.has(`item:${name}`)) {
        continue;
      }
      m.set(`item:${name}`, {
        id: String(il[i].id ?? ''),
        icon: il[i].icon ?? itemIconUrl(String(il[i].id ?? '')),
        title: '',
        type: il[i].type ?? '',
      });
    }
    const runes = BundleStore.api<RunesResp>('/api/tools/runes');
    const rl: RuneItem[] = runes?.list ?? [];
    for (let i = 0; i < rl.length; i++) {
      const name = (rl[i].name ?? '').trim();
      if (name.length === 0 || m.has(`rune:${name}`)) {
        continue;
      }
      m.set(`rune:${name}`, {
        id: String(rl[i].id ?? ''),
        icon: rl[i].icon ?? mingIconUrl(String(rl[i].id ?? '')),
        title: '',
        type: rl[i].colorName ?? '',
      });
    }
    ToolsUpstream.dictCache = m;
    return m;
  }

  /** 「海月 平衡」→ 海月（前缀命中且后缀 ≤ 6 字） */
  private static dictPrefix(kind: string, text: string): string {
    const dict = ToolsUpstream.dict();
    let best = '';
    dict.forEach((e: DictEntry, k: string) => {
      const parts = k.split(':');
      if (parts.length < 2 || parts[0] !== kind) {
        return;
      }
      const name = parts[1];
      if (text.startsWith(name) && text.length <= name.length + 6 && name.length > best.length) {
        best = name;
      }
    });
    return best;
  }

  /** 行首实体名兜底：「海月：…」/「海月:…」/「海月 …」/ 完全等于 */
  private static dictLineStart(kind: string, text: string): string {
    const dict = ToolsUpstream.dict();
    let best = '';
    dict.forEach((e: DictEntry, k: string) => {
      const parts = k.split(':');
      if (parts.length < 2 || parts[0] !== kind) {
        return;
      }
      const name = parts[1];
      const hit = text === name || text.startsWith(name + '：') || text.startsWith(name + ':')
        || text.startsWith(name + ' ');
      if (hit && name.length > best.length) {
        best = name;
      }
    });
    return best;
  }

  /* ==================== 玩加：梯度榜 / 选手详情 ====================
   * 与桌面端 tools-sources.js 同源同构：
   *   · 会话：GET /kog/teamstats 拿 cookie，gtk = time33(wanplus_token 前 7 位)
   *   · 数据：POST /ajax/stats/list（type=player，gametype=6），分页取满
   *   · 2023~2026 赛季上游通常为 0 行（桌面端同样回退随包种子）——
   *     此时返回 null，由 NetStore 落回离线包，不覆盖好数据。
   */

  private static wpCookie: string = '';
  private static wpGtk: string = '';
  private static wpAt: number = 0;

  /** wanplus_token 前 7 位 → time33 哈希（桌面端同款） */
  private static time33(token: string): string {
    const a = String(token ?? '').slice(0, 7);
    let d = 5381;
    for (let i = 0; i < a.length; i++) {
      d += (d << 5) + a.charCodeAt(i);
    }
    return String(d & 2147483647);
  }

  /** 会话引导：30 分钟有效；force=true 时强制换新 cookie */
  private static async wpSession(force: boolean): Promise<boolean> {
    if (!force && ToolsUpstream.wpGtk.length > 0 && Date.now() - ToolsUpstream.wpAt < 30 * 60e3) {
      return true;
    }
    const req = http.createHttp();
    try {
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': UA, 'Accept': 'text/html' },
        connectTimeout: TIMEOUT,
        readTimeout: TIMEOUT,
      };
      const resp = await req.request(URL_WP_PAGE, opt);
      if (resp.responseCode !== 200) {
        return false;
      }
      const hd = resp.header as Record<string, Object>;
      let cookieText = '';
      const sc: Object | undefined = hd['set-cookie'];
      if (Array.isArray(sc)) {
        const arr = sc as Array<Object>;
        for (let i = 0; i < arr.length; i++) {
          cookieText += J.str(arr[i]) + '\n';
        }
      } else {
        cookieText = J.str(sc);
      }
      const re: RegExp = /((?:wanplus_[a-z]+)|(?:gameType))=([^;,\s]+)/g;
      const jar: Map<string, string> = new Map<string, string>();
      let m: RegExpExecArray | null = re.exec(cookieText);
      while (m !== null) {
        jar.set(m[1], m[2]);
        m = re.exec(cookieText);
      }
      const parts: string[] = [];
      jar.forEach((v: string, k: string) => {
        parts.push(`${k}=${v}`);
      });
      if (parts.length === 0) {
        return false;
      }
      ToolsUpstream.wpCookie = parts.join('; ');
      ToolsUpstream.wpGtk = ToolsUpstream.time33(jar.get('wanplus_token') ?? '');
      ToolsUpstream.wpAt = Date.now();
      return true;
    } catch (e) {
      return false;
    } finally {
      try {
        req.destroy();
      } catch (e) {
        /* 忽略 */
      }
    }
  }

  /** 玩加 POST：ret!==0 时换会话重试一次（桌面端同款策略） */
  private static async wpPost(pathname: string, params: Record<string, string>): Promise<Record<string, Object>> {
    let lastErr: string = '';
    for (let attempt = 0; attempt < 2; attempt++) {
      const ok = await ToolsUpstream.wpSession(attempt > 0);
      if (!ok) {
        lastErr = '玩加会话不可用';
        continue;
      }
      const req = http.createHttp();
      try {
        let body = `_gtk=${encodeURIComponent(ToolsUpstream.wpGtk)}`;
        const keys = Object.keys(params);
        for (let i = 0; i < keys.length; i++) {
          body += `&${encodeURIComponent(keys[i])}=${encodeURIComponent(params[keys[i]])}`;
        }
        const opt: http.HttpRequestOptions = {
          method: http.RequestMethod.POST,
          header: {
            'User-Agent': UA,
            'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
            'Accept': 'application/json, text/javascript, */*; q=0.01',
            'X-Requested-With': 'XMLHttpRequest',
            'X-CSRF-Token': ToolsUpstream.wpGtk,
            'Referer': URL_WP_REFERER,
            'Origin': 'https://wanplus.cn',
            'Cookie': ToolsUpstream.wpCookie,
          },
          extraData: body,
          connectTimeout: TIMEOUT,
          readTimeout: TIMEOUT,
          expectDataType: http.HttpDataType.STRING,
        };
        const resp = await req.request('https://wanplus.cn' + pathname, opt);
        if (resp.responseCode !== 200) {
          throw new Error(`HTTP ${resp.responseCode}`);
        }
        const json = JSON.parse(String(resp.result ?? '')) as Record<string, Object>;
        if (J.num(json['ret']) !== 0) {
          throw new Error(J.str(json['msg']) || '玩加上游返回异常');
        }
        return json;
      } catch (e) {
        lastErr = String(e);
      } finally {
        try {
          req.destroy();
        } catch (e) {
          /* 忽略 */
        }
      }
    }
    throw new Error(lastErr);
  }

  /** 分页拉满整个数据中心表（单页 500 行，桌面端同款） */
  private static async wpStatsAll(eid: string, type: string): Promise<Array<Record<string, Object>>> {
    const rows: Array<Record<string, Object>> = [];
    let start = 0;
    let guard = 0;
    while (guard++ < 20) {
      const q: Record<string, string> = {
        'draw': String(guard),
        'start': String(start),
        'length': '500',
        'area': '',
        'time': '',
        'eid': eid,
        'type': type,
        'gametype': '6',
        'filter': '[]',
      };
      const json = await ToolsUpstream.wpPost('/ajax/stats/list', q);
      const data = J.arr(json['data']);
      if (data.length === 0) {
        break;
      }
      for (let i = 0; i < data.length; i++) {
        rows.push(J.rec(data[i]));
      }
      const total = J.num(json['iTotalRecords']) > 0 ? J.num(json['iTotalRecords']) : rows.length;
      if (rows.length >= total) {
        break;
      }
      start = rows.length;
    }
    return rows;
  }

  /** 官方英雄库索引（id → brief），池内英雄的类型/分路/图标以官方库为准 */
  private static async heroIndex(): Promise<Map<number, HeroBrief>> {
    const resp = await ToolsUpstream.heroes(false);
    const m: Map<number, HeroBrief> = new Map<number, HeroBrief>();
    const list = resp.heroes ?? [];
    for (let i = 0; i < list.length; i++) {
      m.set(list[i].id, list[i]);
    }
    return m;
  }

  /** 单行上游数据 → 英雄池条目（normPoolItem 的 ArkTS 版） */
  private static poolOf(raw: Object, idx: Map<number, HeroBrief>): PlayerPoolItem | null {
    const h = J.rec(raw);
    const heroId = J.num(h['heroid']);
    const games = J.num(h['appearancetimes']);
    if (games <= 0) {
      return null;
    }
    const official = idx.get(heroId);
    const wins = J.num(h['winnum']);
    const upWr = J.num(h['winrate']);
    const wr = games > 0 ? wins / games : 0;
    const pk: PlayerPoolItem = {
      name: official ? official.name : J.str(h['heroname']),
      heroId: heroId,
      games: games,
      wins: wins,
      losses: J.num(h['losenum']) > 0 ? J.num(h['losenum']) : Math.max(0, games - wins),
      winRate: upWr > 0 ? r2(upWr) : r2(wr),
      kda: r1(J.num(h['kda'])),
      icon: official ? official.icon : (heroId > 0 ? heroIconUrl(String(heroId)) : ''),
      types: official ? (official.types ?? []) : [],
      lanes: official ? (official.lanes ?? []) : [],
      title: official ? official.title : '',
    };
    return pk;
  }

  /**
   * 选手详情直连。上游 0 行 / 失败时返回 null（调用方回退离线包）；
   * 拿到 0 行也写 10 分钟负缓存，避免反复打上游。
   */
  static async playersWp(eid: string, bust: boolean): Promise<PlayersResp | null> {
    const key = `players-${eid}`;
    const hit = ToolsUpstream.memGet(key, 10 * 60e3, bust);
    if (hit !== null) {
      const got = hit as PlayersResp;
      return (got.count ?? 0) > 0 ? got : null;
    }
    let rows: Array<Record<string, Object>> = [];
    try {
      rows = await ToolsUpstream.wpStatsAll(eid, 'player');
    } catch (e) {
      rows = [];
    }
    if (rows.length === 0) {
      const empty: PlayersResp = { ok: true, eventId: Number(eid), count: 0, players: [] };
      ToolsUpstream.memSet(key, empty);
      return null;
    }
    const idx = await ToolsUpstream.heroIndex();
    const seen: Set<string> = new Set<string>();
    const out: PlayerItem[] = [];
    const sums: Map<string, Sum3> = new Map<string, Sum3>();
    const first: PlayerItem[] = [];
    /* 第一遍：基础数值 + 队伍小计（占比兜底用） */
    for (let i = 0; i < rows.length; i++) {
      const r = rows[i];
      const name = J.str(r['playername']);
      if (name.length === 0) {
        continue;
      }
      const team = J.str(r['teamname']);
      const k = `${name}|${team}`;
      if (seen.has(k)) {
        continue;
      }
      seen.add(k);
      const poolRaw = safeJsonObject(J.str(r['herojson']));
      const pool: PlayerPoolItem[] = [];
      poolRaw.forEach((v: Object) => {
        const pk = ToolsUpstream.poolOf(v, idx);
        if (pk !== null && (pk.name ?? '').length > 0) {
          pool.push(pk);
        }
      });
      pool.sort((a: PlayerPoolItem, b: PlayerPoolItem) => (b.games ?? 0) - (a.games ?? 0));
      for (let j = 0; j < pool.length; j++) {
        pool[j].rank = j + 1;
      }
      const durationSec = J.num(r['duration']);
      const teamId = J.str(r['teamid']);
      const golds = J.num(r['golds']);
      const dmg = J.num(r['damagetohero']);
      const taken = J.num(r['damagetaken']);
      const it: PlayerItem = {
        id: J.str(r['playerid']),
        name: name,
        team: team,
        teamId: teamId,
        games: J.num(r['appearedTimes']),
        wins: J.num(r['winnum']),
        losses: J.num(r['losenum']),
        winRate: r2(J.num(r['winrate'])),
        kda: r1(J.num(r['kda'])),
        kills: r1(J.num(r['killsPergame'])),
        deaths: r1(J.num(r['deathsPergame'])),
        assists: r1(J.num(r['assistsPergame'])),
        goldPerMin: J.num(r['goldsPermin']),
        dmgPerMin: J.num(r['damagetoheroPermin']),
        dmgTakenPerMin: J.num(r['damagetakenPermin']),
        mostKills: J.num(r['mostkills']),
        mostAssists: J.num(r['mostassists']),
        mostDeaths: J.num(r['mostdeaths']),
        dmgConversion: r2(J.num(r['damagetoheroConversionRate'])),
        durationSec: durationSec,
        durationMin: durationSec > 0 ? Math.round(durationSec / 60) : 0,
        totals: {
          kills: J.num(r['kills']),
          deaths: J.num(r['deaths']),
          assists: J.num(r['assists']),
          golds: golds,
          damage: dmg,
          damageTaken: taken,
        },
        pool: pool,
        goldPercent: pctStr(r['goldsPercent'], NaN),
        dmgPercent: pctStr(r['damagetoheroPercent'], NaN),
        dmgTakenPercent: pctStr(r['damagetakenPercent'], NaN),
        attendRate: pctStr(r['attendrate'], NaN),
      };
      first.push(it);
      let s = sums.get(teamId);
      if (s === undefined) {
        s = new Sum3();
        sums.set(teamId, s);
      }
      s.golds += golds;
      s.dmg += dmg;
      s.taken += taken;
    }
    /* 第二遍：占比为空时用队伍小计兜底（保证百分比类字段永不为空） */
    for (let i = 0; i < first.length; i++) {
      const it = first[i];
      const t = sums.get(it.teamId ?? '') ?? new Sum3();
      const tg = (it.totals?.golds ?? 0);
      const td = (it.totals?.damage ?? 0);
      const tt = (it.totals?.damageTaken ?? 0);
      if ((it.goldPercent ?? '') === '' || it.goldPercent === '0%') {
        it.goldPercent = t.golds > 0 ? pctStr('', (tg / t.golds) * 100) : '0%';
      }
      if ((it.dmgPercent ?? '') === '' || it.dmgPercent === '0%') {
        it.dmgPercent = t.dmg > 0 ? pctStr('', (td / t.dmg) * 100) : '0%';
      }
      if ((it.dmgTakenPercent ?? '') === '' || it.dmgTakenPercent === '0%') {
        it.dmgTakenPercent = t.taken > 0 ? pctStr('', (tt / t.taken) * 100) : '0%';
      }
      it.rank = i + 1;
      out.push(it);
    }
    const resp: PlayersResp = { ok: true, eventId: Number(eid), count: out.length, players: out };
    ToolsUpstream.memSet(key, resp);
    return resp;
  }

  /** 梯度榜直连：由选手英雄池聚合（buildGradient 的 ArkTS 版） */
  static async gradientWp(eid: string, bust: boolean): Promise<GradientResp | null> {
    const key = `gradient-${eid}`;
    const hit = ToolsUpstream.memGet(key, 10 * 60e3, bust);
    if (hit !== null) {
      const got = hit as GradientResp;
      return ((got.list ?? []).length) > 0 ? got : null;
    }
    const ps = await ToolsUpstream.playersWp(eid, bust);
    const players = ps?.players ?? [];
    if (players.length === 0) {
      const empty: GradientResp = { ok: true, eventId: Number(eid), list: [] };
      ToolsUpstream.memSet(key, empty);
      return null;
    }
    const idx = await ToolsUpstream.heroIndex();
    const agg: Map<string, AggH> = new Map<string, AggH>();
    for (let i = 0; i < players.length; i++) {
      const p = players[i];
      const pool = p.pool ?? [];
      for (let j = 0; j < pool.length; j++) {
        const h = pool[j];
        const hn = h.name ?? '';
        const hg = h.games ?? 0;
        if (hn.length === 0 || hg <= 0) {
          continue;
        }
        let cur = agg.get(hn);
        if (cur === undefined) {
          cur = new AggH();
          cur.name = hn;
          cur.heroId = h.heroId ?? 0;
          cur.icon = h.icon ?? '';
          cur.types = h.types ?? [];
          cur.lanes = h.lanes ?? [];
          agg.set(hn, cur);
        }
        cur.games += hg;
        cur.wins += (h.wins ?? 0);
        cur.kdaW += (h.kda ?? 0) * hg;
        if (cur.icon.length === 0) {
          cur.icon = h.icon ?? '';
        }
        if (cur.heroId === 0) {
          cur.heroId = h.heroId ?? 0;
        }
        cur.users.add(`${p.name}（${p.team ?? ''}）`);
      }
    }
    let totalPicks = 0;
    let maxGames = 1;
    agg.forEach((v: AggH) => {
      totalPicks += v.games;
      if (v.games > maxGames) {
        maxGames = v.games;
      }
    });
    if (totalPicks === 0) {
      totalPicks = 1;
    }
    const list: GradientItem[] = [];
    agg.forEach((v: AggH) => {
      const winRate = v.games > 0 ? v.wins / v.games : 0;
      const smooth = (v.wins + 2) / (v.games + 4);
      const official = idx.get(v.heroId);
      const teams: string[] = Array.from(v.users);
      const gi: GradientItem = {
        name: official ? official.name : v.name,
        heroId: v.heroId,
        icon: v.icon.length > 0 ? v.icon : (official ? official.icon : (v.heroId > 0 ? heroIconUrl(String(v.heroId)) : '')),
        types: (v.types.length > 0 ? v.types : (official ? official.types : ['未分类'])) ?? ['未分类'],
        lanes: (v.lanes.length > 0 ? v.lanes : (official ? official.lanes : ['未知'])) ?? ['未知'],
        title: official ? official.title : '',
        games: v.games,
        wins: v.wins,
        losses: v.games - v.wins,
        winRate: r2(winRate),
        kda: v.games > 0 ? r1(v.kdaW / v.games) : 0,
        users: v.users.size,
        userList: teams.slice(0, 8),
        share: r1((v.games / totalPicks) * 100),
        score: r2(smooth * 0.65 + (v.games / maxGames) * 0.35),
      };
      list.push(gi);
    });
    list.sort((a: GradientItem, b: GradientItem) => {
      if ((b.score ?? 0) !== (a.score ?? 0)) {
        return (b.score ?? 0) - (a.score ?? 0);
      }
      return (b.winRate ?? 0) - (a.winRate ?? 0);
    });
    const labels: Map<string, string> = new Map<string, string>([
      ['T0', '版本答案'], ['T1', '主流选择'], ['T2', '体系英雄'], ['T3', '冷门 / 样本较少'],
    ]);
    const n = list.length > 0 ? list.length : 1;
    for (let i = 0; i < list.length; i++) {
      const pct = ((i + 1) / n) * 100;
      const tier = pct <= 10 ? 'T0' : (pct <= 30 ? 'T1' : (pct <= 60 ? 'T2' : 'T3'));
      list[i].rank = i + 1;
      list[i].tier = tier;
      list[i].tierLabel = labels.get(tier) ?? '';
      list[i].pct = Math.round(pct);
    }
    const teamsAll: Set<string> = new Set<string>();
    let totalPlayerGames = 0;
    for (let i = 0; i < players.length; i++) {
      if ((players[i].team ?? '').length > 0) {
        teamsAll.add(players[i].team ?? '');
      }
      totalPlayerGames += (players[i].games ?? 0);
    }
    const resp: GradientResp = {
      ok: true,
      eventId: Number(eid),
      totalPlayers: players.length,
      totalTeams: teamsAll.size,
      totalHeroPicks: totalPicks === 1 ? 0 : totalPicks,
      totalPlayerGames: totalPlayerGames,
      updatedAt: Date.now(),
      list: list,
    };
    ToolsUpstream.memSet(key, resp);
    return resp;
  }

  /* ==================== KPL 官方统计通道 ====================
   * 移植自 iOS 版 Data/KPLStatsSource.swift（kpl.qq.com 官网同款 RPC）。
   *
   * **为什么需要它**：玩加的「逐选手英雄池」只收录到 2022 年，2023 年及以后
   * （含 2026 KPL 年度总决赛）一直显示「上游尚未收录」的空态——梯度榜与
   * 选手详情因此看不到这些赛季的数据。官方这三条 RPC 无需签名、直接 POST
   * JSON，可完整补齐：
   *   · getHeroRankList     → 逐英雄出场数 / 胜率（梯度榜数据源）
   *   · getSeasonPlayerPerf → 逐选手 KDA / 伤害占比 / 经济占比 / 参团率
   *   · getScheduleList + getScheduleDetail → 逐小局英雄选择（聚合选手英雄池）
   *
   * 官方 hero_id 与 pvp.qq.com 英雄库 ename **完全一致**，可直接复用现有的
   * 英雄图标 / 类型 / 分路元数据。优先级：官方 → 玩加 → 离线包种子。
   */

  /** App 赛事 id → 官方 seasonid；不在表内返回 ''（该赛事走玩加 / 种子通道） */
  static kplSeasonOf(eid: string): string {
    const v = KPL_SEASON.get(eid);
    return v === undefined ? '' : v;
  }

  /** 逐英雄出场数 / 胜率（官方榜含 0 出场英雄，调用方自行过滤） */
  private static async kplHeroRank(season: string): Promise<Array<Record<string, Object>>> {
    const data = await kplPost('getHeroRankList', { 'seasonid': season });
    return J.arr(J.rec(data)['list']) as Array<Record<string, Object>>;
  }

  /** 逐选手核心指标（KDA / 各占比 / 场次 / 位置） */
  private static async kplPlayerPerf(season: string): Promise<Array<Record<string, Object>>> {
    const data = await kplPost('getSeasonPlayerPerf', { 'seasonid': season });
    if (Array.isArray(data)) {
      return data as Array<Record<string, Object>>;
    }
    return J.arr(J.rec(data)['list']) as Array<Record<string, Object>>;
  }

  /** 该赛季赛程（官方 schedule_status：1/2 未开始 · 3 进行中 · 4 已结束）。
   *  ⚠️ 必须带 seasonid：不带时接口只返回**当前赛季**的赛程。 */
  private static async kplSchedule(season: string): Promise<Array<Record<string, Object>>> {
    const data = await kplPost('getScheduleList', {
      'seasonid': season,
      'direction': '1',
      'pivot_scheduleid': '',
      'page_size': '200',
    });
    const raw = J.arr(J.rec(data)['list']) as Array<Record<string, Object>>;
    const out: Array<Record<string, Object>> = [];
    for (let i = 0; i < raw.length; i++) {
      if (J.str(raw[i]['seasonid']) === season) {
        out.push(raw[i]);
      }
    }
    return out;
  }

  /** 单场比赛 → 逐小局每选手的英雄与胜负（失败返回空数组，不打断整体聚合） */
  private static async kplDetailRounds(scheduleId: string, season: string): Promise<KplPick[]> {
    const out: KplPick[] = [];
    let data: Object | null = null;
    try {
      data = await kplPost('getScheduleDetail', { 'scheduleid': scheduleId, 'seasonid': season });
    } catch (e) {
      return out;
    }
    if (data === null) {
      return out;
    }
    const root = J.rec(data);
    // 顶层 players 提供 playerid → team_id / 简称（round_details 里没有队属信息）
    const teamOf: Map<string, string> = new Map<string, string>();
    const nameOf: Map<string, string> = new Map<string, string>();
    const players = J.arr(root['players']) as Array<Record<string, Object>>;
    for (let i = 0; i < players.length; i++) {
      const p = players[i];
      const pid = J.str(p['playerid']);
      if (pid.length === 0) {
        continue;
      }
      teamOf.set(pid, J.str(p['team_id']));
      const short = J.str(p['player_name_short']);
      nameOf.set(pid, short.length > 0 ? short : J.str(p['player_name']));
    }
    const rounds = J.arr(root['round_details']) as Array<Record<string, Object>>;
    for (let i = 0; i < rounds.length; i++) {
      const r = rounds[i];
      const winner = J.str(r['win_team']);
      const rp = J.arr(r['players']) as Array<Record<string, Object>>;
      for (let j = 0; j < rp.length; j++) {
        const p = rp[j];
        const pid = J.str(p['playerid']);
        if (pid.length === 0) {
          continue;
        }
        const tid = teamOf.get(pid) ?? '';
        const rec = new KplPick();
        rec.playerId = pid;
        rec.playerName = nameOf.get(pid) ?? '';
        rec.teamId = tid;
        rec.heroId = J.num(p['hero_id']);
        rec.heroName = J.str(p['hero_name']);
        rec.win = winner.length > 0 && winner === tid;
        out.push(rec);
      }
    }
    return out;
  }

  /** 该赛季已结束比赛的逐小局记录。
   *  每场一次 getScheduleDetail，因此限制抓取场次（KPL_ROUND_LIMIT），
   *  分批并发（KPL_ROUND_BATCH）以控制上游压力。 */
  private static async kplRoundPicks(season: string): Promise<KplPick[]> {
    let list: Array<Record<string, Object>> = [];
    try {
      list = await ToolsUpstream.kplSchedule(season);
    } catch (e) {
      return [];
    }
    const targets: Array<Record<string, Object>> = [];
    for (let i = 0; i < list.length; i++) {
      if (J.num(list[i]['schedule_status']) === 4) {
        targets.push(list[i]);
        if (targets.length >= KPL_ROUND_LIMIT) {
          break;
        }
      }
    }
    const out: KplPick[] = [];
    let i = 0;
    while (i < targets.length) {
      const jobs: Array<Promise<KplPick[]>> = [];
      for (let j = i; j < targets.length && j < i + KPL_ROUND_BATCH; j++) {
        const m = targets[j];
        const sid = J.str(m['scheduleid']);
        const sn = J.str(m['seasonid']);
        if (sid.length === 0 || sn.length === 0) {
          continue;
        }
        jobs.push(ToolsUpstream.kplDetailRounds(sid, sn));
      }
      if (jobs.length > 0) {
        const parts: KplPick[][] = await Promise.all(jobs);
        for (let k = 0; k < parts.length; k++) {
          const arr = parts[k];
          for (let t = 0; t < arr.length; t++) {
            out.push(arr[t]);
          }
        }
      }
      i += KPL_ROUND_BATCH;
    }
    return out;
  }

  /** 英雄名 → 官方英雄库条目（官方选手英雄池只给英雄名，需反查 id / 图标 / 定位） */
  private static async heroIndexByName(): Promise<Map<string, HeroBrief>> {
    const resp = await ToolsUpstream.heroes(false);
    const m: Map<string, HeroBrief> = new Map<string, HeroBrief>();
    const list = resp.heroes ?? [];
    for (let i = 0; i < list.length; i++) {
      m.set(list[i].name, list[i]);
    }
    return m;
  }

  /** 官方通道梯度榜：逐英雄出场 / 胜率（不含逐选手 KDA 与使用人数）。
   *  输出形状对齐 gradientWp，页面无需区分来源。 */
  private static async gradientKpl(eid: string, bust: boolean): Promise<GradientResp | null> {
    const season = ToolsUpstream.kplSeasonOf(eid);
    if (season.length === 0) {
      return null;
    }
    const key = `gradient-kpl-${eid}`;
    const hit = ToolsUpstream.memGet(key, 10 * 60e3, bust);
    if (hit !== null) {
      const got = hit as GradientResp;
      return ((got.list ?? []).length) > 0 ? got : null;
    }
    let rank: Array<Record<string, Object>> = [];
    try {
      rank = await ToolsUpstream.kplHeroRank(season);
    } catch (e) {
      return null;
    }
    if (rank.length === 0) {
      return null;
    }
    const idx = await ToolsUpstream.heroIndex();
    const list: GradientItem[] = [];
    for (let i = 0; i < rank.length; i++) {
      const h = rank[i];
      const games = J.num(h['match_count']);
      if (games <= 0) {
        continue;   // 官方榜含 0 出场英雄，需剔除
      }
      const hid = J.num(h['hero_id']);
      const upName = J.str(h['hero_name']);
      const wr = J.num(h['win_cr']);
      const wins = Math.round(games * wr);
      const losses = Math.max(0, games - wins);
      const official = idx.get(hid);
      const smooth = (wins + 2) / (games + 4);   // 与玩加通道同口径的贝叶斯平滑
      const gi: GradientItem = {
        name: official ? official.name : upName,
        alias: (official && official.name !== upName) ? upName : '',
        heroId: hid,
        icon: official ? official.icon : (hid > 0 ? heroIconUrl(String(hid)) : ''),
        types: official ? (official.types ?? ['未分类']) : ['未分类'],
        lanes: official ? (official.lanes ?? ['未知']) : ['未知'],
        title: official ? official.title : '',
        games: games,
        wins: wins,
        losses: losses,
        winRate: r2(wr),
        smooth: r2(smooth),
        // 官方通道不提供逐选手英雄池与 KDA（只有汇总出场/胜率），
        // 这两个字段留空，卡片整段省略而不是显示误导性的 0。
        userList: [],
        share: 0,
      };
      list.push(gi);
    }
    if (list.length === 0) {
      return null;
    }
    let totalPicks = 0;
    let maxGames = 1;
    for (let i = 0; i < list.length; i++) {
      totalPicks += (list[i].games ?? 0);
      if ((list[i].games ?? 0) > maxGames) {
        maxGames = list[i].games ?? 0;
      }
    }
    for (let i = 0; i < list.length; i++) {
      list[i].share = r1(((list[i].games ?? 0) / totalPicks) * 100);
      list[i].score = r2((list[i].smooth ?? 0) * 0.65 + ((list[i].games ?? 0) / maxGames) * 0.35);
    }
    list.sort((a: GradientItem, b: GradientItem) => {
      if ((b.score ?? 0) !== (a.score ?? 0)) {
        return (b.score ?? 0) - (a.score ?? 0);
      }
      return (b.winRate ?? 0) - (a.winRate ?? 0);
    });
    const labels: Map<string, string> = new Map<string, string>([
      ['T0', '版本答案'], ['T1', '主流选择'], ['T2', '体系英雄'], ['T3', '冷门 / 样本较少'],
    ]);
    const n = list.length > 0 ? list.length : 1;
    for (let i = 0; i < list.length; i++) {
      const pct = ((i + 1) / n) * 100;
      const tier = pct <= 10 ? 'T0' : (pct <= 30 ? 'T1' : (pct <= 60 ? 'T2' : 'T3'));
      list[i].rank = i + 1;
      list[i].tier = tier;
      list[i].tierLabel = labels.get(tier) ?? '';
      list[i].pct = Math.round(pct);
    }
    /* 人数 / 队伍数用官方选手接口补齐（官方英雄榜不含这两个口径） */
    let totalPlayers = 0;
    let totalTeams = 0;
    try {
      const perf = await ToolsUpstream.kplPlayerPerf(season);
      totalPlayers = perf.length;
      const teams: Set<string> = new Set<string>();
      for (let i = 0; i < perf.length; i++) {
        const t = J.str(perf[i]['team_id']);
        if (t.length > 0) {
          teams.add(t);
        }
      }
      totalTeams = teams.size;
    } catch (e) {
      /* 补不齐也不影响榜单本身 */
    }
    const resp: GradientResp = {
      ok: true,
      eventId: Number(eid),
      totalPlayers: totalPlayers,
      totalTeams: totalTeams,
      totalHeroPicks: totalPicks,
      totalPlayerGames: 0,
      source: 'kpl',
      sourceName: 'KPL 官方',
      updatedAt: Date.now(),
      list: list,
    };
    ToolsUpstream.memSet(key, resp);
    return resp;
  }

  /** 官方通道选手榜（含英雄池）。
   *  数据来源分工：
   *    · getSeasonPlayerPerf → KDA、经济/伤害/承伤占比、参团率、位置、战队
   *    · getScheduleDetail 逐小局 → 出场小局、胜负、英雄池
   *  官方未提供分均经济 / 分均伤害等绝对值，对应字段留空（页面显示「—」）。 */
  private static async playersKpl(eid: string, bust: boolean): Promise<PlayersResp | null> {
    const season = ToolsUpstream.kplSeasonOf(eid);
    if (season.length === 0) {
      return null;
    }
    const key = `players-kpl-${eid}`;
    const hit = ToolsUpstream.memGet(key, 10 * 60e3, bust);
    if (hit !== null) {
      const got = hit as PlayersResp;
      return (got.count ?? 0) > 0 ? got : null;
    }
    let perf: Array<Record<string, Object>> = [];
    try {
      perf = await ToolsUpstream.kplPlayerPerf(season);
    } catch (e) {
      return null;
    }
    if (perf.length === 0) {
      return null;
    }
    const byId = await ToolsUpstream.heroIndex();
    const byName = await ToolsUpstream.heroIndexByName();

    /* 逐小局记录 → 按选手聚合出场 / 胜负 / 英雄池。
       逐小局不可用（抓取失败 / 超限）时回落官方 Matchcount，胜负置空。 */
    const picks = await ToolsUpstream.kplRoundPicks(season);
    const games: Map<string, number> = new Map<string, number>();
    const wins: Map<string, number> = new Map<string, number>();
    const losses: Map<string, number> = new Map<string, number>();
    const poolOrder: Map<string, string[]> = new Map<string, string[]>();
    const pool: Map<string, Map<string, KplPoolStat>> = new Map<string, Map<string, KplPoolStat>>();
    for (let i = 0; i < picks.length; i++) {
      const r = picks[i];
      const pid = r.playerId;
      if (pid.length === 0) {
        continue;
      }
      games.set(pid, (games.get(pid) ?? 0) + 1);
      if (r.win) {
        wins.set(pid, (wins.get(pid) ?? 0) + 1);
      } else {
        losses.set(pid, (losses.get(pid) ?? 0) + 1);
      }
      const hname = r.heroName;
      if (hname.length === 0) {
        continue;
      }
      let order = poolOrder.get(pid);
      if (order === undefined) {
        order = [];
        poolOrder.set(pid, order);
      }
      let stat = pool.get(pid);
      if (stat === undefined) {
        stat = new Map<string, KplPoolStat>();
        pool.set(pid, stat);
      }
      let cur = stat.get(hname);
      if (cur === undefined) {
        cur = new KplPoolStat();
        stat.set(hname, cur);
        order.push(hname);
      }
      cur.games += 1;
      if (r.win) {
        cur.wins += 1;
      }
    }

    const out: PlayerItem[] = [];
    for (let i = 0; i < perf.length; i++) {
      const p = perf[i];
      const pid = J.str(p['player_id']);
      if (pid.length === 0) {
        continue;
      }
      const pos = J.num(p['position']);
      const lane = KPL_LANE_OF_POSITION.get(pos) ?? '未知';
      /* 场次 / 胜负口径：优先逐小局聚合（与英雄池、胜负自洽）；
         逐小局不可用（抓取失败 / 超限）时才回落官方 Matchcount，
         且胜负置 null 显示「—」——此前用 l = g - w（w=0）会把
         无数据选手标成「0 胜全负」，胜率也被拉成 0。 */
      let g = 0;
      let w: number | null = null;
      let l: number | null = null;
      const gg = games.get(pid);
      if (gg !== undefined) {
        g = gg;
        w = wins.get(pid) ?? 0;
        l = losses.get(pid) ?? 0;
      } else {
        g = J.num(p['Matchcount']);
      }
      const totalKill = J.num(p['TotalKill']);

      /* 英雄池：按出场降序、同场次按胜率降序 */
      const order = poolOrder.get(pid) ?? [];
      const stat = pool.get(pid);
      const pl: PlayerPoolItem[] = [];
      for (let j = 0; j < order.length; j++) {
        const hn = order[j];
        const st = stat === undefined ? undefined : stat.get(hn);
        const hg = st === undefined ? 0 : st.games;
        const hw = st === undefined ? 0 : st.wins;
        const official = byName.get(hn);
        const hid = official ? official.id : 0;
        pl.push({
          name: official ? official.name : hn,
          alias: official ? hn : '',
          heroId: hid,
          games: hg,
          wins: hw,
          losses: Math.max(0, hg - hw),
          winRate: hg > 0 ? r2(hw / hg) : 0,
          icon: official ? official.icon : (hid > 0 ? heroIconUrl(String(hid)) : ''),
          types: official ? (official.types ?? []) : [],
          lanes: official ? (official.lanes ?? []) : [],
          title: official ? official.title : '',
        });
      }
      pl.sort((a: PlayerPoolItem, b: PlayerPoolItem) => {
        if ((b.games ?? 0) !== (a.games ?? 0)) {
          return (b.games ?? 0) - (a.games ?? 0);
        }
        return (b.winRate ?? 0) - (a.winRate ?? 0);
      });
      for (let j = 0; j < pl.length; j++) {
        pl[j].rank = j + 1;
      }

      /* 主打分路按英雄池出场加权（与玩加通道同口径） */
      const laneWeight: Map<string, number> = new Map<string, number>();
      for (let j = 0; j < pl.length; j++) {
        const lanes = pl[j].lanes ?? [];
        for (let k = 0; k < lanes.length; k++) {
          laneWeight.set(lanes[k], (laneWeight.get(lanes[k]) ?? 0) + (pl[j].games ?? 0));
        }
      }
      const lanes: string[] = [];
      laneWeight.forEach((v: number, k: string) => {
        lanes.push(k);
      });
      lanes.sort((a: string, b: string) => (laneWeight.get(b) ?? 0) - (laneWeight.get(a) ?? 0));
      const firstHero = pl.length > 0 ? byId.get(pl[0].heroId ?? 0) : undefined;

      const row: PlayerItem = {
        id: pid,
        name: J.str(p['player_short_name']).length > 0
          ? J.str(p['player_short_name']) : J.str(p['player_real_name']),
        team: J.str(p['team_name']),
        teamId: J.str(p['team_id']),
        games: g,
        wins: w,
        losses: l,
        winRate: (w !== null && g > 0) ? r2(w / g) : null,
        kda: r2(J.num(p['KDA'])),
        kills: g > 0 ? r1(totalKill / g) : 0,
        lane: lanes.length > 0 ? lanes[0] : lane,
        lanes: lanes.length > 0 ? lanes : [lane],
        types: firstHero ? (firstHero.types ?? []) : [],
        pool: pl,
        poolSize: pl.length,
        // 占比类：官方直接给百分数（如 "22.8" 表示 22.8%）
        goldPercent: kplPctText(p['AVGGoldCR']),
        goldPercentNum: r1(J.num(p['AVGGoldCR'])),
        dmgPercent: kplPctText(p['AVGHurtCR']),
        dmgPercentNum: r1(J.num(p['AVGHurtCR'])),
        dmgTakenPercent: kplPctText(p['AVGBeHurtCr']),
        dmgTakenPercentNum: r1(J.num(p['AVGBeHurtCr'])),
        attendRate: kplPctText(p['AVGPartacipationCR']),
        attendRateNum: r1(J.num(p['AVGPartacipationCR'])),
        totals: { kills: totalKill },
        // 官方未提供：显式置空，页面显示「—」而不是误导性的 0
        deaths: null,
        assists: null,
        goldPerMin: null,
        dmgPerMin: null,
        dmgTakenPerMin: null,
        mostKills: null,
        mostAssists: null,
        mostDeaths: null,
        dmgConversion: null,
        durationSec: null,
        durationMin: null,
        rank: 0,
        source: 'kpl',
      };
      out.push(row);
    }
    out.sort((a: PlayerItem, b: PlayerItem) => {
      const ka = a.kda ?? 0;
      const kb = b.kda ?? 0;
      if (ka !== kb) {
        return kb - ka;
      }
      const ga = a.games ?? 0;
      const gb = b.games ?? 0;
      if (ga !== gb) {
        return gb - ga;
      }
      return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
    });
    const n = out.length > 0 ? out.length : 1;
    for (let i = 0; i < out.length; i++) {
      out[i].rank = i + 1;
    }
    const resp: PlayersResp = {
      ok: true,
      eventId: Number(eid),
      count: out.length,
      source: 'kpl',
      players: out,
    };
    ToolsUpstream.memSet(key, resp);
    return resp;
  }
}

/** 字典条目（公告解析用） */
class DictEntry {
  id: string = '';
  icon: string = '';
  title: string = '';
  type: string = '';
}

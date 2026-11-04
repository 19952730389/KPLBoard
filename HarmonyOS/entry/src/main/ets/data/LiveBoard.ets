/* 直连公网的看板数据层（无需桌面端、无需任何配置）
 * ---------------------------------------------------------------------------
 * 数据源与桌面端 server.js 完全相同的上游，全部为公网可直达接口：
 *   ① 玩加赛事 wanplus.cn/ajax/schedule/list —— 赛程 / 比分 / 阶段
 *      （按周拉取，端内缓存 10 分钟，手动刷新强制重拉）
 *   ② KPL 官网数据接口（kpl.qq.com 同款） —— 进行中比赛的权威大比分与状态
 *      （逐小局结束数秒内更新；端内缓存 20s）
 *   ③ esportsresults（PandaScore 数据）—— 逐小局胜方补充，失败不影响主流程
 *
 * 端内重新实现了桌面端的 normalizeMatch / decorate / buildStandings /
 * buildGroupedStandings / buildSummary / boardOf 管线，输出与桌面端
 * /api/board 完全同构的 BoardResp——页面代码零改动即可显示实时数据。
 *
 * 状态判断（与桌面端 decorate 一致）：over → 已结束；liveFlag → 进行中；
 * 否则按日期推算（早于今天 → 已结束；今天且已过开赛时间 → 进行中）。
 */
import { common } from '@kit.AbilityKit';
// 本 SDK 的 CoreFileKit 导出名是 fileIo（即 @ohos.file.fs），重命名为 fs 使用
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { BundleStore } from './BundleStore';
import {
  BoardResp,
  BoardSummary,
  EventItem,
  EventsResp,
  FormItem,
  MatchItem,
  RealtimeInfo,
  StageCount,
  StandingGroup,
  StandingRow,
  StandingsBlock,
  TeamRef,
} from './Models';

const UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const WANPLUS_API: string = 'https://wanplus.cn/ajax/schedule/list';
const KPL_RT_API: string = 'https://kplshop-op.timi-esports.qq.com/kplow/getScheduleList';
const RT_API: string = 'https://esportsresults.com/api/matches?date=';
const GAME: string = 'kog';
const GAMETYPE: string = '6';
/** 玩加赛程缓存：10 分钟（手动刷新强制重拉） */
const WANPLUS_TTL: number = 10 * 60 * 1000;
/** KPL 官方实时缓存：20s（与桌面端一致） */
const RT_TTL: number = 20000;
const TIMEOUT: number = 15000;

/* ==================== JSON 取值工具（上游字段可缺省） ==================== */

class J {
  static rec(v: Object | undefined | null): Record<string, Object> {
    if (v === undefined || v === null) {
      const e: Record<string, Object> = {};
      return e;
    }
    return v as Record<string, Object>;
  }

  static arr(v: Object | undefined | null): Array<Object> {
    if (v === undefined || v === null || !Array.isArray(v)) {
      const e: Array<Object> = [];
      return e;
    }
    return v as Array<Object>;
  }

  static str(v: Object | undefined | null): string {
    if (v === undefined || v === null) {
      return '';
    }
    const s = String(v);
    return s === 'undefined' || s === 'null' ? '' : s;
  }

  static num(v: Object | undefined | null): number {
    if (v === undefined || v === null) {
      return 0;
    }
    const n = Number(String(v));
    return isNaN(n) ? 0 : n;
  }

  static bool(v: Object | undefined | null): boolean {
    if (v === undefined || v === null) {
      return false;
    }
    if (typeof v === 'boolean') {
      return v as boolean;
    }
    return String(v) === 'true' || String(v) === '1';
  }
}

/* ==================== 内部数据结构 ==================== */

class LiveTeam {
  id: string = '';
  name: string = '';
  icon: string = '';
  score: number = 0;
}

class LiveMatch {
  id: string = '';
  date: string = '';
  dateLabel: string = '';
  time: string = '';
  stage: string = '';
  bo: number = 0;
  over: boolean = false;
  liveFlag: boolean = false;
  hasVideo: boolean = false;
  a: LiveTeam = new LiveTeam();
  b: LiveTeam = new LiveTeam();
  legs: Array<string | null> = [];
  realtime: boolean = false;
  officialScore: boolean = false;
}

/** 单个赛季的端内缓存 */
class EventRec {
  matches: LiveMatch[] = [];
  updatedAt: number = 0;
  wanplusAt: number = 0;
  lastOk: boolean = false;
  error: string = '';
  loading: boolean = false;
  /** 进行中的全量赛程拉取：并发调用共用同一个 Promise，
   *  后来的调用（尤其是手动刷新）await 它而不是被丢弃 */
  pending: Promise<void> | null = null;
}

/** 实时源（官方 / PandaScore）的一条记录 */
class RtEntry {
  cnA: string = '';
  cnB: string = '';
  scoreA: number = 0;
  scoreB: number = 0;
  status: string = 'scheduled';
  bestOf: number = 0;
  legs: Array<string | null> = [];
  /**
   * 开赛时刻换算出的北京日期键 yyyyMMdd（与玩加赛程的 date 同格式）。
   * 年度总决赛这类赛制里同一对战队会在不同阶段多次交手（如 重庆狼队 vs 深圳DYG
   * 既有 10-16 擂台赛也有 10-20 突围赛），只按队名配准会把旧比赛的结果
   * 盖到新比赛上——上游按时间正序返回，后写入的条目覆盖先写入的。
   */
  dateKey: string = '';
}

class RtState {
  at: number = 0;
  ok: boolean = false;
  error: string = '';
  updatedAt: number = 0;
  seen: number = 0;
  matched: number = 0;
  list: RtEntry[] = [];
  pending: Promise<boolean> | null = null;
}

/** 分组配置（与桌面端 GROUPS 一致：2026 年度总决赛 大师组 / 精英组） */
class GroupCfg {
  key: string;
  name: string;
  desc: string;
  rule: string;
  accent: string;
  direct: number;
  playin: number;
  teams: string[];

  constructor(key: string, name: string, desc: string, rule: string, accent: string,
    direct: number, playin: number, teams: string[]) {
    this.key = key;
    this.name = name;
    this.desc = desc;
    this.rule = rule;
    this.accent = accent;
    this.direct = direct;
    this.playin = playin;
    this.teams = teams;
  }
}

const GROUPS: GroupCfg[] = [
  new GroupCfg('masters', '大师组', '年度积分 1-6 名',
    '组内前 4 直接晋级淘汰赛，第 5-6 名进入突围赛', '#f5c451', 4, 2,
    ['重庆狼队', '成都AG超玩会', '北京JDG', '广州TTG', 'KSG', '北京WB']),
  new GroupCfg('elite', '精英组', '年度积分 7-12 名',
    '组内第 1 直接晋级淘汰赛，第 2-5 名进入突围赛，第 6 名淘汰', '#9b6bff', 1, 4,
    ['长沙TES.A', '上海EDG.M', '杭州LGD.NBW', '深圳DYG', '济南RW侠', '南通Hero久竞']),
];

/** 官方源状态码 → 状态 */
function kplStatusOf(code: number): string {
  if (code === 3) {
    return 'live';
  }
  if (code === 4) {
    return 'completed';
  }
  return 'scheduled';
}

function normName(n: string): string {
  let out: string = '';
  for (let i = 0; i < n.length; i++) {
    const c = n.charAt(i);
    if (c !== ' ' && c !== '.' && c !== '·' && c !== '．') {
      out += c;
    }
  }
  return out.toLowerCase();
}

/** 实时源英文队名 → 玩加中文队名（与桌面端 TEAM_ALIAS 一致） */
class AliasMap {
  static map: Map<string, string> = new Map<string, string>();

  static get(en: string): string {
    const v = AliasMap.map.get(en);
    return v === undefined ? '' : v;
  }
}

AliasMap.map.set('agsuperplay', '成都AG超玩会');
AliasMap.map.set('douyugaming', '深圳DYG');
AliasMap.map.set('jdgaming', '北京JDG');
AliasMap.map.set('herojiujing', '南通Hero久竞');
AliasMap.map.set('talentgaming', '广州TTG');
AliasMap.map.set('roguewarriors', '济南RW侠');
AliasMap.map.set('wolves', '重庆狼队');
AliasMap.map.set('edwardgaming', '上海EDG.M');
AliasMap.map.set('weibogaming', '北京WB');
AliasMap.map.set('topesportsarmor', '长沙TES.A');
AliasMap.map.set('kuaishougaming', 'KSG');
AliasMap.map.set('lgdnbw', '杭州LGD.NBW');

/* ==================== 时间工具（统一按北京时间 UTC+8） ==================== */

function pad2(n: number): string {
  return n < 10 ? '0' + n : String(n);
}

function bjTodayKey(): string {
  const now = new Date(Date.now() + 8 * 3600 * 1000);
  return `${now.getUTCFullYear()}${pad2(now.getUTCMonth() + 1)}${pad2(now.getUTCDate())}`;
}

/** 'YYYY-MM-DD' → 北京时间当天 0 点的秒级时间戳 */
function dayStartSec(dateStr: string): number {
  return Math.floor(Date.parse(`${dateStr}T00:00:00+08:00`) / 1000);
}

function bjNowMin(): number {
  const now = new Date(Date.now() + 8 * 3600 * 1000);
  return now.getUTCHours() * 60 + now.getUTCMinutes();
}

function bjDateKey(): string {
  const now = new Date(Date.now() + 8 * 3600 * 1000);
  return `${now.getUTCFullYear()}-${pad2(now.getUTCMonth() + 1)}-${pad2(now.getUTCDate())}`;
}

/**
 * Unix 秒 → 北京日期键 yyyyMMdd。
 * 实时源（官方 start_timestamp / PandaScore date）都要靠它换算成与赛程
 * 同格式的日期，Aggregator 才能按「队名 + 日期」配准。缺字段时返回空串，
 * 由调用方退回纯队名兜底索引。
 */
function dateKeyOfUnixSec(unixSec: number): string {
  if (!(unixSec > 0)) {
    return '';
  }
  const d = new Date(unixSec * 1000 + 8 * 3600 * 1000);
  return `${d.getUTCFullYear()}${pad2(d.getUTCMonth() + 1)}${pad2(d.getUTCDate())}`;
}

/** ISO8601（含 Z / 带时区偏移）→ Unix 秒；解析失败返回 0 */
function isoToUnixSec(s: string): number {
  if (s.length === 0) {
    return 0;
  }
  const ms = Date.parse(s);
  return isNaN(ms) ? 0 : Math.floor(ms / 1000);
}

/** 赛事覆盖的每一周的周一 0 点（秒），末尾多取两周防溢出（与桌面端一致） */
function weekStartsOf(ev: EventItem): number[] {
  const starts: number[] = [];
  const start: string = (ev.start ?? '').replace(/-/g, '');
  const end: string = (ev.end ?? '').replace(/-/g, '');
  if (start.length !== 8 || end.length !== 8) {
    return starts;
  }
  const sd = `${start.slice(0, 4)}-${start.slice(4, 6)}-${start.slice(6, 8)}`;
  const ed = `${end.slice(0, 4)}-${end.slice(4, 6)}-${end.slice(6, 8)}`;
  let cursor: number = dayStartSec(sd);
  const wd = new Date(cursor * 1000 + 8 * 3600 * 1000).getUTCDay();
  cursor -= (wd === 0 ? 6 : wd - 1) * 86400;
  const limit: number = dayStartSec(ed) + 14 * 86400;
  while (cursor <= limit) {
    starts.push(cursor);
    cursor += 7 * 86400;
  }
  return starts;
}

function isActive(ev: EventItem): boolean {
  if ((ev.mode ?? 'live') !== 'live') {
    return false;
  }
  const s: string = (ev.start ?? '').replace(/-/g, '');
  const e: string = (ev.end ?? '').replace(/-/g, '');
  if (s.length !== 8 || e.length !== 8) {
    return false;
  }
  const t = bjTodayKey();
  return t >= s && t <= e;
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });
}

/* ==================== 玩加赛程通道 ==================== */

/** 拉一周赛程并解析为标准场次（失败返回空数组） */
async function fetchWeek(eventId: number, weekStartSec: number): Promise<LiveMatch[]> {
  const req = http.createHttp();
  try {
    const opt: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: {
        'User-Agent': UA,
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        'Accept': 'application/json, text/javascript, */*; q=0.01',
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': `https://wanplus.cn/${GAME}/schedule`,
        'Origin': 'https://wanplus.cn',
      },
      extraData: `game=${GAME}&eids=${eventId}&time=${weekStartSec}`,
      connectTimeout: TIMEOUT,
      readTimeout: TIMEOUT,
      expectDataType: http.HttpDataType.STRING,
    };
    const resp = await req.request(WANPLUS_API, opt);
    if (resp.responseCode !== 200) {
      return [];
    }
    const txt: string = typeof resp.result === 'string' ? resp.result : '';
    if (txt.length === 0) {
      return [];
    }
    const root = J.rec(JSON.parse(txt) as Object);
    if (J.num(root['ret']) !== 0 && J.num(root['code']) !== 0) {
      return [];
    }
    return parseWeek(J.rec(root['data']));
  } catch (e) {
    return [];
  } finally {
    try {
      req.destroy();
    } catch (e) {
      /* 忽略 */
    }
  }
}

function parseWeek(data: Record<string, Object>): LiveMatch[] {
  const out: LiveMatch[] = [];
  const sl = J.rec(data['scheduleList']);
  const keys = Object.keys(sl);
  for (let i = 0; i < keys.length; i++) {
    const dateKey = keys[i];
    const day = J.rec(sl[dateKey]);
    const list = day['list'];
    if (!Array.isArray(list)) {
      continue; // 无比赛的日期上游给 false
    }
    const dateLabel = J.str(day['date']);
    const arr = J.arr(list);
    for (let k = 0; k < arr.length; k++) {
      out.push(normalizeMatch(J.rec(arr[k]), dateKey, dateLabel));
    }
  }
  return out;
}

function normalizeMatch(m: Record<string, Object>, dateKey: string, dateLabel: string): LiveMatch {
  const out = new LiveMatch();
  out.id = J.str(m['scheduleid']);
  out.date = dateKey;
  out.dateLabel = dateLabel.length > 0 ? dateLabel : J.str(m['date']);
  out.time = J.str(m['starttime']);
  out.stage = J.str(m['groupname']);
  out.bo = J.num(m['bonum']);
  out.over = J.bool(m['isover']);
  out.liveFlag = J.bool(m['live']);
  out.hasVideo = J.bool(m['hasvideo']);
  out.a.id = J.str(m['oneseedid']);
  out.a.name = J.str(m['oneseedname']).length > 0 ? J.str(m['oneseedname']) : '待定';
  out.a.icon = J.str(m['oneicon']);
  out.a.score = J.num(m['onewin']);
  out.b.id = J.str(m['twoseedid']);
  out.b.name = J.str(m['twoseedname']).length > 0 ? J.str(m['twoseedname']) : '待定';
  out.b.icon = J.str(m['twoicon']);
  out.b.score = J.num(m['twowin']);
  // 逐小局：oneScore / twoScore 是每局 1/0 的数组
  const ga = J.arr(m['oneScore']);
  const gb = J.arr(m['twoScore']);
  const len = Math.max(ga.length, gb.length, out.bo);
  for (let i = 0; i < len; i++) {
    const va: number = i < ga.length ? J.num(ga[i]) : -1;
    const vb: number = i < gb.length ? J.num(gb[i]) : -1;
    out.legs.push(va === 1 ? 'A' : vb === 1 ? 'B' : null);
  }
  return out;
}

function cloneMatch(m: LiveMatch): LiveMatch {
  const c = new LiveMatch();
  c.id = m.id;
  c.date = m.date;
  c.dateLabel = m.dateLabel;
  c.time = m.time;
  c.stage = m.stage;
  c.bo = m.bo;
  c.over = m.over;
  c.liveFlag = m.liveFlag;
  c.hasVideo = m.hasVideo;
  c.a.id = m.a.id;
  c.a.name = m.a.name;
  c.a.icon = m.a.icon;
  c.a.score = m.a.score;
  c.b.id = m.b.id;
  c.b.name = m.b.name;
  c.b.icon = m.b.icon;
  c.b.score = m.b.score;
  c.legs = m.legs.slice();
  c.realtime = m.realtime;
  c.officialScore = m.officialScore;
  return c;
}

function sortMatches(list: LiveMatch[]): void {
  list.sort((x: LiveMatch, y: LiveMatch) => {
    if (x.date !== y.date) {
      return x.date < y.date ? -1 : 1;
    }
    return (x.time || '') < (y.time || '') ? -1 : 1;
  });
}

/** 无 bo 字段时按赛果推断（3/5/7 局） */
function inferBo(list: LiveMatch[]): number {
  let mx = 0;
  for (let i = 0; i < list.length; i++) {
    const m = list[i];
    if (m.over && m.a.score + m.b.score > mx) {
      mx = m.a.score + m.b.score;
    }
  }
  if (mx <= 3) {
    return 3;
  }
  if (mx <= 5) {
    return 5;
  }
  return 7;
}

/* ==================== KPL 官方实时通道 ==================== */

interface KplReq {
  direction: number;
  pivot_scheduleid: string;
  page_size: number;
}

async function fetchKplRealtime(): Promise<RtEntry[]> {
  const req = http.createHttp();
  try {
    const body: KplReq = { direction: 1, pivot_scheduleid: '', page_size: 50 };
    const opt: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: {
        'User-Agent': UA,
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Origin': 'https://kpl.qq.com',
        'Referer': 'https://kpl.qq.com/',
      },
      extraData: JSON.stringify(body),
      connectTimeout: 12000,
      readTimeout: 12000,
      expectDataType: http.HttpDataType.STRING,
    };
    const resp = await req.request(KPL_RT_API, opt);
    if (resp.responseCode !== 200) {
      throw new Error(`官方源返回 ${resp.responseCode}`);
    }
    const txt: string = typeof resp.result === 'string' ? resp.result : '';
    const root = J.rec(JSON.parse(txt) as Object);
    if (J.num(root['result']) !== 0) {
      throw new Error(J.str(root['msg']).length > 0 ? J.str(root['msg']) : '官方源数据异常');
    }
    const data = J.rec(root['data']);
    const list = J.arr(data['list']);
    const out: RtEntry[] = [];
    for (let i = 0; i < list.length; i++) {
      const m = J.rec(list[i]);
      const cnA = J.str(m['team_a_name']);
      const cnB = J.str(m['team_b_name']);
      if (cnA.length === 0 || cnB.length === 0) {
        continue;
      }
      const e = new RtEntry();
      e.cnA = cnA;
      e.cnB = cnB;
      e.scoreA = J.num(m['team_a_score']);
      e.scoreB = J.num(m['team_b_score']);
      e.status = kplStatusOf(J.num(m['schedule_status']));
      e.bestOf = J.num(m['bo_total']);
      // 官方时间戳是 Unix 秒（可能是字符串），换算成北京日期键供按天配准
      e.dateKey = dateKeyOfUnixSec(J.num(m['start_timestamp']));
      out.push(e);
    }
    return out;
  } finally {
    try {
      req.destroy();
    } catch (e) {
      /* 忽略 */
    }
  }
}

/* ==================== PandaScore 通道（逐小局补充，可失败） ==================== */

async function fetchRealtime(dateKey: string): Promise<RtEntry[]> {
  const req = http.createHttp();
  try {
    const opt: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: { 'User-Agent': UA, 'Accept': 'application/json' },
      connectTimeout: 12000,
      readTimeout: 12000,
      expectDataType: http.HttpDataType.STRING,
    };
    const resp = await req.request(RT_API + dateKey, opt);
    if (resp.responseCode !== 200) {
      throw new Error(`实时源返回 ${resp.responseCode}`);
    }
    const txt: string = typeof resp.result === 'string' ? resp.result : '';
    const root = J.rec(JSON.parse(txt) as Object);
    const list = J.arr(root['matches']);
    const out: RtEntry[] = [];
    for (let i = 0; i < list.length; i++) {
      const m = J.rec(list[i]);
      if (J.str(m['game']).toLowerCase().indexOf('king of glory') < 0) {
        continue;
      }
      const aEn = normName(J.str(m['teamA']));
      const bEn = normName(J.str(m['teamB']));
      const e = new RtEntry();
      e.cnA = AliasMap.get(aEn);
      e.cnB = AliasMap.get(bEn);
      e.scoreA = J.num(m['scoreA']);
      e.scoreB = J.num(m['scoreB']);
      e.status = J.str(m['status']);
      e.bestOf = J.num(m['bestOf']);
      // "2026-10-20T10:07:49Z" 是 UTC，换算成北京日期键；上游偶发缺字段时留空走兜底
      e.dateKey = dateKeyOfUnixSec(isoToUnixSec(J.str(m['date'])));
      const games = J.arr(m['games']);
      for (let k = 0; k < games.length; k++) {
        const g = J.rec(games[k]);
        // 只认「已结束」的小局，避免多算（finished 缺省时视为已结束）
        const fin = g['finished'];
        const finOk = fin === undefined ? true : J.bool(fin);
        const w = J.str(g['winner']);
        e.legs.push(finOk && w.length > 0 ? w : null);
      }
      out.push(e);
    }
    return out;
  } finally {
    try {
      req.destroy();
    } catch (e) {
      /* 忽略 */
    }
  }
}

/* ==================== 实时覆盖（与桌面端 applyOfficial / applyRealtime 一致） ==================== */

/** 双索引：主键「归一化队名 + 北京日期键」，兜底键「仅归一化队名」 */
class RtIndex {
  byDay: Map<string, RtEntry> = new Map<string, RtEntry>();
  byTeam: Map<string, RtEntry> = new Map<string, RtEntry>();
}

/** 状态新鲜度：数字越大信息越新（completed 视为 live 的终态） */
function statusRank(s: string): number {
  if (s === 'scheduled') {
    return 0;
  }
  if (s === 'live') {
    return 1;
  }
  return 2;
}

function matchIndexOf(list: RtEntry[]): RtIndex {
  const idx = new RtIndex();
  for (let i = 0; i < list.length; i++) {
    const r = list[i];
    if (r.cnA.length === 0 || r.cnB.length === 0) {
      continue;
    }
    const teams = `${normName(r.cnA)}|${normName(r.cnB)}`;
    if (r.dateKey.length > 0) {
      // 同一天同一对阵出现多条时保留状态最新的那条；首次插入必须无条件写入
      const key = `${teams}@${r.dateKey}`;
      const old = idx.byDay.get(key);
      if (old === undefined || statusRank(r.status) > statusRank(old.status)) {
        idx.byDay.set(key, r);
      }
    }
    // 上游偶发缺日期字段时仍要能配准，故保留纯队名兜底索引
    idx.byTeam.set(teams, r);
  }
  return idx;
}

/** 命中结果：条目 + 是否需要交换左右 */
class RtHit {
  entry: RtEntry;
  swap: boolean;

  constructor(entry: RtEntry, swap: boolean) {
    this.entry = entry;
    this.swap = swap;
  }
}

/**
 * 取某场比赛的实时条目：先按「队名 + 日期」精确匹配，
 * 实时源缺日期时才退回「仅队名」。
 */
function lookupEntry(a: string, b: string, date: string, idx: RtIndex): RtHit | null {
  const na: string = normName(a);
  const nb: string = normName(b);
  if (date.length > 0) {
    const d1 = idx.byDay.get(`${na}|${nb}@${date}`);
    if (d1 !== undefined) {
      return new RtHit(d1, false);
    }
    const d2 = idx.byDay.get(`${nb}|${na}@${date}`);
    if (d2 !== undefined) {
      return new RtHit(d2, true);
    }
  }
  const t1 = idx.byTeam.get(`${na}|${nb}`);
  if (t1 !== undefined) {
    return new RtHit(t1, false);
  }
  const t2 = idx.byTeam.get(`${nb}|${na}`);
  if (t2 !== undefined) {
    return new RtHit(t2, true);
  }
  return null;
}

/** 官方源覆盖：大比分与状态最权威（就地修改） */
function applyOfficial(matches: LiveMatch[], kpl: RtState): void {
  kpl.matched = 0;
  if (!kpl.ok || kpl.list.length === 0) {
    return;
  }
  const idx = matchIndexOf(kpl.list);
  for (let i = 0; i < matches.length; i++) {
    const m = matches[i];
    if (m.a.name.length === 0 || m.b.name.length === 0) {
      continue;
    }
    const hit = lookupEntry(m.a.name, m.b.name, m.date, idx);
    if (hit === null) {
      continue;
    }
    const r = hit.entry;
    const swap = hit.swap;
    const playable = r.status === 'live' || r.status === 'completed';
    if (playable) {
      m.a.score = swap ? r.scoreB : r.scoreA;
      m.b.score = swap ? r.scoreA : r.scoreB;
    }
    if (r.status === 'completed') {
      m.over = true;
      m.liveFlag = false;
    } else if (r.status === 'live') {
      m.over = false;
      m.liveFlag = true;
      // 上游偶发状态滞后（已到赛点仍报 live）：BO 制拿到所需胜局即视为结束
      const need = r.bestOf > 0 ? Math.ceil(r.bestOf / 2) : 0;
      if (need > 0 && Math.max(m.a.score, m.b.score) >= need) {
        m.over = true;
        m.liveFlag = false;
      }
    }
    m.realtime = true;
    // officialScore 只在「可结算」（live/completed）时置位：scheduled（未开始）时
    // 即便官方源没有实时数据，也不该屏蔽 PandaScore 的兜底覆盖。
    if (playable) {
      m.officialScore = true;
    }
    kpl.matched += 1;
  }
}

/** PandaScore 补充：逐小局胜方；官方未覆盖的场次兜底大比分与状态（就地修改） */
function applyRealtime(matches: LiveMatch[], rt: RtState): void {
  rt.matched = 0;
  if (!rt.ok || rt.list.length === 0) {
    return;
  }
  const idx = matchIndexOf(rt.list);
  for (let i = 0; i < matches.length; i++) {
    const m = matches[i];
    if (m.a.name.length === 0 || m.b.name.length === 0) {
      continue;
    }
    const hit = lookupEntry(m.a.name, m.b.name, m.date, idx);
    if (hit === null) {
      continue;
    }
    const r = hit.entry;
    const swap = hit.swap;
    const playable = r.status === 'live' || r.status === 'completed';
    if (playable && !m.officialScore) {
      m.a.score = swap ? r.scoreB : r.scoreA;
      m.b.score = swap ? r.scoreA : r.scoreB;
    }
    if (r.legs.length > 0) {
      const legs = r.legs.slice();
      if (swap) {
        for (let k = 0; k < legs.length; k++) {
          const v = legs[k];
          legs[k] = v === 'A' ? 'B' : v === 'B' ? 'A' : v;
        }
      }
      let known = 0;
      for (let k = 0; k < legs.length; k++) {
        if (legs[k] !== null) {
          known++;
        }
      }
      let oldKnown = 0;
      for (let k = 0; k < m.legs.length; k++) {
        if (m.legs[k] !== null) {
          oldKnown++;
        }
      }
      // 只在实时源的小局信息不少于本地时覆盖，避免信息倒退
      if (known >= oldKnown) {
        m.legs = legs;
        // 逐小局先落地、大比分后结算：用逐小局推导比分校正。
        // 但官方源已给出权威大比分时尊重官方、不覆盖。
        if (!m.officialScore) {
          let dA = 0;
          let dB = 0;
          for (let k = 0; k < legs.length; k++) {
            if (legs[k] === 'A') {
              dA++;
            } else if (legs[k] === 'B') {
              dB++;
            }
          }
          if (dA + dB > m.a.score + m.b.score) {
            m.a.score = dA;
            m.b.score = dB;
          }
        }
      }
    }
    if (r.status === 'completed' && !m.officialScore) {
      m.over = true;
      m.liveFlag = false;
    } else if (r.status === 'live' && !m.officialScore) {
      m.over = false;
      m.liveFlag = true;
      const need = r.bestOf > 0 ? Math.ceil(r.bestOf / 2) : 0;
      if (need > 0 && Math.max(m.a.score, m.b.score) >= need) {
        m.over = true;
        m.liveFlag = false;
      }
    }
    m.realtime = true;
    rt.matched += 1;
  }
}

/* ==================== 统计聚合（与桌面端一致） ==================== */

function sortRows(rows: StandingRow[]): StandingRow[] {
  rows.sort((x: StandingRow, y: StandingRow) => {
    const p = (y.points ?? 0) - (x.points ?? 0);
    if (p !== 0) {
      return p;
    }
    const n = (y.net ?? 0) - (x.net ?? 0);
    if (n !== 0) {
      return n;
    }
    const gw = (y.gameWins ?? 0) - (x.gameWins ?? 0);
    if (gw !== 0) {
      return gw;
    }
    const gl = (x.gameLosses ?? 0) - (y.gameLosses ?? 0);
    if (gl !== 0) {
      return gl;
    }
    return x.name < y.name ? -1 : x.name > y.name ? 1 : 0;
  });
  for (let i = 0; i < rows.length; i++) {
    rows[i].rank = i + 1;
  }
  return rows;
}

class AccRow {
  id: string = '';
  name: string = '';
  icon: string = '';
  matches: number = 0;
  wins: number = 0;
  losses: number = 0;
  gameWins: number = 0;
  gameLosses: number = 0;
  points: number = 0;
  form: FormItem[] = [];
  opponents: string[] = [];
}

function buildStandings(items: MatchItem[]): StandingRow[] {
  const table: Map<string, AccRow> = new Map<string, AccRow>();
  for (let i = 0; i < items.length; i++) {
    const m = items[i];
    if (m.status !== 'finished' || m.a.name.length === 0 || m.b.name.length === 0) {
      continue;
    }
    let A = table.get(m.a.id ?? m.a.name);
    if (A === undefined) {
      A = new AccRow();
      A.id = m.a.id ?? m.a.name;
      A.name = m.a.name;
      A.icon = m.a.icon ?? '';
      table.set(A.id, A);
    }
    let B = table.get(m.b.id ?? m.b.name);
    if (B === undefined) {
      B = new AccRow();
      B.id = m.b.id ?? m.b.name;
      B.name = m.b.name;
      B.icon = m.b.icon ?? '';
      table.set(B.id, B);
    }
    A.matches += 1;
    B.matches += 1;
    A.opponents.push(B.name);
    B.opponents.push(A.name);
    A.gameWins += m.a.score ?? 0;
    A.gameLosses += m.b.score ?? 0;
    B.gameWins += m.b.score ?? 0;
    B.gameLosses += m.a.score ?? 0;
    const sa = m.a.score ?? 0;
    const sb = m.b.score ?? 0;
    if (sa > sb) {
      A.wins += 1;
      B.losses += 1;
      A.points += 1;
      const fa: FormItem = { r: 'W', vs: B.name, score: `${sa}-${sb}` };
      A.form.push(fa);
      const fb: FormItem = { r: 'L', vs: A.name, score: `${sb}-${sa}` };
      B.form.push(fb);
    } else if (sb > sa) {
      B.wins += 1;
      A.losses += 1;
      B.points += 1;
      const fa: FormItem = { r: 'L', vs: B.name, score: `${sa}-${sb}` };
      A.form.push(fa);
      const fb: FormItem = { r: 'W', vs: A.name, score: `${sb}-${sa}` };
      B.form.push(fb);
    } else {
      const fa: FormItem = { r: 'D', vs: B.name, score: `${sa}-${sb}` };
      A.form.push(fa);
      const fb: FormItem = { r: 'D', vs: A.name, score: `${sb}-${sa}` };
      B.form.push(fb);
    }
  }
  const out: StandingRow[] = [];
  table.forEach((t: AccRow) => {
    const row: StandingRow = {
      id: t.id,
      name: t.name,
      icon: t.icon,
      matches: t.matches,
      wins: t.wins,
      losses: t.losses,
      gameWins: t.gameWins,
      gameLosses: t.gameLosses,
      net: t.gameWins - t.gameLosses,
      points: t.points,
      winRate: t.matches > 0 ? Math.round((t.wins / t.matches) * 1000) / 1000 : 0,
      gameRate: t.gameWins + t.gameLosses > 0
        ? Math.round((t.gameWins / (t.gameWins + t.gameLosses)) * 1000) / 1000 : 0,
      form: t.form.slice(-6),
      opponents: t.opponents,
      rank: 0,
      groupKey: groupKeyOf(t.name) ?? undefined,
    };
    out.push(row);
  });
  return out;
}

function teamGroupOf(name: string): string {
  const n = normName(name);
  if (n.length === 0) {
    return '';
  }
  for (let i = 0; i < GROUPS.length; i++) {
    const g = GROUPS[i];
    for (let k = 0; k < g.teams.length; k++) {
      const tn = normName(g.teams[k]);
      if (n === tn || tn.indexOf(n) >= 0 || n.indexOf(tn) >= 0) {
        return g.key;
      }
    }
  }
  return '';
}

function groupKeyOf(name: string): string {
  return teamGroupOf(name);
}

function advanceOf(g: GroupCfg, rank: number): string {
  if (rank <= g.direct) {
    return 'direct';
  }
  if (rank <= g.direct + g.playin) {
    return 'playin';
  }
  return 'out';
}

function buildGroupedStandings(items: MatchItem[], grouped: boolean): StandingsBlock {
  const rows = buildStandings(items);
  if (!grouped) {
    const all: StandingGroup = {
      key: 'all',
      name: '战队战绩榜',
      desc: `共 ${rows.length} 支战队 · 按积分 → 净胜小局排序`,
      rule: '',
      accent: '#f5c451',
      rows: sortRows(rows),
    };
    const gs: StandingGroup[] = [all];
    const block: StandingsBlock = { mode: 'flat', groups: gs, ungrouped: [] };
    return block;
  }
  const used: Set<string> = new Set<string>();
  const groups: StandingGroup[] = [];
  let ungrouped: StandingRow[] = [];
  for (let i = 0; i < GROUPS.length; i++) {
    const g = GROUPS[i];
    const inner: StandingRow[] = [];
    for (let k = 0; k < rows.length; k++) {
      const r = rows[k];
      if (teamGroupOf(r.name) === g.key) {
        inner.push(r);
        used.add(r.id ?? r.name);
      }
    }
    sortRows(inner);
    for (let k = 0; k < inner.length; k++) {
      inner[k].adv = advanceOf(g, inner[k].rank ?? k + 1);
      inner[k].groupKey = g.key;
    }
    const sg: StandingGroup = {
      key: g.key,
      name: g.name,
      desc: g.desc,
      rule: g.rule,
      accent: g.accent,
      rows: inner,
    };
    groups.push(sg);
  }
  ungrouped = rows.filter((r: StandingRow) => !used.has(r.id ?? r.name));
  for (let k = 0; k < ungrouped.length; k++) {
    ungrouped[k].adv = undefined;
  }
  const block: StandingsBlock = { mode: 'grouped', groups: groups, ungrouped: ungrouped };
  return block;
}

function buildSummary(items: MatchItem[]): BoardSummary {
  const t = bjTodayKey();
  let finished = 0;
  let live = 0;
  let upcoming = 0;
  let todayTotal = 0;
  let todayDone = 0;
  let totalGames = 0;
  let bo = 0;
  let deciding = 0;
  let sweep = 0;
  for (let i = 0; i < items.length; i++) {
    const m = items[i];
    const sa = m.a.score ?? 0;
    const sb = m.b.score ?? 0;
    if ((m.bo ?? 0) > 0 && bo === 0) {
      bo = m.bo ?? 0;
    }
    if (m.status === 'finished') {
      finished++;
      totalGames += sa + sb;
      if (bo > 0 && sa + sb === bo) {
        deciding++;
      }
      if (Math.min(sa, sb) === 0 && bo > 0 && Math.max(sa, sb) >= Math.ceil(bo / 2)) {
        sweep++;
      }
    } else if (m.status === 'live') {
      live++;
    } else {
      upcoming++;
    }
    if ((m.date ?? '') === t) {
      todayTotal++;
      if (m.status === 'finished') {
        todayDone++;
      }
    }
  }
  if (bo === 0) {
    bo = 3;
  }
  const summary: BoardSummary = {
    totalMatches: items.length,
    finished: finished,
    live: live,
    upcoming: upcoming,
    todayTotal: todayTotal,
    todayDone: todayDone,
    totalGames: totalGames,
    avgGames: finished > 0 ? Math.round((totalGames / finished) * 100) / 100 : 0,
    bo: bo,
    decidingGames: deciding,
    sweep: sweep,
  };
  return summary;
}

function collectStages(items: MatchItem[]): StageCount[] {
  const counts: Map<string, number> = new Map<string, number>();
  const order: string[] = [];
  for (let i = 0; i < items.length; i++) {
    const s = items[i].stage ?? '';
    if (s.length === 0) {
      continue;
    }
    const c = counts.get(s);
    if (c === undefined) {
      counts.set(s, 1);
      order.push(s);
    } else {
      counts.set(s, c + 1);
    }
  }
  const out: StageCount[] = [];
  for (let i = 0; i < order.length; i++) {
    const sc: StageCount = { name: order[i], count: counts.get(order[i]) ?? 0 };
    out.push(sc);
  }
  return out;
}

/* ==================== 本地持久化缓存 ====================
 * 页面以本地数据为展示源：联网拉取成功 → 同步写入 cacheDir；
 * 下次进入页面 / 网络失败 → 先读本地缓存渲染并标记数据时间，
 * 再由页面轮询在后台继续尝试联网刷新。 */

interface CachePayload {
  updatedAt: number;
  matches: LiveMatch[];
}

function reviveTeam(o: Record<string, Object>): LiveTeam {
  const t = new LiveTeam();
  t.id = J.str(o['id']);
  t.name = J.str(o['name']);
  t.icon = J.str(o['icon']);
  t.score = J.num(o['score']);
  return t;
}

/** 磁盘 JSON → LiveMatch（字段缺失全部安全兜底） */
function reviveMatch(o: Record<string, Object>): LiveMatch {
  const m = new LiveMatch();
  m.id = J.str(o['id']);
  m.date = J.str(o['date']);
  m.dateLabel = J.str(o['dateLabel']);
  m.time = J.str(o['time']);
  m.stage = J.str(o['stage']);
  m.bo = J.num(o['bo']);
  m.over = J.bool(o['over']);
  m.liveFlag = J.bool(o['liveFlag']);
  m.hasVideo = J.bool(o['hasVideo']);
  m.a = reviveTeam(J.rec(o['a']));
  m.b = reviveTeam(J.rec(o['b']));
  const legs = J.arr(o['legs']);
  for (let i = 0; i < legs.length; i++) {
    const v = legs[i];
    m.legs.push(v === null ? null : J.str(v));
  }
  m.realtime = false; // 实时覆盖只作用于副本，缓存里不落这个标记
  m.officialScore = false;
  return m;
}

/* ==================== 对外入口 ==================== */

export class LiveBoard {
  private static ctx: common.UIAbilityContext | null = null;

  /** 在 EntryAbility / Index 里注入上下文，用于读写 cacheDir */
  static init(c: common.UIAbilityContext): void {
    LiveBoard.ctx = c;
  }

  private static cachePath(eventId: number): string {
    return `${LiveBoard.ctx?.cacheDir ?? ''}/liveboard_${eventId}.json`;
  }

  /** 联网成功后同步落盘（失败静默，不影响主流程） */
  private static saveCache(eventId: number, rec: EventRec): void {
    if (LiveBoard.ctx === null || rec.matches.length === 0) {
      return;
    }
    try {
      const payload: CachePayload = { updatedAt: rec.updatedAt, matches: rec.matches };
      const text = JSON.stringify(payload);
      const f = fs.openSync(
        LiveBoard.cachePath(eventId),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
      );
      fs.writeSync(f.fd, text);
      fs.closeSync(f);
    } catch (e) {
      /* 缓存写失败不影响功能 */
    }
  }

  /** 磁盘缓存 → EventRec（无缓存 / 解析失败返回 null） */
  private static loadCache(eventId: number): EventRec | null {
    if (LiveBoard.ctx === null) {
      return null;
    }
    try {
      const txt = fs.readTextSync(LiveBoard.cachePath(eventId));
      if (txt.length === 0) {
        return null;
      }
      const root = J.rec(JSON.parse(txt) as Object);
      const arr = J.arr(root['matches']);
      if (arr.length === 0) {
        return null;
      }
      const rec = new EventRec();
      for (let i = 0; i < arr.length; i++) {
        rec.matches.push(reviveMatch(J.rec(arr[i])));
      }
      rec.updatedAt = J.num(root['updatedAt']);
      rec.wanplusAt = 0; // 下次联网照常重拉最新
      rec.lastOk = false; // 数据来自本地缓存，联网状态未知
      sortMatches(rec.matches);
      return rec;
    } catch (e) {
      return null;
    }
  }

  private static store: Map<string, EventRec> = new Map<string, EventRec>();
  private static kpl: RtState = new RtState();
  private static rt: RtState = new RtState();

  /** 最近一次玩加数据落库时间（0 = 从未联网成功） */
  static updatedAtOf(eventId: number): number {
    const rec = LiveBoard.store.get(String(eventId));
    return rec === undefined ? 0 : rec.updatedAt;
  }

  /** 最近一次联网是否成功（用于状态点显示） */
  static lastOkOf(eventId: number): boolean {
    const rec = LiveBoard.store.get(String(eventId));
    return rec !== undefined && rec.lastOk;
  }

  /**
   * 同步取本地数据（内存缓存 / 磁盘缓存），不发任何网络请求。
   * 用于页面首帧渲染：有数据立即显示，联网刷新交给后台轮询。
   * 无任何本地数据时返回 null（页面回退离线快照）。
   */
  static cachedBoardOf(eventId: number): BoardResp | null {
    if (eventId <= 0) {
      return null;
    }
    let rec = LiveBoard.store.get(String(eventId));
    if (rec === undefined || rec.matches.length === 0) {
      const disk = LiveBoard.loadCache(eventId);
      if (disk === null) {
        return null;
      }
      LiveBoard.store.set(String(eventId), disk);
      rec = disk;
    }
    const ev = LiveBoard.findEvent(eventId);
    if (ev === null) {
      return null;
    }
    return LiveBoard.boardOf(ev, rec, isActive(ev));
  }

  private static findEvent(eventId: number): EventItem | null {
    const resp = BundleStore.api<EventsResp>('/api/events');
    const list = resp ? resp.events : [];
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === eventId) {
        return list[i];
      }
    }
    return null;
  }

  /** 拉全量赛程（按周），合并去重后写进 rec */
  private static async refreshWanplus(rec: EventRec, ev: EventItem): Promise<void> {
    /* 全量赛程是按周串行拉的，一次可能要好几秒。旧写法 `if (rec.loading) return;`
     * 会让这段时间里的手动刷新被静默吞掉：boardOf 仍用旧 matches 出图，界面不动，
     * 但后台那次拉取成功后已经落盘 —— 于是只有杀进程重启才看得到新数据。
     * 改为等待在途请求，调用方拿到的是它完成后的最新结果。 */
    if (rec.pending !== null) {
      await rec.pending;
      return;
    }
    rec.loading = true;
    rec.pending = (async (): Promise<void> => {
      try {
        const map: Map<string, LiveMatch> = new Map<string, LiveMatch>();
        let weeks = 0;
        const starts = weekStartsOf(ev);
        for (let i = 0; i < starts.length; i++) {
          const week = await fetchWeek(ev.id, starts[i]);
          for (let k = 0; k < week.length; k++) {
            const m = week[k];
            const key = m.id.length > 0 ? m.id : `${m.date}-${m.time}-${m.a.name}-${m.b.name}`;
            map.set(key, m);
          }
          if (week.length > 0) {
            weeks++;
          }
          await sleep(150); // 与桌面端一致：周与周之间小间隔
        }
        if (map.size > 0) {
          const list: LiveMatch[] = [];
          map.forEach((m: LiveMatch) => {
            list.push(m);
          });
          if (boMissing(list)) {
            const bo = inferBo(list);
            for (let i = 0; i < list.length; i++) {
              if ((list[i].bo ?? 0) === 0) {
                list[i].bo = bo;
              }
            }
          }
          sortMatches(list);
          rec.matches = list;
          rec.updatedAt = Date.now();
          rec.error = '';
          rec.lastOk = true;
          LiveBoard.saveCache(ev.id, rec); // 拉取成功 → 同步写本地缓存
        } else {
          rec.lastOk = false;
          if (rec.matches.length === 0) {
            rec.error = weeks > 0 ? '未获取到赛程数据' : '赛程拉取失败';
          }
        }
        if (rec.lastOk) {
          rec.wanplusAt = Date.now();
        } else {
          // 失败只退避 20s：手动/自动刷新很快就能重试，而不是等满 10 分钟
          rec.wanplusAt = Date.now() - WANPLUS_TTL + 20 * 1000;
        }
      } finally {
        rec.loading = false;
        rec.pending = null;
      }
    })();
    await rec.pending;
  }

  /** KPL 官方实时（20s 缓存 + 并发合并） */
  private static async ensureKpl(force: boolean): Promise<void> {
    const s = LiveBoard.kpl;
    if (!force && s.at > 0 && Date.now() - s.at < RT_TTL) {
      return;
    }
    if (s.pending !== null) {
      await s.pending;
      return;
    }
    s.pending = (async (): Promise<boolean> => {
      try {
        s.list = await fetchKplRealtime();
        s.ok = true;
        s.error = '';
        s.updatedAt = Date.now();
        s.seen = s.list.length;
      } catch (e) {
        s.ok = false;
        s.error = e instanceof Error ? e.message : '官方源不可用';
        if (s.updatedAt === 0) {
          s.updatedAt = Date.now();
        }
      } finally {
        s.at = Date.now();
        s.pending = null;
      }
      return s.ok;
    })();
    await s.pending;
  }

  /** PandaScore 实时（20s 缓存 + 并发合并，失败不影响主流程） */
  private static async ensureRt(force: boolean): Promise<void> {
    const s = LiveBoard.rt;
    if (!force && s.at > 0 && Date.now() - s.at < RT_TTL) {
      return;
    }
    if (s.pending !== null) {
      await s.pending;
      return;
    }
    s.pending = (async (): Promise<boolean> => {
      try {
        s.list = await fetchRealtime(bjDateKey());
        s.ok = true;
        s.error = '';
        s.updatedAt = Date.now();
        s.seen = s.list.length;
      } catch (e) {
        s.ok = false;
        s.error = e instanceof Error ? e.message : '实时源不可用';
        if (s.updatedAt === 0) {
          s.updatedAt = Date.now();
        }
      } finally {
        s.at = Date.now();
        s.pending = null;
      }
      return s.ok;
    })();
    await s.pending;
  }

  /**
   * 取一次看板数据（端内直连公网）。
   * @param force true = 手动刷新，绕过玩加 10 分钟缓存
   * @returns 拉到数据（含端内缓存）时返回 BoardResp；完全无数据时返回 null
   *          （页面继续用离线快照渲染）
   */
  static async fetchBoard(eventId: number, force: boolean = false): Promise<BoardResp | null> {
    if (eventId <= 0) {
      return null;
    }
    const key = String(eventId);
    let rec = LiveBoard.store.get(key);
    if (rec === undefined) {
      rec = new EventRec();
      LiveBoard.store.set(key, rec);
    }
    // 内存无数据时先读本地缓存：页面立即可渲染，联网在后续轮询中继续
    if (rec.matches.length === 0) {
      const disk = LiveBoard.loadCache(eventId);
      if (disk !== null) {
        rec.matches = disk.matches;
        rec.updatedAt = disk.updatedAt;
        LiveBoard.store.set(key, rec);
      }
    }
    const ev = LiveBoard.findEvent(eventId);
    if (ev === null) {
      return null;
    }
    const active = isActive(ev);
    const now = Date.now();
    const needWanplus = rec.matches.length === 0 || force
      || (active && now - rec.wanplusAt > WANPLUS_TTL)
      || (!active && rec.updatedAt === 0);
    if (needWanplus) {
      await LiveBoard.refreshWanplus(rec, ev);
    }
    if (active) {
      await LiveBoard.ensureKpl(force);
      await LiveBoard.ensureRt(force);
    }
    if (rec.matches.length === 0) {
      return null; // 无任何数据：页面回退离线快照
    }
    return LiveBoard.boardOf(ev, rec, active);
  }

  /* ---------- 组装（与桌面端 boardOf 同构） ---------- */

  private static boardOf(ev: EventItem, rec: EventRec, active: boolean): BoardResp {
    // 实时覆盖只作用于副本，避免污染缓存
    const src: LiveMatch[] = [];
    for (let i = 0; i < rec.matches.length; i++) {
      src.push(cloneMatch(rec.matches[i]));
    }
    let rtMatched = 0;
    if (active) {
      applyOfficial(src, LiveBoard.kpl);
      applyRealtime(src, LiveBoard.rt);
      for (let i = 0; i < src.length; i++) {
        if (src[i].realtime) {
          rtMatched++;
        }
      }
    }
    // 过期 LIVE 修正：缓存/快照里的「进行中」如果早已过了比赛时间、
    // 且没有任何实时源确认，就按时间落回「已结束」，避免僵尸 LIVE 行
    const today = bjTodayKey();
    const nowMin = bjNowMin();
    for (let i = 0; i < src.length; i++) {
      const m = src[i];
      if (m.over || !m.liveFlag || m.realtime) {
        continue;
      }
      if (m.date < today) {
        m.over = true;
        m.liveFlag = false;
        continue;
      }
      if (m.date === today) {
        const parts = (m.time || '00:00').split(':');
        const hh = parts.length > 0 ? Number(parts[0]) : 0;
        const mm = parts.length > 1 ? Number(parts[1]) : 0;
        if (nowMin >= hh * 60 + (isNaN(mm) ? 0 : mm) + 300) {
          // 开赛 5 小时后仍无实时源确认 → 视为已结束
          m.over = true;
          m.liveFlag = false;
        }
      }
    }
    const items: MatchItem[] = [];
    for (let i = 0; i < src.length; i++) {
      items.push(decorateOne(src[i]));
    }
    const evMeta: EventItem = {
      id: ev.id,
      name: ev.name,
      short: ev.short ?? ev.name,
      year: ev.year,
      category: ev.category ?? '',
      mode: ev.mode ?? 'live',
      start: ev.start ?? '',
      end: ev.end ?? '',
      grouped: ev.grouped ?? false,
      active: active,
    };
    const out: BoardResp = {
      ok: true,
      event: evMeta,
      stage: '',
      stages: collectStages(items),
      summary: buildSummary(items),
      standings: buildGroupedStandings(items, evMeta.grouped ?? false),
      matches: items,
      updatedAt: rec.updatedAt,
      error: rec.error.length > 0 ? rec.error : undefined,
      stale: false,
    };
    if (active) {
      const kpl = LiveBoard.kpl;
      const rt = LiveBoard.rt;
      const info: RealtimeInfo = {
        enabled: true,
        ok: kpl.ok || rt.ok,
        source: 'KPL官方 · PandaScore',
        updatedAt: Math.max(kpl.updatedAt, rt.updatedAt),
        matched: rtMatched,
        error: (!kpl.ok && kpl.error.length > 0) ? kpl.error
          : ((!rt.ok && rt.error.length > 0) ? rt.error : undefined),
      };
      out.realtime = info;
    }
    return out;
  }
}

function boMissing(list: LiveMatch[]): boolean {
  for (let i = 0; i < list.length; i++) {
    if ((list[i].bo ?? 0) === 0) {
      return true;
    }
  }
  return false;
}

/** 状态推断 + 输出 MatchItem（与桌面端 decorate 单场逻辑一致） */
function decorateOne(m: LiveMatch): MatchItem {
  let status = 'upcoming';
  if (m.over) {
    status = 'finished';
  } else if (m.liveFlag) {
    status = 'live';
  } else {
    const parts = (m.time || '00:00').split(':');
    const hh = parts.length > 0 ? Number(parts[0]) : 0;
    const mm = parts.length > 1 ? Number(parts[1]) : 0;
    const t = bjTodayKey();
    if (m.date < t) {
      status = 'finished';
    } else if (m.date === t && bjNowMin() >= hh * 60 + (isNaN(mm) ? 0 : mm)) {
      status = 'live';
    }
  }
  let playedLegs = 0;
  for (let i = 0; i < m.legs.length; i++) {
    if (m.legs[i] !== null) {
      playedLegs++;
    }
  }
  const sa = m.a.score;
  const sb = m.b.score;
  const ta: TeamRef = { id: m.a.id, name: m.a.name, icon: m.a.icon, score: sa };
  const tb: TeamRef = { id: m.b.id, name: m.b.name, icon: m.b.icon, score: sb };
  const out: MatchItem = {
    id: m.id,
    date: m.date,
    dateLabel: m.dateLabel,
    time: m.time,
    stage: m.stage,
    bo: m.bo,
    a: ta,
    b: tb,
    legs: m.legs,
    playedLegs: playedLegs,
    winner: status === 'finished' && sa !== sb ? (sa > sb ? 'A' : 'B') : undefined,
    over: m.over,
    liveFlag: m.liveFlag,
    hasVideo: m.hasVideo,
    status: status,
    isToday: m.date === bjTodayKey(),
  };
  return out;
}

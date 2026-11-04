/* 比分看板（原生实现，与桌面端逻辑对齐）
 * ---------------------------------------------------------------------------
 * 数据：bundle/api 里的 /api/events + /api/board?event=<id>，
 *      离线快照为底、联网实时覆盖（顶部条可手动刷新 + 页面自动轮询）。
 *
 * 桌面端对齐点（public/app.js）：
 *   ① 状态判断：over → 已结束；liveFlag → 进行中；否则按日期推算——
 *      date < 今天 → 已结束，date == 今天且已过开赛时间 → 进行中。
 *   ② 大比分取值：逐小局推导比大比分更靠前时以逐小局为准。
 *   ③ 自动刷新间隔：进行中 8s / 常规 15s / 今日赛毕 60s / 已结束赛季 120s /
 *      历史赛事 600s；请求带 t=时间戳防中间层缓存（缓存键剔除该参数）。
 *   ④ 战绩榜：分组赛事渲染 大师组 / 精英组 面板（含晋级规则图例与晋级标记），
 *      未分组战队归入「其他战队」。
 *   ⑤ 赛事日历：周一起始的周视图，进行中赛事默认本周、已结束默认末周，
 *      支持上一周 / 下一周 / 本周切换。
 *
 * 渲染机制：ArkUI 只在 @State 变化时重渲染对应节点，所以所有视图模型
 * （MatchVM / DayVM / CalDayVM / GroupVM）都落在 @State 数组里，
 * 由 rebuild() 统一重建——联网成功、每 30s 心跳、切周、切阶段都会触发，
 * 保证无网时按时间推算的「进行中」状态也能及时翻转。
 */
import { BundleStore } from '../data/BundleStore';
import { ImageRepo } from '../data/ImageRepo';
import { LiveBoard } from '../data/LiveBoard';
import { DeviceEnv } from '../common/DeviceEnv';
import { HeaderFade } from '../common/HeaderFade';
import { TopBar } from '../common/TopBar';
import { Kpi, MENU_MATERIAL_OFF, Ui, clockText, numText } from '../common/Ui';
import { BoardResp, EventItem, EventsResp, MatchItem, StandingGroup, StandingRow } from '../data/Models';

/* ---------- 周历工具（与桌面端 bjTodayKey / mondayOf / weekDiff 一致） ---------- */

function pad2(n: number): string {
  return n < 10 ? '0' + n : String(n);
}

/** 北京时区的「今天」日期键 yyyymmdd */
function bjTodayKey(): string {
  const now = new Date(Date.now() + 8 * 3600 * 1000);
  return `${now.getUTCFullYear()}${pad2(now.getUTCMonth() + 1)}${pad2(now.getUTCDate())}`;
}

/** 北京时区的「当前分钟数」（0:00 起算） */
function bjNowMin(): number {
  const now = new Date(Date.now() + 8 * 3600 * 1000);
  return now.getUTCHours() * 60 + now.getUTCMinutes();
}

function parseDateKey(k: string): number {
  const y = Number(k.slice(0, 4));
  const mo = Number(k.slice(4, 6));
  const d = Number(k.slice(6, 8));
  return Date.UTC(y, mo - 1, d);
}

function mondayOf(ms: number): number {
  const d = new Date(ms);
  const wd = d.getUTCDay();
  d.setUTCDate(d.getUTCDate() - (wd === 0 ? 6 : wd - 1));
  return d.getTime();
}

/** 场次日期所在周一与本周周一相差几周（过去为负） */
function weekDiff(dateKey: string): number {
  const a = mondayOf(parseDateKey(dateKey));
  const b = mondayOf(parseDateKey(bjTodayKey()));
  return Math.round((a - b) / (7 * 86400000));
}

/** 00:00 → 分钟数 */
function timeToMin(t: string): number {
  const parts = t.split(':');
  if (parts.length < 2) {
    return 0;
  }
  return Number(parts[0]) * 60 + Number(parts[1]);
}

const WEEK_NAMES: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

/** 自动刷新间隔（毫秒），与桌面端完全一致 */
const REFRESH_IDLE: number = 15000;
const REFRESH_LIVE: number = 8000;
const REFRESH_DONE: number = 120000;
const REFRESH_ARCHIVE: number = 600000;
/** 无网心跳：按时间推算的状态每 30s 重算一次 */
const REBUILD_TICK: number = 30000;

/* ---------- 视图模型 ---------- */

class MatchVM {
  id: string;
  date: string;
  time: string;
  headText: string;
  stageText: string;
  /** live | finished | upcoming（与桌面端 decorate() 同一套判断） */
  status: string;
  statusText: string;
  statusColor: string;
  aName: string;
  bName: string;
  aIcon: string;
  bIcon: string;
  /** 展示用大比分（逐小局推导更靠前时以逐小局为准） */
  scoreA: number;
  scoreB: number;
  score: string;
  legs: string[];
  winner: string;
  isLive: boolean;
  /** ForEach key 用：状态 + 比分签名，状态翻转时 key 变化 → 节点重建 */
  sig: string;

  constructor(m: MatchItem) {
    this.id = m.id ?? '';
    this.date = m.date ?? '';
    this.time = m.time ?? '';
    this.headText = `${m.time ?? ''} · BO${m.bo ?? '-'}`;
    this.stageText = m.stage ?? '';

    // 状态：与桌面端 /api/board decorate() 完全一致
    let status = 'upcoming';
    if (m.over) {
      status = 'finished';
    } else if (m.liveFlag) {
      status = 'live';
    } else {
      const t = bjTodayKey();
      if ((m.date ?? '') < t) {
        status = 'finished';
      } else if ((m.date ?? '') === t && bjNowMin() >= timeToMin(m.time ?? '')) {
        status = 'live';
      }
    }
    this.status = status;

    // 大比分：上游大比分常常滞后于逐小局，逐小局推导更靠前时以逐小局为准
    const sa = m.a ? (m.a.score ?? 0) : 0;
    const sb = m.b ? (m.b.score ?? 0) : 0;
    let la = 0;
    let lb = 0;
    if (m.legs) {
      for (let i = 0; i < m.legs.length; i++) {
        if (m.legs[i] === 'A') {
          la++;
        } else if (m.legs[i] === 'B') {
          lb++;
        }
      }
    }
    this.scoreA = la + lb > sa + sb ? la : sa;
    this.scoreB = la + lb > sa + sb ? lb : sb;
    this.score = `${this.scoreA} : ${this.scoreB}`;

    if (status === 'live') {
      this.statusText = '进行中';
      this.statusColor = Ui.RED;
    } else if (status === 'finished') {
      this.statusText = '已结束';
      this.statusColor = Ui.MUTED;
    } else {
      this.statusText = '未开始';
      this.statusColor = Ui.BLUE;
    }

    this.aName = m.a ? m.a.name : '-';
    this.bName = m.b ? m.b.name : '-';
    this.aIcon = ImageRepo.src(m.a ? m.a.icon : undefined, 56);
    this.bIcon = ImageRepo.src(m.b ? m.b.icon : undefined, 56);

    const lg: string[] = [];
    if (m.legs) {
      for (let i = 0; i < m.legs.length; i++) {
        lg.push(m.legs[i] === 'A' ? '胜' : m.legs[i] === 'B' ? '负' : '·');
      }
    }
    this.legs = lg;
    this.winner =
      status === 'finished' && this.scoreA !== this.scoreB ? (this.scoreA > this.scoreB ? 'A' : 'B') : '';
    this.isLive = status === 'live';
    this.sig = `${status}-${this.scoreA}-${this.scoreB}-${la + lb}`;
  }
}

class DayVM {
  label: string;
  items: MatchVM[];
  /** ForEach key 用：本组所有场次签名的拼接，组内任何一场变化都会让 key 变 */
  sig: string;

  constructor(label: string, items: MatchVM[]) {
    this.label = label;
    this.items = items;
    this.sig = sigOf(items);
  }
}

/** 赛事日历的一天 */
class CalDayVM {
  /** 「10月8日 周三」 */
  label: string;
  dateKey: string;
  isToday: boolean;
  items: MatchVM[];
  /** ForEach key 用：本日所有场次签名的拼接 */
  sig: string;

  constructor(label: string, dateKey: string, isToday: boolean, items: MatchVM[]) {
    this.label = label;
    this.dateKey = dateKey;
    this.isToday = isToday;
    this.items = items;
    this.sig = sigOf(items);
  }
}

/** 一组场次的内容签名（状态 / 比分 / 队名任一变化即变） */
function sigOf(items: MatchVM[]): string {
  let s: string = '';
  for (let i = 0; i < items.length; i++) {
    s += items[i].sig + '|';
  }
  return s;
}

class RowVM {
  rank: string;
  rankColor: string;
  name: string;
  icon: string;
  wl: string;
  games: string;
  net: string;
  netColor: string;
  rate: string;
  adv: string;
  advColor: string;
  form: string[];
  /** ForEach key 用：行内容签名（战绩 / 小局 / 净分 / 近况任一变化即变） */
  sig: string;

  constructor(r: StandingRow, i: number) {
    const rk: number = r.rank ?? i + 1;
    this.rank = String(rk);
    this.rankColor = rk <= 3 ? Ui.GOLD : Ui.MUTED;
    this.name = r.name;
    this.icon = ImageRepo.src(r.icon, 40);
    this.wl = `${r.wins ?? 0}-${r.losses ?? 0}`;
    this.games = `${r.gameWins ?? 0}-${r.gameLosses ?? 0}`;
    this.net = (r.net ?? 0) > 0 ? '+' + (r.net ?? 0) : String(r.net ?? 0);
    this.netColor = (r.net ?? 0) >= 0 ? Ui.GREEN : Ui.RED;
    const wr = r.winRate ?? 0;
    this.rate = `${Math.round(wr <= 1 ? wr * 100 : wr)}%`;
    // 晋级标记（与桌面端 ADV_SHORT 一致）
    if (r.adv === 'direct') {
      this.adv = '直进';
      this.advColor = Ui.GOLD;
    } else if (r.adv === 'playin') {
      this.adv = '突围';
      this.advColor = '#9b6bff';
    } else if (r.adv === 'out') {
      this.adv = '淘汰';
      this.advColor = Ui.MUTED;
    } else {
      this.adv = '';
      this.advColor = Ui.MUTED;
    }
    const fm: string[] = [];
    if (r.form) {
      for (let k = 0; k < r.form.length; k++) {
        const v = r.form[k].r ?? '';
        fm.push(v === 'W' ? '胜' : v === 'L' ? '负' : '平');
      }
    }
    this.form = fm;
    this.sig = `${this.rank}-${this.wl}-${this.games}-${this.net}-${this.rate}-${this.adv}-${fm.join('')}`;
  }
}

class GroupVM {
  name: string;
  desc: string;
  rule: string;
  accent: string;
  rows: RowVM[];
  /** ForEach key 用：本组所有行签名的拼接，任一行战绩变化即变 */
  sig: string;

  constructor(name: string, desc: string, rule: string, accent: string, rows: StandingRow[]) {
    this.name = name;
    this.desc = desc;
    this.rule = rule;
    this.accent = accent.length > 0 ? accent : Ui.GOLD;
    const rs: RowVM[] = [];
    for (let i = 0; i < rows.length; i++) {
      rs.push(new RowVM(rows[i], i));
    }
    this.rows = rs;
    let s: string = '';
    for (let i = 0; i < rs.length; i++) {
      s += rs[i].sig + '|';
    }
    this.sig = s;
  }
}

@Component
export struct BoardPage {
  @StorageLink('dev.bp') bp: string = 'sm';
  @StorageLink('dev.widthVp') widthVp: number = 360;
  @StorageLink('dev.safeBottom') safeBottom: number = 0;
  @StorageLink('dev.safeTop') safeTop: number = 0;
  @State events: EventItem[] = [];
  @State years: number[] = [];
  @State year: number = 0;
  @State eventId: number = 0;
  @State stages: string[] = [];
  @State stage: string = '';
  @State board: BoardResp | null = null;
  @State ready: boolean = false;
  @State loading: boolean = false;
  @State online: boolean = false;
  /** 悬浮页头实测高度：内容顶部据此让位（onAreaChange 回写） */
  @State headH: number = 0;
  /** 实时区提示文案（rebuild 时刷新） */
  @State hint: string = '';
  /** 进行中 / 兜底卡片 */
  @State liveVMs: MatchVM[] = [];
  @State fbVMs: MatchVM[] = [];
  /** 赛程（按天分组） */
  @State dayVMs: DayVM[] = [];
  /** 战绩榜面板（大师组 / 精英组 / 其他战队） */
  @State groupVMs: GroupVM[] = [];
  /** 赛事日历（本周） */
  @State calVMs: CalDayVM[] = [];
  /** 赛事日历：相对本周的偏移（-1 上一周 / +1 下一周） */
  @State weekOffset: number = 0;
  /** 日历周标签 */
  @State weekLabel: string = '';
  @StorageLink('ui.themeMode') themeMode: string = 'dark';

  private timerId: number = -1;
  private tickId: number = -1;
  /** 与桌面端一致：每个赛事只做一次「默认周」定位 */
  private firstLoadDone: number = 0;

  aboutToAppear(): void {
    this.loadEvents();
    this.loadBoard();
    this.refresh(false); // 立即联网拉一次（异步），不等首轮询
    this.scheduleNext();
    this.tickId = setInterval(() => {
      this.rebuild(); // 无网心跳：让按时间推算的状态及时翻转
    }, REBUILD_TICK);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    if (this.tickId >= 0) {
      clearInterval(this.tickId);
      this.tickId = -1;
    }
  }

  /* ---------- 数据 ---------- */

  private loadEvents(): void {
    const resp = BundleStore.api<EventsResp>('/api/events');
    const list = resp ? resp.events : [];
    // 与网页版一致：按开赛时间从新到旧
    const sorted = list.slice().sort((a: EventItem, b: EventItem) => {
      const sa = a.start ?? '';
      const sb = b.start ?? '';
      if (sa === sb) {
        return (b.year || 0) - (a.year || 0);
      }
      return sa < sb ? 1 : -1;
    });
    this.events = sorted;
    const ys: number[] = [];
    for (let i = 0; i < sorted.length; i++) {
      const y = sorted[i].year;
      if (ys.indexOf(y) < 0) {
        ys.push(y);
      }
    }
    this.years = ys;
    if (sorted.length > 0) {
      this.year = sorted[0].year;
      this.eventId = sorted[0].id;
    }
  }

  private boardKey(): string {
    return '/api/board?event=' + this.eventId;
  }

  private loadBoard(): void {
    if (this.eventId <= 0) {
      this.board = null;
      this.ready = true;
      this.rebuild();
      return;
    }
    // 页面以本地数据为展示源：优先内存/磁盘缓存（不发网络请求），
    // 无缓存再回退包内离线快照；联网刷新由 aboutToAppear 与轮询在后台做。
    const cached = LiveBoard.cachedBoardOf(this.eventId);
    if (cached !== null) {
      this.applyBoard(cached);
    } else {
      let resp = BundleStore.api<BoardResp>(this.boardKey());
      if (!resp) {
        resp = BundleStore.api<BoardResp>('/api/board');
      }
      this.applyBoard(resp);
    }
    this.online = LiveBoard.lastOkOf(this.eventId);
  }

  private applyBoard(resp: BoardResp | null): void {
    this.board = resp;
    const ss: string[] = [];
    const st = resp ? resp.stages : undefined;
    if (st) {
      for (let i = 0; i < st.length; i++) {
        ss.push(st[i].name ?? '');
      }
    }
    this.stages = ss;
    this.stage = '';
    this.ready = true;
    // 与桌面端一致：进行中赛事默认定位本周，已结束赛事定位末周（每个赛事只定位一次）
    if (this.firstLoadDone !== this.eventId) {
      const ms = resp && resp.matches ? resp.matches : [];
      const last = ms.length > 0 ? (ms[ms.length - 1].date ?? '') : '';
      const ev = resp ? resp.event : undefined;
      this.weekOffset = ev && ev.active ? 0 : last.length > 0 ? weekDiff(last) : 0;
      this.firstLoadDone = this.eventId;
    }
    this.rebuild();
  }

  /* ---------- 视图模型重建（联网成功 / 30s 心跳 / 切周 / 切阶段都会触发） ---------- */

  private rebuild(): void {
    const src = this.visibleMatches();

    // 进行中
    const lv: MatchVM[] = [];
    for (let i = 0; i < src.length; i++) {
      const m = src[i];
      if (m.over !== true && m.liveFlag === true) {
        lv.push(new MatchVM(m));
      }
    }
    this.liveVMs = lv;

    // 兜底卡片：下一场未开赛 + 今日收官战（与桌面端 renderLive 一致）
    const fbs: MatchVM[] = [];
    const next = this.pickNextUpcoming(src);
    if (next !== null) {
      fbs.push(next);
    }
    const last = this.pickTodayLastFinished(src);
    if (last !== null) {
      fbs.push(last);
    }
    this.fbVMs = fbs;
    this.hint = this.buildHint(lv.length, next);

    // 赛程（按天分组）
    const map: Map<string, MatchVM[]> = new Map<string, MatchVM[]>();
    const order: string[] = [];
    const ds: MatchVM[] = [];
    for (let i = 0; i < src.length; i++) {
      ds.push(new MatchVM(src[i]));
    }
    for (let i = 0; i < ds.length; i++) {
      const m: MatchItem = src[i];
      const key: string = m.dateLabel ?? (m.date ?? '待定');
      let arr = map.get(key);
      if (arr === undefined) {
        arr = [];
        map.set(key, arr);
        order.push(key);
      }
      arr.push(ds[i]);
    }
    const days: DayVM[] = [];
    for (let i = 0; i < order.length; i++) {
      const arr = map.get(order[i]);
      days.push(new DayVM(order[i], arr ?? []));
    }
    this.dayVMs = days;

    // 战绩榜面板
    this.groupVMs = this.buildGroups();

    // 赛事日历（本周）
    this.weekLabel = this.buildWeekLabel();
    this.calVMs = this.buildCalDays(src);
  }

  /** 下一场未开赛 */
  private pickNextUpcoming(src: MatchItem[]): MatchVM | null {
    const today = bjTodayKey();
    let best: MatchItem | null = null;
    for (let i = 0; i < src.length; i++) {
      const m = src[i];
      if (m.over === true || m.liveFlag === true) {
        continue;
      }
      if ((m.date ?? '') < today) {
        continue; // 过去日期按已结束处理
      }
      if (
        best === null ||
        (m.date ?? '') < (best.date ?? '') ||
        ((m.date ?? '') === (best.date ?? '') && (m.time ?? '') < (best.time ?? ''))
      ) {
        best = m;
      }
    }
    return best !== null ? new MatchVM(best) : null;
  }

  /** 今日已结束的最后一场 */
  private pickTodayLastFinished(src: MatchItem[]): MatchVM | null {
    const today = bjTodayKey();
    let best: MatchItem | null = null;
    for (let i = 0; i < src.length; i++) {
      const m = src[i];
      if ((m.date ?? '') !== today) {
        continue;
      }
      if (m.over === true || ((m.date ?? '') < today && m.liveFlag !== true)) {
        if (best === null || (m.time ?? '') >= (best.time ?? '')) {
          best = m;
        }
      }
    }
    return best !== null ? new MatchVM(best) : null;
  }

  /** 实时区提示文案（与桌面端 liveHint 同款） */
  private buildHint(liveCount: number, next: MatchVM | null): string {
    if (liveCount > 0) {
      return `${liveCount} 场比赛进行中，页面每 8s 自动刷新`;
    }
    if (next !== null) {
      return `暂无进行中比赛 · 下一场：${next.date.slice(4, 6)}/${next.date.slice(6)} ${next.time} ${next.aName} vs ${next.bName}`;
    }
    return '本阶段比赛已全部结束';
  }

  /** 战绩榜面板：分组赛事 = 大师组 / 精英组，未分组战队归入「其他战队」（与桌面端一致） */
  private buildGroups(): GroupVM[] {
    const b = this.board;
    const st = b ? b.standings : undefined;
    const out: GroupVM[] = [];
    if (st) {
      const gs = st.groups;
      if (gs) {
        for (let i = 0; i < gs.length; i++) {
          const g: StandingGroup = gs[i];
          out.push(new GroupVM(g.name ?? '战队战绩榜', g.desc ?? '', g.rule ?? '', g.accent ?? '', g.rows));
        }
      }
      const ug = st.ungrouped;
      if (ug && ug.length > 0) {
        out.push(new GroupVM('其他战队', '非年度总决赛 12 队', '', '#8b95ad', ug));
      }
    }
    return out;
  }

  private buildWeekLabel(): string {
    const start = mondayOf(parseDateKey(bjTodayKey())) + this.weekOffset * 7 * 86400000;
    const f = (ms: number): string => {
      const d = new Date(ms);
      return `${d.getUTCMonth() + 1}.${pad2(d.getUTCDate())}`;
    };
    return `${f(start)} - ${f(start + 6 * 86400000)}`;
  }

  private buildCalDays(src: MatchItem[]): CalDayVM[] {
    const start = mondayOf(parseDateKey(bjTodayKey())) + this.weekOffset * 7 * 86400000;
    const end = start + 6 * 86400000;
    const today = bjTodayKey();
    const inWeek: MatchItem[] = [];
    for (let i = 0; i < src.length; i++) {
      const dk = src[i].date ?? '';
      if (dk.length === 8) {
        const ms = parseDateKey(dk);
        if (ms >= start && ms <= end) {
          inWeek.push(src[i]);
        }
      }
    }
    inWeek.sort((a: MatchItem, b: MatchItem) => {
      if (a.date === b.date) {
        return (a.time ?? '') < (b.time ?? '') ? -1 : 1;
      }
      return (a.date ?? '') < (b.date ?? '') ? -1 : 1;
    });
    const out: CalDayVM[] = [];
    const map: Map<string, MatchVM[]> = new Map<string, MatchVM[]>();
    const order: string[] = [];
    for (let i = 0; i < inWeek.length; i++) {
      const m = inWeek[i];
      const dk = m.date ?? '';
      let arr = map.get(dk);
      if (arr === undefined) {
        arr = [];
        map.set(dk, arr);
        order.push(dk);
      }
      arr.push(new MatchVM(m));
    }
    for (let i = 0; i < order.length; i++) {
      const dk = order[i];
      const d = new Date(parseDateKey(dk));
      const label = `${d.getUTCMonth() + 1}月${d.getUTCDate()}日 ${WEEK_NAMES[d.getUTCDay()]}`;
      const arr = map.get(dk);
      out.push(new CalDayVM(label, dk, dk === today, arr ?? []));
    }
    return out;
  }

  /* ---------- 自动轮询（与桌面端 scheduleNext 同一套节奏） ---------- */

  private scheduleNext(): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    let interval = REFRESH_IDLE;
    const b = this.board;
    if (b) {
      const liveCount = b.summary ? (b.summary.live ?? 0) : 0;
      const ev = b.event;
      if (liveCount > 0) {
        interval = REFRESH_LIVE;
      } else if (ev && ev.mode === 'archive') {
        interval = REFRESH_ARCHIVE;
      } else if (ev && !ev.active) {
        interval = REFRESH_DONE;
      } else if (b.summary && (b.summary.todayTotal ?? 0) > 0 && b.summary.todayDone === b.summary.todayTotal) {
        interval = 60000;
      }
    }
    this.timerId = setTimeout(() => {
      this.autoRefresh();
    }, interval);
  }

  private async autoRefresh(): Promise<void> {
    await this.refresh(false);
    this.scheduleNext();
  }

  private async refresh(bust: boolean): Promise<void> {
    if (this.loading || this.eventId <= 0) {
      return;
    }
    this.loading = true;
    try {
      // 端内直连公网（玩加 + KPL 官方实时），bust=true 时绕过 10 分钟缓存
      const r = await LiveBoard.fetchBoard(this.eventId, bust);
      if (r !== null) {
        this.applyBoard(r);
      }
      this.online = LiveBoard.lastOkOf(this.eventId);
      if (r === null) {
        this.rebuild(); // 拉取失败也重算：让按时间推算的状态及时翻转
      }
    } catch (e) {
      // 任何异常都不能把 loading 卡死，否则后续所有刷新都会被吞掉
      this.rebuild();
    } finally {
      this.loading = false;
    }
  }

  private statusText(): string {
    const at: number = LiveBoard.updatedAtOf(this.eventId);
    if (at > 0) {
      // 联网成功 = 实时；联网失败回退本地缓存时也要标明数据时间
      return LiveBoard.lastOkOf(this.eventId)
        ? `实时 · ${clockText(at)} 更新`
        : `缓存 · ${clockText(at)} 数据`;
    }
    const up = this.board?.updatedAt;
    return `离线包 · ${up ? clockText(up) + ' 快照' : '暂无数据'}`;
  }

  /** 概览指标（沿用桌面端 summary 字段） */
  private kpis(): Kpi[] {
    const s = this.board ? this.board.summary : undefined;
    if (!s) {
      return [];
    }
    return [
      new Kpi('总场次', String(s.totalMatches ?? 0)),
      new Kpi('已结束', String(s.finished ?? 0)),
      new Kpi('进行中', String(s.live ?? 0)),
      new Kpi('未开始', String(s.upcoming ?? 0)),
      new Kpi('场均小局', numText(s.avgGames, 2)),
      new Kpi('横扫场次', String(s.sweep ?? 0)),
    ];
  }

  private eventsOfYear(): EventItem[] {
    const out: EventItem[] = [];
    for (let i = 0; i < this.events.length; i++) {
      if (this.events[i].year === this.year) {
        out.push(this.events[i]);
      }
    }
    return out;
  }

  private currentEventName(): string {
    for (let i = 0; i < this.events.length; i++) {
      if (this.events[i].id === this.eventId) {
        return this.events[i].name;
      }
    }
    return '未选择赛事';
  }

  private visibleMatches(): MatchItem[] {
    const b = this.board;
    if (!b || !b.matches) {
      return [];
    }
    const all = b.matches;
    if (!this.stage) {
      return all;
    }
    const out: MatchItem[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].stage === this.stage) {
        out.push(all[i]);
      }
    }
    return out;
  }

  /* ---------- 赛事日历交互 ---------- */

  private homeWeekLabel(): string {
    const ev = this.board ? this.board.event : undefined;
    return ev && !ev.active ? '末周' : '本周';
  }

  private goHomeWeek(): void {
    const ev = this.board ? this.board.event : undefined;
    if (ev && !ev.active) {
      const ms = this.board && this.board.matches ? this.board.matches : [];
      const last = ms.length > 0 ? (ms[ms.length - 1].date ?? '') : '';
      this.weekOffset = last.length > 0 ? weekDiff(last) : 0;
    } else {
      this.weekOffset = 0;
    }
    this.weekLabel = this.buildWeekLabel();
    this.calVMs = this.buildCalDays(this.visibleMatches());
  }

  private stepWeek(dir: number): void {
    this.weekOffset += dir;
    this.weekLabel = this.buildWeekLabel();
    this.calVMs = this.buildCalDays(this.visibleMatches());
  }

  /** 断点自适应取值：build() 内不能声明局部变量，统一走成员方法 */
  private gut(): number {
    return DeviceEnv.gutter(DeviceEnv.bpOf(this.widthVp));
  }

  /* ---------- 渲染 ---------- */

  @Builder
  private teamIcon(uri: string, size: number) {
    if (uri) {
      Image(uri)
        .width(size)
        .height(size)
        .objectFit(ImageFit.Contain)
        .borderRadius(size / 2)
        .backgroundColor(Ui.PANEL_2)
    } else {
      Text('队')
        .width(size)
        .height(size)
        .fontSize(size * 0.36)
        .fontColor(Ui.MUTED)
        .textAlign(TextAlign.Center)
        .borderRadius(size / 2)
        .backgroundColor(Ui.PANEL_2)
    }
  }

  @Builder
  private kpiCard(k: Kpi) {
    Column() {
      Text(k.value)
        .fontSize(Ui.FS_SUB)
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.GOLD)
      Text(k.key)
        .fontSize(Ui.FS_TINY)
        .fontColor(Ui.MUTED)
        .margin({ top: 2 })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .borderRadius(Ui.R_SM)
    .backgroundColor(Ui.PANEL)
  }

  @Builder
  private matchCard(vm: MatchVM) {
    Column() {
      Row() {
        Text(vm.headText)
          .fontSize(Ui.FS_SMALL)
          .fontColor(Ui.MUTED)
        Blank()
        Text(vm.statusText)
          .fontSize(Ui.FS_TINY)
          .fontColor(vm.statusColor)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(4)
          .backgroundColor(Ui.PANEL_2)
        if (vm.stageText) {
          Text(vm.stageText)
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.MUTED)
            .margin({ left: 6 })
        }
      }
      .width('100%')

      Row() {
        Row() {
          Text(vm.aName)
            .fontSize(Ui.FS_BODY)
            .fontColor(vm.winner === 'B' ? Ui.MUTED : Ui.TEXT)
            .layoutWeight(1)
            .textAlign(TextAlign.End)
          this.teamIcon(vm.aIcon, 28)
        }
        .layoutWeight(1)

        Column() {
          Text(vm.score)
            .fontSize(Ui.FS_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(vm.isLive ? Ui.GOLD : Ui.TEXT)
          if (vm.legs.length > 0) {
            Row() {
              ForEach(vm.legs, (lg: string, i: number) => {
                Text(lg)
                  .fontSize(Ui.FS_TINY)
                  .fontColor(lg === '胜' ? Ui.GOLD : Ui.MUTED)
                  .width(18)
                  .textAlign(TextAlign.Center)
              }, (lg: string, i: number) => `leg-${i}`)
            }
            .margin({ top: 2 })
          }
        }
        .margin({ left: 10, right: 10 })

        Row() {
          this.teamIcon(vm.bIcon, 28)
          Text(vm.bName)
            .fontSize(Ui.FS_BODY)
            .fontColor(vm.winner === 'A' ? Ui.MUTED : Ui.TEXT)
            .layoutWeight(1)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 8 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(12)
    .borderRadius(Ui.R_MD)
    .backgroundColor(vm.isLive ? Ui.LIVE_BG : Ui.PANEL)
  }

  @Builder
  private standTable(g: GroupVM) {
    Column() {
      Row() {
        Text(g.name)
          .fontSize(Ui.FS_BODY)
          .fontWeight(FontWeight.Bold)
          .fontColor(g.accent)
        Blank()
        if (g.desc) {
          Text(g.desc)
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.MUTED)
        }
      }
      .width('100%')
      .margin({ bottom: 4 })

      if (g.rule) {
        // 晋级规则 + 图例（与桌面端 group-rule 一致）
        Row() {
          Text(g.rule)
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.MUTED)
            .layoutWeight(1)
          Row() {
            Circle()
              .width(6)
              .height(6)
              .fill(Ui.GOLD)
            Text('直进淘汰赛')
              .fontSize(Ui.FS_TINY)
              .fontColor(Ui.MUTED)
              .margin({ left: 3 })
            Circle()
              .width(6)
              .height(6)
              .fill('#9b6bff')
              .margin({ left: 6 })
            Text('突围赛')
              .fontSize(Ui.FS_TINY)
              .fontColor(Ui.MUTED)
              .margin({ left: 3 })
          }
        }
        .width('100%')
        .margin({ bottom: 6 })
      }

      Row() {
        Text('#').width(22).fontSize(Ui.FS_TINY).fontColor(Ui.MUTED)
        Text('战队').layoutWeight(1).fontSize(Ui.FS_TINY).fontColor(Ui.MUTED)
        Text('胜-负').width(40).fontSize(Ui.FS_TINY).fontColor(Ui.MUTED).textAlign(TextAlign.Center)
        Text('小局').width(44).fontSize(Ui.FS_TINY).fontColor(Ui.MUTED).textAlign(TextAlign.Center)
        Text('净').width(26).fontSize(Ui.FS_TINY).fontColor(Ui.MUTED).textAlign(TextAlign.Center)
        // 小屏放不下时省略胜率列，保证其余列完整显示不溢出
        if (this.showRate()) {
          Text('胜率').width(40).fontSize(Ui.FS_TINY).fontColor(Ui.MUTED).textAlign(TextAlign.Center)
        }
        Text('近况').width(72).fontSize(Ui.FS_TINY).fontColor(Ui.MUTED)
      }
      .width('100%')
      .padding({ bottom: 4 })

      ForEach(g.rows, (r: RowVM, i: number) => {
        Row() {
          Text(r.rank)
            .width(22)
            .fontSize(Ui.FS_SMALL)
            .fontColor(r.rankColor)
          Row() {
            this.teamIcon(r.icon, 20)
            Text(r.name)
              .fontSize(Ui.FS_SMALL)
              .fontColor(Ui.TEXT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .margin({ left: 6 })
            if (r.adv) {
              Text(r.adv)
                .fontSize(Ui.FS_TINY)
                .fontColor(r.advColor)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .borderRadius(3)
                .border({ width: 1, color: r.advColor })
                .margin({ left: 4 })
            }
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)
          Text(r.wl)
            .width(40)
            .fontSize(Ui.FS_SMALL)
            .fontColor(Ui.TEXT)
            .textAlign(TextAlign.Center)
          Text(r.games)
            .width(44)
            .fontSize(Ui.FS_SMALL)
            .fontColor(Ui.MUTED)
            .textAlign(TextAlign.Center)
          Text(r.net)
            .width(26)
            .fontSize(Ui.FS_SMALL)
            .fontColor(r.netColor)
            .textAlign(TextAlign.Center)
          if (this.showRate()) {
            Text(r.rate)
              .width(40)
              .fontSize(Ui.FS_SMALL)
              .fontColor(Ui.GOLD)
              .textAlign(TextAlign.Center)
          }
          Row() {
            ForEach(r.form, (f: string, k: number) => {
              Text(f)
                .fontSize(Ui.FS_TINY)
                .fontColor(f === '胜' ? Ui.GREEN : f === '负' ? Ui.RED : Ui.MUTED)
                .width(16)
                .height(16)
                .textAlign(TextAlign.Center)
                .borderRadius(3)
                .backgroundColor(Ui.PANEL_2)
                .margin({ right: 2 })
            }, (f: string, k: number) => `fm-${k}`)
          }
          .width(72)
        }
        .width('100%')
        .constraintSize({ minHeight: 30 })
        .alignItems(VerticalAlign.Center)
        .margin({ top: 2, bottom: 2 })
      }, (r: RowVM) => `row-${r.name}-${r.sig}`)
    }
    .width('100%')
    .padding(12)
    .borderRadius(Ui.R_MD)
    .backgroundColor(Ui.PANEL)
  }

  @Builder
  private pickers() {
    Row() {
      Column() {
        Text('年份')
          .fontSize(Ui.FS_TINY)
          .fontColor(Ui.MUTED)
        Select(this.yearOptions())
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
          .backgroundColor(Ui.PANEL)
          .borderRadius(Ui.R_SM)
          .height(DeviceEnv.tapMin(DeviceEnv.bpOf(this.widthVp)))
          .width('100%')
          .onSelect((index: number, value: string) => {
            this.year = Number(value);
            const list = this.eventsOfYear();
            if (list.length > 0) {
              this.eventId = list[0].id;
              this.loadBoard();
            }
          })
      }
      .layoutWeight(1)

      Column() {
        Text('赛事')
          .fontSize(Ui.FS_TINY)
          .fontColor(Ui.MUTED)
        Select(this.eventOptions())
          .value(this.currentEventName())
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
          .backgroundColor(Ui.PANEL)
          .borderRadius(Ui.R_SM)
          .height(DeviceEnv.tapMin(DeviceEnv.bpOf(this.widthVp)))
          .width('100%')
          .margin({ left: 8 })
          .onSelect((index: number, value: string) => {
            for (let i = 0; i < this.events.length; i++) {
              if (this.events[i].name === value) {
                this.eventId = this.events[i].id;
                this.year = this.events[i].year;
                this.loadBoard();
                break;
              }
            }
          })
      }
      .layoutWeight(2)

      if (this.stages.length > 1) {
        Column() {
          Text('阶段')
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.MUTED)
          Select(this.stageOptions())
            .value(this.stage ? this.stage : '全部阶段')
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
            .backgroundColor(Ui.PANEL)
            .borderRadius(Ui.R_SM)
            .height(DeviceEnv.tapMin(DeviceEnv.bpOf(this.widthVp)))
            .width('100%')
            .margin({ left: 8 })
            .onSelect((index: number, value: string) => {
              this.stage = value === '全部阶段' ? '' : value;
              this.rebuild();
            })
        }
        .layoutWeight(1)
      }
    }
    .width('100%')
  }

  private yearOptions(): SelectOption[] {
    const out: SelectOption[] = [];
    for (let i = 0; i < this.years.length; i++) {
      const o: SelectOption = { value: String(this.years[i]) };
      out.push(o);
    }
    return out;
  }

  private eventOptions(): SelectOption[] {
    const list = this.eventsOfYear();
    const out: SelectOption[] = [];
    for (let i = 0; i < list.length; i++) {
      const o: SelectOption = { value: list[i].name };
      out.push(o);
    }
    return out;
  }

  private stageOptions(): SelectOption[] {
    const out: SelectOption[] = [];
    const all: SelectOption = { value: '全部阶段' };
    out.push(all);
    for (let i = 0; i < this.stages.length; i++) {
      const o: SelectOption = { value: this.stages[i] };
      out.push(o);
    }
    return out;
  }

  @Builder
  private overviewBlock() {
    Grid() {
      ForEach(this.kpis(), (k: Kpi) => {
        GridItem() {
          this.kpiCard(k)
        }
      }, (k: Kpi) => `kpi-${k.key}-${k.value}`)
    }
    .columnsTemplate('1fr 1fr 1fr')
    .columnsGap(this.gut())
    .rowsGap(this.gut())
    .width('100%')
    .margin({ bottom: this.gut() })
  }

  /** 进行中 / 即将开赛：有进行中场次时全部展示；否则展示下一场 + 今日收官战（与桌面端一致） */
  @Builder
  private liveBlock() {
    Column() {
      Row() {
        Text('进行中 / 即将开赛')
          .fontSize(Ui.FS_BODY)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.liveVMs.length > 0 ? Ui.RED : Ui.TEXT)
        Blank()
        Text(this.hint)
          .fontSize(Ui.FS_TINY)
          .fontColor(Ui.MUTED)
          .maxLines(2)
          .textAlign(TextAlign.End)
          .layoutWeight(1)
          .margin({ left: 8 })
      }
      .width('100%')
      .margin({ bottom: 6 })

      if (this.liveVMs.length > 0) {
        ForEach(this.liveVMs, (vm: MatchVM, i: number) => {
          Column() {
            this.matchCard(vm)
          }
          .width('100%')
          .margin({ bottom: this.gut() })
        }, (vm: MatchVM, i: number) => `live-${i}-${vm.id}-${vm.sig}`)
      } else {
        ForEach(this.fbVMs, (vm: MatchVM, i: number) => {
          Column() {
            this.matchCard(vm)
          }
          .width('100%')
          .margin({ bottom: this.gut() })
        }, (vm: MatchVM, i: number) => `fb-${i}-${vm.id}-${vm.sig}`)
      }
    }
    .width('100%')
    .margin({ bottom: this.gut() * 2 })
  }

  @Builder
  private scheduleBlock() {
    Column() {
      Text('赛程')
        .fontSize(Ui.FS_BODY)
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.TEXT)
        .width('100%')
        .margin({ bottom: 6 })
      ForEach(this.dayVMs, (d: DayVM, i: number) => {
        Column() {
          Text(d.label)
            .fontSize(Ui.FS_SMALL)
            .fontColor(Ui.GOLD)
            .width('100%')
            .margin({ top: i === 0 ? 0 : 8, bottom: 4 })
          /* key 必须带上场次签名：只按日期分组时，刷新后 key 不变 →
           * ArkUI 复用旧节点、跳过 itemGenerator → 比分/状态永远不更新 */
          ForEach(d.items, (vm: MatchVM, j: number) => {
            Column() {
              this.matchCard(vm)
            }
            .width('100%')
            .margin({ bottom: this.gut() })
          }, (vm: MatchVM, j: number) => `m-${j}-${vm.id}-${vm.sig}`)
        }
        .width('100%')
      }, (d: DayVM) => `day-${d.label}-${d.sig}`)
    }
    .width('100%')
  }

  @Builder
  private standBlock() {
    Column() {
      ForEach(this.groupVMs, (g: GroupVM, i: number) => {
        Column() {
          this.standTable(g)
        }
        .width('100%')
        .margin({ bottom: this.gut() })
      }, (g: GroupVM) => `st-${g.name}-${g.sig}`)
    }
    .width('100%')
  }

  /** 周切换小按钮 */
  @Builder
  private weekBtn(label: string) {
    Text(label)
      .fontSize(Ui.FS_SMALL)
      .fontColor(Ui.TEXT)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .borderRadius(Ui.R_SM)
      .backgroundColor(Ui.PANEL)
      .border({ width: 1, color: Ui.LINE })
  }

  /** 日历里的紧凑场次行：时间 + 左队 + 比分 + 右队 + 阶段（队名过长自动换行） */
  @Builder
  private calRow(vm: MatchVM) {
    Row() {
      Text(vm.isLive ? 'LIVE' : vm.time)
        .fontSize(Ui.FS_TINY)
        .fontColor(vm.isLive ? Ui.RED : Ui.MUTED)
        .width(42)
      Text(vm.aName)
        .fontSize(Ui.FS_SMALL)
        .fontColor(vm.winner === 'B' ? Ui.MUTED : Ui.TEXT)
        .layoutWeight(1)
        .textAlign(TextAlign.End)
      Text(vm.status === 'upcoming' ? '- : -' : vm.score)
        .fontSize(Ui.FS_SMALL)
        .fontWeight(FontWeight.Bold)
        .fontColor(vm.isLive ? Ui.GOLD : Ui.TEXT)
        .width(64)
        .textAlign(TextAlign.Center)
        .margin({ left: 6, right: 6 })
      Text(vm.bName)
        .fontSize(Ui.FS_SMALL)
        .fontColor(vm.winner === 'A' ? Ui.MUTED : Ui.TEXT)
        .layoutWeight(1)
      Text(vm.stageText ? vm.stageText : '—')
        .fontSize(Ui.FS_TINY)
        .fontColor(Ui.MUTED)
        .width(46)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
        .margin({ left: 4 })
    }
    .width('100%')
    .constraintSize({ minHeight: 30 })
    .alignItems(VerticalAlign.Center)
  }

  /** 赛事日历：默认本周（已结束赛事默认末周），上一周 / 下一周 / 本周切换 */
  @Builder
  private calendarBlock() {
    Column() {
      Row() {
        Text('赛事日历')
          .fontSize(Ui.FS_BODY)
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.TEXT)
        Blank()
        Row() {
          this.weekBtn('上一周')
        }
        .onClick(() => this.stepWeek(-1))
        Text(this.weekLabel)
          .fontSize(Ui.FS_SMALL)
          .fontColor(Ui.GOLD)
          .width(96)
          .textAlign(TextAlign.Center)
          .margin({ left: 6, right: 6 })
        Row() {
          this.weekBtn('下一周')
        }
        .onClick(() => this.stepWeek(1))
        Text(this.homeWeekLabel())
          .fontSize(Ui.FS_SMALL)
          .fontColor(Ui.ON_GOLD)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(Ui.R_SM)
          .backgroundColor(Ui.GOLD)
          .margin({ left: 6 })
          .onClick(() => this.goHomeWeek())
      }
      .width('100%')
      .margin({ bottom: 8 })

      if (this.calVMs.length === 0) {
        Text('该周暂无赛程')
          .fontSize(Ui.FS_SMALL)
          .fontColor(Ui.MUTED)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 18, bottom: 18 })
      }

      ForEach(this.calVMs, (d: CalDayVM, i: number) => {
        Column() {
          Row() {
            Text(d.label)
              .fontSize(Ui.FS_SMALL)
              .fontColor(d.isToday ? Ui.GOLD : Ui.TEXT)
              .fontWeight(d.isToday ? FontWeight.Bold : FontWeight.Normal)
            if (d.isToday) {
              Text('今天')
                .fontSize(Ui.FS_TINY)
                .fontColor(Ui.ON_GOLD)
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                .borderRadius(3)
                .backgroundColor(Ui.GOLD)
                .margin({ left: 6 })
            }
            Blank()
            Text(`${d.items.length} 场`)
              .fontSize(Ui.FS_TINY)
              .fontColor(Ui.MUTED)
          }
          .width('100%')
          .margin({ top: i === 0 ? 0 : 10, bottom: 4 })

          ForEach(d.items, (vm: MatchVM, j: number) => {
            Row() {
              this.calRow(vm)
            }
            .width('100%')
            .borderRadius(Ui.R_SM)
            .backgroundColor(vm.isLive ? Ui.LIVE_BG : Color.Transparent)
            .padding({ left: 4, right: 4 })
          }, (vm: MatchVM, j: number) => `calrow-${d.dateKey}-${j}-${vm.id}-${vm.sig}`)
        }
        .width('100%')
      }, (d: CalDayVM) => `calday-${d.dateKey}-${d.sig}`)
    }
    .width('100%')
    .padding(12)
    .borderRadius(Ui.R_MD)
    .backgroundColor(Ui.PANEL)
  }

  /** 断点自适应取值：build() 内不能声明局部变量，统一走成员方法 */
  private pad(): number {
    return DeviceEnv.padOf(this.widthVp);
  }

  /** 断点自适应取值：build() 内不能声明局部变量，统一走成员方法 */
  private wide(): boolean {
    return DeviceEnv.wideOf(this.widthVp);
  }

  /** 小屏（<600vp）放不下全部列时省略胜率列，保证战绩榜不溢出、不错位 */
  private showRate(): boolean {
    return this.widthVp >= 600;
  }

  /** 断点自适应取值：build() 内不能声明局部变量，统一走成员方法 */
  private hasData(): boolean {
    return this.ready && this.board !== null;
  }

  /** 底部留白：窄屏时底部页签已吞掉手势条高度，页面不再重复加安全区 */
  private bottomGap(): number {
    return this.widthVp >= DeviceEnv.MD_MAX ? this.safeBottom + 8 : 84 + this.safeBottom + 12;
  }

  build() {

    /* 悬浮毛玻璃页头：标题 + 赛事选择浮在内容之上，滚动时内容从其下方穿过并模糊 */
    Stack({ alignContent: Alignment.Top }) {
      if (!this.hasData()) {
        Column() {
          Text(this.ready ? '该赛事暂无离线数据' : '加载中…')
            .fontSize(Ui.FS_BODY)
            .fontColor(Ui.MUTED)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: this.headH })
      }

      if (this.hasData() && this.wide()) {
        Row() {
          Scroll() {
            Column() {
              this.overviewBlock()
              this.liveBlock()
            }
            .width('100%')
            .padding({
              top: this.headH + 10,
              bottom: this.bottomGap(),
            })
          }
          .layoutWeight(1.15)
          .align(Alignment.TopStart)
          .height('100%')

          Scroll() {
            Column() {
              this.standBlock()
              this.calendarBlock()
              this.scheduleBlock()
            }
            .width('100%')
            .padding({
              top: this.headH + 10,
              bottom: this.bottomGap(),
            })
          }
          .layoutWeight(1)
          .align(Alignment.TopStart)
          .height('100%')
          .margin({ left: this.gut() })
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Top)
        .padding({
          left: this.pad(),
          right: this.pad(),
        })
      }

      if (this.hasData() && !this.wide()) {
        Scroll() {
          Column() {
            this.overviewBlock()
            this.liveBlock()
            this.standBlock()
            this.calendarBlock()
            this.scheduleBlock()
          }
          .width('100%')
          .padding({
            top: this.headH + 10,
            bottom: this.bottomGap(),
            left: this.pad(),
            right: this.pad(),
          })
        }
        .width('100%')
        .height('100%')
      }

      Column() {
        TopBar({
          title: '比分看板',
          status: this.statusText(),
          live: this.online,
          loading: this.loading,
          onRefresh: () => {
            this.refresh(true);
          }
        })

        this.pickers()

        HeaderFade()
      }
      .width('100%')
      .padding({
        top: this.safeTop + 12,
        left: this.pad(),
        right: this.pad(),
      })
      .backgroundColor(Ui.GLASS)
      .backgroundEffect({ radius: Ui.BLUR, saturation: 1.5 })
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.headH = Number(newArea.height);
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Ui.BG)
  }
}

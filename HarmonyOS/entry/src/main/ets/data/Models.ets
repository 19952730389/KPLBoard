/* 数据模型：与离线包 bundle/api/*.json 的字段一一对应
 * ---------------------------------------------------------------------------
 * 离线包由 tools/build-mobile-bundle.js 生成，字段沿用网页版 /api 的输出，
 * 这里只做「形状声明」，不做运行时校验（ArkTS 里 JSON.parse 后直接断言类型）。
 */

export interface EventItem {
  id: number;
  name: string;
  short?: string;
  year: number;
  category?: string;
  mode?: string;
  start?: string;
  end?: string;
  grouped?: boolean;
  active?: boolean;
  loaded?: boolean;
  matchCount?: number;
}

export interface EventsResp {
  ok?: boolean;
  events: EventItem[];
  defaultId?: number;
}

export interface TeamRef {
  id?: string;
  name: string;
  icon?: string;
  score?: number;
}

export interface MatchItem {
  id?: string;
  date?: string;
  dateLabel?: string;
  time?: string;
  stage?: string;
  bo?: number;
  a: TeamRef;
  b: TeamRef;
  legs?: Array<string | null>;
  playedLegs?: number;
  winner?: string;
  over?: boolean;
  liveFlag?: boolean;
  hasVideo?: boolean;
  status?: string;
  isToday?: boolean;
}

export interface FormItem {
  r?: string;
  vs?: string;
  score?: string;
}

export interface StandingRow {
  id?: string;
  name: string;
  icon?: string;
  matches?: number;
  wins?: number;
  losses?: number;
  gameWins?: number;
  gameLosses?: number;
  net?: number;
  points?: number;
  winRate?: number;
  gameRate?: number;
  form?: FormItem[];
  opponents?: string[];
  rank?: number;
  /** 晋级情况：direct=直进淘汰赛 playin=突围赛 out=淘汰（分组赛事才有） */
  adv?: string;
  /** 所属分组 key（masters / elite），与桌面端一致 */
  groupKey?: string;
}

export interface StandingGroup {
  key?: string;
  name?: string;
  desc?: string;
  rule?: string;
  accent?: string;
  rows: StandingRow[];
}

export interface BoardSummary {
  totalMatches?: number;
  finished?: number;
  live?: number;
  upcoming?: number;
  todayTotal?: number;
  todayDone?: number;
  totalGames?: number;
  avgGames?: number;
  bo?: number;
  decidingGames?: number;
  sweep?: number;
}

export interface StageCount {
  name?: string;
  count?: number;
}

export interface StandingsBlock {
  mode?: string;
  groups?: StandingGroup[];
  /** 未进分组榜单的战队（桌面端渲染成「其他战队」面板） */
  ungrouped?: StandingRow[];
}

/** 实时源状态（桌面端 /api/board 的 realtime 字段） */
export interface RealtimeInfo {
  enabled?: boolean;
  ok?: boolean;
  source?: string;
  updatedAt?: number;
  matched?: number;
  error?: string;
}

export interface BoardResp {
  ok?: boolean;
  serverTime?: number;
  realtime?: RealtimeInfo;
  event?: EventItem;
  stage?: string;
  stages?: StageCount[];
  summary?: BoardSummary;
  standings?: StandingsBlock;
  matches?: MatchItem[];
  updatedAt?: number;
  stale?: boolean;
  error?: string;
}

/* ---------- 梯度榜 ---------- */
export interface GradientItem {
  name: string;
  /** 上游使用的名称（与官方英雄库不一致时才有值） */
  alias?: string;
  heroId?: number;
  icon?: string;
  types?: string[];
  lanes?: string[];
  title?: string;
  games?: number;
  wins?: number;
  losses?: number;
  winRate?: number;
  /** 贝叶斯平滑胜率（评分用，官方 / 玩加同口径） */
  smooth?: number;
  /** 官方（KPL 统计）通道不提供逐选手 KDA / 使用人数 → null，卡片整段省略 */
  kda?: number | null;
  users?: number | null;
  userList?: string[];
  share?: number;
  score?: number;
  rank?: number;
  tier?: string;
  tierLabel?: string;
  pct?: number;
}

export interface GradientResp {
  ok?: boolean;
  event?: string;
  eventId?: number;
  totalPlayers?: number;
  totalTeams?: number;
  totalHeroPicks?: number;
  totalPlayerGames?: number;
  /** 数据来源：kpl = KPL 官方统计（与 iOS 版同口径） */
  source?: string;
  sourceName?: string;
  updatedAt?: number;
  list?: GradientItem[];
}

/* ---------- 选手 ---------- */
export interface PlayerPoolItem {
  name?: string;
  /** 上游使用的名称（官方英雄库无此名时才有值） */
  alias?: string;
  heroId?: number;
  games?: number;
  wins?: number;
  losses?: number;
  winRate?: number;
  /** 官方通道不提供逐英雄 KDA → null，列表显示「—」 */
  kda?: number | null;
  icon?: string;
  types?: string[];
  lanes?: string[];
  title?: string;
  rank?: number;
}

export interface PlayerTotals {
  kills?: number;
  deaths?: number;
  assists?: number;
  golds?: number;
  damage?: number;
  damageTaken?: number;
}

export interface PlayerItem {
  id?: string;
  name: string;
  team?: string;
  teamId?: string;
  games?: number;
  /** 官方通道逐小局不可用时为 null → 显示「—」而不是误导性的 0 */
  wins?: number | null;
  losses?: number | null;
  winRate?: number | null;
  kda?: number;
  kills?: number;
  deaths?: number | null;
  assists?: number | null;
  goldPerMin?: number | null;
  dmgPerMin?: number | null;
  dmgTakenPerMin?: number | null;
  mostKills?: number | null;
  mostAssists?: number | null;
  mostDeaths?: number | null;
  dmgConversion?: number | null;
  durationSec?: number | null;
  totals?: PlayerTotals;
  pool?: PlayerPoolItem[];
  goldPercent?: string;
  dmgPercent?: string;
  dmgTakenPercent?: string;
  attendRate?: string;
  /** 占比裸数值（官方通道提供，用于排序 / 展示兜底） */
  goldPercentNum?: number;
  dmgPercentNum?: number;
  dmgTakenPercentNum?: number;
  attendRateNum?: number;
  lane?: string;
  lanes?: string[];
  types?: string[];
  durationMin?: number | null;
  rank?: number;
  poolSize?: number;
  /** 数据来源：kpl = KPL 官方统计 */
  source?: string;
}

export interface PlayersResp {
  ok?: boolean;
  eventId?: number;
  event?: string;
  count?: number;
  source?: string;
  players?: PlayerItem[];
}

/* ---------- 英雄 ---------- */
export interface HeroBrief {
  id: number;
  name: string;
  title?: string;
  pinyin?: string;
  types?: string[];
  lanes?: string[];
  skinCount?: number;
  icon?: string;
}

export interface HeroesResp {
  ok?: boolean;
  heroes: HeroBrief[];
}

export interface SkinItem {
  name?: string;
  big?: string;
  bigAlt?: string;
}

/** 英雄属性评分（官网 herodetail 四项） */
export interface HeroAttr {
  label?: string;
  value?: number;
}

/** 英雄技能（官网 herodetail 解析） */
export interface HeroSkill {
  name?: string;
  cd?: string;
  cost?: string;
  desc?: string;
  icon?: string;
}

export interface HeroDetail extends HeroBrief {
  skins?: SkinItem[];
  attr?: HeroAttr[];
  skills?: HeroSkill[];
  /** 背景故事（官网「英雄故事」弹层，纯文本、段落用 \n 分隔） */
  story?: string;
  /** 历史上的 TA（可选） */
  history?: string;
  /** true = 官网未建页，仅基础资料 */
  partial?: boolean;
}

export interface HeroResp {
  ok?: boolean;
  hero: HeroDetail;
}

/* ---------- 装备 ---------- */
export interface ItemRow {
  id?: number | string;
  name: string;
  typeId?: number;
  type?: string;
  price?: number;
  total?: number;
  desc?: string;
  lines?: string[];
  passive?: string;
  passives?: string[];
  hasPassive?: boolean;
  icon?: string;
}

export interface ItemsResp {
  ok?: boolean;
  items: ItemRow[];
}

/* ---------- 铭文 ---------- */
export interface RuneColor {
  key?: string;
  name?: string;
  short?: string;
  accent?: string;
  desc?: string;
  count?: number;
  level5?: number;
}

export interface RuneGrade {
  grade?: number;
  count?: number;
}

export interface RuneItem {
  id?: number | string;
  name: string;
  color?: string;
  colorName?: string;
  grade?: number;
  desc?: string;
  lines?: string[];
  officialType?: string;
  icon?: string;
}

export interface RunesResp {
  ok?: boolean;
  updatedAt?: number;
  total?: number;
  topLevel?: number;
  slotPerColor?: number;
  colors?: RuneColor[];
  grades?: RuneGrade[];
  note?: string;
  priceNote?: string;
  list?: RuneItem[];
}

/* ---------- 版本动态 ---------- */
export interface PatchNote {
  id?: string;
  title?: string;
  time?: string;
  version?: string;
  url?: string;
  kinds?: string[];
  changeCount?: number;
}

/** 一条具体改动（英雄 / 装备 / 铭文） */
export interface PatchChange {
  kind?: string;      // hero | item | rune
  name?: string;      // 英雄名 / 装备名
  id?: string;        // 英雄 id / 装备 id
  icon?: string;      // 头像 / 装备图标
  title?: string;     // 英雄称号
  type?: string;      // 装备分类（攻击 / 防御 …）
  section?: string;   // 原文小标题
  dir?: string;       // buff(增强) | nerf(削弱) | adjust(调整)
  lines?: string[];   // 逐条改动明细
  summary?: string;
  newsId?: string;
  newsTitle?: string;
  newsTime?: string;
  newsUrl?: string;
  version?: string;
}

export interface PatchResp {
  ok?: boolean;
  updatedAt?: number;
  notes?: PatchNote[];
  changes?: PatchChange[];
  latestVersion?: string;
  latestTime?: string;
  counts?: Record<string, number>;
}

/** 公告详情（点开公告后按 id 直连官网拉正文：纯文本 + 结构化调整条目） */
export interface PatchDetail {
  ok?: boolean;
  id?: string;
  /** 游戏版本号（官网 sGameVersion，可能为空） */
  version?: string;
  /** 正文纯文本，段落用 \n 分隔 */
  text?: string;
  changes?: PatchChange[];
}

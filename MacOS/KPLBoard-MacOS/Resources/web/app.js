/* KPL 赛季比分看板 - 前端逻辑 */

const REFRESH_IDLE = 15000;    // 无进行中比赛时的轮询间隔
const REFRESH_LIVE = 8000;     // 有进行中比赛时的轮询间隔
const REFRESH_DONE = 120000;   // 已结束赛季的轮询间隔（结果不会变）
const REFRESH_ARCHIVE = 600000; // 历史赛事：后端已落盘缓存，几乎无需再取
const REFRESH_TODAY_DONE = 60000; // 今日赛程已全部结束：当天不会再变，降到 1 分钟

const state = {
  events: [],
  eventId: null,
  stage: '',
  data: null,
  weekOffset: 0,
  nextAt: 0,
  timer: null,
  tickTimer: null,
  loading: false,
  lastError: null,
  firstLoadDone: null,
  refreshQueued: false,  // 加载期间用户又点了一次刷新 → 结束后补一次
  fails: 0,              // 连续失败次数，用于指数退避
};

const $ = (s) => document.querySelector(s);

/* ---------- 工具 ---------- */
function fmtTime(ts) {
  const d = new Date(ts);
  const p = (n) => String(n).padStart(2, '0');
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}
function bjTodayKey() {
  const now = new Date(Date.now() + 8 * 3600 * 1000);
  return `${now.getUTCFullYear()}${String(now.getUTCMonth() + 1).padStart(2, '0')}${String(now.getUTCDate()).padStart(2, '0')}`;
}
function parseDateKey(k) {
  const y = +k.slice(0, 4), m = +k.slice(4, 6), d = +k.slice(6, 8);
  return new Date(Date.UTC(y, m - 1, d));
}
function mondayOf(date) {
  const d = new Date(date.getTime());
  const wd = d.getUTCDay();
  d.setUTCDate(d.getUTCDate() - (wd === 0 ? 6 : wd - 1));
  return d;
}
function weekDiff(dateKey) {
  const a = mondayOf(parseDateKey(dateKey));
  const b = mondayOf(parseDateKey(bjTodayKey()));
  return Math.round((a - b) / (7 * 86400000));
}
function weekRange(offset) {
  const base = mondayOf(parseDateKey(bjTodayKey()));
  const start = new Date(base.getTime() + offset * 7 * 86400000);
  const end = new Date(start.getTime() + 6 * 86400000);
  const f = (dt) => `${dt.getUTCMonth() + 1}.${String(dt.getUTCDate()).padStart(2, '0')}`;
  return { start, end, label: `${f(start)} - ${f(end)}` };
}
function shortName(n, len) {
  return (n || '').length > len ? n.slice(0, len) : n || '—';
}

/* 转义：队名 / 阶段名来自上游 JSON，可能含 "、<、&，
   直接拼进 innerHTML 或 title= 属性会破坏标签或被注入。与 tools.js 的 esc 保持一致。 */
function esc(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/* 颜色白名单校验：accent / groupDot 会被拼进 style="--accent:…"（CSS 注入上下文）。
   只放行 #RGB / #RGBA / #RRGGBB / #RRGGBBAA，不合法时返回 ''，由调用方兜底默认色。 */
function safeColor(c) {
  const s = String(c ?? '').trim();
  return /^#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(s) ? s : '';
}

/* ---------- 名称显示：按「视觉宽度」裁剪 + 队名简称 ---------- */
/** 全角按 1、半角按 0.55 计算视觉宽度，避免「深圳DYG」被当成 5 单位硬切成「深圳DY」 */
function visWidth(s) {
  let w = 0;
  for (const ch of s) w += /[\x00-\xff]/.test(ch) ? 0.55 : 1;
  return w;
}
/** 超出 max 视觉宽度才裁剪，并补省略号 */
function clipVis(s, max) {
  if (!s) return '';
  if (visWidth(s) <= max) return s;
  let w = 0;
  let out = '';
  for (const ch of s) {
    const cw = /[\x00-\xff]/.test(ch) ? 0.55 : 1;
    if (w + cw > max - 0.5) break;
    w += cw;
    out += ch;
  }
  return out + '…';
}

/** 队名中的城市 / 赛区前缀，用于生成更短且仍可辨识的简称 */
const CITY_PREFIX = [
  '成都', '广州', '北京', '上海', '深圳', '武汉', '重庆', '济南', '苏州', '长沙',
  '西安', '佛山', '南京', '杭州', '厦门', '无锡', '惠州', '东莞', '镇江', '昆山',
  '太原', '青岛', '宁波', '贵阳', '郑州', '天津', '沈阳', '大连', '合肥', '福州',
  '南昌', '昆明', '南宁', '石家庄', '哈尔滨', '长春', '乌鲁木齐', '兰州', '银川',
];
/** 少数无城市前缀但更希望按品牌简写的队名（规则之外的兜底特例） */
const TEAM_ALIAS = {
  AG超玩会: 'AG',
  Hero久竞: 'Hero',
  'LGD大鹅': 'LGD',
  'QGhappy': 'QG',
  eStarPro: 'eStar',
};
/** 队伍简称：去城市前缀 → 裁剪到视觉宽度 max（默认 8，足够放下「成都AG超玩会」这类最长队名） */
function teamShort(name, max = 8) {
  const raw = (name || '').trim();
  if (!raw) return '—';
  let s = raw;
  for (const c of CITY_PREFIX) {
    if (s.startsWith(c) && s.length - c.length >= 2) {
      s = s.slice(c.length);
      break;
    }
  }
  if (TEAM_ALIAS[s] && visWidth(TEAM_ALIAS[s]) < visWidth(s)) s = TEAM_ALIAS[s];
  return clipVis(s, max);
}
/** 阶段名：去空格后按视觉宽度裁剪 */
function stageShort(s, max = 6) {
  return clipVis((s || '').replace(/\s+/g, ''), max);
}
function fmtDateLabel(k) {
  if (!k || k.length !== 8) return '';
  return `${+k.slice(4, 6)}月${+k.slice(6, 8)}日`;
}
/** yyyyMMdd → MM/DD；上游偶发缺失 / 畸形 date（archive 通道）时不抛异常 */
function fmtMD(k) {
  const s = String(k || '');
  return s.length === 8 ? `${s.slice(4, 6)}/${s.slice(6)}` : '—';
}
/** 赛程统一比较器：先日期后时间（String 比较对 yyyyMMdd / HH:mm 即字典序正确）。
    必须对相等键返回 0：返回 ±1 违反比较器契约，会破坏排序稳定性。 */
function cmpByDateTime(a, b) {
  if (a.date !== b.date) return a.date < b.date ? -1 : 1;
  if (a.time !== b.time) return a.time < b.time ? -1 : 1;
  return 0;
}
function fmtFullDate(k) {
  if (!k || k.length !== 8) return '—';
  return `${k.slice(0, 4)}.${k.slice(4, 6)}.${k.slice(6, 8)}`;
}
/** 队名首字：图片兜底占位用 */
function initialOf(team) {
  return teamShort(team?.name, 8).replace(/[^一-龥A-Za-z0-9]/g, '').slice(0, 1) || '?';
}
function avatarHTML(team) {
  const initial = initialOf(team);
  /* 战队头像统一走 KPLImg：代理取图 + 统一尺寸(58×58) + 失败落到带首字的占位图（保持原有的首字观感） */
  return `<div class="avatar">${KPLImg.tag(team.icon, {
    w: 58, h: 58, fb: initial, alt: team.name, eager: true, ci: false,
  })}</div>`;
}
function statusBadge(m) {
  if (m.status === 'live') return `<span class="badge live">LIVE 进行中</span>`;
  if (m.status === 'finished') return `<span class="badge done">已结束</span>`;
  return `<span class="badge soon">未开始</span>`;
}

/* ---------- 筛选组件：赛季下拉（年份倒序分组，同年内按开赛时间正序） ---------- */
/** 开赛日期升序；缺日期的排到该年最后 */
function byStartAsc(a, b) {
  return (a.start || '9999-99-99').localeCompare(b.start || '9999-99-99');
}

/** 时间轴：全部赛事按开赛时间从早到晚（用于「新 / 旧」逐场切换） */
function timeline() {
  return [...state.events].sort((a, b) => {
    const c = byStartAsc(a, b);
    return c !== 0 ? c : (a.year || 0) - (b.year || 0);
  });
}

/** renderTabs 每次轮询都被调用（77 个 option 全量重建，会打断 macOS 上展开的下拉）。
    用「列表内容签名 + 当前赛季」判断列表是否真的变了：没变就只同步选中项。 */
let _tabsSignature = '';
function eventsSignature() {
  return state.events.map((e) => `${e.id}:${e.matchCount || 0}:${e.active ? 1 : 0}`).join('|');
}
function renderTabs() {
  const sel = $('#seasonSelect');
  const byYear = new Map();
  for (const e of state.events) {
    if (!byYear.has(e.year)) byYear.set(e.year, []);
    byYear.get(e.year).push(e);
  }
  const years = [...byYear.keys()].sort((a, b) => b - a);
  const sig = eventsSignature();
  if (sig !== _tabsSignature) {
    _tabsSignature = sig;
    sel.innerHTML = years
      .map((y) => {
        const opts = byYear
          .get(y)
          .slice()
          .sort(byStartAsc)
          .map((e) => {
            const mark = e.active ? ' ●' : '';
            const cnt = e.matchCount ? ` · ${e.matchCount}场` : '';
            const label = `${e.short || e.name}${mark}${cnt}`;
            return `<option value="${esc(e.id)}" ${String(e.id) === String(state.eventId) ? 'selected' : ''}>${esc(label)}</option>`;
          })
          .join('');
        return `<optgroup label="${esc(y)} 年">${opts}</optgroup>`;
      })
      .join('');
  } else {
    // 列表没变：只把选中项同步到当前赛季，不重建 option（避免打断展开中的下拉）
    sel.value = String(state.eventId ?? '');
  }

  const ev = state.events.find((e) => String(e.id) === String(state.eventId));
  $('#seasonMeta').textContent = ev
    ? `${ev.year} · ${ev.category || '赛事'} · ${ev.mode === 'live' ? '实时数据' : '历史数据'}`
    : '';
  $('#homeWeek').textContent = ev && !ev.active ? '末周' : '本周';
}

/** 沿时间轴切换赛季：dir=-1 更新，dir=1 更早 */
async function stepSeason(dir) {
  const asc = timeline();
  const idx = asc.findIndex((e) => String(e.id) === String(state.eventId));
  if (idx < 0) return;
  const next = asc[idx - dir];
  if (!next) return;
  $('#seasonSelect').value = next.id;
  /* 必须 await：切换失败（id 未加载等）时要把下拉框回退到实际生效的赛季，
     否则 select 显示 X 而 state.eventId 仍是 Y，界面与状态永久错位。 */
  try {
    await switchEvent(next.id);
  } finally {
    const sel = $('#seasonSelect');
    if (sel && String(sel.value) !== String(state.eventId)) sel.value = state.eventId;
  }
}

function renderStageSelect() {
  const sel = $('#stageSelect');
  const stages = state.data ? state.data.stages || [] : [];
  const cur = state.stage;
  sel.innerHTML =
    `<option value="">全部阶段</option>` +
    stages.map((s) => `<option value="${esc(s.name)}" ${s.name === cur ? 'selected' : ''}>${esc(s.name)}（${s.count}场）</option>`).join('');
  sel.disabled = stages.length === 0;
  if (cur && !stages.some((s) => s.name === cur)) {
    state.stage = '';
    sel.value = '';
  }
}

/** 原生菜单 / 前端下拉统一入口。
   前端 events 列表（/api/events）与原生菜单（bundle events.json）是两个来源，
   原生菜单先于前端列表就绪时，id 可能暂时不在 state.events 里 ——
   此时不能静默 return：要么从缓存层再取一次列表，要么给出可见的错误提示。 */
async function switchEvent(id) {
  if (id == null || String(id) === String(state.eventId)) return;
  let hit = state.events.find((e) => String(e.id) === String(id));
  if (!hit) {
    // 列表尚未就绪或过期 → 重取一次（KPLStore 未就绪时直接走网络）
    try {
      const json = window.KPLStore
        ? await window.KPLStore.api('/api/events', { force: true })
        : await fetch('/api/events', { cache: 'no-store' }).then((r) => r.json());
      if (json && json.ok) {
        state.events = json.events || [];
        renderTabs();
        hit = state.events.find((e) => String(e.id) === String(id));
      }
    } catch (_) { /* 下方统一提示 */ }
  }
  if (!hit) {
    showFatal(`赛季 ${id} 不存在或尚未加载`);
    return;
  }
  state.eventId = String(id);
  state.stage = '';
  state.data = null;
  state.weekOffset = 0;
  state.firstLoadDone = null;
  renderTabs();
  $('#stageSelect').innerHTML = '<option value="">全部阶段</option>';
  $('#connText').textContent = '正在加载该赛季数据…';
  await load(true);
}

/* ---------- 渲染：统计条 ---------- */
function renderStats(s) {
  const items = [
    { k: '进行中', v: s.live, cls: s.live ? 'hot' : '' },
    { k: '今日赛程', v: `${s.todayDone}<small>/${s.todayTotal}</small>`, cls: '' },
    { k: '已完赛', v: s.finished, cls: 'green' },
    { k: '待开赛', v: s.upcoming, cls: '' },
    { k: '总小局数', v: s.totalGames, cls: '' },
    { k: '场均小局', v: s.avgGames, cls: 'gold' },
    { k: `打满BO${s.bo || 5}`, v: s.decidingGames, cls: '' },
    { k: '零封场次', v: s.sweep, cls: '' },
  ];
  $('#stats').innerHTML = items
    .map((i) => `<div class="stat ${i.cls}"><div class="k">${i.k}</div><div class="v">${i.v}</div></div>`)
    .join('');
}

/* ---------- 渲染：实时区 ---------- */
function renderLive(matches) {
  const live = matches.filter((m) => m.status === 'live');
  const todayKey = bjTodayKey();

  if (live.length) {
    const rt = (state.data && state.data.realtime) || null;
    const sync = rt && rt.enabled ? (rt.ok ? ' · 比分实时同步中' : ' · 实时源异常，显示上游数据') : '';
    $('#liveHint').textContent = `${live.length} 场比赛进行中，页面每 ${REFRESH_LIVE / 1000}s 自动刷新${sync}`;
    setLiveHTML(live.map(matchCard).filter(Boolean).join('') || `<div class="empty">暂无比赛数据</div>`);
    return;
  }

  const rest = matches
    .filter((m) => m.status === 'upcoming')
    .sort(cmpByDateTime);
  const next = rest[0];

  $('#liveHint').textContent = next
    ? `暂无进行中比赛 · 下一场：${fmtMD(next.date)} ${next.time || ''} ${next.a?.name || '—'} vs ${next.b?.name || '—'}`.trim()
    : '本阶段比赛已全部结束';

  const cards = [];
  if (next) cards.push(matchCard({ ...next, highlightNext: true }));

  // 已结束赛季展示最后一场；进行中赛季展示今日收官战
  const todayFinished = matches.filter((m) => m.status === 'finished' && m.date === todayKey);
  if (todayFinished.length) cards.push(...todayFinished.slice(-1).map(matchCard));
  else if (!cards.length) {
    const last = matches.filter((m) => m.status === 'finished').slice(-1);
    cards.push(...last.map(matchCard));
  }
  setLiveHTML(cards.filter(Boolean).join('') || `<div class="empty">暂无比赛数据</div>`);
}

/** 直播卡片区只在内容变化时重写：进行中比赛每 8s 轮询一次，
    内容没变（最常见情况）就不动 DOM，保住文本选区与滚动。 */
function setLiveHTML(html) {
  const box = $('#liveCards');
  if (!box) return;
  const sig = hashStr(html);
  if (sig === _liveSig) return;
  _liveSig = sig;
  box.innerHTML = html;
}
let _liveSig = '';

/** 大比分取值：上游大比分常常滞后于逐小局，逐小局推导更靠前时以逐小局为准，保证卡片上下一致 */
function scoreOf(m) {
  const a = (m.a && m.a.score) || 0;
  const b = (m.b && m.b.score) || 0;
  const la = (m.legs || []).filter((x) => x === 'A').length;
  const lb = (m.legs || []).filter((x) => x === 'B').length;
  return la + lb > a + b ? { a: la, b: lb, derived: true } : { a, b, derived: false };
}

function matchCard(m) {
  /* 上游（archive HTML 解析 / 缓存 JSON）偶发产出缺 a/b 侧的残缺行，
     直接解引用会让整个 render 半途 throw、看板留白，这里跳过坏行。 */
  if (!m || !m.a || !m.b) return '';
  const isLive = m.status === 'live';
  const finished = m.status === 'finished';
  const winner = m.winner;
  const sc = scoreOf(m);

  const played = (m.legs || []).filter(Boolean).length;
  const noLegData = finished && played === 0; // 早期赛事上游只公布大比分
  const total = finished ? Math.max(sc.a + sc.b, played) : Number(m.bo) || (m.legs || []).length || 5;
  const legs = noLegData
    ? `<div class="legs-empty">该赛事年代较早，仅记录大比分</div>`
    : Array.from({ length: total }, (_, i) => {
        const l = (m.legs || [])[i] || null;
        if (!l) {
          const tip = finished ? `第${i + 1}局 胜方数据未公布` : `第${i + 1}局 未开始`;
          return `<div class="leg pending" title="${esc(tip)}"><b>G${i + 1}</b><span class="t">—</span></div>`;
        }
        const team = l === 'A' ? m.a : m.b;
        return `<div class="leg ${l}" title="${esc(`第${i + 1}局 ${team.name} 胜`)}"><b>G${i + 1}</b><span class="t">${teamShort(
          team.name
        )}</span></div>`;
      }).join('');

  const footLeft = [m.dateLabel || fmtDateLabel(m.date), m.time, m.stage].filter(Boolean).join(' · ');
  const footRight = finished
    ? `完赛 · 共 ${sc.a + sc.b} 局`
    : isLive
      ? `进行中 · 已打 ${m.playedLegs} 局${m.realtime ? ' · 实时源' : ''}`
      : m.highlightNext
        ? '即将开赛'
        : '未开始';

  return `
  <div class="match-card ${isLive ? 'is-live' : ''}">
    <div class="mc-top">
      <span>${footLeft}${m.bo ? ` · BO${m.bo}` : ''}</span>
      ${statusBadge(m)}
    </div>
    <div class="mc-body">
      <div class="team ${winner === 'A' ? 'win' : winner ? 'lose' : ''}">
        ${avatarHTML(m.a)}
        <div class="tname">${esc(m.a.name)}</div>
      </div>
      <div class="score-box">
        <div class="num">
          <span class="${winner === 'A' || (!winner && sc.a > sc.b) ? 'lead' : ''}">${sc.a}</span>
          <span class="sep">:</span>
          <span class="${winner === 'B' || (!winner && sc.b > sc.a) ? 'lead' : ''}">${sc.b}</span>
        </div>
        <div class="tag">${m.bo ? `BO${m.bo}` : '—'}</div>
      </div>
      <div class="team ${winner === 'B' ? 'win' : winner ? 'lose' : ''}">
        ${avatarHTML(m.b)}
        <div class="tname">${esc(m.b.name)}</div>
      </div>
    </div>
    <div class="legs"${noLegData ? '' : ` style="--n:${total}"`}>${legs}</div>
    <div class="mc-foot"><span>${noLegData ? '大比分' : '逐小局胜方'}</span><span>${footRight}</span></div>
  </div>`;
}

/* ---------- 渲染：战绩榜 ---------- */
const ADV_TEXT = { direct: '直接晋级淘汰赛', playin: '进入突围赛', out: '淘汰' };
const ADV_SHORT = { direct: '直进', playin: '突围', out: '淘汰' };
const GROUP_LABEL = { masters: { text: '大师', accent: '#f5c451' }, elite: { text: '精英', accent: '#9b6bff' } };

function renderStandings(payload) {
  const zone = $('#standingsZone');
  const data = payload || {};
  const groups = Array.isArray(data.groups) ? data.groups : [];
  const ungrouped = Array.isArray(data.ungrouped) ? data.ungrouped : [];

  const panels = groups.map((g) => groupPanel(g, data.mode));
  if (ungrouped.length) {
    panels.push(
      groupPanel(
        { key: 'other', name: '其他战队', desc: '非年度总决赛 12 队', rule: '', accent: '#8b95ad', rows: ungrouped },
        data.mode
      )
    );
  }

  if (!panels.length) {
    zone.innerHTML = `<section class="panel"><div class="section-head"><h2>战队战绩榜</h2></div><div class="empty">暂无战绩数据</div></section>`;
    _standingsSig = '';
    return;
  }
  /* 内容没变就整块跳过：战绩榜每 8~15s 轮询一次，全量 innerHTML 会
     丢掉 .table-wrap 的滚动位置与文本选区（mac.css:133 限高 720px，可滚动）。 */
  const sig = panels.join('').length + ':' + hashStr(panels.join(''));
  if (sig === _standingsSig) return;
  _standingsSig = sig;
  const keep = keepScroll(zone);
  zone.innerHTML = panels.join('');
  restoreScroll(zone, keep);
}

/* 滚动位置保持：记录区块内所有可滚动后代（含自身）的 scrollTop，重绘后还原 */
function keepScroll(root) {
  const out = [];
  const collect = (el) => {
    if (el.scrollHeight > el.clientHeight + 1) out.push([el, el.scrollTop]);
    for (const c of el.children) collect(c);
  };
  collect(root);
  return out;
}
function restoreScroll(root, saved) {
  for (const [el, top] of saved) {
    if (root.contains(el)) el.scrollTop = top;
  }
}
/** 轻量字符串签名（djb2）：比 JSON.stringify 便宜，足以发现「内容是否变化」 */
function hashStr(s) {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0;
  return (h >>> 0).toString(36);
}
let _standingsSig = '';

function groupPanel(g, mode) {
  const rows = Array.isArray(g.rows) ? g.rows : [];
  /* accent / adv / rule 来自后端 JSON，虽然当前是硬编码值，仍是注入上下文：
     accent 只接受合法颜色，adv 只接受白名单，rule 一律转义。 */
  const accent = safeColor(g.accent) || '#f5c451';
  const grouped = mode === 'grouped';
  const showOut = rows.some((r) => r.adv === 'out');

  const legend =
    grouped && g.rule
      ? `<div class="group-rule">
           ${esc(g.rule)}
           <span class="legend">
             <i class="chip-mini direct"></i>直进淘汰赛
             <i class="chip-mini playin"></i>突围赛
             ${showOut ? '<i class="chip-mini out"></i>淘汰' : ''}
           </span>
         </div>`
      : '';

  const body = rows.length
    ? rows
        .map((r) => {
          const form = (Array.isArray(r.form) ? r.form : [])
            .map(
              (f) =>
                `<span class="${esc(f.r)}" title="${esc(`${f.r === 'W' ? '胜' : f.r === 'L' ? '负' : '平'} ${f.score} vs ${f.vs}`)}">${
                  f.r === 'W' ? '胜' : f.r === 'L' ? '负' : '平'
                }</span>`
            )
            .join('');
          const rate = Math.round((r.winRate || 0) * 100);
          const chip = r.adv ? `<span class="adv-chip ${esc(r.adv)}" title="${ADV_TEXT[r.adv] || ''}">${ADV_SHORT[r.adv] || ''}</span>` : '';
          const gl = GROUP_LABEL[r.groupKey];
          const groupDot =
            !grouped && gl
              ? `<span class="grp-dot" style="--gc:${safeColor(gl.accent) || '#f5c451'}" title="年度总决赛${esc(gl.text)}组">${esc(gl.text)}</span>`
              : '';
          return `
          <tr class="${r.rank === 1 ? 'top1' : ''} ${r.adv ? 'adv-' + esc(r.adv) : ''}">
            <td class="c-rank"><span class="rank-n ${r.rank <= 3 ? 'gold' : ''}">${r.rank}</span></td>
            <td class="c-team">
              <div class="teamcell" title="${esc(r.name)}">
                ${KPLImg.tag(r.icon, { w: 26, h: 26, fb: initialOf(r), alt: r.name })}
                <span class="nm">${esc(r.name)}</span>
                ${groupDot}${chip}
              </div>
            </td>
            <td class="num-cell">${r.wins}-${r.losses}</td>
            <td class="num-cell">${r.gameWins}-${r.gameLosses}</td>
            <td class="num-cell ${r.net >= 0 ? 'pos' : 'neg'}">${r.net > 0 ? '+' : ''}${r.net}</td>
            <td class="num-cell">
              <div class="ratecell"><div class="bar"><i style="width:${rate}%"></i></div><span>${rate}%</span></div>
            </td>
            <td class="c-form"><div class="form">${form || '<span class="D">-</span>'}</div></td>
          </tr>`;
        })
        .join('')
    : `<tr><td colspan="7" class="empty">暂无战绩数据</td></tr>`;

  return `
  <section class="panel group-panel" style="--accent:${accent}">
    <div class="section-head">
      <h2 class="accent-h">${esc(g.name)}</h2>
      <span class="hint">${esc(g.desc || '')}</span>
    </div>
    ${legend}
    <div class="table-wrap">
      <table class="standing">
        <thead>
          <tr>
            <th class="c-rank">#</th>
            <th class="c-team">战队</th>
            <th>胜-负</th>
            <th>小局</th>
            <th>净胜</th>
            <th>胜率</th>
            <th class="c-form">近况</th>
          </tr>
        </thead>
        <tbody>${body}</tbody>
      </table>
    </div>
  </section>`;
}

/* ---------- 渲染：赛程 ---------- */
function renderSchedule(matches) {
  const { start, end, label } = weekRange(state.weekOffset);
  $('#weekLabel').textContent = label;

  const inWeek = matches
    .filter((m) => {
      const d = parseDateKey(m.date);
      return d >= start && d <= end;
    })
    .sort(cmpByDateTime);

  const box = $('#scheduleList');
  if (!inWeek.length) {
    box.innerHTML = `<div class="empty">该周暂无赛程</div>`;
    return;
  }

  const todayKey = bjTodayKey();
  const groups = {};
  for (const m of inWeek) (groups[m.date] ||= []).push(m);

  box.innerHTML = Object.entries(groups)
    .map(([date, list]) => {
      const d = parseDateKey(date);
      const wd = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'][d.getUTCDay()];
      const rows = list
        .map((m) => {
          if (!m || !m.a || !m.b) return '';   // 残缺行跳过，避免整表 throw
          const finished = m.status === 'finished';
          const isLive = m.status === 'live';
          const sc = scoreOf(m);
          const aWin = finished && sc.a > sc.b;
          const bWin = finished && sc.b > sc.a;
          return `
          <div class="srow ${isLive ? 'live' : ''} ${finished ? 'done' : ''}">
            <div class="stime">${m.time}</div>
            <div class="sname left ${aWin ? 'winner' : finished ? 'loser' : ''}" title="${esc(m.a.name)}">${esc(m.a.name)}</div>
            <div class="sscore">
              <span class="${aWin ? 'w' : ''}">${finished || isLive ? sc.a : '-'}</span>
              <span class="dash">:</span>
              <span class="${bWin ? 'w' : ''}">${finished || isLive ? sc.b : '-'}</span>
            </div>
            <div class="sname right ${bWin ? 'winner' : finished ? 'loser' : ''}" title="${esc(m.b.name)}">${esc(m.b.name)}</div>
            <div class="sstage" title="${esc(m.stage || '')}">${esc(stageShort(m.stage) || (isLive ? 'LIVE' : '—'))}</div>
          </div>`;
        })
        .filter(Boolean)
        .join('');
      return `
      <div class="day-group">
        <div class="day-title">
          <span>${d.getUTCMonth() + 1}月${d.getUTCDate()}日 ${wd}</span>
          ${date === todayKey ? '<span class="tag-today">今天</span>' : ''}
          <span style="margin-left:auto">${list.length} 场</span>
        </div>
        ${rows}
      </div>`;
    })
    .join('');
}

/* ---------- 数据获取 ---------- */
async function load(manual = false) {
  const btn = $('#refreshBtn');
  /* 没有 seasonId 时不能只 return：scheduleNext() 在 finally 里，
     直接返回会让轮询彻底停摆、页面永远停在「连接中」且无任何错误提示。 */
  if (!state.eventId) {
    if (!state.loading) {
      showFatal('尚未获取到赛事列表，无法加载赛程');
      scheduleNext();
    }
    return;
  }
  if (state.loading) return;
  state.loading = true;
  if (btn) btn.classList.add('loading');
  try {
    const q = new URLSearchParams({ event: state.eventId });
    if (state.stage) q.set('stage', state.stage);
    q.set('t', Date.now()); // 防中间层缓存；KPLStore 会把它从缓存键里剔除

    // 统一走本地缓存层：命中即渲染，联网后自动刷新；断网时回落到上次缓存
    const url = `/api/board?${q.toString()}`;
    const json = window.KPLStore
      ? await window.KPLStore.api(url, manual ? { force: true } : null)
      : await fetch(url, { cache: 'no-store' }).then(async (res) => {
          if (!res.ok) throw new Error(`HTTP ${res.status}`);
          const j = await res.json();
          if (!j.ok) throw new Error('接口返回异常');
          return j;
        });
    if (!json || !json.ok) throw new Error('接口返回异常');

    state.data = json;
    state.lastError = null;
    state.fails = 0; // 成功一次即清零退避计数

    $('#eventName').textContent = json.event.name;
    const msAll = json.matches || [];
    const range =
      json.event.start && json.event.end
        ? `${json.event.start} ~ ${json.event.end}`
        : msAll.length
          ? `${fmtFullDate(msAll[0].date)} ~ ${fmtFullDate(msAll[msAll.length - 1].date)}`
          : '—';
    $('#eventRange').textContent = range;

    // 已结束赛季默认定位到末周，进行中赛季定位本周
    if (state.firstLoadDone !== json.event.id) {
      const last = json.matches.length ? json.matches[json.matches.length - 1].date : null;
      state.weekOffset = json.event.active ? 0 : last ? weekDiff(last) : 0;
      state.firstLoadDone = json.event.id;
    }

    renderStats(json.summary);
    renderLive(json.matches);
    renderStandings(json.standings);
    renderSchedule(json.matches);
    renderStageSelect();

    const e = state.events.find((x) => String(x.id) === String(json.event.id));
    if (e) {
      e.matchCount = json.matches.length;
      e.loaded = true;
    }
    renderTabs();

    const t = new Date(json.updatedAt || Date.now());
    const rt = json.realtime;
    const rtTxt =
      rt && rt.enabled && rt.updatedAt
        ? rt.ok
          ? ` · 实时源 ${new Date(rt.updatedAt).toLocaleTimeString('zh-CN', { hour12: false })} 同步`
          : ` · 实时源异常，用上游数据`
        : '';
    $('#updatedAt').textContent = `数据更新：${t.toLocaleTimeString('zh-CN', { hour12: false })} · ${json.matches.length} 场${
      json.stage ? ` · ${json.stage}` : ''
    }${rtTxt}`;

    const dot = $('#connDot');
    const st = window.KPLStore && window.KPLStore.status;
    if (st && !st.online) {
      dot.className = 'dot warn';
      $('#connText').textContent = '离线模式 · 显示本地缓存';
    } else if (json.error) {
      dot.className = 'dot warn';
      $('#connText').textContent = '部分数据获取失败，展示上次结果';
    } else {
      dot.className = 'dot';
      const cached = st && st.servedFromCache;
      $('#connText').textContent = cached ? '本地缓存 · 已联网校验' : manual ? '已刷新' : '实时连接正常';
    }
  } catch (e) {
    state.lastError = errText(e);
    state.fails += 1;
    $('#connDot').className = 'dot err';
    $('#connText').textContent = '获取失败：' + state.lastError;
  } finally {
    if (btn) btn.classList.remove('loading');
    state.loading = false;
    scheduleNext();
    /* 加载期间用户点过刷新（⌘R / 按钮）→ 立刻补一次强制刷新，不静默丢弃 */
    if (state.refreshQueued) {
      state.refreshQueued = false;
      load(true);
    }
  }
}

/* 统一取错误信息：上游可能抛字符串 / undefined，直接读 e.message 会显示 undefined */
function errText(e) {
  if (!e) return '未知错误';
  if (e.message) return e.message;
  return String(e);
}

/* 顶部不可恢复的提示（赛事列表都没拿到时用） */
function showFatal(msg) {
  const dot = $('#connDot');
  const txt = $('#connText');
  if (dot) dot.className = 'dot err';
  if (txt) txt.textContent = msg;
}

function scheduleNext() {
  const d = state.data;
  let interval = REFRESH_IDLE;
  if (d) {
    const liveCount = (d.summary && d.summary.live) || 0;
    if (liveCount > 0) interval = REFRESH_LIVE;
    else if (d.event.mode === 'archive') interval = REFRESH_ARCHIVE;
    else if (!d.event.active) interval = REFRESH_DONE;
    else if (d.summary && d.summary.todayTotal > 0 && d.summary.todayDone === d.summary.todayTotal)
      interval = REFRESH_TODAY_DONE;
  }
  /* 失败退避：网络不可用时按 1x → 2x → 4x（封顶 8x）拉长间隔，
     否则离线状态下会以 8~15s 的节奏无限重试。 */
  if (state.fails > 0) {
    interval = Math.min(interval * Math.pow(2, Math.min(state.fails, 3)), interval * 8);
  }
  state.nextAt = Date.now() + interval;
  clearTimeout(state.timer);
  state.timer = setTimeout(() => load(), interval);
}

function tick() {
  $('#clock').textContent = fmtTime(Date.now());
  const left = Math.max(0, Math.ceil((state.nextAt - Date.now()) / 1000));
  $('#countdown').textContent = `下次刷新 ${left}s`;
}

/* ---------- 事件绑定 ---------- */
$('#refreshBtn').addEventListener('click', () => load(true));
$('#prevWeek').addEventListener('click', () => {
  state.weekOffset -= 1;
  if (state.data) renderSchedule(state.data.matches);
});
$('#nextWeek').addEventListener('click', () => {
  state.weekOffset += 1;
  if (state.data) renderSchedule(state.data.matches);
});
$('#homeWeek').addEventListener('click', () => {
  const ev = state.data && state.data.event;
  if (!ev) return;
  const last = state.data.matches.length ? state.data.matches[state.data.matches.length - 1].date : null;
  state.weekOffset = ev.active ? 0 : last ? weekDiff(last) : 0;
  renderSchedule(state.data.matches);
});
$('#stageSelect').addEventListener('change', (e) => {
  state.stage = e.target.value;
  load(true);
});
$('#seasonSelect').addEventListener('change', (e) => switchEvent(e.target.value));
$('#seasonNewer').addEventListener('click', () => stepSeason(-1));
$('#seasonOlder').addEventListener('click', () => stepSeason(1));

/* ---------- 启动 ---------- */
(async function init() {
  tick();
  state.tickTimer = setInterval(tick, 1000);
  try {
    // 赛季列表同样走本地缓存：断网时也能列出全部赛事
    const json = window.KPLStore
      ? await window.KPLStore.api('/api/events')
      : await fetch('/api/events', { cache: 'no-store' }).then(async (res) => {
          if (!res.ok) throw new Error(`HTTP ${res.status}`);
          return res.json();
        });
    /* 必须检查 ok：{ok:false,error:…} 不会抛异常，静默把 undefined 塞进
       eventId 会让 load() 走到「无赛事」分支（配合 scheduleNext 守卫才有提示）。 */
    if (!json || json.ok === false) throw new Error((json && json.error) || '接口返回异常');
    state.events = json.events || [];
    state.eventId = json.defaultId || (state.events[0] && state.events[0].id) || null;
    renderTabs();
  } catch (e) {
    $('#connDot').className = 'dot err';
    $('#connText').textContent = '赛季列表获取失败：' + errText(e);
  }
  await load(true);
})().catch((e) => {
  /* 启动链路里任何未预期异常都不能变成 unhandled rejection（WKWebView 里不可见） */
  console.error('[KPL] init failed:', e);
  showFatal('初始化失败：' + errText(e));
});

/* 原生菜单栏 ⌘R / 工具栏刷新按钮调用。
   必须传 manual=true：否则 KPLStore.api 走缓存分支直接返回旧数据，
   ⌘R 就只是拿缓存重渲染一遍（表现为「点了刷新但数据没动」）。
   加载中则登记一次，load() 的 finally 会补发，避免点击被静默丢弃。 */
window.KPLBoardRefresh = () => {
  if (state.loading) {
    state.refreshQueued = true;
    return;
  }
  load(true);
};

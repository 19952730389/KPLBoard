/* KPL 赛季比分看板 - 前端逻辑 */

const REFRESH_IDLE = 15000;    // 无进行中比赛时的轮询间隔
const REFRESH_LIVE = 8000;     // 有进行中比赛时的轮询间隔
const REFRESH_DONE = 120000;   // 已结束赛季的轮询间隔（结果不会变）
const REFRESH_ARCHIVE = 600000; // 历史赛事：后端已落盘缓存，几乎无需再取

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
};

const $ = (s) => document.querySelector(s);

/* HTML 转义：所有插入 innerHTML 的**上游值**都必须过这一层。
 * 上游队名/阶段名来自 events.json 与玩加/PandaScore 抓取，含 < > " &
 * 时会破坏属性闭合（title 提前结束、下拉选项截断），甚至注入脚本——
 * WKWebView 里页面与 /api 同源，注入即可读写全部 localStorage。
 * 与 tools.js 的 esc() 完全一致。前端常量（i.k/i.v）与数字（r.rank）可豁免。 */
const esc = (s) =>
  String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

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
  // 必须校验格式：非 YYYYMMDD（如 '2024-1-5'）会解析出 NaN → Invalid Date，
  // 进而把 state.weekOffset 污染成 NaN，导致赛程日历永久空白且无法恢复。
  // fmtDateLabel 里已有同类保护（k.length !== 8），这里是遗漏。
  if (typeof k !== 'string' || !/^\d{8}$/.test(k)) return null;
  const y = +k.slice(0, 4), m = +k.slice(4, 6), d = +k.slice(6, 8);
  if (!Number.isFinite(y) || !Number.isFinite(m) || !Number.isFinite(d)) return null;
  return new Date(Date.UTC(y, m - 1, d));
}
function mondayOf(date) {
  const d = new Date(date.getTime());
  const wd = d.getUTCDay();
  d.setUTCDate(d.getUTCDate() - (wd === 0 ? 6 : wd - 1));
  return d;
}
function weekDiff(dateKey) {
  const pd = parseDateKey(dateKey);
  if (!pd) return 0;                       // 非法日期：回退本周，不污染 weekOffset
  const a = mondayOf(pd);
  const b = mondayOf(parseDateKey(bjTodayKey()));
  const n = Math.round((a - b) / (7 * 86400000));
  return Number.isFinite(n) ? n : 0;
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
function fmtFullDate(k) {
  if (!k || k.length !== 8) return '—';
  return `${k.slice(0, 4)}.${k.slice(4, 6)}.${k.slice(6, 8)}`;
}
/** 队名首字：图片兜底占位用 */
function initialOf(team) {
  return teamShort(team.name, 8).replace(/[^一-龥A-Za-z0-9]/g, '').slice(0, 1) || '?';
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

function renderTabs() {
  const sel = $('#seasonSelect');
  const byYear = new Map();
  for (const e of state.events) {
    if (!byYear.has(e.year)) byYear.set(e.year, []);
    byYear.get(e.year).push(e);
  }
  const years = [...byYear.keys()].sort((a, b) => b - a);
  sel.innerHTML = years
    .map((y) => {
      const opts = byYear
        .get(y)
        .slice()
        .sort(byStartAsc)
        .map((e) => {
          const mark = e.active ? ' ●' : '';
          const cnt = e.matchCount ? ` · ${e.matchCount}场` : '';
          const label = `${esc(e.short || e.name)}${mark}${cnt}`;
          return `<option value="${e.id}" ${String(e.id) === String(state.eventId) ? 'selected' : ''}>${label}</option>`;
        })
        .join('');
      return `<optgroup label="${y} 年">${opts}</optgroup>`;
    })
    .join('');

  const ev = state.events.find((e) => String(e.id) === String(state.eventId));
  $('#seasonMeta').textContent = ev
    ? `${ev.year} · ${ev.category || '赛事'} · ${ev.mode === 'live' ? '实时数据' : '历史数据'}`
    : '';
  $('#homeWeek').textContent = ev && !ev.active ? '末周' : '本周';
}

/** 沿时间轴切换赛季：dir=-1 更新，dir=1 更早 */
function stepSeason(dir) {
  const asc = timeline();
  const idx = asc.findIndex((e) => String(e.id) === String(state.eventId));
  if (idx < 0) return;
  const next = asc[idx - dir];
  if (!next) return;
  $('#seasonSelect').value = next.id;
  switchEvent(next.id);
}

function renderStageSelect() {
  const sel = $('#stageSelect');
  const stages = state.data ? state.data.stages || [] : [];
  const cur = state.stage;
  sel.innerHTML =
    `<option value="">全部阶段</option>` +
    stages.map((s) => `<option value="${s.name}" ${s.name === cur ? 'selected' : ''}>${s.name}（${s.count}场）</option>`).join('');
  sel.disabled = stages.length === 0;
  if (cur && !stages.some((s) => s.name === cur)) {
    state.stage = '';
    sel.value = '';
  }
}

async function switchEvent(id) {
  if (String(id) === String(state.eventId)) return;
  const nowId = state.events.findIndex((e) => String(e.id) === String(id)) >= 0;
  if (!nowId) return;
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
  const box = $('#liveCards');
  const live = matches.filter((m) => m.status === 'live');
  const todayKey = bjTodayKey();

  if (live.length) {
    const rt = (state.data && state.data.realtime) || null;
    const sync = rt && rt.enabled ? (rt.ok ? ' · 比分实时同步中' : ' · 实时源异常，显示上游数据') : '';
    $('#liveHint').textContent = `${live.length} 场比赛进行中，页面每 ${REFRESH_LIVE / 1000}s 自动刷新${sync}`;
    box.innerHTML = live.map(matchCard).join('');
    return;
  }

  const rest = matches
    .filter((m) => m.status === 'upcoming')
    .sort((a, b) => (a.date === b.date ? (a.time < b.time ? -1 : 1) : a.date < b.date ? -1 : 1));
  const next = rest[0];

  $('#liveHint').textContent = next
    ? `暂无进行中比赛 · 下一场：${next.date.slice(4, 6)}/${next.date.slice(6)} ${next.time} ${next.a.name} vs ${next.b.name}`
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
  box.innerHTML = cards.join('') || `<div class="empty">暂无比赛数据</div>`;
}

/** 大比分取值：上游大比分常常滞后于逐小局，逐小局推导更靠前时以逐小局为准，保证卡片上下一致 */
function scoreOf(m) {
  const a = (m.a && m.a.score) || 0;
  const b = (m.b && m.b.score) || 0;
  const la = (m.legs || []).filter((x) => x === 'A').length;
  const lb = (m.legs || []).filter((x) => x === 'B').length;
  return la + lb > a + b ? { a: la, b: lb, derived: true } : { a, b, derived: false };
}

function matchCard(m) {
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
          return `<div class="leg pending" title="${tip}"><b>G${i + 1}</b><span class="t">—</span></div>`;
        }
        const team = l === 'A' ? m.a : m.b;
        return `<div class="leg ${l}" title="第${i + 1}局 ${team.name} 胜"><b>G${i + 1}</b><span class="t">${teamShort(
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
    return;
  }
  zone.innerHTML = panels.join('');
}

function groupPanel(g, mode) {
  const rows = Array.isArray(g.rows) ? g.rows : [];
  const accent = g.accent || '#f5c451';
  const grouped = mode === 'grouped';
  const showOut = rows.some((r) => r.adv === 'out');

  const legend =
    grouped && g.rule
      ? `<div class="group-rule">
           ${g.rule}
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
          const form = (r.form || [])
            .map(
              (f) =>
                `<span class="${f.r}" title="${f.r === 'W' ? '胜' : f.r === 'L' ? '负' : '平'} ${esc(f.score)} vs ${esc(f.vs)}">${
                  f.r === 'W' ? '胜' : f.r === 'L' ? '负' : '平'
                }</span>`
            )
            .join('');
          const rate = Math.round((r.winRate || 0) * 100);
          const chip = r.adv ? `<span class="adv-chip ${r.adv}" title="${ADV_TEXT[r.adv]}">${ADV_SHORT[r.adv]}</span>` : '';
          const gl = GROUP_LABEL[r.groupKey];
          const groupDot =
            !grouped && gl
              ? `<span class="grp-dot" style="--gc:${gl.accent}" title="年度总决赛${gl.text}组">${gl.text}</span>`
              : '';
          return `
          <tr class="${r.rank === 1 ? 'top1' : ''} ${r.adv ? 'adv-' + r.adv : ''}">
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
      <span class="hint">${g.desc || ''}</span>
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
    .sort((a, b) => (a.date === b.date ? (a.time < b.time ? -1 : 1) : a.date < b.date ? -1 : 1));

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
            <div class="sstage" title="${esc(m.stage || '')}">${esc(stageShort(m.stage)) || (isLive ? 'LIVE' : '—')}</div>
          </div>`;
        })
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
  if (state.loading || !state.eventId) return;
  state.loading = true;
  const btn = $('#refreshBtn');
  btn.classList.add('loading');
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
      // 552 行已用 `json.matches || []` 承认 matches 可能缺失，这里必须用 msAll 而非裸访问
      const last = msAll.length ? msAll[msAll.length - 1].date : null;
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
    state.lastError = e.message;
    $('#connDot').className = 'dot err';
    $('#connText').textContent = '获取失败：' + e.message;
  } finally {
    btn.classList.remove('loading');
    state.loading = false;
    scheduleNext();
  }
}

function scheduleNext() {
  const d = state.data;
  let interval = REFRESH_IDLE;
  if (d) {
    const liveCount = (d.summary && d.summary.live) || 0;
    if (liveCount > 0) interval = REFRESH_LIVE;
    else if (d.event.mode === 'archive') interval = REFRESH_ARCHIVE;
    else if (!d.event.active) interval = REFRESH_DONE;
    else if (d.summary && d.summary.todayTotal > 0 && d.summary.todayDone === d.summary.todayTotal) interval = 60000;
  }
  state.nextAt = Date.now() + interval;
  clearTimeout(state.timer);
  state.timer = setTimeout(() => load(), interval);
}

function tick() {
  $('#clock').textContent = fmtTime(Date.now());
}

/* ---------- 前后台切换：暂停 / 恢复轮询与时钟 ----------
 * 页面隐藏（App 进后台、切到其它工具页）时清掉两个定时器：
 * tickTimer 每秒刷时钟，timer 每 8s 触发全量 innerHTML 重建，
 * 后台空跑既耗电发热又白费网络。恢复时立即 load() 拿最新数据，
 * 轮询间隔沿用 scheduleNext() 里的 REFRESH_* 常量，不在这里写死。 */
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    clearInterval(state.tickTimer);
    state.tickTimer = null;
    clearTimeout(state.timer);
    state.timer = null;
  } else {
    if (state.tickTimer === null) {
      tick(); // 先补一次时钟，避免回到前台看到旧时间闪一下
      state.tickTimer = setInterval(tick, 1000);
    }
    if (state.timer === null) {
      if (state.loading) return; // 加载中：它自己的 finally 会 scheduleNext()
      if (!state.eventId) return; // 赛季列表还没到：init() 里的 load() 会接手，
                                  // 这里不能调 scheduleNext()，否则会排上第二个 timer
      load(); // 立即刷新一次，随后由 scheduleNext() 恢复轮询
    }
  }
});

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
  const ms = state.data.matches || [];
  const last = ms.length ? ms[ms.length - 1].date : null;
  state.weekOffset = ev.active ? 0 : last ? weekDiff(last) : 0;
  renderSchedule(ms);
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
    // 赛季列表同样走本地缓存：断网时也能列出全部 78 项赛事
    const json = window.KPLStore
      ? await window.KPLStore.api('/api/events')
      : await fetch('/api/events', { cache: 'no-store' }).then((r) => r.json());
    state.events = json.events || [];
    state.eventId = json.defaultId;
    renderTabs();
  } catch (e) {
    $('#connDot').className = 'dot err';
    $('#connText').textContent = '赛季列表获取失败：' + e.message;
  }
  // 注意：不能传 'first'——字符串是 truthy，会让首次加载强制走网络，
  // 与「优先本地缓存渲染、断网也能看」的设计矛盾（离线冷启动会直接报错）。
  await load();
})();

/* 后台缓存更新完成后由外壳调用：静默重渲染（不显示按钮 loading）。
 * 传 true 时强制走网络（原生刷新按钮 / 回到前台触发） */
window.KPLBoardRefresh = (force) => {
  if (state.loading) return;
  load(!!force);
};

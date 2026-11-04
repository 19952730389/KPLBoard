/* KPL 工具箱 · 前端逻辑
 * 七个视图：比分看板（另有）/ 装备 / 铭文 / 梯度榜 / 英雄详情 / 选手详情 / 原画画廊
 * 数据：官方英雄库·装备库·铭文库·技能页（腾讯）+ 玩加赛事职业统计
 * 由统一外壳（shell.js）挂载：通过 window.KPLTools.go(view) 切换子视图
 */
(function () {
'use strict';

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

const S = {
  view: 'items',
  heroes: null,
  items: null,
  runes: null,
  skins: null,
  coverage: null,
  gradientCache: {},
  playerCache: {},
  teamCache: {},
  heroCache: {},
  gradientEvent: null,
  gradientTier: '全部',
  gradientLane: '全部',
  gradientQ: '',
  playerEvent: null,
  playerEventMeta: null,
  heroId: null,
  itemType: '全部',
  itemQ: '',
  itemSort: 'priceDesc',
  /* 铭文 */
  runeColor: '全部',
  runeGrade: '5',
  runeQ: '',
  heroQ: '',
  heroType: '全部',
  playerTeam: '全部',
  playerQ: '',
  playerSort: 'kda',
  /* 原画画廊 */
  galleryQ: '',
  /* 「选中候选后才检索」：pick = null | {kind:'hero'|'skin', hero, skin} */
  galleryPick: null,
  galleryTypes: [],
  galleryLanes: [],
  galleryQuality: '全部',
  galleryLabel: '全部',
  gallerySort: 'dateAsc',
  galleryHeroLimit: 24,
  galleryExpanded: {},
  currentPlayer: null,
  /* 版本动态 */
  patch: null,
  patchKind: '全部',
  patchDir: '全部',
  patchQ: '',
  patchNews: null,
};

/* ---------------- 工具 ---------------- */
const UNTYPED = '未分类'; // 上游英雄库缺职业字段时的兜底分类
/* 候选下拉：选中后短暂抑制「聚焦即展开」，否则重渲染还原焦点会把候选又弹出来（跨渲染保留，故放模块级） */
let comboSuppressUntil = 0;
/* 图片统一交给 img.js（KPLImg）：走代理 + 按显示尺寸取 CDN 缩略图 + 统一加载态 + 占位兜底 */
const imgUrl = (u, w) => (u ? KPLImg.url(u, w ? { w } : null) : '');

/** 大图弹层换图：先清掉上一次的加载/失败标记，避免上一张的状态污染下一张 */
function setBig(url, fb, cls) {
  const el = $('#lbImg');
  el.className = `im${cls ? ' ' + cls : ''}`;
  el.dataset.done = '';
  el.dataset.retry = '';
  el.dataset.fb = fb || '';
  el.dataset.src = url || '';
  el.dataset.w = '480';
  el.dataset.h = '270';
  el.classList.remove('im-bad', 'on');
  el.src = url ? KPLImg.url(url) : KPLImg.ph(fb || '', 480, 270);
  el.alt = fb || '';
}
const pct = (v) => `${Math.round((Number(v) || 0) * 100)}%`;
const esc = (s) =>
  String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const num = (v) => (v == null ? '—' : Number(v).toLocaleString('zh-CN'));
/* 原样输出但 null → 「—」：官方（KPL 统计接口）通道不提供分均经济 / 伤害 / 承伤、
   场均死亡 / 助攻等字段（为 null），直接输出会显示 undefined 或误导性的 0。 */
const nz = (v) => (v == null ? '—' : v);

/* 数据请求：统一走 KPLStore（本地缓存优先 + 后台更新 + 断网回落）。
 * opt.force 用于「立即同步」等需要强制走网络的场景。 */
async function api(path, opt) {
  if (window.KPLStore) return window.KPLStore.api(path, opt);
  const r = await fetch(path, { cache: 'no-store' });
  let j;
  try {
    j = await r.json();
  } catch (_) {
    throw new Error(`HTTP ${r.status}`);
  }
  if (!j || !j.ok) throw new Error((j && j.error) || `HTTP ${r.status}`);
  return j;
}

/** 数据来源提示：缓存命中时给出「本地缓存 · 更新于 …」，避免误以为是刚拉的实时数据 */
function srcHint(updatedAt) {
  const st = window.KPLStore && window.KPLStore.status;
  const fromCache = !!(st && st.servedFromCache);
  const t = updatedAt || (st && st.fetchedAt) || 0;
  const when = t ? new Date(t).toLocaleString('zh-CN', { hour12: false }) : '—';
  return fromCache ? `本地缓存 · 更新于 ${when}` : `实时数据 · 更新于 ${when}`;
}

function pageHead(title, desc, extra = '') {
  return `<div class="page-head">
    <div><h1>${title}</h1><p>${desc}</p></div>
    <div class="hint">${extra}</div>
  </div>`;
}

function loading(text) {
  return `<div class="panel"><div class="loading">${text}</div></div>`;
}

/* 重渲染后保持搜索框焦点与光标位置 */
function captureFocus() {
  const el = document.activeElement;
  if (!el || !el.id || !/^(iQ|hQ|pQ|gQ)$/.test(el.id)) return null;
  const f = { id: el.id, pos: null, end: null };
  try {
    f.pos = el.selectionStart;
    f.end = el.selectionEnd;
  } catch (_) {}
  return f;
}
function restoreFocus(f) {
  if (!f) return;
  const el = document.getElementById(f.id);
  if (!el) return;
  el.focus();
  try {
    if (f.pos != null) el.setSelectionRange(f.pos, f.end);
  } catch (_) {}
}
function errorPanel(msg) {
  return `<div class="error-box">数据获取失败：${esc(msg)}<br><span style="font-size:12px;opacity:.8">可稍后重试；若持续失败，多为上游接口临时不可用。</span></div>`;
}

/* ---------------- 公共数据 ---------------- */
async function loadHeroes() {
  if (S.heroes) return S.heroes;
  const j = await api('/api/tools/heroes');
  S.heroes = j.heroes || [];
  return S.heroes;
}
async function loadCoverage() {
  if (S.coverage) return S.coverage;
  S.coverage = await api('/api/tools/coverage');
  return S.coverage;
}
/** 严格按时间先后排序：年份倒序 → 开赛日期倒序（同年里最新的在前）→ id 倒序兜底。
 *  早期版本只按「年份 + id 倒序」，id 与开赛先后并不一致（如 1171 挑战者杯 4 月开赛、
 *  1172 夏季赛 6 月开赛），会出现同年内赛程乱序；开赛日期来自 events.json 的 start 字段。 */
function sortByTime(list) {
  return (list || []).slice().sort((a, b) => {
    const ay = Number(a.year) || 0;
    const by = Number(b.year) || 0;
    if (ay !== by) return by - ay;
    const as = a.start || '';
    const bs = b.start || '';
    if (as && bs && as !== bs) return bs.localeCompare(as);
    if (as !== bs) return as ? -1 : 1; // 缺日期的排到该年最后
    return String(b.id).localeCompare(String(a.id));
  });
}

/** 有逐选手统计的赛季（严格按时间倒序）
 *  玩加口径（2016~2022）+ Score 选手通道（2022 世冠、2023~2026，hasPlayers 标记） */
async function eventsWithStats() {
  const cov = await loadCoverage();
  const wan = (cov.events || []).filter((e) => e.players > 0);
  const score = (cov.scoreEvents || []).filter((e) => e.hasPlayers);
  return sortByTime(wan.concat(score));
}
/** 梯度榜的赛季清单（玩加统计赛季 + Score 电竞补充赛季，含待收录的 pending 赛季）
 *  Score 通道没有逐选手英雄池，但提供逐英雄 BP（2023 年及以后的梯度数据源）；
 *  pending 赛季（如 2026 年度总决赛）也展示，选中时给出「收录中」空态。 */
async function eventsWithGradient() {
  const cov = await loadCoverage();
  const wan = (cov.events || [])
    .filter((e) => e.players > 0)
    .map((e) => Object.assign({}, e, { source: 'wanplus' }));
  const score = (cov.scoreEvents || []).map((e) => Object.assign({}, e));
  return sortByTime(wan.concat(score));
}
function eventLabel(e) {
  return `${e.year || ''} ${e.short || e.name}`.trim();
}
/** 赛季下拉：按年份分组，年份标题下方列出该年的赛季（与比分看板页的下拉一致）
 *  unit —— 人数单位（梯度榜「名选手」 / 选手详情「人」） */
function seasonOptionsHTML(evs, selectedId, unit) {
  const u = unit || '名选手';
  const byYear = new Map();
  for (const e of evs) {
    const y = e.year || 0;
    if (!byYear.has(y)) byYear.set(y, []);
    byYear.get(y).push(e);
  }
  const years = [...byYear.keys()].sort((a, b) => b - a);
  return years
    .map((y) => {
      const opts = sortByTime(byYear.get(y))
        .map((e) => {
          const tail = e.source === 'score' ? ' · Score' : e.source === 'kpl' ? ' · 官方' : '';
          const cnt = e.players > 0 ? `（${e.players} ${u}）` : '';
          // 官方通道有 hasPlayers=true 但 players=0 表示尚未抓取数据，仍显示「收录中」
          const pend = e.pending || (e.source === 'kpl' && e.players === 0) ? ' · 收录中' : '';
          return `<option value="${e.id}" ${String(e.id) === String(selectedId) ? 'selected' : ''}>${esc(
            `${e.short || e.name}${cnt}${tail}${pend}`
          )}</option>`;
        })
        .join('');
      return `<optgroup label="${y} 年">${opts}</optgroup>`;
    })
    .join('');
}

/* ================= 梯度榜 ================= */
const TIER_META = {
  T0: { label: 'T0', desc: '版本答案 · 高强度高热度' },
  T1: { label: 'T1', desc: '主流选择 · 稳定强势' },
  T2: { label: 'T2', desc: '体系英雄 · 有出场空间' },
  T3: { label: 'T3', desc: '冷门 / 样本较少' },
};

async function viewGradient() {
  const main = $('#main');
  const focus = captureFocus();
  main.innerHTML = pageHead('英雄梯度榜', '按 KPL 职业赛场出场与胜率聚合的英雄强度分档', '数据口径：玩加逐选手英雄池 / Score 逐英雄 BP（2023 年及以后）') + loading('正在拉取职业赛场统计…');
  let evs;
  try {
    evs = await eventsWithGradient();
  } catch (e) {
    main.innerHTML = pageHead('英雄梯度榜', '按 KPL 职业赛场出场与胜率聚合的英雄强度分档') + errorPanel(e.message);
    return;
  }
  if (!evs.length) {
    main.innerHTML = pageHead('英雄梯度榜', '') + `<div class="panel"><div class="empty">暂无职业统计赛季数据</div></div>`;
    return;
  }
  // 默认选中「最新一个有数据的赛季」；pending 赛季（无出场统计）只作展示，不作默认
  if (!S.gradientEvent || !evs.some((e) => String(e.id) === String(S.gradientEvent))) {
    const withData = evs.find((e) => (e.players || 0) > 0 && !e.pending);
    S.gradientEvent = String((withData || evs[0]).id);
  }
  S.gradientEventMeta = evs.find((e) => String(e.id) === String(S.gradientEvent)) || null;

  const toolbarHTML = `<div class="toolbar">
    <label for="gEvent">赛季</label>
    <select id="gEvent" class="kpl-select">${seasonOptionsHTML(evs, S.gradientEvent)}</select>
    <label for="gTier">梯度</label>
    <select id="gTier">
      <option value="全部" ${S.gradientTier === '全部' ? 'selected' : ''}>全部梯度</option>
      ${['T0', 'T1', 'T2', 'T3'].map((t) => `<option value="${t}" ${S.gradientTier === t ? 'selected' : ''}>${t} · ${TIER_META[t].desc.split(' · ')[0]}</option>`).join('')}
    </select>
    <label for="gLane">分路</label>
    <select id="gLane">
      <option value="全部" ${S.gradientLane === '全部' ? 'selected' : ''}>全部分路</option>
      ${['对抗路', '打野', '中路', '发育路', '游走'].map((l) => `<option value="${l}" ${S.gradientLane === l ? 'selected' : ''}>${l}</option>`).join('')}
    </select>
    <input type="search" id="gQ" placeholder="搜索英雄 / 定位" value="${esc(S.gradientQ)}">
    <span class="hint" id="gNote"></span>
  </div>`;

  // 已有该赛季缓存 → 直接渲染，不再显示加载态（切换回来 / 后台更新重渲染）
  const have = S.gradientCache[S.gradientEvent];
  main.innerHTML =
    pageHead(
      '英雄梯度榜',
      '按 KPL 职业赛场出场与胜率聚合的英雄强度分档',
      '数据口径：玩加逐选手英雄池（2016~2022）/ Score 电竞逐英雄 BP（2022 世冠、2023~2026）· 综合分 = 平滑胜率 × 0.65 + 赛场热度 × 0.35'
    ) +
    toolbarHTML +
    `<div id="gBody">${have ? '' : loading('正在聚合英雄数据…')}</div>`;

  $('#gEvent').addEventListener('change', (e) => {
    S.gradientEvent = e.target.value;
    if (!S.gradientCache[S.gradientEvent]) $('#gBody').innerHTML = loading('正在聚合英雄数据…');
    paintGradient();
  });
  $('#gTier').addEventListener('change', (e) => {
    S.gradientTier = e.target.value;
    paintGradient();
  });
  $('#gLane').addEventListener('change', (e) => {
    S.gradientLane = e.target.value;
    paintGradient();
  });
  $('#gQ').addEventListener('input', (e) => {
    S.gradientQ = e.target.value;
    clearTimeout(S._gqTimer);
    S._gqTimer = setTimeout(paintGradient, 200);
  });
  await paintGradient();
  restoreFocus(focus);
}

async function paintGradient() {
  const body = $('#gBody');
  if (!body) return;
  const eid = S.gradientEvent;
  let g = S.gradientCache[eid];
  if (!g) {
    try {
      g = await api(`/api/tools/gradient?event=${encodeURIComponent(eid)}`);
      S.gradientCache[eid] = g;
    } catch (e) {
      body.innerHTML = errorPanel(e.message);
      return;
    }
  }
  const all = g.list || [];
  if (!all.length) {
    const ev = (S.gradientEventMeta && String(S.gradientEventMeta.id) === String(eid) ? S.gradientEventMeta : null) || {};
    // 官方通道首次拉取时 players=0 → 显示「收录中」，后续自动刷新为真实数据
    const isPending = ev.pending || (ev.source === 'kpl' && (g.event?.players ?? g.totalPlayers ?? 0) === 0);
    const pendMsg = isPending
      ? '该赛季的英雄出场/禁用统计正在同步（通常 1~2 秒内完成），选中即可，完成后自动展示。'
      : '该赛季暂无英雄统计数据';
    body.innerHTML = `<div class="panel"><div class="empty">${esc(pendMsg)}</div></div>`;
    const note0 = $('#gNote');
    if (note0) {
      const src = ev.source === 'kpl' ? ' · 数据来源：KPL 官方' : ev.id ? ' · 数据来源：Score 电竞' : '';
      note0.textContent = `${[ev.year, ev.short || ev.name].filter(Boolean).join(' ') || eid}${src} · ${srcHint()}`;
    }
    return;
  }

  const list = all
    .filter((h) => (S.gradientTier === '全部' ? true : h.tier === S.gradientTier))
    .filter((h) => (S.gradientLane === '全部' ? true : (h.lanes || []).includes(S.gradientLane)))
    .filter((h) =>
      S.gradientQ
        ? (h.name + (h.types || []).join('') + (h.lanes || []).join('')).toLowerCase().includes(S.gradientQ.toLowerCase())
        : true
    );

  const note = $('#gNote');
  if (note) {
    const ev = g.event || {};
    const src =
      g.source === 'kpl'
        ? ` · 数据来源：${g.sourceName || 'KPL 官方'}（出场与胜率）`
        : g.source === 'score'
          ? ` · 数据来源：${g.sourceName || 'Score 电竞'}（含禁用数据）`
          : '';
    note.textContent = `${[ev.year, ev.short || ev.name].filter(Boolean).join(' ') || eid}${src} · ${srcHint(g.updatedAt)}`;
  }

  // Score 通道额外提供禁用数据；玩加通道没有 → 按数据自适应列与卡片文案
  const hasBan = list.some((h) => h.bans != null);
  // 官方（KPL 统计）通道没有逐小局 KDA / 使用人数（为 null/0）→ 相应片段整段省略
  const tileMeta = (h) =>
    `出场 ${h.games}` +
    (h.bans != null ? ` · 禁用 ${h.bans} · 禁用率 ${pct(h.banRate)}` : '') +
    (h.users ? ` · ${h.users} 人使用` : '') +
    (h.kda != null ? ` · KDA ${h.kda}` : '');

  const tiers = ['T0', 'T1', 'T2', 'T3'];
  const blocks = tiers
    .map((t) => {
      const rows = list.filter((h) => h.tier === t);
      if (!rows.length) return '';
      const meta = TIER_META[t];
      return `<div class="tier-block">
        <div class="tier-title">
          <span class="tier-badge ${t}">${t}</span>
          <span class="desc">${esc((rows[0] && rows[0].tierLabel) || meta.desc)}</span>
          <span class="cnt">${rows.length} 位英雄</span>
        </div>
        <div class="tier-grid">
          ${rows
            .map(
              (h) => `<div class="hero-tile" data-hero="${esc(h.name)}" data-rank="${h.rank}">
                <span class="rank-badge" title="赛季强度排名">#${h.rank}</span>
                ${KPLImg.tag(h.icon, { w: 40, h: 40, fb: h.name, alt: h.name })}
                <div class="info">
                  <div class="nm">${esc(h.name)}${
                    h.alias ? `<span class="alias" title="上游使用的名称">${esc(h.alias)}</span>` : ''
                  }</div>
                  <div class="meta">${tileMeta(h)}</div>
                  <div class="tags">${(h.lanes || []).map((l) => `<span class="tag lane">${esc(l)}</span>`).join('')}${(h.types || [])
                    .map((x) => `<span class="tag">${esc(x)}</span>`)
                    .join('')}</div>
                </div>
                <div class="wr ${h.winRate >= 0.5 ? 'hi' : 'lo'}">${pct(h.winRate)}<small>胜率</small></div>
              </div>`
            )
            .join('')}
        </div>
      </div>`;
    })
    .join('');

  body.innerHTML = `
    <div class="stats-row">
      <div class="stat-kpi"><div class="k">赛季</div><div class="v" style="font-size:15px">${esc(
        (g.event && (g.event.name || g.event.short)) || eid
      )}</div></div>
      <div class="stat-kpi"><div class="k">参赛选手</div><div class="v">${g.totalPlayers}</div></div>
      <div class="stat-kpi"><div class="k">参赛战队</div><div class="v">${g.totalTeams}</div></div>
      <div class="stat-kpi"><div class="k">英雄出场累计</div><div class="v">${num(g.totalHeroPicks)}<small> 人次</small></div></div>
      <div class="stat-kpi"><div class="k">上榜英雄</div><div class="v">${all.length}<small> 位</small></div></div>
      <div class="stat-kpi"><div class="k">筛选结果</div><div class="v">${list.length}<small> 位</small></div></div>
    </div>
    <div class="panel">
      <div class="panel-head">
        <h2>强度分档</h2>
        <span class="hint">按排名分位切档（前 10% / 30% / 60%）· 每张卡片左上角为赛季强度排名</span>
      </div>
      ${blocks || '<div class="empty">没有符合筛选条件的英雄</div>'}
    </div>
    <div class="panel">
      <div class="panel-head">
        <h2>完整榜单</h2>
        <span class="hint">共 ${list.length} 条 · 点击「英雄」列可跳转英雄详情</span>
      </div>
      <div style="overflow-x:auto">
        <table class="player-table">
          <thead><tr>
            <th>名次</th><th>英雄</th><th>梯度</th><th>定位</th><th>分路</th><th>出场</th>
            ${hasBan ? '<th>禁用</th><th>禁用率</th>' : ''}
            <th>胜-负</th><th>胜率</th><th>KDA</th><th>使用人数</th><th>出场占比</th><th>综合分</th>
          </tr></thead>
          <tbody>
            ${list
              .map(
                (h) => `<tr data-hero="${esc(h.name)}">
                  <td><b class="rank-num">${h.rank}</b></td>
                  <td class="nm">${esc(h.name)}${h.alias ? `<span class="alias">${esc(h.alias)}</span>` : ''}</td>
                  <td><span class="tier-badge sm ${h.tier}">${h.tier}</span></td>
                  <td>${esc((h.types || []).join(' / ') || '未分类')}</td>
                  <td>${esc((h.lanes || []).join(' / ') || '未知')}</td>
                  <td>${h.games}</td>
                  ${hasBan ? `<td>${h.bans != null ? h.bans : '—'}</td><td>${h.bans != null ? pct(h.banRate) : '—'}</td>` : ''}
                  <td>${h.wins}-${h.losses}</td>
                  <td>${pct(h.winRate)}</td>
                  <td><b>${h.kda != null ? h.kda : '—'}</b></td>
                  <td>${h.users != null ? h.users : '—'}</td>
                  <td>${h.share != null ? h.share + '%' : '—'}</td>
                  <td>${h.score}</td>
                </tr>`
              )
              .join('') || `<tr><td colspan="${hasBan ? 14 : 12}" class="empty">没有符合筛选条件的英雄</td></tr>`}
          </tbody>
        </table>
      </div>
    </div>`;

  const openHero = (name) => {
    if (!name) return;
    S.heroQ = name;
    S.heroType = '全部';
    const hero = (S.heroes || []).find((x) => x.name === name);
    if (hero) S.heroId = hero.id;
    // 交给外壳切换（会同步左侧导航高亮）
    if (window.KPLShell) window.KPLShell.setView('hero');
    else go('hero');
  };
  $$('.hero-tile', body).forEach((el) => el.addEventListener('click', () => openHero(el.dataset.hero)));
  $$('tr[data-hero]', body).forEach((el) => el.addEventListener('click', () => openHero(el.dataset.hero)));
}

/* ================= 装备 ================= */
async function viewItems() {
  const main = $('#main');
  const focus = captureFocus();
  if (!S.items) {
    main.innerHTML = pageHead('装备', '王者荣耀官方装备库：类型 · 价格 · 属性', '') + loading('正在加载装备库…');
    try {
      S.items = (await api('/api/tools/items')).items || [];
    } catch (e) {
      main.innerHTML = pageHead('装备', '') + errorPanel(e.message);
      return;
    }
  }
  const items = S.items;
  const types = ['全部', ...[...new Set(items.map((i) => i.type))]];
  const filtered = items
    .filter((i) => (S.itemType === '全部' ? true : i.type === S.itemType))
    .filter((i) => (S.itemQ ? (i.name + i.desc).toLowerCase().includes(S.itemQ.toLowerCase()) : true))
    .sort((a, b) => {
      if (S.itemSort === 'priceDesc') return b.total - a.total;
      if (S.itemSort === 'priceAsc') return a.total - b.total;
      return a.name.localeCompare(b.name, 'zh-CN');
    });

  main.innerHTML =
    pageHead(
      '装备',
      '王者荣耀官方装备库，含类型、价格与属性说明 · 点击任意装备查看详情',
      `共 ${items.length} 件 · <button class="ph-link" data-goto="runes">铭文图鉴 →</button>`
    ) +
    `<div class="toolbar">
      <div class="chips" id="iTypes">${types
        .map((t) => `<button class="chip ${t === S.itemType ? 'on' : ''}" data-type="${esc(t)}">${esc(t)}</button>`)
        .join('')}</div>
      <input type="search" id="iQ" placeholder="搜索装备名 / 属性" value="${esc(S.itemQ)}">
      <select id="iSort">
        <option value="priceDesc" ${S.itemSort === 'priceDesc' ? 'selected' : ''}>价格 高→低</option>
        <option value="priceAsc" ${S.itemSort === 'priceAsc' ? 'selected' : ''}>价格 低→高</option>
        <option value="name" ${S.itemSort === 'name' ? 'selected' : ''}>按名称</option>
      </select>
      <span class="hint">${filtered.length} / ${items.length} 件</span>
    </div>
    <div class="panel">
      <div class="item-grid" id="itemGrid">
        ${filtered
          .map(
            (i) => `<div class="item-card" data-id="${esc(i.id)}" title="点击查看 ${esc(i.name)} 详细属性">
              ${KPLImg.tag(i.icon, { w: 46, h: 46, fb: i.name, alt: i.name })}
              <div class="info">
                <div class="top"><span class="nm">${esc(i.name)}</span><span class="tag">${esc(i.type)}</span><span class="price">${num(i.total)} 金</span></div>
                <div class="desc">${esc(i.desc || '—')}</div>
                ${i.hasPassive ? `<div class="passive-flag">唯一被动</div>` : ''}
              </div>
            </div>`
          )
          .join('') || '<div class="empty">没有匹配的装备</div>'}
      </div>
    </div>`;

  $$('#iTypes .chip').forEach((c) =>
    c.addEventListener('click', () => {
      S.itemType = c.dataset.type;
      viewItems();
    })
  );
  $('#iQ').addEventListener('input', (e) => {
    S.itemQ = e.target.value;
    clearTimeout(S._iqTimer);
    S._iqTimer = setTimeout(viewItems, 220);
  });
  $('#iSort').addEventListener('change', (e) => {
    S.itemSort = e.target.value;
    viewItems();
  });
  $$('#itemGrid .item-card').forEach((el) =>
    el.addEventListener('click', () => openItem((S.items || []).find((x) => x.id === el.dataset.id)))
  );
  bindGoto();
  restoreFocus(focus);
}

/** 页头里的跨视图快捷入口（铭文 ⇄ 装备） */
function bindGoto() {
  $$('#main [data-goto]').forEach((b) =>
    b.addEventListener('click', () => {
      const id = b.dataset.goto;
      if (window.KPLShell) window.KPLShell.setView(id);
      else location.hash = '#' + id;
    })
  );
}

/* ---------- 装备详情（大图 + 类型 / 价格 / 属性 / 唯一被动 / 同类装备） ---------- */
function openItem(it) {
  if (!it) return;
  const all = S.items || [];
  const same = all
    .filter((x) => x.id !== it.id && x.type === it.type)
    .sort((a, b) => b.total - a.total)
    .slice(0, 10);
  setBig(it.icon, it.name, 'lb-item');
  $('#lbInfo').innerHTML = `
    <div class="lb-title">${esc(it.name)}</div>
    <div class="lb-rows">
      <div class="lb-row"><span>类型</span><b class="type-chip">${esc(it.type)}</b></div>
      <div class="lb-row"><span>总价</span><b class="lb-price">${num(it.total)} 金</b></div>
      <div class="lb-row"><span>合成价</span><b>${num(it.price)} 金</b></div>
      <div class="lb-row"><span>装备 ID</span><b>${esc(it.id)}</b></div>
    </div>
    ${section('属性加成', (it.lines || []).map((l) => `<li>${esc(l)}</li>`).join(''))}
    ${it.hasPassive ? section('唯一被动', (it.passives || []).map((l) => `<li>${esc(l)}</li>`).join('')) : ''}
    ${
      same.length
        ? section(
            `同类型装备（${esc(it.type)}）`,
            `<div class="lb-chips">${same
              .map((s) => `<button class="lb-chip" data-id="${esc(s.id)}">${esc(s.name)}<i>${num(s.total)}</i></button>`)
              .join('')}</div>`
          )
        : ''
    }`;
  $('#lbCap').innerHTML = `${esc(it.type)} · ${esc(it.name)} <a href="${esc(it.icon)}" target="_blank" rel="noopener">查看原图</a>`;
  $('#lightbox').classList.add('on');
  $$('#lbInfo .lb-chip').forEach((b) =>
    b.addEventListener('click', () => openItem(all.find((x) => x.id === b.dataset.id)))
  );
}

/** 弹层里的小节（标题 + 列表容器） */
function section(title, inner) {
  return `<div class="lb-sec"><h4>${title}</h4><ul class="lb-list">${inner}</ul></div>`;
}

/* ================= 铭文 ================= */
async function loadRunes() {
  if (S.runes) return S.runes;
  S.runes = await api('/api/tools/runes');
  return S.runes;
}

/** 单枚属性 → 整套 10 枚（满配）的换算文本 */
function runeFull(text) {
  return String(text).replace(/(\d+(?:\.\d+)?)/g, (m) => String(Math.round(Number(m) * 100) / 10));
}

async function viewRunes(keepScroll) {
  const main = $('#main');
  const focus = captureFocus();
  const scrollY = keepScroll ? window.scrollY : 0;
  let d;
  try {
    if (!S.runes) main.innerHTML = pageHead('铭文', '', '') + loading('正在加载官方铭文库…');
    d = await loadRunes();
  } catch (e) {
    main.innerHTML = pageHead('铭文', '') + errorPanel(e.message);
    return;
  }

  const colors = d.colors || [];
  const grades = d.grades || [];
  const q = S.runeQ.trim().toLowerCase();
  const hit = (r) =>
    (S.runeColor === '全部' || r.color === S.runeColor) &&
    (S.runeGrade === '全部' || String(r.grade) === S.runeGrade) &&
    (!q || (r.name + ' ' + r.desc).toLowerCase().includes(q));

  const shown = colors.filter((c) => S.runeColor === '全部' || c.key === S.runeColor);
  const matched = (d.list || []).filter(hit);
  const topCount = (grades.find((g) => g.grade === 5) || {}).count || 0;

  const cardOf = (r) => `<figure class="rune-card" data-id="${esc(r.id)}" data-color="${esc(r.color)}"
      title="${esc(r.colorName)}铭文 · ${esc(r.name)}（${r.grade} 级）｜点击查看详情">
      <div class="rc-pic">${KPLImg.tag(r.icon, { w: 44, h: 52, fb: r.name, alt: r.name })}</div>
      <figcaption>
        <div class="rc-nm">${esc(r.name)}<span class="rc-g">${r.grade} 级</span></div>
        <div class="rc-lines">${(r.lines || []).map((l) => `<span>${esc(l)}</span>`).join('') || '—'}</div>
      </figcaption>
    </figure>`;

  main.innerHTML =
    pageHead(
      '铭文',
      '官方铭文图鉴 · 红蓝绿三色各 10 种，1~5 级，点开可看属性与整套换算',
      `共 ${d.total} 枚 · 5 级 ${topCount} 枚 · <button class="ph-link" data-goto="items">装备图鉴 →</button>`
    ) +
    `<div class="panel rune-intro">
      <div class="ri-main">
        <h3>铭文怎么用</h3>
        <p>${esc(d.note || '')}</p>
        <p class="ri-note">${esc(d.priceNote || '')}</p>
      </div>
      <div class="ri-colors">
        ${colors
          .map(
            (c) => `<div class="ri-color" data-color="${esc(c.key)}">
          <span class="dot"></span>
          <div class="ri-t"><b>${esc(c.name)}铭文</b><span>${c.level5} 种 5 级 / 共 ${c.count} 枚</span></div>
          <p>${esc(c.desc)}</p>
        </div>`
          )
          .join('')}
      </div>
    </div>
    <div class="toolbar">
      <div class="chips" id="rColors">
        <button class="chip ${S.runeColor === '全部' ? 'on' : ''}" data-color="全部">全部颜色</button>
        ${colors
          .map(
            (c) =>
              `<button class="chip ${S.runeColor === c.key ? 'on' : ''}" data-color="${esc(c.key)}"><i class="dot-c ${esc(
                c.key
              )}"></i>${esc(c.name)} ${c.count}</button>`
          )
          .join('')}
      </div>
      <div class="chips" id="rGrades">
        <button class="chip ${S.runeGrade === '全部' ? 'on' : ''}" data-grade="全部">全部等级</button>
        ${grades
          .map(
            (g) =>
              `<button class="chip ${S.runeGrade === String(g.grade) ? 'on' : ''}" data-grade="${g.grade}">${g.grade} 级 ${g.count}</button>`
          )
          .join('')}
      </div>
      <input type="search" id="rQ" placeholder="搜索铭文名 / 属性" value="${esc(S.runeQ)}">
      <span class="hint">${matched.length} / ${d.total} 枚</span>
    </div>
    ${
      shown
        .map((c) => {
          const rows = (d.list || []).filter((r) => r.color === c.key && hit(r));
          if (!rows.length) return '';
          return `<section class="rune-group" data-color="${esc(c.key)}">
        <header class="rg-head">
          <span class="dot"></span>
          <b>${esc(c.name)}铭文</b>
          <span class="rg-cnt">${rows.length} 枚</span>
          <span class="rg-desc">${esc(c.desc)}</span>
        </header>
        <div class="rune-grid">${rows.map(cardOf).join('')}</div>
      </section>`;
        })
        .join('') || '<div class="panel"><div class="empty">没有匹配的铭文</div></div>'
    }`;

  $$('#rColors .chip').forEach((c) =>
    c.addEventListener('click', () => {
      S.runeColor = c.dataset.color;
      viewRunes(true);
    })
  );
  $$('#rGrades .chip').forEach((c) =>
    c.addEventListener('click', () => {
      S.runeGrade = c.dataset.grade;
      viewRunes(true);
    })
  );
  $('#rQ').addEventListener('input', (e) => {
    S.runeQ = e.target.value;
    clearTimeout(S._rqTimer);
    S._rqTimer = setTimeout(() => viewRunes(true), 220);
  });
  $$('.rune-card').forEach((el) =>
    el.addEventListener('click', () => openRune(((S.runes && S.runes.list) || []).find((x) => x.id === el.dataset.id)))
  );
  bindGoto();
  restoreFocus(focus);
  if (keepScroll) window.scrollTo(0, scrollY);
}

/* ---------- 铭文详情（图标 + 颜色 / 等级 / 单枚属性 / 整套换算 / 同类对比） ---------- */
function openRune(r) {
  if (!r || !S.runes) return;
  const meta = (S.runes.colors || []).find((c) => c.key === r.color) || {};
  const same = (S.runes.list || []).filter((x) => x.color === r.color && x.grade === r.grade && x.id !== r.id);
  const lines = r.lines || [];
  setBig(r.icon, r.name, 'lb-rune');
  $('#lbInfo').innerHTML = `
    <div class="lb-title"><span class="rune-dot ${esc(r.color)}"></span>${esc(r.colorName)}铭文 · ${esc(r.name)}</div>
    <div class="lb-rows">
      <div class="lb-row"><span>颜色</span><b class="clr-${esc(r.color)}">${esc(r.colorName)}</b></div>
      <div class="lb-row"><span>等级</span><b>${r.grade} 级</b></div>
      <div class="lb-row"><span>铭文 ID</span><b>${esc(r.id)}</b></div>
      <div class="lb-row"><span>镶嵌</span><b>${esc(r.colorName)}槽 ×10</b></div>
    </div>
    ${lines.length ? section('单枚属性', lines.map((l) => `<li>${esc(l)}</li>`).join('')) : ''}
    ${lines.length ? section('整套 10 枚（×10 换算）', lines.map((l) => `<li>${esc(runeFull(l))}</li>`).join('')) : ''}
    <div class="lb-sec"><h4>定位说明</h4><p class="lb-text">${esc(meta.desc || '')}${
    r.grade < 5 ? `　当前为 ${r.grade} 级铭文，升满 5 级后属性更高（可用铭文碎片升级）。` : ''
  }</p></div>
    ${
      same.length
        ? section(
            `同色同级（${esc(r.colorName)} ${r.grade} 级）`,
            `<div class="lb-chips">${same
              .map((s) => `<button class="lb-chip" data-id="${esc(s.id)}">${esc(s.name)}</button>`)
              .join('')}</div>`
          )
        : ''
    }`;
  $('#lbCap').innerHTML = `${esc(r.colorName)} · ${esc(r.name)}（${r.grade} 级） <a href="${esc(
    r.icon
  )}" target="_blank" rel="noopener">查看原图</a>`;
  $('#lightbox').classList.add('on');
  $$('#lbInfo .lb-chip').forEach((b) =>
    b.addEventListener('click', () => openRune((S.runes.list || []).find((x) => x.id === b.dataset.id)))
  );
}

/* ================= 英雄详情 ================= */
async function viewHero() {
  const main = $('#main');
  const focus = captureFocus();
  if (!S.heroes) {
    main.innerHTML = pageHead('英雄详情', '', '') + loading('正在加载英雄库…');
    try {
      await loadHeroes();
    } catch (e) {
      main.innerHTML = pageHead('英雄详情', '') + errorPanel(e.message);
      return;
    }
  }
  const heroes = S.heroes;
  const types = ['全部', ...[...new Set(heroes.flatMap((h) => h.types))]];
  const list = heroes
    .filter((h) => (S.heroType === '全部' ? true : h.types.includes(S.heroType)))
    .filter((h) => (S.heroQ ? (h.name + h.title + h.pinyin).toLowerCase().includes(S.heroQ.toLowerCase()) : true));
  if (!S.heroId || !heroes.some((h) => String(h.id) === String(S.heroId))) S.heroId = (list[0] || heroes[0] || {}).id;

  main.innerHTML =
    pageHead('英雄详情', '技能 · 属性 · 皮肤原画（腾讯官方英雄资料）', `共 ${heroes.length} 位英雄`) +
    `<div class="hero-layout">
      <div class="panel">
        <div class="toolbar" style="margin-bottom:8px">
          <input type="search" id="hQ" placeholder="搜索英雄" value="${esc(S.heroQ)}" style="min-width:0;width:100%">
        </div>
        <div class="chips" id="hTypes" style="margin-bottom:10px">${types
          .map((t) => `<button class="chip ${t === S.heroType ? 'on' : ''}" data-type="${esc(t)}">${esc(t)}</button>`)
          .join('')}</div>
        <div class="hero-list" id="hList">
          ${list
            .map(
              (h) => `<div class="hero-row ${String(h.id) === String(S.heroId) ? 'on' : ''}" data-id="${h.id}">
                ${KPLImg.tag(h.icon, { w: 32, h: 32, fb: h.name, alt: h.name })}
                <span class="nm">${esc(h.name)}</span>
                <span class="ty">${esc(h.types.join('/'))}</span>
              </div>`
            )
            .join('') || '<div class="empty">没有匹配的英雄</div>'}
        </div>
      </div>
      <div id="hDetail">${loading('正在加载英雄资料…')}</div>
    </div>`;

  $$('#hTypes .chip').forEach((c) =>
    c.addEventListener('click', () => {
      S.heroType = c.dataset.type;
      viewHero();
    })
  );
  $('#hQ').addEventListener('input', (e) => {
    S.heroQ = e.target.value;
    clearTimeout(S._hqTimer);
    S._hqTimer = setTimeout(viewHero, 220);
  });
  $$('#hList .hero-row').forEach((row) =>
    row.addEventListener('click', () => {
      S.heroId = row.dataset.id;
      $$('#hList .hero-row').forEach((r) => r.classList.toggle('on', r === row));
      paintHeroDetail();
    })
  );
  await paintHeroDetail();
  restoreFocus(focus);
}

async function paintHeroDetail() {
  const box = $('#hDetail');
  if (!box) return;
  const id = S.heroId;
  let d = S.heroCache[id];
  if (!d) {
    box.innerHTML = loading('正在加载英雄资料…');
    try {
      d = (await api(`/api/tools/hero?id=${encodeURIComponent(id)}`)).hero;
      S.heroCache[id] = d;
    } catch (e) {
      box.innerHTML = errorPanel(e.message);
      return;
    }
  }
  const skins = d.skins || [];
  box.innerHTML = `
    <div class="panel hero-detail">
      <div class="hd-top">
        ${KPLImg.tag(d.icon, { w: 86, h: 86, fb: d.name, alt: d.name, eager: true })}
        <div>
          <h2>${esc(d.name)} <span style="font-size:13px;color:var(--muted);font-weight:500">${esc(d.title || '')}</span></h2>
          <div class="sub">英雄 ID ${d.id} · 皮肤 ${skins.length} 款</div>
          <div class="badges">
            ${(d.types || []).map((t) => `<span class="badge-s">${esc(t)}</span>`).join('')}
            ${(d.lanes || []).map((t) => `<span class="badge-s" style="background:rgba(245,196,81,.14);color:var(--gold)">${esc(t)}</span>`).join('')}
          </div>
        </div>
      </div>

      <div class="attr-list">
        ${(d.attr || [])
          .map(
            (a) => `<div class="attr-item">
              <div class="lbl"><span>${esc(a.label)}</span><span>${a.value}%</span></div>
              <div class="attr-bar"><i style="width:${a.value}%"></i></div>
            </div>`
          )
          .join('') || '<div class="hint">暂无属性评分</div>'}
      </div>
    </div>

    <div class="panel">
      <div class="panel-head"><h2>技能</h2><span class="hint">${(d.skills || []).length} 个技能（含被动）</span></div>
      <div class="skill-list">
        ${(d.skills || [])
          .map(
            (s) => `<div class="skill">
              ${KPLImg.tag(s.icon, { w: 44, h: 44, alt: s.name })}
              <div>
                <div class="nm">${esc(s.name)}${s.cd ? `<span class="cd">冷却 ${esc(s.cd)}${s.cost && s.cost !== '0' ? ` · 消耗 ${esc(s.cost)}` : ''}</span>` : ''}</div>
                <div class="desc">${esc(s.desc || '—')}</div>
              </div>
            </div>`
          )
          .join('') || '<div class="empty">暂无技能数据</div>'}
      </div>
    </div>

    <div class="panel">
      <div class="panel-head"><h2>原画 / 皮肤</h2><span class="hint">点击查看大图</span></div>
      <div class="skin-strip">
        ${skins
          .map(
            (s) => `<div class="skin-card" data-big="${esc(s.big)}" data-name="${esc(d.name)} · ${esc(s.name)}">
              ${KPLImg.tag(s.big, { w: 138, h: 78, fb: s.name, alt: s.name, altUrl: s.bigAlt })}
              <div class="nm">${esc(s.name)}</div>
            </div>`
          )
          .join('')}
      </div>
    </div>`;

  $$('.skin-card', box).forEach((c) =>
    c.addEventListener('click', () => openLightbox(c.dataset.big, c.dataset.name))
  );
}

/* ================= 选手详情 ================= */
/** 选手排序口径（同时也是「赛季名次」的比较口径） */
const PLAYER_SORTERS = {
  kda: (a, b) => (b.kda || 0) - (a.kda || 0),
  winRate: (a, b) => (b.winRate || 0) - (a.winRate || 0),
  games: (a, b) => (b.games || 0) - (a.games || 0),
  /* 官方（KPL 统计接口）通道没有分均经济 / 分均伤害（字段为 null），
     直接相减得 NaN 会让排序结果不可预期——统一 || 0 兜底。 */
  gold: (a, b) => (b.goldPerMin || 0) - (a.goldPerMin || 0),
  dmg: (a, b) => (b.dmgPerMin || 0) - (a.dmgPerMin || 0),
  rank: (a, b) => (a.rank || 0) - (b.rank || 0),
};
const PLAYER_SORT_LABEL = {
  kda: '按 KDA',
  winRate: '按胜率',
  games: '按出场场次',
  gold: '按分均经济',
  dmg: '按分均伤害',
  rank: '按赛季名次',
};

async function viewPlayer() {
  const main = $('#main');
  const focus = captureFocus();
  let evs;
  const cachedFirst = S.playerCache[S.playerEvent];
  if (!cachedFirst) main.innerHTML = pageHead('选手详情', 'KPL 职业选手赛场数据与英雄池', '') + loading('正在拉取选手统计…');
  try {
    evs = await eventsWithStats();
  } catch (e) {
    main.innerHTML = pageHead('选手详情', '') + errorPanel(e.message);
    return;
  }
  if (!evs.length) {
    main.innerHTML = pageHead('选手详情', '') + `<div class="panel"><div class="empty">暂无职业统计赛季数据</div></div>`;
    return;
  }
  if (!S.playerEvent || !evs.some((e) => String(e.id) === String(S.playerEvent))) S.playerEvent = String(evs[0].id);

  const eid = S.playerEvent;
  let ps = S.playerCache[eid];
  if (!ps) {
    try {
      /* revalidate：命中本地缓存时也立刻后台拉一次最新数据；
         服务端缓存 10 分钟、上游玩加随时间更新，否则页面会停在旧数据上。 */
      const res = await api(`/api/tools/players?event=${encodeURIComponent(eid)}`, { revalidate: true });
      ps = res.players || [];
      S.playerEventMeta = res.event || S.playerEventMeta;
      S.playerCache[eid] = ps;
    } catch (e) {
      main.innerHTML = pageHead('选手详情', '') + errorPanel(e.message);
      return;
    }
  }
  const meta = S.playerEventMeta && String(S.playerEventMeta.id) === String(eid) ? S.playerEventMeta : null;

  const teams = ['全部', ...[...new Set(ps.map((p) => p.team).filter(Boolean))]].sort((a, b) =>
    a === '全部' ? -1 : b === '全部' ? 1 : a.localeCompare(b, 'zh-CN')
  );
  let rows = ps
    .filter((p) => (S.playerTeam === '全部' ? true : p.team === S.playerTeam))
    .filter((p) => (S.playerQ ? (p.name + p.team).toLowerCase().includes(S.playerQ.toLowerCase()) : true));
  rows = rows.slice().sort(PLAYER_SORTERS[S.playerSort] || PLAYER_SORTERS.kda);

  main.innerHTML =
    pageHead(
      '选手详情',
      '按赛季查看选手的 KDA、场均数据与英雄池 · 点击任意选手展开完整资料',
      `${rows.length} / ${ps.length} 名选手 · ${srcHint()} · <button class="ph-link" id="pSync">立即同步</button>`
    ) +
    `<div class="toolbar">
      <label for="pEvent">赛季</label>
      <select id="pEvent" class="kpl-select">${seasonOptionsHTML(evs, eid, '人')}</select>
      <label for="pTeam">战队</label>
      <select id="pTeam">${teams.map((t) => `<option value="${esc(t)}" ${t === S.playerTeam ? 'selected' : ''}>${esc(t)}</option>`).join('')}</select>
      <input type="search" id="pQ" placeholder="搜索选手 / 战队" value="${esc(S.playerQ)}">
      <select id="pSort">
        ${Object.keys(PLAYER_SORTERS)
          .map((k) => `<option value="${k}" ${S.playerSort === k ? 'selected' : ''}>${PLAYER_SORT_LABEL[k]}</option>`)
          .join('')}
      </select>
    </div>
    <div class="panel">
      <div class="panel-head">
        <h2>选手榜单</h2>
        <span class="hint">名次 = 赛季内 KDA 排名 · 主打分路由英雄池按出场加权得出</span>
      </div>
      <div style="overflow-x:auto">
        <table class="player-table">
          <thead><tr>
            <th>#</th><th>名次</th><th>选手</th><th>战队</th><th>分路</th><th>场次</th><th>胜-负</th><th>胜率</th><th>KDA</th>
            <th>场均 K/D/A</th><th>分均经济</th><th>经济占比</th><th>分均伤害</th><th>伤害占比</th><th>分均承伤</th><th>承伤占比</th><th>参团率</th><th>英雄池</th>
          </tr></thead>
          <tbody>
            ${rows
              .map(
                (p, i) => `<tr data-id="${p.id}">
                  <td>${i + 1}</td>
                  <td><b class="rank-num">${p.rank || i + 1}</b></td>
                  <td class="nm">${esc(p.name)}</td>
                  <td class="tm">${esc(p.team || '—')}</td>
                  <td><span class="tag lane">${esc(p.lane || '未知')}</span></td>
                  <td>${p.games}</td>
                  <td>${p.wins != null ? `${p.wins}-${p.losses}` : '—'}</td>
                  <td>${p.winRate != null ? pct(p.winRate) : '—'}</td>
                  <td><b>${p.kda}</b></td>
                  <td>${nz(p.kills)} / ${nz(p.deaths)} / ${nz(p.assists)}</td>
                  <td>${num(p.goldPerMin)}</td>
                  <td>${p.goldPercent || '—'}</td>
                  <td>${num(p.dmgPerMin)}</td>
                  <td>${p.dmgPercent || '—'}</td>
                  <td>${num(p.dmgTakenPerMin)}</td>
                  <td>${p.dmgTakenPercent || '—'}</td>
                  <td>${p.attendRate || '—'}</td>
                  <td>${p.pool && p.pool.length ? `<span class="pill">${p.pool.length} 位</span>` : '<span class="hint">暂无</span>'}</td>
                </tr>`
              )
              .join('') || '<tr><td colspan="18" class="empty">没有匹配的选手</td></tr>'}
          </tbody>
        </table>
      </div>
    </div>
    <div id="pDetail"></div>`;

  $('#pEvent').addEventListener('change', (e) => {
    S.playerEvent = e.target.value;
    S.playerTeam = '全部';
    S.currentPlayer = null;
    viewPlayer();
  });
  $('#pTeam').addEventListener('change', (e) => {
    S.playerTeam = e.target.value;
    viewPlayer();
  });
  $('#pSort').addEventListener('change', (e) => {
    S.playerSort = e.target.value;
    viewPlayer();
  });
  $('#pQ').addEventListener('input', (e) => {
    S.playerQ = e.target.value;
    clearTimeout(S._pqTimer);
    S._pqTimer = setTimeout(viewPlayer, 220);
  });
  /* 立即同步：跳过本地缓存直连服务端重拉，确保看到的是最新数据 */
  const pSync = $('#pSync');
  if (pSync)
    pSync.addEventListener('click', async () => {
      pSync.disabled = true;
      pSync.textContent = '同步中…';
      try {
        delete S.playerCache[eid];
        await api(`/api/tools/players?event=${encodeURIComponent(eid)}`, { force: true });
      } catch (e) {
        /* 失败也继续重渲染：会回落到本地缓存并给出提示 */
      }
      await viewPlayer();
      const again = $('#pSync');
      if (again) {
        again.disabled = false;
        again.textContent = '立即同步';
      }
    });
  $$('.player-table tbody tr[data-id]').forEach((tr) =>
    tr.addEventListener('click', () => {
      const p = ps.find((x) => x.id === tr.dataset.id);
      if (p) paintPlayerDetail(p, meta);
    })
  );
  restoreFocus(focus);
}

function paintPlayerDetail(p, meta) {
  const box = $('#pDetail');
  if (!box) return;
  const ev = meta || S.playerEventMeta || {};
  const seasonText = [ev.year, ev.short || ev.name].filter(Boolean).join(' ') || String(S.playerEvent || '');
  const profile = [
    ['所属战队', p.team || '—'],
    ['赛季', seasonText || '—'],
    ['主打分路', p.lane || '未知'],
    ['擅长位置', (p.types || []).join(' / ') || '—'],
    ['赛季名次', p.rank ? `第 ${p.rank} 名 / ${(p.rankPct ? p.rankPct + '%' : '')}`.trim() : '—'],
    ['出场场次', p.wins != null ? `${p.games} 场（${p.wins} 胜 ${p.losses} 负）` : `${p.games} 场`],
    ['出场时长', p.durationMin ? `${p.durationMin} 分钟` : '—'],
    ['MVP 次数', p.mvp != null ? `${p.mvp}` : '—'],
    ['英雄池', p.pool && p.pool.length ? `${p.pool.length} 位英雄` : '暂无（上游未收录）'],
    ['单场最高', p.mostKills || p.mostAssists || p.mostDeaths ? `击杀 ${p.mostKills} / 助攻 ${p.mostAssists} / 死亡 ${p.mostDeaths}` : '—'],
    ['伤害转化率', p.dmgConversion ? `${p.dmgConversion}` : '—'],
  ];
  const kpis = [
    ['胜率', p.winRate != null ? pct(p.winRate) : '—', p.winRate >= 0.5 ? 'var(--green)' : '#ff8a95'],
    ['KDA', p.kda, 'var(--gold)'],
    ['场均 K / D / A', `${nz(p.kills)} / ${nz(p.deaths)} / ${nz(p.assists)}`, ''],
    ['分均经济', num(p.goldPerMin), ''],
    ['经济占比', p.goldPercent || '—', ''],
    ['分均伤害', num(p.dmgPerMin), ''],
    ['伤害占比', p.dmgPercent || '—', ''],
    ['分均承伤', num(p.dmgTakenPerMin), ''],
    ['承伤占比', p.dmgTakenPercent || '—', ''],
    ['参团率', p.attendRate || '—', ''],
    ['总击杀 / 助攻', `${p.totals ? p.totals.kills : 0} / ${p.totals ? p.totals.assists : 0}`, ''],
  ];
  box.innerHTML = `
    <div class="panel">
      <div class="panel-head">
        <h2>${esc(p.name)} <span class="hint" style="font-weight:500">${esc(p.team || '')} · ${esc(p.lane || '未知')}</span></h2>
        <button class="chip" id="pClose">收起</button>
      </div>
      <div class="profile-grid">
        ${profile
          .map(
            ([k, v]) => `<div class="pf"><span class="pf-k">${esc(k)}</span><span class="pf-v">${esc(String(v))}</span></div>`
          )
          .join('')}
      </div>
      <div class="panel-head" style="margin-top:6px"><h2 style="font-size:14px">赛季统计指标</h2><span class="hint">数据口径：本赛季全部出场</span></div>
      <div class="stats-row" style="margin-bottom:14px">
        ${kpis
          .map(
            ([k, v, color]) => `<div class="stat-kpi"><div class="k">${esc(k)}</div><div class="v" style="font-size:16px;${
              color ? `color:${color}` : ''
            }">${esc(String(v))}</div></div>`
          )
          .join('')}
      </div>
      <div class="panel-head"><h2 style="font-size:14px">英雄池（${p.pool && p.pool.length ? p.pool.length + ' 位' : '暂无'}）</h2><span class="hint">按出场次数排序 · 括号内为使用该英雄时名次</span></div>
      <div class="pool-grid">
        ${p.pool
          .map(
            (h) => `<div class="pool-item">
              ${KPLImg.tag(h.icon, { w: 34, h: 34, fb: h.name, alt: h.name })}
              <div>
                <div class="nm">${esc(h.name)}${h.alias ? `<span class="alias">${esc(h.alias)}</span>` : ''}</div>
                <div class="m">${h.games} 场 · 胜率 ${pct(h.winRate)} · KDA ${h.kda}</div>
                <div class="tags">${(h.lanes || []).map((l) => `<span class="tag lane">${esc(l)}</span>`).join('')}${(h.types || [])
                  .map((x) => `<span class="tag">${esc(x)}</span>`)
                  .join('')}</div>
              </div>
              <div class="pool-rank">#${h.rank || 1}</div>
            </div>`
          )
          .join('') || '<div class="empty">暂无英雄池数据</div>'}
      </div>
    </div>`;
  box.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  const btn = $('#pClose');
  if (btn) btn.addEventListener('click', () => (box.innerHTML = ''));
}

/* ================= 原画画廊（按英雄分组） ================= */
/** 品质 → 配色档位 */
function qTier(q) {
  const s = String(q || '');
  if (/荣耀典藏|珍品无双/.test(s)) return 't-s';
  if (/珍品传说|无双/.test(s)) return 't-a';
  if (/^传说/.test(s)) return 't-b';
  if (/^史诗/.test(s)) return 't-c';
  if (/勇者/.test(s)) return 't-d';
  if (/赛季/.test(s)) return 't-e';
  return 't-f';
}
/** 价格文案：纯数字 → 补「点券」 */
function priceLabel(t) {
  const s = String(t || '').trim();
  if (!s || s === '—') return '—';
  return /^\d+$/.test(s) ? `${s} 点券` : s;
}

async function loadSkins() {
  if (S.skins) return S.skins;
  S.skins = await api('/api/tools/skins');
  return S.skins;
}

/** 组内排序 */
function sortSkins(list, mode, qOrder) {
  const a = list.slice();
  const rank = (q) => {
    const i = qOrder.indexOf(q);
    return i < 0 ? 99 : i;
  };
  if (mode === 'dateDesc') a.sort((x, y) => String(y.date || '').localeCompare(String(x.date || '')) || x.name.localeCompare(y.name, 'zh'));
  else if (mode === 'quality') a.sort((x, y) => rank(x.quality) - rank(y.quality) || String(x.date || '9999').localeCompare(String(y.date || '9999')));
  else a.sort((x, y) => String(x.date || '9999').localeCompare(String(y.date || '9999')) || x.name.localeCompare(y.name, 'zh'));
  return a;
}

/** 候选下拉：输入过程只出候选，选中（回车 / 点击）后才回调 onPick 触发检索 */
function bindCombo({ input, pop, candidates, onPick, onDismiss }) {
  let items = [];
  let active = -1;
  const isOpen = () => pop.classList.contains('on');

  const close = () => {
    pop.classList.remove('on');
    pop.innerHTML = '';
    input.setAttribute('aria-expanded', 'false');
    input.removeAttribute('aria-activedescendant');
    items = [];
    active = -1;
  };
  const paint = () => {
    pop.innerHTML = items.length
      ? items
          .map(
            (it, i) => `<div class="combo-item${i === active ? ' on' : ''}" id="gPop-${i}" role="option"
              aria-selected="${i === active}" data-i="${i}">
              ${KPLImg.tag(it.icon, { w: 30, h: 30, fb: it.name, alt: '' })}
              <span class="ci-nm">${esc(it.name)}</span>
              <span class="ci-kind">${it.kind === 'hero' ? '英雄' : '皮肤'}</span>
              <span class="ci-sub">${esc(it.sub || '')}</span>
            </div>`
          )
          .join('')
      : '<div class="combo-empty">没有匹配的英雄 / 皮肤</div>';
    pop.classList.add('on');
    input.setAttribute('aria-expanded', 'true');
    if (active >= 0) input.setAttribute('aria-activedescendant', `gPop-${active}`);
    $$('.combo-item', pop).forEach((el) =>
      el.addEventListener('mousedown', (e) => {
        e.preventDefault(); // 抢在 blur 之前完成选中
        pick(+el.dataset.i);
      })
    );
  };
  const open = (q) => {
    items = candidates(q) || [];
    active = items.length ? 0 : -1;
    paint();
  };
  const pick = (i) => {
    const it = items[i];
    if (!it) return;
    comboSuppressUntil = Date.now() + 800; // 选中后焦点会回到输入框，别再把候选弹出来
    close();
    onPick(it);
  };
  const move = (d) => {
    if (!items.length) return;
    active = (active + d + items.length) % items.length;
    paint();
    const el = $(`#gPop-${active}`, pop);
    if (el && el.scrollIntoView) el.scrollIntoView({ block: 'nearest' });
  };

  input.setAttribute('role', 'combobox');
  input.setAttribute('autocomplete', 'off');
  input.setAttribute('aria-expanded', 'false');
  input.addEventListener('input', () => {
    const q = input.value.trim();
    if (!q) {
      close(); // 清空输入：不检索，下方列表保持原状
      return;
    }
    open(q); // 只出候选，不动列表
  });
  input.addEventListener('focus', () => {
    if (Date.now() < comboSuppressUntil) return;
    const q = input.value.trim();
    if (q) open(q);
  });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      if (isOpen()) move(1);
      else {
        const q = input.value.trim();
        if (q) open(q);
      }
      return;
    }
    if (e.key === 'ArrowUp') {
      if (isOpen()) {
        e.preventDefault();
        move(-1);
      }
      return;
    }
    if (e.key === 'Enter') {
      if (isOpen() && active >= 0) {
        e.preventDefault();
        pick(active);
      }
      return;
    }
    if (e.key === 'Escape') {
      close();
      if (onDismiss) onDismiss();
      return;
    }
    if (e.key === 'Tab') close();
  });
  input.addEventListener('blur', () => setTimeout(close, 140));
  return { close, open };
}

async function viewGallery(keepScroll) {
  const main = $('#main');
  const focus = captureFocus();
  const scrollY = keepScroll ? window.scrollY : 0;
  let d;
  try {
    if (!S.skins) main.innerHTML = pageHead('原画画廊', '', '') + loading('正在加载官方皮肤图鉴…');
    d = await loadSkins();
  } catch (e) {
    main.innerHTML = pageHead('原画画廊', '') + errorPanel(e.message);
    return;
  }

  const qOrder = (d.qualities || []).map((q) => q.name);
  const pick = S.galleryPick;
  const passFilter = (s) =>
    (S.galleryQuality === '全部' || s.quality === S.galleryQuality) &&
    (S.galleryLabel === '全部' || s.label === S.galleryLabel);

  /* 英雄分类：职业（多选，含「未分类」）+ 分路（多选），任一命中即保留 */
  const wantTypes = S.galleryTypes.filter((t) => t !== UNTYPED);
  const wantUntyped = S.galleryTypes.includes(UNTYPED);
  const typeHit = (h) =>
    !S.galleryTypes.length ||
    (wantTypes.length > 0 && h.types.some((t) => wantTypes.includes(t))) ||
    (wantUntyped && !h.types.length);
  const laneHit = (h) => !S.galleryLanes.length || (h.lanes || []).some((l) => S.galleryLanes.includes(l));

  const groups = [];
  let totalSkins = 0;
  for (const h of d.heroes) {
    if (!typeHit(h) || !laneHit(h)) continue;
    if (pick && h.name !== pick.hero) continue; // 未选中候选时 pick 恒为 null，列表保持原状
    let skins = h.skins.filter(passFilter);
    if (pick && pick.kind === 'skin') skins = skins.filter((s) => s.id === pick.skin);
    if (!skins.length) continue;
    totalSkins += skins.length;
    groups.push({ ...h, skins: sortSkins(skins, S.gallerySort, qOrder) });
  }

  const filtered = !!pick || S.galleryTypes.length > 0 || S.galleryLanes.length > 0;
  const shownGroups = groups.slice(0, pick ? groups.length : S.galleryHeroLimit);
  const cardOf = (h, s) =>
    `<figure class="sk-card" data-hero="${esc(h.name)}" data-skin="${esc(s.id)}"
        title="${esc(h.name)} · ${esc(s.name)}｜${esc(s.quality)}｜${esc(priceLabel(s.priceText))}｜${esc(s.date || '上线时间未公开')}">
      <div class="sk-pic">
        ${KPLImg.tag(s.big, { w: 262, h: 164, fb: s.name, alt: s.name })}
        ${s.tagIcon ? `<img class="sk-badge im-plain" loading="lazy" src="${imgUrl(s.tagIcon)}" alt="${esc(s.label)}" title="${esc(s.label)}">` : ''}
        <span class="sk-ware ${qTier(s.quality)}">${esc(s.quality)}</span>
      </div>
      <figcaption>
        <div class="sk-nm">${esc(s.name)}</div>
        <div class="sk-info">
          <span class="sk-price">${esc(priceLabel(s.priceText))}</span>
          <span class="sk-date">${esc(s.date || '—')}</span>
        </div>
      </figcaption>
    </figure>`;

  const groupOf = (h) => {
    const exp = pick ? true : !!S.galleryExpanded[h.name];
    const cap = exp ? h.skins.length : 8;
    const dist = Object.entries(h.qualities || {})
      .sort((a, b) => qOrder.indexOf(a[0]) - qOrder.indexOf(b[0]))
      .slice(0, 4)
      .map(([k, v]) => `<span class="gg-q ${qTier(k)}">${esc(k)} ${v}</span>`)
      .join('');
    return `<section class="g-group" data-hero="${esc(h.name)}">
      <header class="gg-head" data-toggle="${esc(h.name)}">
        ${KPLImg.tag(h.icon, { w: 34, h: 34, cls: 'gg-av', fb: h.name, alt: h.name })}
        <div class="gg-title"><b>${esc(h.name)}</b>${h.lane ? `<span class="gg-lane">${esc(h.lane)}</span>` : ''}${(h.types || [])
      .map((t) => `<span class="gg-type">${esc(t)}</span>`)
      .join('')}</div>
        <div class="gg-stats">${h.count} 款皮肤 ${dist}</div>
        ${pick ? '' : `<button class="gg-btn" data-toggle="${esc(h.name)}">${exp ? '收起' : '展开'}</button>`}
      </header>
      <div class="gg-grid">${h.skins.slice(0, cap).map((s) => cardOf(h, s)).join('')}</div>
      ${
        !pick && h.skins.length > cap
          ? `<div class="gg-foot"><button class="chip" data-toggle="${esc(h.name)}">展开该英雄全部 ${h.skins.length} 款</button></div>`
          : ''
      }
    </section>`;
  };

  /* 候选数据：英雄（名称 / 拼音 / 职业 / 分路）+ 皮肤名 */
  const flatSkins = [];
  for (const h of d.heroes) for (const s of h.skins) flatSkins.push({ h, s });
  const candidates = (qq) => {
    const ql = qq.toLowerCase();
    const out = [];
    const heroHits = d.heroes
      .filter(
        (h) =>
          h.name.toLowerCase().includes(ql) ||
          (h.pinyin || '').toLowerCase().includes(ql) ||
          (h.types || []).some((t) => t.includes(qq)) ||
          (h.lane || '').includes(qq)
      )
      .sort(
        (a, b) =>
          (b.name.toLowerCase().startsWith(ql) ? 1 : 0) - (a.name.toLowerCase().startsWith(ql) ? 1 : 0) || b.count - a.count
      );
    for (const h of heroHits.slice(0, 8))
      out.push({
        kind: 'hero',
        hero: h.name,
        skin: null,
        name: h.name,
        sub: [...(h.types || []), h.lane || '', `${h.count} 款`].filter(Boolean).join(' · '),
        icon: h.icon,
      });
    for (const { h, s } of flatSkins.filter(({ s }) => s.name.toLowerCase().includes(ql)).slice(0, 6))
      out.push({ kind: 'skin', hero: h.name, skin: s.id, name: s.name, sub: `${h.name} · ${s.quality}`, icon: s.big });
    return out;
  };

  const pickHero = pick ? d.heroes.find((x) => x.name === pick.hero) : null;
  const pickSkin = pickHero && pick.kind === 'skin' ? (pickHero.skins || []).find((s) => s.id === pick.skin) : null;
  const pickText = !pick ? '' : pick.kind === 'hero' ? pick.hero : `${pick.hero} · ${(pickSkin || {}).name || '皮肤'}`;

  const unt = d.untypedHeroes || 0;
  const typeChips = [
    `<button class="chip${S.galleryTypes.length ? '' : ' on'}" data-v="" title="清空职业筛选">全部</button>`,
    ...(d.types || []).map(
      (t) =>
        `<button class="chip${S.galleryTypes.includes(t.name) ? ' on' : ''}" data-v="${esc(t.name)}">${esc(t.name)}<i>${t.count}</i></button>`
    ),
    unt > 0
      ? `<button class="chip${S.galleryTypes.includes(UNTYPED) ? ' on' : ''}" data-v="${UNTYPED}">${UNTYPED}<i>${unt}</i></button>`
      : '',
  ].join('');
  const laneChips = [
    `<button class="chip${S.galleryLanes.length ? '' : ' on'}" data-v="" title="清空分路筛选">全部</button>`,
    ...(d.lanes || []).map(
      (l) =>
        `<button class="chip${S.galleryLanes.includes(l.name) ? ' on' : ''}" data-v="${esc(l.name)}">${esc(l.name)}<i>${l.count}</i></button>`
    ),
  ].join('');

  const activeDesc = [
    S.galleryTypes.length ? `职业 ${S.galleryTypes.join('/')}` : '',
    S.galleryLanes.length ? `分路 ${S.galleryLanes.join('/')}` : '',
    S.galleryQuality !== '全部' ? `品质 ${S.galleryQuality}` : '',
    S.galleryLabel !== '全部' ? `标签 ${S.galleryLabel}` : '',
    pick ? `搜索 ${pickText}` : '',
  ].filter(Boolean);

  main.innerHTML =
    pageHead('原画画廊', '全部英雄皮肤原画 · 按英雄分组（品质标签 / 价格 / 上线时间）', `${d.heroCount} 位英雄 · ${d.total} 款皮肤`) +
    `<div class="toolbar">
      <div class="combo" id="gCombo">
        <input type="search" id="gQ" placeholder="搜索英雄 / 皮肤（选中候选后才筛选）" value="${esc(S.galleryQ)}"
          aria-controls="gPop" aria-autocomplete="list">
        <div class="combo-pop" id="gPop" role="listbox" aria-label="搜索候选"></div>
      </div>
      ${pick ? `<button class="chip on g-pick" id="gClearPick" title="清除搜索条件，恢复全部英雄">搜索：${esc(pickText)}<i>✕</i></button>` : ''}
      <label for="gQuality">品质</label>
      <select id="gQuality"><option value="全部" ${S.galleryQuality === '全部' ? 'selected' : ''}>全部品质</option>
        ${(d.qualities || [])
          .map((x) => `<option value="${esc(x.name)}" ${x.name === S.galleryQuality ? 'selected' : ''}>${esc(x.name)}（${x.count}）</option>`)
          .join('')}
      </select>
      <label for="gLabel">标签</label>
      <select id="gLabel"><option value="全部" ${S.galleryLabel === '全部' ? 'selected' : ''}>全部标签</option>
        ${(d.labels || [])
          .map((x) => `<option value="${esc(x.name)}" ${x.name === S.galleryLabel ? 'selected' : ''}>${esc(x.name)}（${x.count}）</option>`)
          .join('')}
      </select>
      <label for="gSort">排序</label>
      <select id="gSort">
        <option value="dateAsc" ${S.gallerySort === 'dateAsc' ? 'selected' : ''}>上线时间 ↑</option>
        <option value="dateDesc" ${S.gallerySort === 'dateDesc' ? 'selected' : ''}>上线时间 ↓</option>
        <option value="quality" ${S.gallerySort === 'quality' ? 'selected' : ''}>品质优先</option>
      </select>
      <button class="chip" id="gExpandAll">全部展开</button>
      <button class="chip" id="gCollapseAll">全部收起</button>
      <span class="hint">命中 ${groups.length} 位英雄 / ${totalSkins} 款皮肤${filtered ? '（已筛选）' : `（共 ${d.total} 款）`}</span>
    </div>
    <div class="filter-row">
      <span class="flt-lbl">职业</span>
      <div class="chips" id="gTypes">${typeChips}</div>
    </div>
    <div class="filter-row">
      <span class="flt-lbl">分路</span>
      <div class="chips" id="gLanes">${laneChips}</div>
      <div class="flt-actions">
        <button class="chip" id="gClearFilters" title="清空职业 / 分路 / 品质 / 标签（保留已选中的搜索）">清除筛选</button>
        <button class="chip" id="gResetAll" title="清空全部条件，恢复全部英雄">恢复全部英雄</button>
      </div>
    </div>
    <div class="g-note">官方未公开皮肤定价，价格按官方品质徽章与获取方式推算，仅供参考；标签与上线时间取自官方皮肤图鉴。<br>
      职业 / 分路支持多选（点「全部」即清空该分类）；搜索请在下拉候选中选中后再筛选，输入过程不会刷新下方列表。</div>
    <div class="g-groups" id="gGroups">
      ${
        shownGroups.map(groupOf).join('') ||
        `<div class="panel"><div class="empty">
          没有匹配的英雄 / 皮肤
          ${activeDesc.length ? `<div class="empty-tip">当前条件：${esc(activeDesc.join(' · '))}</div>` : ''}
          <div class="empty-actions"><button class="chip" id="gEmptyReset">恢复全部英雄</button></div>
        </div></div>`
      }
    </div>
    ${
      groups.length > shownGroups.length
        ? `<div style="text-align:center;margin:16px 0"><button class="chip" id="gMore">加载更多英雄（还有 ${groups.length - shownGroups.length} 位）</button></div>`
        : ''
    }`;

  /* 搜索：输入只出候选；选中候选才写回 pick 并重渲染 */
  bindCombo({
    input: $('#gQ'),
    pop: $('#gPop'),
    candidates,
    onPick: (it) => {
      S.galleryPick = { kind: it.kind, hero: it.hero, skin: it.skin };
      S.galleryQ = it.kind === 'skin' ? `${it.hero} · ${it.name}` : it.name;
      S.galleryExpanded = { [it.hero]: true };
      S.galleryHeroLimit = 24;
      viewGallery(true);
    },
    onDismiss: () => {
      const el = $('#gQ');
      if (el) el.value = S.galleryQ; // 取消选择：输入框回到已选条件，列表不动
    },
  });

  const resetAll = () => {
    S.galleryPick = null;
    S.galleryQ = '';
    S.galleryTypes = [];
    S.galleryLanes = [];
    S.galleryQuality = '全部';
    S.galleryLabel = '全部';
    S.galleryHeroLimit = 24;
    viewGallery();
  };
  const clearFilters = () => {
    S.galleryTypes = [];
    S.galleryLanes = [];
    S.galleryQuality = '全部';
    S.galleryLabel = '全部';
    S.galleryHeroLimit = 24;
    viewGallery();
  };
  const toggleIn = (arr, v, view) => {
    if (!v) arr.length = 0; // 「全部」
    else {
      const i = arr.indexOf(v);
      if (i >= 0) arr.splice(i, 1);
      else arr.push(v);
    }
    S.galleryHeroLimit = 24;
    view();
  };
  $$('#gTypes .chip').forEach((c) => c.addEventListener('click', () => toggleIn(S.galleryTypes, c.dataset.v, viewGallery)));
  $$('#gLanes .chip').forEach((c) => c.addEventListener('click', () => toggleIn(S.galleryLanes, c.dataset.v, viewGallery)));
  const clearPick = $('#gClearPick');
  if (clearPick)
    clearPick.addEventListener('click', () => {
      S.galleryPick = null;
      S.galleryQ = '';
      S.galleryHeroLimit = 24;
      viewGallery();
    });
  $('#gClearFilters').addEventListener('click', clearFilters);
  $('#gResetAll').addEventListener('click', resetAll);
  const emptyReset = $('#gEmptyReset');
  if (emptyReset) emptyReset.addEventListener('click', resetAll);
  $('#gQuality').addEventListener('change', (e) => {
    S.galleryQuality = e.target.value;
    S.galleryHeroLimit = 24;
    viewGallery();
  });
  $('#gLabel').addEventListener('change', (e) => {
    S.galleryLabel = e.target.value;
    S.galleryHeroLimit = 24;
    viewGallery();
  });
  $('#gSort').addEventListener('change', (e) => {
    S.gallerySort = e.target.value;
    viewGallery(true);
  });
  $('#gExpandAll').addEventListener('click', () => {
    for (const h of groups) S.galleryExpanded[h.name] = true;
    viewGallery(true);
  });
  $('#gCollapseAll').addEventListener('click', () => {
    S.galleryExpanded = {};
    viewGallery(true);
  });
  const more = $('#gMore');
  if (more)
    more.addEventListener('click', () => {
      S.galleryHeroLimit += 24;
      viewGallery(true);
    });
  $$('#gGroups [data-toggle]').forEach((el) =>
    el.addEventListener('click', (ev) => {
      ev.preventDefault();
      const n = el.dataset.toggle;
      if (S.galleryExpanded[n]) delete S.galleryExpanded[n];
      else S.galleryExpanded[n] = true;
      viewGallery(true);
    })
  );
  $$('#gGroups .sk-card').forEach((el) =>
    el.addEventListener('click', () => {
      const h = d.heroes.find((x) => x.name === el.dataset.hero);
      const skin = h ? h.skins.find((x) => x.id === el.dataset.skin) : null;
      if (h && skin) openSkin(h, skin);
    })
  );
  restoreFocus(focus);
  if (keepScroll) window.scrollTo(0, scrollY);
}

/** 皮肤详情（大图 + 品质 / 标签 / 价格 / 上线时间 / 获取方式） */
function openSkin(h, s) {
  setBig(s.big, `${h.name} · ${s.name}`, 'lb-skin');
  const badge = s.tagIcon
    ? `<img class="lb-badge im-plain" src="${imgUrl(s.tagIcon)}" alt="${esc(s.label)}">`
    : '';
  $('#lbInfo').innerHTML = `
    <div class="lb-title">${esc(h.name)} · ${esc(s.name)}</div>
    <div class="lb-rows">
      <div class="lb-row"><span>品质</span><b class="q-chip ${qTier(s.quality)}">${esc(s.quality)}</b>${
    s.officialQuality ? '' : '<i class="lb-ref">参考</i>'
  }</div>
      <div class="lb-row"><span>标签</span><b>${esc(s.label || '无专属标签')}</b>${badge}</div>
      <div class="lb-row"><span>价格</span><b class="lb-price">${esc(priceLabel(s.priceText))}</b></div>
      <div class="lb-row"><span>上线时间</span><b>${esc(s.date || '官方未公开')}</b></div>
      <div class="lb-row"><span>获取方式</span><b>${esc(s.obtain || '—')}</b></div>
      <div class="lb-row"><span>皮肤 ID</span><b>${esc(s.id || '—')}</b></div>
    </div>
    ${s.intro ? `<p class="lb-intro">${esc(s.intro)}</p>` : ''}`;
  $('#lbCap').innerHTML = `${esc(h.name)} · ${esc(s.name)} <a href="${esc(s.big)}" target="_blank" rel="noopener">查看原图</a>`;
  $('#lightbox').classList.add('on');
}

/* ================= 大图 ================= */
function openLightbox(url, cap) {
  if (!url) return;
  setBig(url, cap, 'lb-skin');
  $('#lbInfo').innerHTML = '';
  $('#lbCap').innerHTML = `${esc(cap || '')} <a href="${esc(url)}" target="_blank" rel="noopener">查看原图</a>`;
  $('#lightbox').classList.add('on');
}
function closeLightbox() {
  $('#lightbox').classList.remove('on');
  const el = $('#lbImg');
  el.dataset.done = '1'; // 先标记，避免清空 src 触发一次 error 事件
  el.className = 'im';
  el.src = KPLImg.ph('', 4, 4);
  $('#lbInfo').innerHTML = '';
}

/* ================= 版本动态（王者荣耀官网） =================
 * 左侧：最近更新公告里解析出的英雄 / 装备 / 铭文调整（可按类型、增强/削弱、关键字筛选）
 * 右侧：官网更新公告列表小板块，点击直达官网原文
 */
const KIND_LABEL = { hero: '英雄', item: '装备', rune: '铭文' };
const DIR_LABEL = { buff: '增强', nerf: '削弱', adjust: '调整' };
const PATCH_KINDS = ['全部', '英雄', '装备', '铭文'];
const PATCH_DIRS = ['全部', '增强', '削弱', '调整'];

async function loadPatch(force) {
  if (S.patch && !force) return S.patch;
  S.patch = await api(`/api/patch?what=feed&limit=8${force ? '&t=' + Date.now() : ''}`);
  return S.patch;
}

function patchHeroCard(f) {
  const src = f.source || {};
  const cv = f.latestVersion ? `<span class="ph-chip">最新版本 <b>${esc(f.latestVersion)}</b></span>` : '';
  const ct = f.latestTime ? `<span class="ph-chip">最近公告 <b>${esc(f.latestTime.slice(0, 10))}</b></span>` : '';
  const cc = `<span class="ph-chip">英雄 <b>${f.counts.hero || 0}</b> · 装备 <b>${f.counts.item || 0}</b> · 铭文 <b>${f.counts.rune || 0}</b></span>`;
  return `<div class="patch-hero">
    <div class="ph-l">
      <div class="ph-ico"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3.2l2.1 4.3 4.7.7-3.4 3.3.8 4.7-4.2-2.2-4.2 2.2.8-4.7L5.2 8.2l4.7-.7L12 3.2z"/><path d="M18.6 19.4h-13"/></svg></div>
      <div>
        <h2>最近版本调整</h2>
        <p class="ph-sub">自动同步 ${esc(src.name || '王者荣耀官方网站')} 更新公告，解析出英雄 / 装备 / 铭文改动</p>
      </div>
    </div>
    <div class="ph-meta">${cv}${ct}${cc}</div>
  </div>`;
}

function chgCard(c) {
  const av = c.icon
    ? KPLImg.tag(c.icon, { w: 46, h: 46, fb: c.name, cls: 'chg-av', eager: false })
    : `<div class="chg-av"></div>`;
  const lines = (c.lines || [])
    .slice(0, 4)
    .map((l) => `<li title="${esc(l)}">${esc(l)}</li>`)
    .join('');
  return `<div class="chg-card">
    ${av}
    <div class="chg-body">
      <div class="chg-top">
        <span class="chg-name">${esc(c.name)}</span>
        <span class="chg-kind">${KIND_LABEL[c.kind] || c.kind}</span>
        <span class="chg-dir ${c.dir}">${DIR_LABEL[c.dir] || '调整'}</span>
      </div>
      <ul class="chg-lines">${lines}</ul>
      <div class="chg-foot">
        <span>${esc((c.newsTime || '').slice(0, 10))}${c.version ? ' · ' + esc(c.version) : ''}</span>
        <a href="${esc(c.newsUrl || '#')}" target="_blank" rel="noopener">查看公告原文 ↗</a>
      </div>
    </div>
  </div>`;
}

function newsPanel(list) {
  const items = (list || []).slice(0, 30);
  if (!items.length) return `<div class="empty">暂无公告</div>`;
  return `<div class="news-list">${items
    .map(
      (n) => `<a class="news-item" href="${esc(n.url)}" target="_blank" rel="noopener">
      <div class="ni-t">
        <div class="ni-title">${esc(n.title)}</div>
        <div class="ni-meta">
          <span class="ni-tag${n.patch ? ' patch' : ''}">${n.patch ? '更新公告' : '公告'}</span>
          <span>${esc((n.time || '').slice(0, 16))}</span>
        </div>
      </div>
      <span class="ni-go">官网 ↗</span>
    </a>`
    )
    .join('')}</div>`;
}

function patchFilterBar() {
  const chip = (arr, cur, key) =>
    arr
      .map((v) => `<span class="chip${cur === v ? ' on' : ''}" data-pf="${key}" data-pv="${esc(v)}">${esc(v)}</span>`)
      .join('');
  return `<div class="toolbar">
    <input id="pfQ" type="search" placeholder="搜索英雄 / 装备 / 铭文名" value="${esc(S.patchQ)}">
    <div class="patch-tabs chips">${chip(PATCH_KINDS, S.patchKind, 'kind')}</div>
    <div class="patch-tabs chips">${chip(PATCH_DIRS, S.patchDir, 'dir')}</div>
    <button class="mini-btn" id="pfSync">⟳ 立即同步</button>
  </div>`;
}

function paintPatch() {
  const f = S.patch || {};
  const all = f.changes || [];
  const kw = S.patchQ.trim();
  const dirKey = Object.keys(DIR_LABEL).find((k) => DIR_LABEL[k] === S.patchDir) || '';
  const kindKey = Object.keys(KIND_LABEL).find((k) => KIND_LABEL[k] === S.patchKind) || '';
  const list = all.filter(
    (c) =>
      (!kindKey || c.kind === kindKey) &&
      (!dirKey || c.dir === dirKey) &&
      (!kw || c.name.includes(kw) || String(c.summary || '').includes(kw))
  );
  const grid = list.length
    ? `<div class="chg-grid">${list.map(chgCard).join('')}</div>`
    : `<div class="empty">没有匹配的调整${kw ? `（搜索：${esc(kw)}）` : ''}<div class="empty-actions"><button class="mini-btn" id="pfReset">清空筛选</button></div></div>`;
  const syncAt = f.updatedAt ? new Date(f.updatedAt).toLocaleString('zh-CN') : '—';
  const src = f.source || {};

  $('#main').innerHTML =
    pageHead(
      '版本动态',
      '官网更新公告与英雄 / 装备 / 铭文调整',
      `同步于 ${esc(syncAt)}${f.offline ? ' · 离线缓存' : ''}`
    ) +
    `<div class="patch-wrap">
      ${patchHeroCard(f)}
      ${patchFilterBar()}
      <div class="patch-cols">
        <section class="panel">
          <div class="panel-head"><h3 style="margin:0;font-size:14.5px">调整明细</h3><span class="hint">共 ${list.length} 条${all.length !== list.length ? ` / ${all.length}` : ''}</span></div>
          ${grid}
        </section>
        <section class="panel">
          <div class="panel-head">
            <h3 style="margin:0;font-size:14.5px">官网更新公告</h3>
            <a class="hint" href="${esc(src.url || 'https://pvp.qq.com/')}" target="_blank" rel="noopener">王者荣耀官网 ↗</a>
          </div>
          ${newsPanel(f.notes && f.notes.length ? f.notes : S.patchNews)}
        </section>
      </div>
    </div>`;

  const q = $('#pfQ');
  if (q) {
    q.addEventListener('input', () => {
      S.patchQ = q.value;
      const pos = q.selectionStart;
      paintPatch();
      const n = $('#pfQ');
      if (n) {
        n.focus();
        try {
          n.setSelectionRange(pos, pos);
        } catch (_) {}
      }
    });
  }
  $$('#main .chip[data-pf]').forEach((el) => {
    el.addEventListener('click', () => {
      const k = el.dataset.pf;
      const v = el.dataset.pv;
      if (k === 'kind') S.patchKind = v;
      if (k === 'dir') S.patchDir = v;
      paintPatch();
    });
  });
  const reset = $('#pfReset');
  if (reset)
    reset.addEventListener('click', () => {
      S.patchQ = '';
      S.patchKind = '全部';
      S.patchDir = '全部';
      paintPatch();
    });
  const sync = $('#pfSync');
  if (sync)
    sync.addEventListener('click', async () => {
      sync.disabled = true;
      sync.textContent = '同步中…';
      try {
        await api('/api/patch?what=refresh&force=1');
        await loadPatch(true);
        paintPatch();
      } catch (e) {
        alert('同步失败：' + (e.message || e));
      } finally {
        const b = $('#pfSync');
        if (b) {
          b.disabled = false;
          b.textContent = '⟳ 立即同步';
        }
      }
    });
}

async function viewPatch() {
  const main = $('#main');
  main.innerHTML =
    pageHead('版本动态', '官网更新公告与英雄 / 装备 / 铭文调整', '数据来源：王者荣耀官方网站') +
    loading('正在同步官网更新公告…');
  try {
    await loadPatch();
    paintPatch();
  } catch (e) {
    main.innerHTML =
      pageHead('版本动态', '官网更新公告与英雄 / 装备 / 铭文调整', '') + errorPanel(e.message || e);
  }
}

/* ================= 视图路由（由外壳驱动） ================= */
const VIEWS = { items: viewItems, runes: viewRunes, gradient: viewGradient, hero: viewHero, player: viewPlayer, gallery: viewGallery, patch: viewPatch };

/* ---------------- 数据同步 ----------------
 * store.js 命中缓存时会后台重验证，只有内容变化才派发 `kpl:data`；
 * 但各视图的内存缓存（S.playerCache / S.gradientCache / S.items …）不会因此失效，
 * 于是页面会一直停在旧数据上（典型表现：选手详情页切回来还是上一次的内容）。
 * 这里按视图登记它依赖的接口，收到更新通知就丢掉对应内存缓存并重渲染当前视图。 */
const VIEW_DEPS = {
  items: [/^\/api\/tools\/items/],
  runes: [/^\/api\/tools\/runes/],
  gradient: [/^\/api\/tools\/gradient/, /^\/api\/tools\/coverage/],
  hero: [/^\/api\/tools\/hero/, /^\/api\/tools\/coverage/],
  player: [/^\/api\/tools\/players/, /^\/api\/tools\/coverage/],
  gallery: [/^\/api\/tools\/skins/, /^\/api\/tools\/heroes/],
  patch: [/^\/api\/tools\/patch/, /^\/api\/tools\/news/, /^\/api\/patch/],
};
const CACHE_CLEAR = {
  items: () => { S.items = null; },
  runes: () => { S.runes = null; },
  gradient: (key) => {
    if (/^\/api\/tools\/coverage/.test(key)) { S.coverage = null; S.gradientCache = {}; }
    else S.gradientCache = {};
  },
  hero: () => { S.heroes = null; S.heroDetail = null; },
  player: (key) => {
    if (/^\/api\/tools\/coverage/.test(key)) { S.coverage = null; S.playerCache = {}; }
    else S.playerCache = {};
  },
  gallery: () => { S.skins = null; S.heroes = null; },
  patch: () => { S.patch = null; S.patchNews = null; },
};
let syncTimer = null;
function onDataUpdated(e) {
  const key = (e && e.detail && e.detail.key) || '';
  const view = S.view;
  if (!key || !view || !VIEW_DEPS[view]) return;
  if (!VIEW_DEPS[view].some((re) => re.test(key))) return;
  if (CACHE_CLEAR[view]) CACHE_CLEAR[view](key);
  clearTimeout(syncTimer);
  syncTimer = setTimeout(() => {
    if (S.view !== view) return;                // 期间已切走就不打扰
    const el = document.getElementById('pQ') || document.getElementById('gQ');
    const focus = el && document.activeElement === el ? captureFocus() : null;
    const p = VIEWS[view] && VIEWS[view]();
    Promise.resolve(p).then(() => restoreFocus(focus));
  }, 260);
}

/** 切换到某个工具子视图；param 可选（英雄 id / 赛事 id） */
function go(view, param) {
  if (!VIEWS[view]) view = 'items';
  S.view = view;
  if (param) {
    if (S.view === 'hero') S.heroId = param;
    if (S.view === 'gradient') S.gradientEvent = param;
    if (S.view === 'player') S.playerEvent = param;
  }
  return VIEWS[S.view](); // 视图多为 async，返回 Promise 便于外部等待
}

/** 首次挂载：绑定弹层等全局事件（只做一次） */
let mounted = false;
function mount() {
  if (mounted) return;
  mounted = true;
  const close = $('#lbClose');
  const box = $('#lightbox');
  if (close) close.addEventListener('click', closeLightbox);
  if (box)
    box.addEventListener('click', (e) => {
      if (e.target.id === 'lightbox') closeLightbox();
    });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') closeLightbox();
  });
  window.addEventListener('kpl:data', onDataUpdated);
}

window.KPLTools = {
  has: (v) => !!VIEWS[v],
  go,
  mount,
  views: Object.keys(VIEWS),
  /* 供离屏冒烟脚本（tools/test-tools-ui.js）调用内部函数 */
  _: { S, VIEWS, qTier, priceLabel, openSkin, openItem, openRune, runeFull, section, closeLightbox, viewPatch, paintPatch },
};
})();

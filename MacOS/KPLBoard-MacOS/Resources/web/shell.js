/* KPL 统一外壳
 *  - 左侧导航：比分看板 / 梯度榜 / 选手详情 / 装备 / 铭文 / 英雄详情 / 原画画廊 / 版本动态
 *  - 切换：同一时刻只显示一个视图，工具类视图交给 KPLTools 渲染
 *  - 排序：鼠标按住导航条目拖动即可换位（触摸端长按 300ms），顺序存入 localStorage
 */
(function () {
  'use strict';

  const I = {
    board:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M7 4h10v5a5 5 0 0 1-10 0V4z"/><path d="M7 6H4.5v1.5A3.5 3.5 0 0 0 8 11M17 6h2.5v1.5A3.5 3.5 0 0 1 16 11"/><path d="M12 14v3M8.5 20h7M10 17h4l.6 3h-5.2z"/></svg>',
    items:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h16v11a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V8z"/><path d="M8.5 8V5.5a1.5 1.5 0 0 1 1.5-1.5h4a1.5 1.5 0 0 1 1.5 1.5V8M10 12h4"/></svg>',
    runes:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2.8l7.6 4.4v8.8L12 20.4 4.4 16V7.2L12 2.8z"/><path d="M12 7.4l3.4 2v3.6L12 15l-3.4-2V9.4l3.4-2z"/><path d="M12 2.8v4.6M12 15v5.4M4.4 7.2l4.2 2.2M15.4 12.6l4.2 2.2M19.6 7.2l-4.2 2.2M8.6 12.6l-4.2 2.2"/></svg>',
    gradient:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 20h16"/><rect x="4.5" y="12" width="3.4" height="5"/><rect x="10.3" y="5" width="3.4" height="12"/><rect x="16.1" y="9" width="3.4" height="8"/></svg>',
    hero:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l7.5 3v6.2c0 4.3-3.1 7.6-7.5 9.3-4.4-1.7-7.5-5-7.5-9.3V6L12 3z"/><path d="M12 8.6l1.2 2.5 2.6.3-1.9 1.8.5 2.6-2.4-1.3-2.4 1.3.5-2.6-1.9-1.8 2.6-.3z"/></svg>',
    player:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="7.6" r="3.4"/><path d="M4.8 20c.7-3.7 3.6-5.7 7.2-5.7s6.5 2 7.2 5.7"/></svg>',
    gallery:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="2.4"/><path d="M3.4 15.4l4.6-3.7 3.6 2.7 2.8-1.9 6 4.5"/><circle cx="8.6" cy="9.4" r="1.3"/></svg>',
    patch:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3.2l2.1 4.3 4.7.7-3.4 3.3.8 4.7-4.2-2.2-4.2 2.2.8-4.7L5.2 8.2l4.7-.7L12 3.2z"/><path d="M18.6 19.4h-13"/></svg>',
    grip:
      '<svg viewBox="0 0 16 16" fill="currentColor"><circle cx="5" cy="4" r="1.35"/><circle cx="11" cy="4" r="1.35"/><circle cx="5" cy="8" r="1.35"/><circle cx="11" cy="8" r="1.35"/><circle cx="5" cy="12" r="1.35"/><circle cx="11" cy="12" r="1.35"/></svg>',
    move:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v18M3 12h18M12 3l-2.4 2.4M12 3l2.4 2.4M12 21l-2.4-2.4M12 21l2.4-2.4M3 12l2.4-2.4M3 12l2.4 2.4M21 12l-2.4-2.4M21 12l-2.4 2.4"/></svg>',
  };

  /* 默认展示顺序（与产品确认的顺序一致；用户拖过之后以 localStorage 为准） */
  const NAV = [
    { id: 'board', name: '比分看板', note: '实时比分 · 战绩榜 · 赛程', icon: I.board },
    { id: 'gradient', name: '梯度榜', note: '职业赛场英雄梯度', icon: I.gradient },
    { id: 'player', name: '选手详情', note: 'KDA · 经济 · 英雄池', icon: I.player },
    { id: 'items', name: '装备', note: '官方装备图鉴 · 可看详情', icon: I.items },
    { id: 'runes', name: '铭文', note: '红蓝绿铭文图鉴 · 可看详情', icon: I.runes },
    { id: 'hero', name: '英雄详情', note: '技能 · 属性 · 皮肤', icon: I.hero },
    { id: 'gallery', name: '原画画廊', note: '皮肤原画与品质', icon: I.gallery },
    { id: 'patch', name: '版本动态', note: '官网更新公告 · 英雄/装备/铭文调整', icon: I.patch },
  ];

  const TOOL_IDS = ['items', 'runes', 'gradient', 'hero', 'player', 'gallery', 'patch'];
  /* v2：默认顺序调整（装备榜→装备、梯度榜/选手详情前置）后，必须让旧用户的 v1 存档失效 */
  const ORDER_KEY = 'kpl.nav.order.v2';
  const TITLE = {
    board: 'KPL 赛事比分看板 · 2016-现在',
    items: '装备 · KPL 工具箱',
    runes: '铭文 · KPL 工具箱',
    gradient: '英雄梯度榜 · KPL 工具箱',
    hero: '英雄详情 · KPL 工具箱',
    player: '选手详情 · KPL 工具箱',
    gallery: '原画画廊 · KPL 工具箱',
    patch: '版本动态 · 官网更新公告与调整',
  };

  const $ = (s) => document.querySelector(s);
  const $$ = (s) => Array.from(document.querySelectorAll(s));

  let current = null;
  let suppressClick = false;

  /* ---------------- 导航渲染 ---------------- */
  const itemHTML = (n) =>
    `<div class="nav-item" data-id="${n.id}" role="button" tabindex="0" title="${n.name} · ${n.note}">` +
    `${n.icon}<span class="nm">${n.name}</span><span class="grip">${I.grip}</span></div>`;

  function buildNav() {
    const list = $('#nav');
    list.innerHTML = `<div class="nav-label">功能导航</div>` + NAV.map(itemHTML).join('');
    applyOrder(list);
  }

  /** 读取本地保存的顺序并重排 DOM */
  function applyOrder(list) {
    let saved = [];
    try {
      saved = JSON.parse(localStorage.getItem(ORDER_KEY) || '[]');
    } catch (_) {
      saved = [];
    }
    if (!Array.isArray(saved) || !saved.length) return;
    const els = new Map(Array.from(list.querySelectorAll('.nav-item')).map((el) => [el.dataset.id, el]));
    const rest = Array.from(els.values()).filter((el) => !saved.includes(el.dataset.id));
    saved.forEach((id) => {
      const el = els.get(id);
      if (el) list.appendChild(el);
    });
    rest.forEach((el) => list.appendChild(el));
  }

  function saveOrder() {
    try {
      const ids = $$('#nav .nav-item').map((el) => el.dataset.id);
      localStorage.setItem(ORDER_KEY, JSON.stringify(ids));
    } catch (_) {}
  }

  /* ---------------- 视图切换 ---------------- */
  function setView(id, param, silent) {
    if (!NAV.some((n) => n.id === id)) id = 'board';
    if (id === current && !param && !silent) return;
    current = id;

    $$('#nav .nav-item').forEach((el) => el.classList.toggle('on', el.dataset.id === id));

    const isBoard = id === 'board';
    $('#view-board').classList.toggle('on', isBoard);
    $('#view-tool').classList.toggle('on', !isBoard);

    if (!isBoard && window.KPLTools) window.KPLTools.go(id, param, silent);
    if (!isBoard) window.scrollTo(0, 0);

    document.title = TITLE[id] || TITLE.board;
    const want = param ? `#${id}/${param}` : `#${id}`;
    if (location.hash !== want) history.replaceState(null, '', want);
  }

  /* ---------------- 拖拽排序 ---------------- */
  function bindReorder(list) {
    let d = null;

    const onMove = (e) => {
      if (!d || e.pointerId !== d.pid) return;
      d.x = e.clientX;
      d.y = e.clientY;
      if (!d.active) {
        const dist = Math.hypot(d.x - d.sx, d.y - d.sy);
        if (d.touch && !d.armed) {
          // 触摸端：未长按成功前若发生位移，视为滚动
          if (dist > 9) {
            clearTimeout(d.timer);
            d = null;
            detach();
          }
          return;
        }
        if (dist < 4) return;
        start();
      }
      e.preventDefault();
      moveGhost();
      reorder();
    };

    const onUp = () => {
      if (!d) return;
      clearTimeout(d.timer);
      detach();
      if (d.active) {
        if (d.ghost) d.ghost.remove();
        d.el.classList.remove('dragging');
        document.body.classList.remove('is-sorting');
        suppressClick = true; // 本次点击是「拖拽结束」，不切换视图
        saveOrder();
      } else {
        d.el.classList.remove('armed');
      }
      d = null;
    };

    const onCancel = () => {
      if (!d) return;
      clearTimeout(d.timer);
      detach();
      if (d.active) {
        if (d.ghost) d.ghost.remove();
        d.el.classList.remove('dragging');
        document.body.classList.remove('is-sorting');
      } else {
        d.el.classList.remove('armed');
      }
      d = null;
    };

    const detach = () => {
      window.removeEventListener('pointermove', onMove);
      window.removeEventListener('pointerup', onUp);
      window.removeEventListener('pointercancel', onCancel);
    };

    function start() {
      d.active = true;
      const r = d.el.getBoundingClientRect();
      // 让浮层初始位置与条目完全重合，避免起手跳动
      d.ox = d.x - r.left;
      d.oy = d.y - r.top;
      const g = d.el.cloneNode(true);
      g.removeAttribute('data-id');
      g.classList.add('nav-ghost');
      g.style.width = `${r.width}px`;
      document.body.appendChild(g);
      d.ghost = g;
      d.el.classList.add('dragging');
      document.body.classList.add('is-sorting');
    }

    function moveGhost() {
      d.ghost.style.transform = `translate3d(${d.x - d.ox}px, ${d.y - d.oy}px, 0) rotate(-1.4deg) scale(1.03)`;
    }

    function reorder() {
      const others = $$('#nav .nav-item').filter((el) => el !== d.el);
      // 导航在窄屏会转成横向排布，按主轴方向比较
      const row = getComputedStyle(list).flexDirection === 'row';
      const pos = row ? d.x : d.y;
      let target = null;
      for (const o of others) {
        const r = o.getBoundingClientRect();
        const mid = row ? r.left + r.width / 2 : r.top + r.height / 2;
        if (pos < mid) {
          target = o;
          break;
        }
      }
      if (target) {
        if (target.previousElementSibling !== d.el) list.insertBefore(d.el, target);
      } else if (list.lastElementChild !== d.el) {
        list.appendChild(d.el);
      }
    }

    list.addEventListener('pointerdown', (e) => {
      const el = e.target.closest('.nav-item');
      if (!el || e.button > 0) return;
      const touch = e.pointerType !== 'mouse';
      d = { el, pid: e.pointerId, sx: e.clientX, sy: e.clientY, x: e.clientX, y: e.clientY, active: false, touch, armed: !touch, timer: 0 };
      if (touch) d.timer = setTimeout(() => { if (d && d.el === el) { d.armed = true; el.classList.add('armed'); } }, 300);
      window.addEventListener('pointermove', onMove, { passive: false });
      window.addEventListener('pointerup', onUp);
      window.addEventListener('pointercancel', onCancel);
    });
  }

  /* ---------------- 本地缓存状态条 ----------------
   * 在线且数据新鲜 → 隐藏
   * 离线 / 网络异常 → 红色「离线模式 · 正在显示本地缓存（更新于 …）」
   * 后台正在重验证 → 灰色「正在联网更新…」
   */
  function bindCacheBar() {
    if (!window.KPLStore) return;
    const bar = $('#cacheBar');
    if (!bar) return;
    const ico = $('#cacheIco');
    const text = $('#cacheText');
    const time = $('#cacheTime');

    const fmt = (t) =>
      t
        ? new Date(t).toLocaleString('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false })
        : '—';

    const paint = () => {
      const st = window.KPLStore.status;
      const stats = window.KPLStore._stats || { count: 0 };
      const served = st.servedFromCache;
      const offline = !st.online;
      let cls = '';
      let msg = '';
      let show = true;

      if (offline) {
        cls = 'offline';
        ico.textContent = '⛔';
        msg = `离线模式 · 正在显示本地缓存（${stats.count} 项）`;
      } else if (st.lastError && served) {
        cls = 'offline';
        ico.textContent = '⚠';
        msg = `接口异常 · 已回落本地缓存（${stats.count} 项）`;
      } else if (st.lastError) {
        cls = 'stale';
        ico.textContent = '⚠';
        msg = `数据获取失败：${st.lastError}`;
      } else if (st.revalidating) {
        cls = 'stale';
        ico.textContent = '⟳';
        msg = '正在联网更新本地缓存…';
      } else {
        show = false; // 一切正常：不打扰
      }

      bar.className = 'cache-bar' + (cls ? ' ' + cls : '');
      bar.hidden = !show;
      if (show) {
        text.textContent = msg;
        time.textContent = served ? `更新于 ${fmt(stats.newest || st.fetchedAt)}` : '';
      }
    };

    const refreshStats = async () => {
      try {
        window.KPLStore._stats = await window.KPLStore.getStats();
      } catch (_) {}
      paint();
    };

    window.addEventListener('kpl:status', paint);
    // 后台重验证拿到新数据 → 让当前工具视图用新数据重渲染。
    // 比分看板有自己的刷新定时器，这里不动它，避免与定时器互相触发。
    let lastDataAt = 0;
    window.addEventListener('kpl:data', () => {
      if (current === 'board') return;
      if (Date.now() - lastDataAt < 8000) return; // 限频，避免频繁重排
      if (!window.KPLTools) return;
      lastDataAt = Date.now();
      window.KPLTools.go(current, '');
    });

    const retry = $('#cacheRetry');
    if (retry)
      retry.addEventListener('click', async () => {
        retry.disabled = true;
        retry.textContent = '正在重试…';
        try {
          await window.KPLStore.refreshAll();
        } finally {
          retry.disabled = false;
          retry.textContent = '重试联网';
          refreshStats();
        }
      });

    const clr = $('#cacheClear');
    if (clr)
      clr.addEventListener('click', async () => {
        await window.KPLStore.clear();
        location.reload();
      });

    window.KPLStore._ready.then(refreshStats).catch((e) => {
      try { console.warn('[KPLShell] store init:', e && e.message ? e.message : e); } catch (_) {}
    });
    setInterval(refreshStats, 15000);
  }

  /* ---------------- 启动 ---------------- */
  function boot() {
    buildNav();
    bindReorder($('#nav'));
    bindCacheBar();

    $('#nav').addEventListener('click', (e) => {
      if (suppressClick) {
        suppressClick = false;
        e.preventDefault();
        e.stopPropagation();
        return;
      }
      const el = e.target.closest('.nav-item');
      if (el) setView(el.dataset.id);
    });

    $('#nav').addEventListener('keydown', (e) => {
      if (e.key !== 'Enter' && e.key !== ' ') return;
      const el = e.target.closest('.nav-item');
      if (el) {
        e.preventDefault();
        setView(el.dataset.id);
      }
    });

    // 主题切换（跟随系统 / 浅色 / 深色）
    if (window.KPLTheme) window.KPLTheme.render($('#themeSwitch'));

    const reset = $('#navReset');
    if (reset) {
      reset.addEventListener('click', () => {
        try {
          localStorage.removeItem(ORDER_KEY);
          localStorage.removeItem('kpl.nav.order.v1'); // 清掉旧版本留下来的顺序存档
        } catch (_) {}
        buildNav();
      });
    }

    if (window.KPLTools) window.KPLTools.mount();

    const raw = (location.hash || '').replace(/^#/, '');
    const [id, param] = raw.split('/');
    setView(NAV.some((n) => n.id === id) ? id : 'board', param || '');
    // hash 变化（外部链接/后退）时同步
    window.addEventListener('hashchange', () => {
      const [h, p] = (location.hash || '').replace(/^#/, '').split('/');
      if (h && h !== current) setView(h, p || '');
    });
  }

  window.KPLShell = { setView, NAV, TOOL_IDS };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();

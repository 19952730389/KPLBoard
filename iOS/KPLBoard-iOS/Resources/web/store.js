/* KPL Agent · 本地数据持久化层（KPLStore）
 * ============================================================================
 * 目标：页面加载优先用本地缓存渲染（断网也能完整查看），联网后再用接口数据更新缓存。
 *
 * 一、缓存什么
 *   只缓存 **GET /api/** 且响应体 `{ok:true}` 的 JSON。图片（/api/tools/img）不缓存
 *   （二进制且已由浏览器 HTTP 缓存承担），错误响应、非 JSON 一律不写。
 *
 * 二、键与结构
 *   键 = 规范化后的请求路径（去掉 t/_/_t 这类防缓存参数、其余 query 按字典序排序），
 *   因此 `/api/board?event=1084&t=173...` 与 `/api/board?event=1084` 命中同一条。
 *   值 = { k: 键, v: 响应体, at: 写入毫秒时间戳, n: 命中次数 }
 *   localStorage 兜底时值形如 { v, at }（同样带结构版本前缀）。
 *
 * 三、写入时机
 *   1) 网络请求成功且 ok:true → 立即写（写穿）；
 *   2) 后台重验证拿到「内容有变化」的结果 → 覆盖写；
 *   3) 启动与每次写入后按容量策略淘汰（见五）。
 *
 * 四、读取与更新策略（stale-while-revalidate）
 *   命中缓存 → **立即返回渲染**，同时后台按 TTL 判断是否需要重验证：
 *     · 未过期（TTL 内）→ 不请求网络；
 *     · 已过期 → 后台静默请求；内容变化才覆盖并派发 `kpl:data` 让视图重渲染。
 *   未命中缓存 → 直接请求网络，失败则抛出（视图显示错误态）。
 *   网络请求进行中时同一键的重复请求会被合并（in-flight 去重），最小重验证间隔 5s。
 *
 * 五、淘汰与失效
 *   · 结构版本 SCHEMA 变更 → 启动时整体丢弃（避免旧字段污染新视图）；
 *   · 条目超过 MAX_AGE(30 天) 或 总数 > MAX_ENTRIES(300) 或 总体积 > MAX_BYTES(12MB) → 淘汰最旧的；
 *   · 用户点「清空缓存」→ 全部删除并重载。
 *
 * 六、对外接口
 *   KPLStore.api(path, opt)   —— 带缓存的数据请求，返回响应体；opt.force 强制走网络
 *   KPLStore.getStats()       —— {backend, count, bytes, oldest, newest}
 *   KPLStore.clear()          —— 清空
 *   KPLStore.status           —— {online, cached, savedAt, fetching, error}
 *   事件：window 'kpl:status'（状态变化）、'kpl:data'（某键数据被后台更新，detail.key）
 * ========================================================================== */
(function () {
  'use strict';

  const SCHEMA = 1; // 缓存结构版本：改动数据结构时 +1，旧缓存自动失效
  const DB_NAME = 'kpl-agent';
  const DB_STORE = 'api';
  const LS_PREFIX = `kpl.cache.v${SCHEMA}.`;
  const LS_MAX_BYTES = 200 * 1024; // localStorage 单条上限（超出则只进内存/IDB）
  const MAX_AGE = 30 * 24 * 3600e3;
  const MAX_ENTRIES = 300;
  const MAX_BYTES = 12 * 1024 * 1024;
  const MIN_REVALIDATE_GAP = 5e3;

  /* 各接口的「新鲜期」：期内直接用缓存、不打网络 */
  const TTL_RULES = [
    [/^\/api\/board/, 8e3],
    [/^\/api\/events/, 5 * 60e3],
    [/^\/api\/health/, 15e3],
    [/^\/api\/tools\/(heroes|items|runes|hero)/, 12 * 3600e3],
    [/^\/api\/tools\/(skins|coverage)/, 6 * 3600e3],
    [/^\/api\/tools\/(players|gradient|teams)/, 30 * 60e3],
    [/^\/api\/patch/, 30 * 60e3],
  ];
  const TTL_DEFAULT = 5 * 60e3;

  const VOLATILE = ['t', '_', '_t', 'timestamp', 'nocache', '_f'];

  const status = {
    online: typeof navigator === 'undefined' ? true : navigator.onLine !== false,
    backend: 'memory',
    fetchedAt: 0, // 最近一次成功走网络的时刻
    servedFromCache: false, // 最近一次视图数据是否来自缓存
    revalidating: false,
    lastError: '',
  };

  /* ---------------- 存储后端 ---------------- */
  let idb = null;
  let idbFailed = false;
  const mem = new Map();
  const inflight = new Map();
  const lastRevalidate = new Map();

  function idbOpen() {
    if (idb || idbFailed) return Promise.resolve(idb);
    return new Promise((resolve) => {
      let req;
      try {
        if (typeof indexedDB === 'undefined') throw new Error('no-indexeddb');
        req = indexedDB.open(DB_NAME, SCHEMA);
      } catch (_) {
        idbFailed = true;
        return resolve(null);
      }
      req.onupgradeneeded = () => {
        const db = req.result;
        if (db.objectStoreNames.contains(DB_STORE)) db.deleteObjectStore(DB_STORE);
        db.createObjectStore(DB_STORE, { keyPath: 'k' });
      };
      req.onsuccess = () => {
        idb = req.result;
        status.backend = 'indexeddb';
        resolve(idb);
      };
      req.onerror = req.onblocked = () => {
        idbFailed = true;
        status.backend = lsOk() ? 'localstorage' : 'memory';
        resolve(null);
      };
    });
  }

  function lsOk() {
    try {
      localStorage.setItem('kpl.probe', '1');
      localStorage.removeItem('kpl.probe');
      return true;
    } catch (_) {
      return false;
    }
  }

  function tx(mode) {
    return idb.transaction(DB_STORE, mode).objectStore(DB_STORE);
  }

  async function rawGet(key) {
    const db = await idbOpen();
    if (db) {
      return new Promise((resolve) => {
        const r = tx('readonly').get(key);
        r.onsuccess = () => resolve(r.result || null);
        r.onerror = () => resolve(null);
      });
    }
    if (lsOk()) {
      try {
        const s = localStorage.getItem(LS_PREFIX + key);
        if (s) return JSON.parse(s);
      } catch (_) {}
    }
    return mem.get(key) || null;
  }

  async function rawAll() {
    const db = await idbOpen();
    if (db) {
      return new Promise((resolve) => {
        const r = tx('readonly').getAll();
        r.onsuccess = () => resolve(r.result || []);
        r.onerror = () => resolve([]);
      });
    }
    if (lsOk()) {
      const out = [];
      try {
        for (let i = 0; i < localStorage.length; i++) {
          const k = localStorage.key(i);
          if (k && k.startsWith(LS_PREFIX)) {
            const rec = JSON.parse(localStorage.getItem(k));
            out.push(Object.assign({ k: k.slice(LS_PREFIX.length) }, rec));
          }
        }
      } catch (_) {}
      if (out.length) return out;
    }
    return [...mem.values()];
  }

  async function rawPut(rec) {
    mem.set(rec.k, rec);
    const db = await idbOpen();
    if (db) {
      await new Promise((resolve) => {
        const r = tx('readwrite').put(rec);
        r.onsuccess = r.onerror = () => resolve();
      });
      return;
    }
    if (lsOk()) {
      try {
        const s = JSON.stringify(rec);
        if (s.length * 2 <= LS_MAX_BYTES) localStorage.setItem(LS_PREFIX + rec.k, s);
      } catch (_) {}
    }
  }

  async function rawDel(key) {
    mem.delete(key);
    const db = await idbOpen();
    if (db) {
      await new Promise((resolve) => {
        const r = tx('readwrite').delete(key);
        r.onsuccess = r.onerror = () => resolve();
      });
      return;
    }
    if (lsOk()) {
      try {
        localStorage.removeItem(LS_PREFIX + key);
      } catch (_) {}
    }
  }

  async function rawClear() {
    mem.clear();
    const db = await idbOpen();
    if (db) {
      await new Promise((resolve) => {
        const r = tx('readwrite').clear();
        r.onsuccess = r.onerror = () => resolve();
      });
    }
    if (lsOk()) {
      try {
        for (let i = localStorage.length - 1; i >= 0; i--) {
          const k = localStorage.key(i);
          if (k && k.startsWith(LS_PREFIX)) localStorage.removeItem(k);
        }
      } catch (_) {}
    }
  }

  /* ---------------- 淘汰策略 ---------------- */
  let pruneAt = 0;
  async function prune(force) {
    if (!force && Date.now() - pruneAt < 60e3) return;
    pruneAt = Date.now();
    const all = await rawAll();
    const now = Date.now();
    for (const r of all) {
      if (!r || !r.k || now - (r.at || 0) > MAX_AGE) await rawDel(r ? r.k : '');
    }
    // 按写入时间从旧到新，超条数或超体积就从最旧的开始删
    const live = all.filter((r) => r && r.k && now - (r.at || 0) <= MAX_AGE).sort((a, b) => (a.at || 0) - (b.at || 0));
    let bytes = live.reduce((s, r) => s + size(r), 0);
    let over = live.length - MAX_ENTRIES;
    while (live.length && (over > 0 || bytes > MAX_BYTES)) {
      const victim = live.shift();
      bytes -= size(victim);
      over--;
      await rawDel(victim.k);
    }
  }
  const size = (r) => {
    try {
      return JSON.stringify(r.v == null ? null : r.v).length * 2;
    } catch (_) {
      return 0;
    }
  };

  /* ---------------- 键规范化 ---------------- */
  function normKey(path) {
    try {
      const u = new URL(path, location.origin);
      VOLATILE.forEach((k) => u.searchParams.delete(k));
      const pairs = [...u.searchParams.entries()].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
      const qs = pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&');
      return u.pathname + (qs ? '?' + qs : '');
    } catch (_) {
      return String(path);
    }
  }
  function ttlOf(key) {
    for (const [re, ms] of TTL_RULES) if (re.test(key)) return ms;
    return TTL_DEFAULT;
  }
  const cacheable = (key) => /^\/api\//.test(key) && !/^\/api\/tools\/img/.test(key);

  /* ---------------- 生命周期事件 ---------------- */
  function emitStatus() {
    try {
      window.dispatchEvent(new CustomEvent('kpl:status', { detail: Object.assign({}, status) }));
    } catch (_) {}
  }
  function emitData(key) {
    try {
      window.dispatchEvent(new CustomEvent('kpl:data', { detail: { key } }));
    } catch (_) {}
  }
  if (typeof window !== 'undefined') {
    window.addEventListener('online', () => {
      status.online = true;
      status.lastError = '';
      emitStatus();
      revalidateVisible();
    });
    window.addEventListener('offline', () => {
      status.online = false;
      emitStatus();
    });
  }

  /* ---------------- 网络 ---------------- */
  /* force 请求的穿透方式（双通道，任一生效即可）：
   * 1) X-KPL-Force 头 —— 自定义 scheme 的 task 不保证保留 fetch 的自定义头，故只是加分项；
   * 2) URL 追加 &_f=1 —— _f 在 VOLATILE 里，不进缓存键，Swift 侧据此绕过
   *    BoardStore 20s 实时 TTL / PatchStore 内嵌缓存：
   *    用户手动刷新必须立刻拿到最新数据（比赛刚打完点刷新不能还看到旧比分）。 */
  function forcePath(path, force) {
    if (!force) return path;
    if (/[?&]_f=1(&|$)/.test(path)) return path;
    return path + (path.includes('?') ? '&' : '?') + '_f=1';
  }
  async function fetchJson(path, force) {
    const res = await fetch(path, {
      cache: 'no-store',
      headers: force ? { 'X-KPL-Force': '1' } : undefined,
    });
    let json = null;
    try {
      json = await res.json();
    } catch (_) {
      throw new Error(`HTTP ${res.status}`);
    }
    if (!res.ok || !json || json.ok === false) throw new Error((json && json.error) || `HTTP ${res.status}`);
    return json;
  }

  /** 后台重验证：拿到内容变化才覆盖缓存并通知视图 */
  function revalidate(key, path) {
    if (inflight.has(key)) return inflight.get(key);
    if (!status.online) return Promise.resolve(null);
    if (Date.now() - (lastRevalidate.get(key) || 0) < MIN_REVALIDATE_GAP) return Promise.resolve(null);
    lastRevalidate.set(key, Date.now());
    status.revalidating = true;
    emitStatus();
    const p = fetchJson(path)
      .then(async (json) => {
        const old = await rawGet(key);
        const changed = !old || JSON.stringify(old.v) !== JSON.stringify(json);
        await rawPut({ k: key, v: json, at: Date.now(), n: (old && old.n) || 0 });
        status.fetchedAt = Date.now();
        status.lastError = '';
        prune();
        if (changed) emitData(key);
        return json;
      })
      .catch((e) => {
        status.lastError = e.message || String(e);
        return null;
      })
      .finally(() => {
        inflight.delete(key);
        status.revalidating = inflight.size > 0;
        emitStatus();
      });
    inflight.set(key, p);
    return p;
  }

  let visible = [];
  function revalidateVisible() {
    visible.forEach(({ key, path }) => revalidate(key, path));
  }

  /** 带缓存的数据请求：返回响应体本身（与旧的 api() 调用方兼容） */
  async function api(path, opt) {
    opt = opt || {};
    const key = normKey(path);
    const canCache = cacheable(key);
    if (visible.length) visible = visible.filter((v) => Date.now() - v.at < 120e3);
    if (canCache) visible.push({ key, path, at: Date.now() });

    const rec = canCache ? await rawGet(key) : null;

    if (!opt.force && rec) {
      const age = Date.now() - (rec.at || 0);
      status.servedFromCache = true;
      emitStatus();
      if (age > ttlOf(key) || opt.revalidate) revalidate(key, path);
      return rec.v;
    }

    // 无缓存 / 强制刷新 → 走网络（force 时带 X-KPL-Force 头，见 fetchJson 注释）
    if (!status.online && rec) return rec.v;
    try {
      const json = await fetchJson(forcePath(path, opt.force), true);
      if (canCache) {
        await rawPut({ k: key, v: json, at: Date.now(), n: 1 });
        prune();
      }
      status.fetchedAt = Date.now();
      status.servedFromCache = false;
      status.lastError = '';
      emitStatus();
      return json;
    } catch (e) {
      status.lastError = e.message || String(e);
      emitStatus();
      if (rec) {
        status.servedFromCache = true;
        return rec.v; // 网络失败但有旧缓存 → 降级返回，页面仍可完整查看
      }
      throw e;
    }
  }

  /* ---------------- 统计 / 维护 ---------------- */
  async function getStats() {
    const all = await rawAll();
    const bytes = all.reduce((s, r) => s + size(r), 0);
    const at = all.map((r) => r.at || 0).filter(Boolean);
    return {
      backend: status.backend,
      count: all.length,
      bytes,
      oldest: at.length ? Math.min(...at) : 0,
      newest: at.length ? Math.max(...at) : 0,
      keys: all.map((r) => r.k).sort(),
    };
  }
  async function clear() {
    await rawClear();
    await idbOpen();
  }

  /** 强制刷新当前页面用到的全部接口（用户点「立即更新」） */
  async function refreshAll() {
    const list = visible.slice();
    await Promise.all(list.map((v) => revalidate(v.key, v.path)));
    return list.length;
  }

  window.KPLStore = {
    SCHEMA,
    api,
    status,
    normKey,
    ttlOf,
    getStats,
    clear,
    refreshAll,
    revalidate,
    _ready: idbOpen().then(() => prune(true)),
  };
})();

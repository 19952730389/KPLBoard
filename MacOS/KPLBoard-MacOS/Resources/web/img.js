/* KPL 数据台 · 图片加载统一入口（app.js / tools.js 共用）
 *
 * 解决的问题：
 *  1) 缓存/复用策略不一致 —— 有的图走本地代理、有的直连；统一为「白名单域名一律走 /api/tools/img」，
 *     既能绕过防盗链，又能命中服务端内存缓存与浏览器长缓存；
 *  2) 加载慢 —— 按「显示尺寸」向支持腾讯云 CI 的 CDN 要缩略图（皮肤原画 765KB → 45KB）；
 *     官方老 CDN（game.gtimg.cn）不支持 CI，自动跳过，不做无效参数；
 *  3) 布局抖动 —— 统一输出 width/height 与 loading/decoding，图未到时先占位，不跳版；
 *  4) 裂图（蓝问号） —— 加载失败先换备用地址（itemimg 缺图时换 itemimgo），仍失败则落到
 *     零请求的内联 SVG 占位图（带首字），数据为空时同样给占位，不再出现浏览器默认裂图。
 *
 * 用法：
 *   KPLImg.tag(url, { w, h, fb, alt, cls, eager })   → <img> 字符串
 *   KPLImg.url(url, { w })                           → 最终请求地址
 *   KPLImg.ph('后', 46, 46)                          → 占位图 data URI
 */
(function () {
  'use strict';

  /* 允许走本地代理的官方域名（与 server.js 白名单保持一致） */
  const PROXY_HOSTS = [
    'game.gtimg.cn',
    'pvp.qq.com',
    'game-1255653016.file.myqcloud.com',
    'static.wanplus.cn',
  ];

  /* 支持腾讯云 CI 图片处理（imageMogr2/thumbnail）的域名 */
  const CI_HOSTS = ['game-1255653016.file.myqcloud.com', 'static.wanplus.cn'];

  const hostOf = (u) => {
    const m = /^https?:\/\/([^/]+)\//.exec(u || '');
    return m ? m[1] : '';
  };

  const state = { loaded: 0, failed: [], requested: 0 };

  /* ---------- 地址 ---------- */

  /** 按显示尺寸拼缩略图参数（仅对支持 CI 的域名生效） */
  function ci(u, w) {
    if (!u || !w || u.indexOf('?') >= 0) return u;
    if (CI_HOSTS.indexOf(hostOf(u)) < 0) return u;
    return `${u}?imageMogr2/thumbnail/${w}x`;
  }

  /** 最终请求地址：先按尺寸取缩略图，再统一走本地代理 */
  function url(u, o) {
    if (!u) return '';
    const w =
      o && o.w && o.ci !== false ? Math.min(1200, Math.max(48, Math.ceil((o.w * 2) / 32) * 32)) : 0;
    const full = ci(u, w);
    if (PROXY_HOSTS.indexOf(hostOf(full)) >= 0) return `/api/tools/img?u=${encodeURIComponent(full)}`;
    return full;
  }

  /* ---------- 占位图（内联 SVG，零请求） ---------- */

  /* 属性上下文专用转义：必须同时转义 `"` 与 `'`，否则 alt / data-* 里的上游队名、
     英雄名、皮肤名可以闭合属性注入事件处理器（如 `A" onerror=…`）。
     与 app.js / tools.js 的 esc() 保持一致：& < > " '。 */
  const xesc = (s) =>
    String(s == null ? '' : s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');

  /** text 传名字首字则画字，否则画一个「无图」图形 */
  function ph(text, w, h) {
    const W = Math.max(16, Math.round(w || 64));
    const H = Math.max(16, Math.round(h || W));
    const glyph = text ? String(text).trim().slice(0, 1) : '';
    const r = Math.round(Math.min(W, H) * 0.22);
    const inner = glyph
      ? `<text x="${W / 2}" y="${H / 2}" text-anchor="middle" dominant-baseline="central" font-family="PingFang SC,Microsoft YaHei,sans-serif" font-size="${Math.round(
          Math.min(W, H) * 0.46
        )}" font-weight="700" fill="#5d6780">${xesc(glyph)}</text>`
      : `<g fill="#3f4859"><path d="M${W * 0.28} ${H * 0.62}l${W * 0.14} -${H * 0.17}l${W * 0.1} ${H * 0.11}l${W * 0.09} -${H * 0.1}l${W * 0.11} ${H * 0.12}v${H * 0.09}H${W * 0.28}z"/><circle cx="${W * 0.37}" cy="${H * 0.34}" r="${Math.min(W, H) * 0.06}"/></g>`;
    const svg =
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMid slice">` +
      `<rect width="${W}" height="${H}" fill="#141a29"/>` +
      `<rect x=".75" y=".75" width="${W - 1.5}" height="${H - 1.5}" rx="${r}" fill="none" stroke="#26304a" stroke-width="1.5"/>` +
      inner +
      `</svg>`;
    return `data:image/svg+xml,${encodeURIComponent(svg)}`;
  }

  /* ---------- 失败兜底备用地址 ---------- */

  /** 装备图标：老路径 itemimg 缺图时换官方新路径 itemimgo；缩略图失败则退回原图 */
  function altUrl(u) {
    if (!u) return '';
    const it = /^https:\/\/game\.gtimg\.cn\/images\/yxzj\/img201606\/itemimg\/(\d+)\.(?:jpg|png)$/.exec(u);
    if (it) return `https://game.gtimg.cn/images/yxzj/img201606/itemimgo/${it[1]}.png`;
    if (u.indexOf('?imageMogr2') > 0) return u.replace(/\?.*$/, ''); // 缩略图参数异常 → 退回原图
    return '';
  }

  /* ---------- 渲染 ---------- */

  function tag(u, o) {
    o = o || {};
    const w = o.w || 0;
    const h = o.h || w;
    const cls = `im${o.cls ? ' ' + o.cls : ''}`;
    const alt = xesc(o.alt);
    const fb = o.fb == null ? '' : o.fb;
    const size = `${w ? ` width="${w}"` : ''}${h ? ` height="${h}"` : ''}`;
    const extra = o.extra || '';
    /* 数据为空：直接给占位图，不再输出空的 img */
    if (!u) {
      return `<img class="${cls} im-bad" src="${ph(fb, w || 64, h || w || 64)}" alt="${alt}"${size}${extra}>`;
    }
    state.requested += 1;
    const dataAlt = o.altUrl ? ` data-alt="${xesc(o.altUrl)}"` : '';
    return (
      `<img class="${cls}" src="${url(u, o)}" alt="${alt}"${size}` +
      ` loading="${o.eager ? 'eager' : 'lazy'}" decoding="async"` +
      ` data-src="${xesc(u)}" data-fb="${xesc(fb)}" data-w="${w}" data-h="${h}"${dataAlt}${extra}>`
    );
  }

  /* ---------- load / error 统一接管（捕获阶段，可覆盖不冒泡的 load/error） ---------- */

  function ok(el) {
    if (el.dataset.done === '1' || el.classList.contains('on')) return;
    el.classList.add('on');
    state.loaded += 1;
  }

  function fail(el) {
    if (el.dataset.done === '1') return;
    /* 第一次失败：尝试备用地址（调用方指定的 data-alt，或按规则推导） */
    if (el.dataset.retry !== '1') {
      const alt = el.dataset.alt || altUrl(el.dataset.src || '');
      if (alt) {
        el.dataset.retry = '1';
        el.dataset.src = alt;
        el.src = url(alt, { w: +el.dataset.w || 0 });
        return;
      }
    }
    /* 备用也失败：落内联占位图 */
    el.dataset.done = '1';
    el.classList.add('on', 'im-bad');
    if (!el.title) el.title = '该图官方 CDN 暂不可用';
    el.src = ph(el.dataset.fb || '', +el.dataset.w || 64, +el.dataset.h || +el.dataset.w || 64);
    /* 仅做诊断用途，上限 200 条：长会话里图片失败可能上百次，不封顶会缓慢泄漏 */
    if (state.failed.length < 200) state.failed.push(el.dataset.src || '(空)');
  }

  function install() {
    /* load / error 不冒泡，但捕获阶段一定能到目标元素 */
    document.addEventListener('load', (e) => {
      const t = e.target;
      if (t && t.tagName === 'IMG') ok(t);
    }, true);
    document.addEventListener('error', (e) => {
      const t = e.target;
      if (t && t.tagName === 'IMG') fail(t);
    }, true);
  }
  install();

  window.KPLImg = {
    tag,
    url,
    ci,
    ph,
    altUrl,
    ok,
    fail,
    hostOf,
    PROXY_HOSTS,
    CI_HOSTS,
    state,
    reset() {
      state.loaded = 0;
      state.failed.length = 0;
      state.requested = 0;
    },
  };
})();

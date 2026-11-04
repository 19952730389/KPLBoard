/* KPL 看板 · 主题控制器
 * 三档：auto（跟随系统，默认） / light / dark
 *  - auto：监听 prefers-color-scheme，系统切换时实时跟随
 *  - 选择结果存入 localStorage，跨会话保留
 *  - 在 <head> 同步执行，先于样式应用，避免刷新时闪白/闪黑
 */
(function () {
  'use strict';
  var KEY = 'kpl.theme.v1';
  var mq = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;

  function read() {
    try {
      var v = localStorage.getItem(KEY);
      if (v === 'light' || v === 'dark' || v === 'auto') return v;
    } catch (_) {}
    return 'auto';
  }
  function save(v) {
    try {
      localStorage.setItem(KEY, v);
    } catch (_) {}
  }
  function resolve(mode) {
    if (mode === 'light') return 'light';
    if (mode === 'dark') return 'dark';
    return mq && mq.matches ? 'dark' : 'light';
  }
  function apply(mode) {
    var t = resolve(mode);
    document.documentElement.setAttribute('data-theme', t);
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute('content', t === 'dark' ? '#0b0e17' : '#f2f5fb');
    return t;
  }

  apply(read());

  // 系统主题变化时，只有 auto 档才跟随
  if (mq) {
    var onChange = function () {
      if (read() === 'auto') apply('auto');
    };
    if (mq.addEventListener) mq.addEventListener('change', onChange);
    else if (mq.addListener) mq.addListener(onChange);
  }

  var ICON = {
    auto:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="13" rx="2.2"/><path d="M8.5 20.5h7M12 17v3.5"/><path d="M12 4v13"/><path d="M12 7.6h4.6M12 7.6H7.4"/></svg>',
    light:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 2.6v2.2M12 19.2v2.2M2.6 12h2.2M19.2 12h2.2M5.4 5.4l1.6 1.6M17 17l1.6 1.6M18.6 5.4L17 7M7 17l-1.6 1.6"/></svg>',
    dark:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20 14.2A8.4 8.4 0 0 1 9.8 4a8.4 8.4 0 1 0 10.2 10.2z"/></svg>',
  };
  var LABEL = { auto: '跟随系统', light: '浅色', dark: '深色' };
  var ORDER = ['auto', 'light', 'dark'];

  /** 在指定容器内渲染切换控件；返回更新高亮的函数 */
  function render(host) {
    if (!host) return function () {};
    host.className = 'theme-switch';
    host.setAttribute('role', 'group');
    host.setAttribute('aria-label', '主题');
    host.innerHTML = ORDER.map(function (m) {
      return (
        '<button type="button" data-mode="' + m + '" title="' + LABEL[m] + '" aria-pressed="false">' +
        ICON[m] + '<span class="lb">' + LABEL[m] + '</span></button>'
      );
    }).join('');
    var btns = host.querySelectorAll('button');
    function sync() {
      var cur = read();
      for (var i = 0; i < btns.length; i++) {
        var on = btns[i].dataset.mode === cur;
        btns[i].classList.toggle('on', on);
        btns[i].setAttribute('aria-pressed', on ? 'true' : 'false');
      }
    }
    host.addEventListener('click', function (e) {
      var b = e.target.closest('button[data-mode]');
      if (!b) return;
      var m = b.dataset.mode;
      save(m);
      apply(m);
      sync();
    });
    sync();
    return sync;
  }

  window.KPLTheme = { get: read, set: function (v) { save(v); apply(v); }, apply: apply, render: render, LABEL: LABEL };
})();

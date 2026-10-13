/* 智夜：从 backgrounddl-ios/BrowserView.swift 的自适应深色算法独立移植。
   只改网页样式，不监听输入、不发送请求、不读取或上传网页内容。 */
(() => {
  "use strict";
  const api = globalThis.browser || globalThis.chrome;
  if (!api || !api.storage || !api.storage.local) return;
  if (location.protocol !== "http:" && location.protocol !== "https:") return;

  const CLASS_NAME = "zhiyeyue-adaptive-dark";
  const STYLE_ID = "zhiyeyue-adaptive-dark-style";
  const hostname = location.hostname.toLowerCase();
  const prefersDark = matchMedia("(prefers-color-scheme: dark)");
  let settings = { mode: "auto", excludedSites: {} };
  let observer = null;
  let updateTimer = null;
  let initialized = false;

  function installStyle() {
    const root = document.documentElement;
    if (!root || document.getElementById(STYLE_ID)) return;
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = [
      "html." + CLASS_NAME + "{filter:invert(1) hue-rotate(180deg)!important;background:#fff!important;color-scheme:light!important;}",
      "html." + CLASS_NAME + " img,",
      "html." + CLASS_NAME + " video,",
      "html." + CLASS_NAME + " canvas,",
      "html." + CLASS_NAME + " svg{filter:invert(1) hue-rotate(180deg)!important;}"
    ].join("\n");
    (document.head || root).appendChild(style);
  }

  function brightness(cssColor) {
    if (!cssColor || cssColor === "transparent") return null;
    const m = cssColor.match(/rgba?\(\s*(\d+)[,\s]+(\d+)[,\s]+(\d+)(?:\s*[,/]\s*([\d.]+))?\s*\)/i);
    if (!m) return null;
    if (m[4] !== undefined && Number(m[4]) < 0.15) return null;
    return 0.2126 * Number(m[1]) + 0.7152 * Number(m[2]) + 0.0722 * Number(m[3]);
  }

  function effectiveBrightness(start) {
    let el = start;
    for (let depth = 0; el && depth < 12; depth++, el = el.parentElement) {
      if (el.nodeType !== Node.ELEMENT_NODE) continue;
      const v = brightness(getComputedStyle(el).backgroundColor);
      if (v !== null) return v;
    }
    return 255;
  }

  function pageLooksBright() {
    if (!document.body) return false;
    const w = Math.max(1, innerWidth);
    const h = Math.max(1, innerHeight);
    const positions = [
      [0.08, 0.08], [0.50, 0.08], [0.92, 0.08],
      [0.08, 0.40], [0.50, 0.40], [0.92, 0.40],
      [0.08, 0.80], [0.50, 0.80], [0.92, 0.80]
    ];
    let bright = 0, total = 0;
    for (const [x, y] of positions) {
      const element = document.elementFromPoint(Math.min(w - 1, Math.floor(w * x)), Math.min(h - 1, Math.floor(h * y)));
      if (!element) continue;
      total++;
      if (effectiveBrightness(element) >= 165) bright++;
    }
    return total ? bright >= Math.ceil(total * 0.55) : effectiveBrightness(document.body) >= 165;
  }

  function disabledHere() {
    const domains = settings.excludedSites;
    return !!(domains && Object.prototype.hasOwnProperty.call(domains, hostname) && domains[hostname]);
  }

  function applyTheme() {
    updateTimer = null;
    if (!document.documentElement) return;
    installStyle();
    const mode = settings.mode;
    const on = !disabledHere() &&
      (mode === "always" || (mode === "auto" && prefersDark.matches && pageLooksBright()));
    document.documentElement.classList.toggle(CLASS_NAME, on);
  }

  function schedule(delay = 60) {
    if (updateTimer !== null) clearTimeout(updateTimer);
    updateTimer = setTimeout(applyTheme, delay);
  }

  function init() {
    if (initialized || !document.documentElement) return;
    initialized = true;
    installStyle();
    schedule();
    document.addEventListener("DOMContentLoaded", () => {
      schedule();
      setupObserver();
    }, { once: true });
    if (document.readyState !== "loading") setupObserver();
  }

  function setupObserver() {
    if (observer || !document.documentElement) return;
    observer = new MutationObserver(mutations => {
      if (settings.mode === "off" || disabledHere()) return;
      // 监听站点 SPA 导航、主题 class/style 变化。自身 class 切换最多触发一次额外检查。
      if (mutations.some(m => m.type === "childList" || m.attributeName === "class" || m.attributeName === "style")) {
        schedule(700);
      }
    });
    observer.observe(document.documentElement, { childList: true, attributes: true, attributeFilter: ["class", "style"] });
    if (document.body) observer.observe(document.body, { childList: true, attributes: true, attributeFilter: ["class", "style"] });
  }

  Promise.resolve(api.storage.local.get({ mode: "auto", excludedSites: {} }))
    .then(data => {
      settings.mode = ["auto", "always", "off"].includes(data.mode) ? data.mode : "auto";
      settings.excludedSites = data.excludedSites && typeof data.excludedSites === "object" ? data.excludedSites : {};
      schedule(0);
    })
    .catch(() => schedule(0));

  if (api.storage.onChanged) {
    api.storage.onChanged.addListener((changes, area) => {
      if (area !== "local") return;
      if (changes.mode) settings.mode = changes.mode.newValue;
      if (changes.excludedSites) settings.excludedSites = changes.excludedSites.newValue || {};
      schedule(0);
    });
  }

  if (api.runtime && api.runtime.onMessage) {
    api.runtime.onMessage.addListener(message => {
      if (message && message.type === "zhiyeyue:getHost") return Promise.resolve({ hostname });
      if (message && message.type === "zhiyeyue:refresh") { schedule(0); return Promise.resolve({ ok: true }); }
      return undefined;
    });
  }

  if (typeof prefersDark.addEventListener === "function") prefersDark.addEventListener("change", () => schedule(0));
  else if (typeof prefersDark.addListener === "function") prefersDark.addListener(() => schedule(0));

  window.addEventListener("pageshow", () => schedule(60));
  window.addEventListener("load", () => schedule(80));
  window.addEventListener("hashchange", () => schedule(150));
  window.addEventListener("popstate", () => schedule(150));
  if (document.documentElement) init();
  else document.addEventListener("readystatechange", init, { once: true });
})();

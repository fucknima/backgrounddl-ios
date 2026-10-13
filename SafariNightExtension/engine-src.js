import * as DarkReader from "darkreader";

/**
 * 智夜 / Dark Reader engine.
 * The hand-written invert/filter and per-element mutation engine are completely removed.
 * Dark Reader is loaded as a LOCAL npm dependency, bundled at build time.
 */
(() => {
  "use strict";
  const api = globalThis.browser || globalThis.chrome;
  if (!api?.storage?.local || !/^https?:$/i.test(location.protocol)) return;

  const host = location.hostname.toLowerCase();
  const root = document.documentElement;
  const colorPreference = matchMedia("(prefers-color-scheme: dark)");
  const DEFAULTS = {mode: "auto", excludedSites: {}};
  const THEMING = {
    mode: 1,
    brightness: 100,
    contrast: 95,
    sepia: 0,
    darkSchemeBackgroundColor: "#151922",
    darkSchemeTextColor: "#e5e9f0",
  };
  // Avoid hijacking document.styleSheets, which can break reactive web apps.
  const FIXES = {disableStyleSheetsProxy: true};

  let settings = {...DEFAULTS};
  let mounted = false;
  let desired = false;
  let resolved = false;
  let started = false;
  let loadingTimeout = 0;
  const isSogou = /(^|\.)m\.sogou\.com$/i.test(host);
  let fallbackTimer = 0;
  let sogouObserver = null;
  let sogouFallback = false;
  let lastEngineError = "";

  // Safari permissions and fast-changing SPA styles can both look like a failed
  // dark theme. Report observable state to the popup instead of guessing.
  function status() {
    return {
      hostname: host,
      mode: settings.mode,
      systemDark: colorPreference.matches,
      excluded: Boolean(settings.excludedSites?.[host]),
      wantsDark: desired,
      darkReaderEnabled: mounted && DarkReader.isEnabled(),
      darkReaderMode: root.getAttribute("data-darkreader-mode") || "",
      sogouFallback,
      error: lastEngineError
    };
  }

  function visibleBackground(node) {
    for (let i = 0; node && i < 8; i++, node = node.parentElement) {
      if (node.nodeType !== 1) continue;
      const color = getComputedStyle(node).backgroundColor;
      const match = color.match(/rgba?\(\s*(\d+)[, ]+\s*(\d+)[, ]+\s*(\d+)(?:[,/ ]+([\d.]+))?\s*\)/i);
      if (match && (match[4] === undefined || Number(match[4]) >= 0.85)) {
        return (Number(match[1]) * .2126 + Number(match[2]) * .7152 + Number(match[3]) * .0722) / 255;
      }
    }
    return 1;
  }

  function markSogouSurfaces() {
    if (!sogouFallback || !document.body) return;
    const tree = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
    const t0 = performance.now();
    let count = 0, el;
    const surfaces = "DIV,SECTION,ARTICLE,MAIN,HEADER,FOOTER,NAV,FORM,LI,UL,ASIDE";
    while ((el = tree.nextNode()) && count++ < 750 && performance.now() - t0 < 22) {
      if (!(el instanceof HTMLElement)) continue;
      if (!surfaces.split(",").includes(el.tagName)) continue;
      const color = getComputedStyle(el).backgroundColor;
      const match = color.match(/rgba?\(\s*(\d+)[, ]+\s*(\d+)[, ]+\s*(\d+)(?:[,/ ]+([\d.]+))?\s*\)/i);
      if (!match || (match[4] !== undefined && Number(match[4]) < .85)) continue;
      const brightness = (Number(match[1]) * .2126 + Number(match[2]) * .7152 + Number(match[3]) * .0722) / 255;
      if (brightness > .82) el.setAttribute("data-zny-bright-surface", "1");
    }
  }

  function clearSogouFallback() {
    clearTimeout(fallbackTimer);
    sogouObserver?.disconnect();
    sogouObserver = null;
    sogouFallback = false;
    root.removeAttribute("data-zny-sogou-fallback");
    // Do not write inline style properties: cleanup remains safe for app sites.
    document.querySelectorAll("[data-zny-bright-surface]").forEach((node) =>
      node.removeAttribute("data-zny-bright-surface"));
  }

  function checkSogou() {
    if (!isSogou || !desired || !mounted || !document.body || sogouFallback) return;
    const w = innerWidth || 1, h = innerHeight || 1;
    const coords = [[.1,.1],[.5,.1],[.9,.1],[.1,.45],[.5,.45],[.9,.45],[.1,.82],[.5,.82],[.9,.82]];
    let light = 0, total = 0;
    for (const [x,y] of coords) {
      const node = document.elementFromPoint(Math.floor(w*x), Math.floor(h*y));
      if (!node) continue;
      total++;
      if (visibleBackground(node) > .77) light++;
    }
    // Only a mostly WHITE result after Dark Reader has had time to analyze
    // stylesheets gets fallback. Dark/native websites are left alone.
    if (!total || light / total < .55) return;
    sogouFallback = true;
    markSogouSurfaces();
    root.setAttribute("data-zny-sogou-fallback", "1");
    let queued = false;
    sogouObserver = new MutationObserver((changes) => {
      if (queued || !changes.some(c => c.type === "childList" && c.addedNodes.length)) return;
      queued = true;
      setTimeout(() => { queued = false; markSogouSurfaces(); }, 650);
    });
    sogouObserver.observe(document.body, {subtree: true, childList: true});
  }

  function scheduleSogouCheck() {
    if (!isSogou || !desired || !mounted || sogouFallback) return;
    clearTimeout(fallbackTimer);
    fallbackTimer = setTimeout(checkSogou, 1300);
  }

  function bgColor(node) {
    if (!node) return null;
    const match = getComputedStyle(node).backgroundColor.match(/rgba?\(\s*(\d+)[, ]+\s*(\d+)[, ]+\s*(\d+)(?:[,/ ]+([\d.]+))?\s*\)/i);
    if (!match) return null;
    if (match[4] != null && Number(match[4]) < 0.85) return null;
    const red = Number(match[1]), green = Number(match[2]), blue = Number(match[3]);
    return (red * 0.2126 + green * 0.7152 + blue * 0.0722) / 255;
  }

  function releasePrepaint() {
    if (resolved) return;
    resolved = true;
    root.setAttribute("data-zny-resolved", "1");
    clearTimeout(loadingTimeout);
  }

  function apply() {
    if (!started) return;
    const mode = ["auto", "always", "off"].includes(settings.mode) ? settings.mode : "auto";
    const excluded = Boolean(settings.excludedSites?.[host]);
    const wantsDark = !excluded && (mode === "always" || (mode === "auto" && colorPreference.matches));
    // A single body's background is NOT proof of a fully dark page.
    // In particular, white SPA cards on a dark/transparent body were wrongly skipped.
    // Let Dark Reader handle mixed themes instead of excluding the entire document.
    desired = wantsDark;
    try {
      if (desired && !mounted) {
        DarkReader.enable(THEMING, FIXES);
        mounted = true;
        lastEngineError = "";
        scheduleSogouCheck();
      } else if (!desired && mounted) {
        DarkReader.disable();
        mounted = false;
        clearSogouFallback();
      }
    } catch (error) {
      // The extension must never block navigation or break page interaction.
      lastEngineError = String(error?.message || error);
      console.warn("[智夜] Dark Reader skipped this page:", error);
      clearSogouFallback();
      try { DarkReader.disable(); } catch (_) {}
      mounted = false;
    } finally {
      if (!desired) clearSogouFallback();
      releasePrepaint();
    }
  }

  function start() {
    if (started) return;
    started = true;
    apply();
  }

  function waitForBody() {
    if (document.body) return start();
    const observer = new MutationObserver(() => {
      if (!document.body) return;
      observer.disconnect();
      start();
    });
    observer.observe(root, {childList: true, subtree: false});
    // Never keep an unpainted or blocked page while waiting for a broken document.
    setTimeout(() => { observer.disconnect(); start(); }, 1600);
  }

  async function readSettings() {
    try {
      const incoming = await api.storage.local.get(DEFAULTS);
      settings = {
        mode: incoming.mode,
        excludedSites: incoming.excludedSites && typeof incoming.excludedSites === "object"
          ? incoming.excludedSites
          : {},
      };
    } catch (error) {
      console.warn("[智夜] Falling back to default settings:", error);
    }
    waitForBody();
  }

  loadingTimeout = setTimeout(releasePrepaint, 1800);
  readSettings();

  api.storage.onChanged?.addListener((changes, area) => {
    if (area !== "local") return;
    if (changes.mode) settings.mode = changes.mode.newValue;
    if (changes.excludedSites) settings.excludedSites = changes.excludedSites.newValue || {};
    apply();
  });

  const schemeChanged = () => apply();
  if (colorPreference.addEventListener) colorPreference.addEventListener("change", schemeChanged);
  else colorPreference.addListener(schemeChanged);

  api.runtime?.onMessage?.addListener((message) => {
    if (message?.type === "zhiyeyue:getHost") return Promise.resolve({hostname: host});
    if (message?.type === "zhiyeyue:getStatus") return Promise.resolve(status());
    if (message?.type === "zhiyeyue:refresh") {
      apply();
      scheduleSogouCheck();
      return Promise.resolve({ok: true, ...status()});
    }
    return undefined;
  });

  window.addEventListener("pageshow", () => { apply(); scheduleSogouCheck(); });
  document.addEventListener("DOMContentLoaded", scheduleSogouCheck, {once: true});
})();

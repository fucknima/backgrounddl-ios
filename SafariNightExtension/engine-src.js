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

  function bgColor(node) {
    if (!node) return null;
    const match = getComputedStyle(node).backgroundColor.match(/rgba?\(\s*(\d+)[, ]+\s*(\d+)[, ]+\s*(\d+)(?:[,/ ]+([\d.]+))?\s*\)/i);
    if (!match) return null;
    if (match[4] != null && Number(match[4]) < 0.85) return null;
    const red = Number(match[1]), green = Number(match[2]), blue = Number(match[3]);
    return (red * 0.2126 + green * 0.7152 + blue * 0.0722) / 255;
  }

  function nativeDarkTheme() {
    if (!document.body) return false;
    // Read DOM before Dark Reader is enabled; do not inspect its own generated colors.
    // Ignore the prepaint root CSS when determining native theme.
    const bodyBrightness = bgColor(document.body);
    const bodyText = getComputedStyle(document.body).color;
    const textMatch = bodyText.match(/rgba?\(\s*(\d+)[, ]+\s*(\d+)[, ]+\s*(\d+)/i);
    const textBrightness = textMatch
      ? (Number(textMatch[1]) + Number(textMatch[2]) + Number(textMatch[3])) / 765
      : 0;
    if (bodyBrightness !== null && bodyBrightness < 0.32 && textBrightness > 0.52) return true;
    const scheme = (document.querySelector('meta[name="color-scheme"]')?.content || "").toLowerCase();
    return scheme.includes("dark") && !scheme.includes("light") && bodyBrightness !== null && bodyBrightness < 0.4;
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
    // For auto, allow pages with a genuine native dark theme to render themselves.
    desired = wantsDark && !(mode === "auto" && !mounted && nativeDarkTheme());
    try {
      if (desired && !mounted) {
        DarkReader.enable(THEMING, FIXES);
        mounted = true;
      } else if (!desired && mounted) {
        DarkReader.disable();
        mounted = false;
      }
    } catch (error) {
      // The extension must never block navigation or break page interaction.
      console.warn("[智夜] Dark Reader skipped this page:", error);
      try { DarkReader.disable(); } catch (_) {}
      mounted = false;
    } finally {
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
    if (message?.type === "zhiyeyue:refresh") {
      apply();
      return Promise.resolve({ok: true, enabled: mounted});
    }
    return undefined;
  });

  window.addEventListener("pageshow", apply);
})();

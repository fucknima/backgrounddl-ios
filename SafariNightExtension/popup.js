(() => {
  "use strict";
  const api = globalThis.browser || globalThis.chrome;
  const buttons = [...document.querySelectorAll("[data-mode]")];
  const siteToggle = document.getElementById("skipSite");
  const siteName = document.getElementById("siteName");
  const status = document.getElementById("status");
  const engineStatus = document.getElementById("engineStatus");
  async function checkEngine() {
    if (tabId == null) {
      engineStatus.textContent = "当前页面无法检测扩展运行状态";
      return;
    }
    try {
      const response = await api.tabs.sendMessage(tabId, {type: "zhiyeyue:getStatus"});
      if (!response || !response.hostname) throw Error("no injected content script");
      host = String(response.hostname).toLowerCase();
      render();
      if (response.error) {
        engineStatus.textContent = "深色引擎报错：" + response.error.slice(0, 85);
      } else if (response.excluded) {
        engineStatus.textContent = "当前网站已设为例外，不进行变色";
      } else if (response.mode === "off") {
        engineStatus.textContent = "当前设置：网站原样";
      } else if (response.mode === "auto" && !response.systemDark) {
        engineStatus.textContent = "系统当前为浅色外观，智能模式没有启用";
      } else if (response.darkReaderEnabled) {
        engineStatus.textContent = response.sogouFallback
          ? "引擎已运行，搜狗专用补色已启用"
          : "Dark Reader 已在当前页面运行";
      } else {
        engineStatus.textContent = "内容脚本已注入，但深色引擎未成功启用";
      }
    } catch (_) {
      engineStatus.textContent = "未检测到网页注入。请检查 Safari 的网站访问授权，并刷新网页。";
    }
  }
  let host = "";
  let tabId = null;
  let mode = "auto";
  let excludedSites = {};

  function render() {
    buttons.forEach(button => button.setAttribute("aria-pressed", String(button.dataset.mode === mode)));
    siteToggle.disabled = !host;
    siteToggle.checked = !!excludedSites[host];
    siteName.textContent = host || "当前页面不可设置（或尚未授权网站访问）";
  }
  function notify(message, error = false) {
    status.textContent = message;
    status.style.color = error ? "#ff9d9d" : "#8ad7aa";
  }
  async function refreshPage() {
    if (tabId === null) return;
    try { await api.tabs.sendMessage(tabId, { type: "zhiyeyue:refresh" }); }
    catch (_) { /* storage.onChanged 将通知已授权的网页；无需刷新页面。 */ }
  }
  async function initialize() {
    if (!api || !api.storage || !api.storage.local) { notify("浏览器不支持扩展存储", true); return; }
    try {
      const result = await api.storage.local.get({ mode: "auto", excludedSites: {} });
      mode = ["auto", "always", "off"].includes(result.mode) ? result.mode : "auto";
      excludedSites = result.excludedSites && typeof result.excludedSites === "object" ? result.excludedSites : {};
    } catch (e) { notify("读取设置失败", true); }

    try {
      const tabs = await api.tabs.query({ active: true, currentWindow: true });
      const tab = tabs && tabs[0];
      if (tab) {
        tabId = tab.id;
        if (tab.url && /^https?:/i.test(tab.url)) host = new URL(tab.url).hostname.toLowerCase();
        if (!host) {
          const response = await api.tabs.sendMessage(tabId, { type: "zhiyeyue:getHost" });
          if (response && response.hostname) host = String(response.hostname).toLowerCase();
        }
      }
    } catch (_) { /* 系统页或未授权网站无法读取地址，保留全局开关。 */ }
    render();
    await checkEngine();
  }

  buttons.forEach(button => button.addEventListener("click", async () => {
    const next = button.dataset.mode;
    try {
      await api.storage.local.set({ mode: next });
      mode = next; render(); await refreshPage();
      notify("已保存网页外观设置");
      await checkEngine();
    } catch (_) { notify("保存失败，请检查 Safari 扩展权限", true); }
  }));
  siteToggle.addEventListener("change", async () => {
    if (!host) return;
    const next = { ...excludedSites };
    if (siteToggle.checked) next[host] = true;
    else delete next[host];
    try {
      await api.storage.local.set({ excludedSites: next });
      excludedSites = next; render(); await refreshPage();
      notify(siteToggle.checked ? "当前网站已加入例外" : "当前网站已恢复网页外观规则");
      await checkEngine();
    } catch (_) { render(); notify("网站例外保存失败", true); }
  });
  initialize();
})();

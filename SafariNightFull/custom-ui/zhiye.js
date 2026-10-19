(() => {
"use strict";
const runtime = globalThis.browser?.runtime || globalThis.chrome?.runtime;
const q = (id) => document.getElementById(id);
const modes = [...document.querySelectorAll("button[data-mode]")];
const message = q("message");
const stateLabel = q("stateText");
const state = q("state");
const site = q("siteEnabled");
let snapshot = null;
let requestedChange = 0;
let transient = false;
let isBusy = false;
let renderAgain = null;

function timeoutPromise(ms) {return new Promise((_, reject) => setTimeout(() => reject(new Error("connection-timeout")), ms));}

function requestData() {
  return new Promise((resolve, reject) => {
    let completed = false;
    const timer = setTimeout(() => { if (!completed) {completed=true; reject(new Error("连接后台超时"));}}, 6500);
    try {
      runtime.sendMessage({type:"ui-bg-get-data"}, (response) => {
        if (completed) return;
        completed=true; clearTimeout(timer);
        const err = globalThis.chrome?.runtime?.lastError;
        if (err) return reject(new Error(err.message || "无法连接后台"));
        if (!response || !response.data) return reject(new Error("后台未返回扩展状态"));
        resolve(response.data);
      });
    } catch(err) { if(!completed){ completed=true; clearTimeout(timer); reject(err); } }
  });
}
function send(type,data) {
  if (!runtime) throw new Error("扩展后台不可用");
  // Dark Reader v4.9.133 UI control methods are one-way by design.
  runtime.sendMessage({type,data});
}
const num = (v,d=100) => Number.isFinite(+v) ? Math.max(50,Math.min(150,Math.round(v))) : d;
function render(data) {
  snapshot=data;
  const settings=data.settings || {};
  const automation=settings.automation || {};
  const active = Boolean(data.isEnabled);
  const mode = automation.enabled ? "auto" : (settings.enabled ? "on" : "off");
  modes.forEach((b)=>b.setAttribute("aria-pressed",String(b.dataset.mode === mode)));
  state.classList.toggle("on", active);
  stateLabel.textContent = mode === "auto" ? (active ? "自动 · 已启用" : "自动 · 已关闭") : (active ? "已启用" : "已关闭");
  q("modeHint").textContent = mode==="auto" ? "跟随 iPhone 的深浅色外观自动切换。" :
    mode==="on" ? "深色模式已开启，会尽量保留图片原色。" : "已关闭网页深色处理，网页保持原样。";

  const tab=data.activeTab || {};
  let hostname = "";
  try {hostname = new URL(tab.url).hostname.replace(/^www\./,"");} catch(_) {}
  const accessible=Boolean(hostname) && !tab.isProtected && tab.isInjected !== false;
  q("siteName").textContent=hostname || "当前不是可访问的网页";
  q("siteName").title=hostname;
  site.disabled=!accessible;
  // For normal allow-by-default installations, site list disables domains.
  const disabledFor=settings.disabledFor || [];
  const enabledFor=settings.enabledFor || [];
  const explicitOff=disabledFor.some(x=>x===hostname || x==="www."+hostname);
  const explicitOn=enabledFor.some(x=>x===hostname || x==="www."+hostname);
  const localOn = settings.enabledByDefault === false ? explicitOn : !explicitOff;
  site.checked=localOn;
  q("siteHint").textContent = !accessible ? "如无法访问，请在 Safari 中授权网站权限" :
    tab.isDarkThemeDetected ? "网页已有原生深色主题" : (localOn ? "本站参与深色处理" : "本站已加入例外");

  const theme=settings.theme || {};
  q("brightness").value=num(theme.brightness);
  q("contrast").value=num(theme.contrast);
  q("brightnessValue").textContent=q("brightness").value+"%";
  q("contrastValue").textContent=q("contrast").value+"%";
  q("engine").value=["dynamicTheme","staticTheme","cssFilter","svgFilter"].includes(theme.engine) ? theme.engine : "dynamicTheme";
  q("detectDark").checked=Boolean(settings.detectDarkTheme);
  ["brightness","contrast","engine","detectDark","reset"].forEach(id=>q(id).disabled=false);
  document.querySelector("main").setAttribute("aria-busy","false");
}
function fail(messageText) {
  message.textContent=messageText;
  q("message").parentElement.classList.add("error");
  document.querySelector("main").setAttribute("aria-busy","false");
}
function ok(messageText) {
  message.textContent=messageText;
  q("message").parentElement.classList.remove("error");
}
async function refresh(delay=480) {
  const nonce=++requestedChange;
  try {
    if(delay) await new Promise(r=>setTimeout(r,delay));
    const data=await requestData();
    if(nonce!==requestedChange) return;
    render(data);
  } catch(err) { if(nonce===requestedChange) fail("扩展设置未同步："+err.message); }
}
function doChange(type,payload,note) {
  try {send(type,payload);ok(note);refresh();}
  catch(err){fail("保存失败："+err.message);}
}
modes.forEach(button=>button.addEventListener("click",()=>{
  if(!snapshot) return;
  const next=button.dataset.mode;
  const automation={...(snapshot.settings.automation||{}),enabled:next==="auto",mode:next==="auto"?"system":(snapshot.settings.automation?.mode||"system"),behavior:"OnOff"};
  doChange("ui-bg-change-settings",{enabled:next!=="off",automation},next==="auto"?"已切换：跟随系统":next==="on"?"已开启深色":"已关闭深色");
  const nextSettings={...snapshot.settings,enabled:next!=="off",automation};
  snapshot={...snapshot,settings:nextSettings};
  modes.forEach(b=>b.setAttribute("aria-pressed",String(b.dataset.mode===next)));
}));
site.addEventListener("change",()=>{
 if(!snapshot) return;
 doChange("ui-bg-toggle-active-tab",{}, "正在切换当前网站设置…");
});
let sliderTimer=0;
function onSlider(id,key){
  q(id).addEventListener("input",()=>{
    q(id+"Value").textContent=q(id).value+"%";
    clearTimeout(sliderTimer);
    sliderTimer=setTimeout(()=>doChange("ui-bg-set-theme",{[key]:Number(q(id).value)},"显示效果已更新"),120);
  });
}
onSlider("brightness","brightness");
onSlider("contrast","contrast");
q("engine").addEventListener("change",()=>doChange("ui-bg-set-theme",{engine:q("engine").value},"已切换渲染引擎"));
q("detectDark").addEventListener("change",()=>doChange("ui-bg-change-settings",{detectDarkTheme:q("detectDark").checked},"深色主题检测已更新"));
q("reset").addEventListener("click",()=>doChange("ui-bg-set-theme",{brightness:100,contrast:100,engine:"dynamicTheme"},"已恢复默认显示参数"));
q("permissionButton").addEventListener("click", () => {
  const panel=q("permissionHelp");
  const show=panel.hidden;
  panel.hidden=!show;
  q("permissionButton").setAttribute("aria-expanded",String(show));
});
if(!runtime){fail("未检测到 Safari 扩展环境");return;}
refresh(0);
})();

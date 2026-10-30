(function () {
  'use strict';
  const host = location.hostname.toLowerCase();
  const exact = ['pan.baidu.com','yun.baidu.com','www.aliyundrive.com','www.alipan.com','yun.139.com','caiyun.139.com','cloud.189.cn','pan.xunlei.com','www.guangyapan.com','pan.quark.cn','drive.uc.cn'];
  const roots = ['123pan.com','123pan.cn','123684.com','123865.com','123952.com','123912.com'];
  if (!exact.includes(host) && !roots.some(v => host === v || host.endsWith('.' + v))) { window.__LS_ALLOWED = false; return; }
  window.__LS_ALLOWED = true;
  const send = data => window.webkit.messageHandlers.linkSwiftNative.postMessage(data);
  const prefix = '__linkswift_gm_';
  window.unsafeWindow = window;
  window.GM_info = { script: { name: 'LinkSwift', author: 'hmjz100', version: '1.1.4' },
                     scriptHandler: 'LinkSwift iOS', version: '1.0' };
  window.GM_getValue = (key, fallback = null) => {
    try { let data = localStorage.getItem(prefix + key); return data === null ? fallback : JSON.parse(data); } catch { return fallback; }
  };
  window.GM_setValue = (key, value) => localStorage.setItem(prefix + key, JSON.stringify(value));
  window.GM_deleteValue = key => localStorage.removeItem(prefix + key);
  window.GM_setClipboard = text => send({action:'clipboard', text:String(text)});
  window.GM_openInTab = url => { send({action:'open', url:String(url)}); return {close(){}}; };
  window.GM_registerMenuCommand = () => undefined;
  window.GM_getResourceText = key => (window.__LS_RESOURCE_CSS || {})[key] || '';
  window.__linkSwiftNativeDownload = (url, name, headers) => {
    send({action:'download',url:String(url),name:String(name||''),headers: headers || {}});
  };
  const pending = new Map();
  let serial = 0;
  const decode = base64 => {
    const bytes = atob(base64 || '');
    const result = new Uint8Array(bytes.length);
    for (let i=0;i<bytes.length;i++) result[i] = bytes.charCodeAt(i);
    return result;
  };
  window.__LS_FINISH = (id, result) => {
    const item = pending.get(id);
    if (!item) return;
    pending.delete(id);
    if (result.error) {
      item.opt.onerror?.({status:result.status||0,statusText:result.error});
      return;
    }
    const bytes = decode(result.base64);
    let text;
    try { text = new TextDecoder('utf-8').decode(bytes); } catch { text = ''; }
    let response = text;
    if (item.opt.responseType === 'arraybuffer') response = bytes.buffer;
    if (item.opt.responseType === 'blob') response = new Blob([bytes]);
    if (item.opt.responseType === 'json') { try { response = JSON.parse(text); } catch {} }
    const detail = { status:result.status, statusText:result.statusText, response,
      responseText:text, responseHeaders:result.responseHeaders };
    item.opt.onload?.(detail);
  };
  window.GM_xmlhttpRequest = opt => {
    const id = String(++serial);
    pending.set(id, {opt});
    const request = {action:'request',id,method:opt.method||'GET',url:String(opt.url),
      headers:opt.headers||{},data:typeof opt.data === 'string' ? opt.data : ''};
    send(request);
    opt.onloadstart?.({});
    return {abort() { pending.delete(id); send({action:'abort',id}); }};
  };
  window.GM = {xmlHttpRequest:window.GM_xmlhttpRequest,setValue:window.GM_setValue,
    getValue:window.GM_getValue,deleteValue:window.GM_deleteValue,
    setClipboard:window.GM_setClipboard,openInTab:window.GM_openInTab};
})();

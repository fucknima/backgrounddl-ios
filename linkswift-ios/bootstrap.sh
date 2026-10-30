#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p Resources third-party
fetch() { curl -fLsS --retry 4 --retry-delay 2 --max-time 150 "$1" -o "$2"; test -s "$2"; }
RAW="https://raw.githubusercontent.com/hmjz100/LinkSwift/dev"
fetch "$RAW/%EF%BC%88%E6%94%B9%EF%BC%89%E7%BD%91%E7%9B%98%E7%9B%B4%E9%93%BE%E4%B8%8B%E8%BD%BD%E5%8A%A9%E6%89%8B.user.js" Resources/linkswift.js
fetch "https://unpkg.com/jquery@3.6.0/dist/jquery.min.js" Resources/jquery.min.js
fetch "https://unpkg.com/sweetalert2@11.4.8/dist/sweetalert2.min.js" Resources/sweetalert2.min.js
fetch "https://unpkg.com/js-md5@0.7.3/build/md5.min.js" Resources/md5.min.js
fetch "https://unpkg.com/sweetalert2@11.4.8/dist/sweetalert2.min.css" /tmp/ls-swal-light.css
fetch "https://unpkg.com/@sweetalert2/theme-dark@5.0.26/dark.min.css" /tmp/ls-swal-dark.css
fetch "$RAW/LICENSE" third-party/LinkSwift-LICENSE.txt
python3 - <<'PY'
import pathlib,json
p=pathlib.Path("Resources")
styles={"SwalLigt":pathlib.Path("/tmp/ls-swal-light.css").read_text(),
        "SwalDark":pathlib.Path("/tmp/ls-swal-dark.css").read_text()}
(p/"resources.js").write_text("window.__LS_RESOURCE_CSS = "+json.dumps(styles)+";\n")
f=p/"linkswift.js"
s=f.read_text(encoding="utf-8-sig")
assert "LinkSwift" in s[:3000] and "GM_xmlhttpRequest" in s
(p/"linkswift.original.user.js").write_text(s)
start=s.index('$doc.on("click", `.${mount}.btn[action="download"]`, async (e) => {')
spot=s.index('case "normal": {',start)
code='''case "native": {
    const state = download.state(index);
    if (!state) return;
    const { files, get, headers } = state;
    const file = files[index];
    const link = get.link(file);
    if (link) {
        window.__linkSwiftNativeDownload(link, get.name(file), headers || {});
        message.success("已添加到 iOS 下载队列");
    } else message.error("无法获取下载地址");
    break;
}
'''
s=s[:spot]+code+s[spot:]
needle='<button action="download" type="normal"'
pos=s.index(needle,s.index('generateDOM(keepDowning'))
s=s[:pos]+'<button action="download" type="native" class="link ${mount} btn success mini">下载到 App</button>\n                            '+s[pos:]
f.write_text(s)
print("Patched upstream LinkSwift",len(s))
PY
node --check Resources/linkswift.js
node --check Resources/bridge.js

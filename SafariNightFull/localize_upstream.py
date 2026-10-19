#!/usr/bin/env python3
"""Localize the FULL Dark Reader binary distribution without changing its theme engine."""
import json, sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
manifest_file = root/"manifest.json"
background = root/"background"/"index.js"
assert manifest_file.exists() and background.exists(), "上游 Dark Reader 发布包不完整"
m=json.loads(manifest_file.read_text(encoding="utf-8"))
assert m.get("manifest_version")==3
assert (root/"_locales"/"zh_CN"/"messages.json").exists(), "官方简体中文语言资源不存在"

m["name"]="智夜 · 智能网页夜间模式"
m["short_name"]="智夜"
m["description"]="iPhone Safari 智能网页夜间模式，支持自动深色、网站例外及显示调节。"
m["default_locale"]="zh_CN"
m["author"]="智夜（网页渲染核心基于 Dark Reader，保留 MIT 许可）"
m["version"]="3.2.0"
m["action"]["default_title"]="智夜 · 网页外观"
m["action"]["default_popup"]="ui/popup/index.html"
if "options_ui" in m:
    m["options_ui"]["page"]="ui/popup/index.html"
manifest_file.write_text(json.dumps(m,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

code=background.read_text(encoding="utf-8")
# Dark Reader upstream background/index.ts registers this listener:
# onInstalled(reason=install) => chrome.tabs.create({url: getHelpURL()})
# Replace precisely the effect, retaining all other engine and message behavior.
old="chrome.tabs.create({url: getHelpURL()});"
assert code.count(old)==1, ("上游首次安装跳转代码发生变化，拒绝忽略",code.count(old))
code=code.replace(old,"/* 智夜：初次安装不跳转外部网站；由本地中文页面说明 Safari 网站授权 */")
uninstall="chrome.runtime.setUninstallURL(UNINSTALL_URL);"
assert code.count(uninstall)==1, "上游卸载时跳转代码发生变化"
code=code.replace(uninstall,"/* 智夜：不设置第三方卸载跳转 */")
background.write_text(code,encoding="utf-8")
assert "chrome.tabs.create({url: getHelpURL()});" not in code
assert "chrome.runtime.setUninstallURL(UNINSTALL_URL);" not in code
assert (root/"ui/popup/index.html").exists()
print("已本地化扩展名称/说明/简体中文默认语言，并清除外部安装帮助与卸载跳转")

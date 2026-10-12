# BackgroundDL — 网页分享链接后台下载器

## 这版主要解决什么问题

不要求用户寻找文件直链。打开 App 的「浏览器」，粘贴别人分享的 HTTPS 网页链接（例如 Google Drive 分享页），在网页内点击原站的「下载」，App 尝试从 WebKit 导航 / Content-Disposition 响应识别文件下载，并转交给原生的 **background URLSession downloadTask**；随后可以切换 App 或锁屏。

## 界面

- **浏览器**：地址栏、网页、返回/前进/刷新。下载按钮若被 WebKit 识别为文件下载，App 会取消网页下载并新建后台下载任务。
- **下载**：进度、暂停、继续、取消、分享/保存；仍保留直链和 Google Drive API 备用入口。
- 默认文件保存位置：iPhone「文件」→「在我的 iPhone 上」→「后台下载」→ `Downloads`。

## Google Drive 和站点限制（务必阅读）

1. 公开可访问、服务器发出 **HTTP/HTTPS GET 文件响应** 的分享下载更容易接管。站点 Cookie 只从 App 自己的 WKWebView 获取、按对应请求域名匹配后传给 URLSession。**Safari 内已登录的 Cookie 不会自动共享**。
2. Google 可能禁止用户在嵌入式 WKWebView 内登录（`disallowed_useragent`）。这是 Google 的安全政策，不应通过伪造浏览器 UA 或窃取 Safari Cookie 绕过。访问需要登录的私有文件，请使用合法 Google OAuth 授权后的 API 备用入口（需自己在 Google Cloud 配置 iOS Client ID 和允许的 scope）；此功能与「直接在网页点击」互补。
3. `blob:` / `data:`、动态 JS 内存文件、页面内部 `fetch`、POST 表单、一次性且绑定浏览器会话的 URL、需要进一步确认的 Google 大文件下载，**不能保证成功转移**到后台 URLSession。页面仍可能需要先点击「继续下载」等确认按钮。浏览器无法接管时会明确提示，不会声称下载成功。
4. 后台 URLSession 受 iOS 网络与电量调度限制；**从多任务界面强制关闭 App** 可能取消当前后台任务。暂停/继续仅暂停当前系统任务，不等于断点续传；系统任务丢失需重新点击网页下载。
5. 对网页下载返回的 HTML 登录页/确认页，程序会提示失败，避免把网页当成下载文件保存。

## 编译

仓库 `main` 上每次推送自动执行 GitHub Actions `Build unsigned iOS IPA`，在 macOS 运行 `xcodebuild ... CODE_SIGNING_ALLOWED=NO`，把 `BackgroundDL.app` 打包为 `BackgroundDL-unsigned.ipa` 并上传至 Actions Artifacts。下载后仍需使用自己的有效签名证书签名才能安装。

### 可选 Google Drive API 配置

仓库 Actions Secrets 可配置：`GOOGLE_CLIENT_ID`、`GOOGLE_URL_SCHEME`（反向 Client ID）。未配置时，**网页下载和普通 HTTP(S) 直链下载无需此配置**；Google Drive API 备用入口不具备 Google 登录权限。不要将私密凭据写入公开源码仓库。

## 隐私

分享链接可能包含临时令牌；公开日志和 Issue 不要粘贴带密钥的下载地址。此 App 不需要云端代理服务器。浏览器 Cookie 仅在下载被用户点击触发时用于对应目标站点，跨站点跳转会移除敏感请求头。

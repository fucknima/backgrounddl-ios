# 后台下载 BackgroundDL — 浏览器 + 灵动岛版

## 功能

- 内置 WKWebView 打开普通 HTTPS 分享网页；网页登录、网页按钮与下载响应由原生 App 处理。
- 可接管的 HTTPS GET 下载交由后台 URLSession 下载；切到其他应用和锁屏时，系统可继续传输。
- 支持暂停、继续（依赖服务器允许恢复下载及有效 resumeData）、取消、重试、断电重开后后台任务关联。
- 支持多个下载任务，写入本机 `Documents/Downloads`，可从「文件」App 访问。
- 下载期间可创建一条 Live Activity：锁屏显示进度；支持灵动岛紧凑、最小及展开视图。
- 提供自制 App 图标，SwiftUI 原生玻璃材质、圆角控件，使用新 Xcode SDK 获得新系统原生外观。

## 限制（重要）

1. 背景 URLSession 的传输与 Live Activity 刷新是**不同机制**。iOS 挂起 App 后，即使下载继续，系统不承诺持续唤醒 App 提供每一段字节的回调，因此灵动岛进度可能暂时保持上次值，完成后系统唤醒时才更新。
2. WebKit 可以接管的普通下载请求才可以交给 URLSession。`blob:`、`data:`、页面 JS 生成文件、POST 等流程不保证可转移；登录 Cookie、限时下载令牌、服务器反爬或续传限制可能导致失败。
3. 手动从多任务界面强制关闭 App 后，iOS 通常会取消后台 URLSession 的传输。
4. `resumeData` 并不保证每个服务器都能断点续传。服务器不支持 Range、token 过期、文件变化时只能重新下载。
5. 公开仓库**不要提交账号密码、Cookie、分享令牌或签名证书**。

## 构建

在 GitHub Actions 的 Build BackgroundDL iOS IPA 中下载 `BackgroundDL-unsigned` Artifacts；其中是未签名 IPA，需自行签名后安装。
工作流使用 GitHub `xcode-27` public preview runner（可用性由 GitHub 决定）。

## 使用

1. 打开「浏览器」，在地址栏粘贴 HTTPS 分享页面；必要时在网页中登录。
2. 点击网页的「下载」。可接管任务进入下载列表。
3. 返回「下载」查看任务进度，切出 App 或锁屏。
4. 打开 iOS 设置，允许本 App 的实时活动。带灵动岛设备会显示紧凑进度。文件 App → 在我的 iPhone 上 → 后台下载 → Downloads。

## 验证计划

实际 Xcode 编译通过不等于真机网络场景都已通过。应分别测试 10GB+ HTTP Range 服务器、下载中锁屏、Wi-Fi→蜂窝网络切换、恢复下载、签名 URL 过期、低存储空间和后台完成后唤醒 App。

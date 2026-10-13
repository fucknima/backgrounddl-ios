> **Safari 网页夜间模式现已更换为完整版 Dark Reader。** 请使用 [智夜 v3 完整 Safari 构建](https://github.com/fucknima/backgrounddl-ios/actions/workflows/build-safari-full.yml)。它集成上游完整浏览器扩展、网站规则库、iframe 和代理脚本；`SafariNightExtension/` 是已停用的旧版简化实验，不要再用于安装。
>
> **注意：** 首次安装仍需授予 Safari 网站访问权限；若旧版智夜仍开启，请先禁用旧版以避免两个夜间模式扩展同时处理同一网页。

# 后台下载器（iOS 原生 SwiftUI 工程）

## 这是什么

- iOS 17+，SwiftUI 原生界面，无服务器、无广告。
- 普通 HTTPS 文件直链：粘贴后可以使用系统 URLSession 后台下载。
- Google Drive 单文件链接：使用 Google 登录授权，通过 Drive API 下载有访问权限的文件。
- 支持多个任务、下载进度、暂停/继续（在任务仍存在时）、取消、重试。
- 下载完成写入 `在我的 iPhone 上 → 后台下载 → Downloads`，可在「文件」App 打开或通过 App 内分享。
- Google Docs/Sheets/Slides 分别转换为 DOCX/XLSX/PPTX；Drawings 转为 PDF。

## 必备环境

1. Mac + Xcode 15 或更高版本、iOS 17 或更高版本的 iPhone。
2. Apple ID 用于 Xcode 自动签名。普通 Apple ID 可以通过 Xcode 安装到自己的设备上，但签名的有效期等限制依 Apple 规则执行。
3. **Google Drive 需要配置自己的 OAuth Client ID**；普通 HTTPS 下载不需要 Google 配置。

## Xcode 打开、安装

1. 双击 `BackgroundDL.xcodeproj`。
2. 打开 `BackgroundDL` Target → `Signing & Capabilities`：选择自己的 Team。
3. 修改 Bundle Identifier（默认 `com.example.backgrounddl`，换成自己独有的，如 `com.example.yourname.downloads`）。
4. 接上 iPhone 或使用无线调试，在 Xcode 选择设备，点击 Run。
5. 首次编译 Xcode 会联网下载 GoogleSignIn-iOS 的 Swift Package 依赖。

注意：这里只提供 **完整源码工程**，不是已经签名好的 IPA；当前制作环境不是 macOS，无法调用 Xcode 真机编译和签名。

## Google Drive 登录配置（必须做）

1. 打开 https://console.cloud.google.com/ 新建项目。
2. `APIs & Services` → `Library`，启用 **Google Drive API**。
3. 设置 `Google Auth Platform / OAuth consent screen`：应用测试中添加自己的 Google 邮箱为测试用户，并配置必要的权限（Drive `https://www.googleapis.com/auth/drive.readonly`）。
4. `Credentials` → `Create credentials` → `OAuth client ID` → 类型选择 **iOS**。
5. Bundle ID 必须与 Xcode 内 Target 的 Bundle Identifier **完全相同**。
6. 把客户端 ID 写入 `BackgroundDL/Info.plist` 的 `GIDClientID`；格式示例：`12345678-abcxyz.apps.googleusercontent.com`。
7. 把 Google 控制台显示的 **iOS URL scheme / REVERSED_CLIENT_ID** 写入 `Info.plist` → `CFBundleURLTypes` → `CFBundleURLSchemes`，格式示例：`com.googleusercontent.apps.12345678-abcxyz`。
8. 再次运行 App，先点击 **登录 Google**，授权只读访问，然后粘贴 Google Drive 单文件分享链接。

这个只读权限允许读取用户可访问的云端硬盘文件；不允许应用修改或删除云端文件。`drive.readonly` 是敏感/受限权限，公开分发可能需要 Google 审核。个人测试可按 Google 控制台的测试用户要求配置。

## 支持的链接

**普通 HTTPS 文件直链**：

    https://example.org/files/movie.mp4

**Google Drive 共享文件**：

    https://drive.google.com/file/d/FILE_ID/view?usp=sharing
    https://drive.google.com/open?id=FILE_ID
    https://drive.google.com/uc?export=download&id=FILE_ID
    https://docs.google.com/document/d/FILE_ID/edit

Google Drive 分享链接里如果包含 `resourcekey` 参数，程序会把它作为 Drive API 的资源键发送。

**不支持：** Google Drive 文件夹整包下载、需要网页里先登录/解验证码的第三方地址、Google Vids 特殊下载、磁力/BT、视频平台分段流媒体提取、绕过所有者禁下载限制。Google 原生 Workspace 文档的 `files.export` 接口有 Google 的导出大小限制（官方说明为 10 MB）。

## 正常下载行为和限制

- 开始任务需要 App 在前台执行初始授权和请求；进入下载状态后切换 App / 锁屏，系统会接管。
- **不要手动上滑强制关闭 App**。这是苹果的系统限制，强杀会取消后台 URLSession 传输。
- iOS 对后台网络调度有最终控制权；本 App 不能保证精确下载速度，也不能保证网络中断时所有服务器都支持续传。
- 「暂停/继续」使用任务挂起与恢复；如果任务已因强制退出被系统移除，请用「重试」重新下载。重试会创建新任务，通常从头下载。
- Google Drive 请求开始时会获取新 token；若极长时间后台传输后发生 `401`，回到 App 点「重试」即可重新授权请求。已下载字节能否重用依赖服务器及 iOS，当前版本不承诺跨进程断点续传。
- 个别文件分享权限或防病毒/组织策略限制下载时会返回 `403`，不会绕过。
- 只有真正返回文件数据的 HTTPS 链接才是可下载的；普通网页地址可能保存成 HTML，不会自动解析网页隐藏下载按钮。

## 文件结构

```
BackgroundDL.xcodeproj/       Xcode 工程
BackgroundDL/
  BackgroundDLApp.swift       SwiftUI 入口/系统后台回调
  ContentView.swift           中文界面
  BackgroundDownloader.swift  后台 URLSession 下载引擎/文件保存
  DownloadStore.swift         本地 JSON 任务持久化
  GoogleDriveService.swift    Google 登录/Drive API 元数据和下载
  DriveLinkParser.swift       Google Drive 分享链接解析
  Models.swift                任务模型
  Info.plist                  OAuth 配置/文件 App 可见配置
```

## 官方参考

- Apple 后台下载: https://developer.apple.com/documentation/foundation/downloading-files-in-the-background
- Google Drive 下载和导出: https://developers.google.com/workspace/drive/api/guides/manage-downloads
- Google Sign-In iOS 安装: https://developers.google.com/identity/sign-in/ios/start-integrating
- Google Drive 资源键: https://developers.google.com/workspace/drive/api/guides/resource-keys

## 没有 Mac：用 GitHub Actions 构建未签名 IPA

工程带有 `.github/workflows/构建未签名IPA.yml`。在 **你自己的 GitHub 仓库** 上传全部项目文件（包括隐藏的 `.github` 目录），代码上传到仓库 `main` 分支后会**自动触发编译**；也可以在 `Actions` → `Build unsigned iOS IPA` → `Run workflow` 手动重跑。构建完成后从本次运行的 Artifacts 取得 `BackgroundDL-unsigned.ipa`。

这个文件 **不带苹果签名，不能直接点开安装**。需要你自己使用合法的开发者证书与签名方式签名，才能安装到 iPhone。GitHub Actions 构建也需要联网下载 Swift Package。注意 GitHub 仓库的源码不要填入密码、Google 登录令牌、签名证书；如需在 GitHub 构建时启用 Google 登录，可在仓库 `Settings → Secrets and variables → Actions` 中配置 `GOOGLE_CLIENT_ID` 和 `GOOGLE_URL_SCHEME` 两个 secrets；应用 Bundle ID 必须和 Google OAuth iOS 客户端登记值匹配。

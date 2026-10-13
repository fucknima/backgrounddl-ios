# 智夜 · Safari 智能网页夜间模式

将同仓库后台下载器 BrowserView.swift 的自适应网页夜间模式，独立移植为 **iPhone Safari Web Extension**，原下载器代码不作修改。

- **智能深色（默认）**：系统深色模式下，使用九点背景亮度采样，仅处理明亮网页。
- **始终深色**：强制对网页做颜色反转并纠正图片、视频、SVG、Canvas 的色彩。
- **网站原样**：完全停用颜色处理。
- **网站例外**：针对当前域名单独关闭夜间模式。
- **隐私**：无统计、无第三方 API、无上传；扩展只读取浏览器本地设置及网页背景颜色。Safari 需要你明确授予网站访问权限。

## GitHub Actions 编译与安装

上传这些文件到 main 分支后，工作流 `构建Safari智夜插件` 将尝试在 GitHub 的 macOS runner 上执行 Apple 官方 `safari-web-extension-packager`，然后用 Xcode 编译 **未签名 iOS IPA**。

1. 打开仓库的 **Actions**，选择 **构建Safari智夜插件**。
2. 进入成功的运行记录 → **Artifacts** → 下载 `SafariNight-unsigned-IPA`（压缩包中有 .ipa）。
3. 使用你自己的有效开发签名或兼容的签名工具对 IPA **连同内置的 .appex 扩展一并正确签名**并安装。
4. 在 iPhone **设置 → App → Safari → 扩展**（不同 iOS 版本菜单可能略有不同）里启用「智夜」，授权需要的网站，然后在 Safari 的扩展菜单打开设置。

**说明**：未签名 IPA 不能直接安装。签名应覆盖主 App 和 Safari 扩展，两者的 Bundle ID 和 provisioning 必须符合你的开发者证书配置。免费签名服务、企业证书和侧载工具对 App Extension 的支持不一定一致。GitHub Actions 能完成构建不等于在每台设备上都能正常签名安装。

## 项目文件

`manifest.json`：扩展权限、配置。
`content.js`：从下载器算法移植的网页变暗逻辑。
`popup.html/css/js`：中文夜间模式设置面板。
`.github/workflows/build-safari-night.yml`：Apple 官方打包工具 + Xcode 自动构建流程。

原项目：`fucknima/backgrounddl-ios`。

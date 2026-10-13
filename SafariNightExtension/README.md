# 智夜 Safari Extension v2.0

这是原后台下载器独立的 Safari 扩展子项目。

**核心采用 [Dark Reader](https://github.com/darkreader/darkreader) 开源动态主题引擎（MIT License）。** 无整页 `filter: invert()`，也不使用旧版逐元素 `MutationObserver` 改写 CSS；原来的 JavaScript 已被弃用。

- 智能深色：只在系统深色模式启用，并尽量识别网页的原生深色主题
- 始终深色：Dark Reader 动态引擎，不做图片/网页整页反色；避免阻断页面交互
- 网站原样：完全禁用引擎
- 网站例外：当前域名单独禁用（基于本地存储）
- 防白闪：在 `document_start` 注入安全的预绘制背景规则，超时自动释放，不隐藏网页
- 图标：构建时生成 iOS 18+ 的 Light/Dark/Tinted 外观 AppIcon 资源并用 `actool` 编译

## 可复现构建

由 `.github/workflows/build-safari-night.yml` 在 macOS runner：

1. `npm install darkreader@4.9.130 esbuild@0.25.12`。
2. 打包 `engine-src.js` + Dark Reader 到扩展的 `content.js`（完全离线运行，不使用 CDN）。
3. 由 Apple `safari-web-extension-packager` / `safari-web-extension-converter` 生成原生 Xcode 工程。
4. 使用 `xcodebuild` 编译未签名 iOS App + Safari Extension。
5. 使用 `actool` 编译真实的 iOS 浅色、深色、着色 App 图标资源，注入主 App 的 `CFBundleIcons`。
6. 验证 IPA 包含 `.appex`、引擎文件、AppIcon 的 `Assets.car`。
7. 导出 **SafariNight-v2-unsigned.ipa** 到 GitHub Actions Artifacts。

注意：GitHub Actions 编译成功 ≠ iPhone 实机已测试。Safari 系统限制、第三方网站复杂 CSS 和跨域资源会影响覆盖率，不承诺百分之百网站无闪白。

## 开源许可

Dark Reader © Dark Reader Ltd. MIT License。构建时随 App 附带依赖完整的 `LICENSE` 许可证文本。

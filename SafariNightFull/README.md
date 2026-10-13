# 智夜 Safari v3 — 官方 Dark Reader 完整扩展移植

采用 **[Dark Reader 4.9.133](https://github.com/darkreader/darkreader/releases/tag/v4.9.133)** 的完整 Chrome Manifest V3 开源扩展，而不是将 Dark Reader npm API 单独注入网页。

完整扩展保留：
- 官方动态主题引擎、样式表/图片分析及异步加载处理；
- 官方网站规则 `dynamic-theme-fixes.config`、深色主题检测与图像规则；
- 官方多 frame、MAIN/ISOLATED 注入及页面 CSSOM 代理；
- 官方中文翻译及全部主题选项、网站例外、自动模式设置。

安装后在 Safari 中打开「智夜」菜单，默认设置可在原生官方设置面板里调整，也可以设置「系统暗色时启用」。源项目遵守 MIT License，构建产物附原项目 LICENSE。主 App 使用我们的 Light/Dark/Tinted iOS 原生图标资源。

此工程是开源扩展的独立复用构建，不是 Dark Reader 官方 Safari iOS 应用，也不是 Dark Reader Ltd. 出品的软件。

## 构建及签名

`.github/workflows/build-safari-full.yml` 拉取 upstream v4.9.133 固定标签的发布包，检查官方 Manifest、网站修复规则、简体中文资源是否存在；再通过 Apple Safari Web Extension packager 和 Xcode 编译 iOS App + Safari Extension。导出 `ZhiYe-FullDarkReader-unsigned.ipa`。

IPA 未签名，请在签名工具中同时签名主 App 和 `.appex`。首次开启请授予 Safari 网站访问权限。iOS WebExtension 的兼容性与 Chrome 并非完全相同：工作流构建成功不意味着所有 API 都在 iOS 运行时可用；请以 iPhone 真机测试为准。尤其不要承诺 100% 网站无白闪。

若出现不生效：先确认「设置→App→Safari→扩展→智夜」已经启用并允许所有网站，再在扩展菜单确认启用状态及当前网站是否在黑名单。

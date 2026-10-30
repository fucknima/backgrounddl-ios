# LinkSwift iOS GitHub Actions build

This is a native SwiftUI + WKWebView iOS adapter for [hmjz100/LinkSwift](https://github.com/hmjz100/LinkSwift).

**Build branch:** \`linkswift-ios\`. The existing \`main\` app is not modified.

- Run the "Build LinkSwift iOS" workflow in GitHub Actions.
- Download the \`LinkSwift-iOS-build\` artifact after a successful build.
- The resulting IPA is **unsigned** and must be signed with your own certificate before installation.
- The workflow downloads the upstream userscript and pinned JavaScript dependencies during build. Download success depends on upstream availability.
- Cross-origin requests are bridged through URLSession. iOS WebKit and cloud-provider API changes can prevent some providers from working; no end-to-end support guarantee is made for all nine drives.
- Built-in download manager uses iOS background URLSession, with pause/resume, task list, and sharing.

Source and license notices: LinkSwift is AGPL-3.0-or-later; original script is fetched into the build and its license is retained under \`third-party\`. Adaptations distributed with LinkSwift must comply with its license.

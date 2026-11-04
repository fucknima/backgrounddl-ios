import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let group = "group.com.example.backgrounddl.shared"
    private let key = "pendingSharedWebLinks"
    private let supportedTypes = [
        UTType.url.identifier,
        UTType.plainText.identifier,
        UTType.text.identifier,
        "com.apple.webarchive"
    ]

    private let titleText = UILabel()
    private let subtitle = UILabel()
    private let done = UIButton(type: .system)

    private var fallbackText = ""
    private var pendingAttempts = 0
    private var settled = false
    private var timeoutWorkItem: DispatchWorkItem?
    private var deliveredURL: URL?
    private var finishing = false
    private var completed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 360, height: 220)
        titleText.font = .preferredFont(forTextStyle: .headline)
        titleText.text = "发送到后台下载"
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.numberOfLines = 4
        subtitle.textColor = .secondaryLabel
        subtitle.text = "正在读取链接…"
        done.setTitle("完成", for: .normal)
        done.isEnabled = false
        done.addTarget(self, action: #selector(finish), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [titleText, subtitle, done])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        importLink()
    }

    deinit {
        timeoutWorkItem?.cancel()
    }

    private func importLink() {
        let items = (extensionContext?.inputItems ?? []).compactMap { $0 as? NSExtensionItem }
        fallbackText = items.compactMap { item in
            [item.attributedTitle?.string, item.attributedContentText?.string]
                .compactMap { $0 }
                .joined(separator: "\n")
        }.joined(separator: "\n")

        let providers = items.flatMap { $0.attachments ?? [] }
        let readable = providers.filter { provider in
            supportedTypes.contains { provider.hasItemConformingToTypeIdentifier($0) }
        }

        guard !readable.isEmpty else {
            if let url = DroppedLinkCodec.extract(fallbackText) {
                deliver(url)
            } else {
                show("没有收到网页链接。", success: false)
            }
            return
        }

        pendingAttempts = readable.count
        for provider in readable { load(provider) }

        let timeout = DispatchWorkItem { [weak self] in self?.finishAttempts() }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
    }

    private func load(_ provider: NSItemProvider) {
        guard let type = supportedTypes.first(where: {
            provider.hasItemConformingToTypeIdentifier($0)
        }) else {
            settleAttempt()
            return
        }
        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, _ in
            let url = DroppedLinkCodec.decode(item: item)
            DispatchQueue.main.async {
                guard let self, !self.settled else { return }
                if let url {
                    self.deliver(url)
                } else {
                    self.settleAttempt()
                }
            }
        }
    }

    private func settleAttempt() {
        pendingAttempts -= 1
        if pendingAttempts <= 0 { finishAttempts() }
    }

    private func finishAttempts() {
        guard !settled else { return }
        timeoutWorkItem?.cancel()
        if let url = DroppedLinkCodec.extract(fallbackText) {
            deliver(url)
        } else {
            show("无法读取网址。\n可以先复制链接，再打开 App，会自动载入。", success: false)
        }
    }

    private func deliver(_ url: URL) {
        guard !settled else { return }
        settled = true
        deliveredURL = url
        timeoutWorkItem?.cancel()

        var stored = false
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil,
           let defaults = UserDefaults(suiteName: group) {
            var pending = defaults.stringArray(forKey: key) ?? []
            if !pending.contains(url.absoluteString) { pending.append(url.absoluteString) }
            defaults.set(Array(pending.suffix(25)), forKey: key)
            defaults.synchronize()
            stored = (defaults.stringArray(forKey: key) ?? []).contains(url.absoluteString)
        }
        if !stored {
            // App Group missing (common with re-signed builds): use the
            // pasteboard, which the app detects on its next activation.
            UIPasteboard.general.setItems([
                [UTType.url.identifier: url, UTType.plainText.identifier: url.absoluteString]
            ], options: [:])
        }

        show(stored
             ? "已发送到「后台下载」\n点「完成」打开 App"
             : "已复制链接到剪贴板\n点「完成」打开 App",
             success: true)
    }

    private func show(_ message: String, success: Bool) {
        DispatchQueue.main.async {
            self.titleText.text = success ? "已添加到下载器" : "导入失败"
            self.subtitle.text = message
            self.done.isEnabled = true
        }
    }

    @objc private func finish() {
        guard !finishing else { return }
        finishing = true
        guard let url = deliveredURL else {
            complete()
            return
        }
        ShareLauncher.open(ShareLauncher.deepLink(for: url), from: self) { [weak self] _ in
            self?.complete()
        }
        // Never leave the share sheet waiting if the scene does not answer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.complete()
        }
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}

private enum ShareLauncher {
    static func deepLink(for link: URL) -> URL {
        var components = URLComponents()
        components.scheme = "backgrounddl"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "url", value: link.absoluteString)]
        return components.url ?? URL(string: "backgrounddl://open")!
    }

    /// Share extensions cannot call UIApplication.shared. Opening through the
    /// extension's UIScene is the remaining public path on current iOS.
    static func open(_ url: URL, from controller: UIViewController, completion: @escaping (Bool) -> Void) {
        var responder: UIResponder? = controller
        while let current = responder {
            if let scene = current as? UIScene {
                scene.open(url, options: nil) { success in
                    if success {
                        completion(true)
                    } else {
                        openViaExtensionContext(url, from: controller, completion: completion)
                    }
                }
                return
            }
            responder = current.next
        }
        openViaExtensionContext(url, from: controller, completion: completion)
    }

    private static func openViaExtensionContext(_ url: URL, from controller: UIViewController,
                                                completion: @escaping (Bool) -> Void) {
        guard let context = controller.extensionContext else {
            completion(false)
            return
        }
        context.open(url) { success in completion(success) }
    }
}

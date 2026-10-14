import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let group = "group.com.example.backgrounddl.shared"
    private let key = "pendingSharedWebLinks"
    private let titleText = UILabel()
    private let subtitle = UILabel()
    private let done = UIButton(type: .system)

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

    private func importLink() {
        let providers = (extensionContext?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }) else { show("没有收到网页链接。", success: false); return }
        let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            ? UTType.url.identifier : UTType.plainText.identifier
        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, _ in
            let raw: String?
            if let url = item as? URL { raw = url.absoluteString }
            else if let str = item as? String { raw = str }
            else { raw = nil }
            guard let raw,
                  let token = raw.components(separatedBy: .whitespacesAndNewlines)
                    .first(where: { $0.hasPrefix("https://") || $0.hasPrefix("http://") }),
                  let url = URL(string: token), url.host != nil,
                  let defaults = UserDefaults(suiteName: self?.group ?? "") else {
                self?.show("无法读取网址，或共享 App Group 尚未授权。", success: false)
                return
            }
            var pending = defaults.stringArray(forKey: self?.key ?? "") ?? []
            if !pending.contains(url.absoluteString) { pending.append(url.absoluteString) }
            defaults.set(Array(pending.suffix(25)), forKey: self?.key ?? "")
            defaults.synchronize()
            self?.show("链接已收取：\(url.host ?? "网页")\n打开「后台下载」即可自动载入网页。", success: true)
        }
    }
    private func show(_ message: String, success: Bool) {
        DispatchQueue.main.async {
            self.titleText.text = success ? "已添加到下载器" : "导入失败"
            self.subtitle.text = message
            self.done.isEnabled = true
        }
    }
    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}

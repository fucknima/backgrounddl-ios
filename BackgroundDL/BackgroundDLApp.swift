import SwiftUI
import UIKit

final class DownloaderAppDelegate: NSObject, UIApplicationDelegate {
    static var backgroundCompletionHandler: (() -> Void)?
    static var segmentCompletionHandler: (() -> Void)?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = BackgroundDownloader.shared
        IncomingLinkRouter.shared.note("App 已启动")
        if let url = launchOptions?[.url] as? URL {
            Task { @MainActor in
                IncomingLinkRouter.shared.receive(url, from: "App 启动参数")
            }
        }
        if #available(iOS 26.0, *) {
            ContinuedDownloadProgress.shared.register()
        }
        Task { @MainActor in
            DownloadCoordinator.shared.reconnect()
            DownloadRetryManager.shared.resumePending()
        }
        return true
    }

    // UIKit may deliver document opens here rather than through SwiftUI onOpenURL.
    func application(_ application: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        Task { @MainActor in
            IncomingLinkRouter.shared.receive(url, from: "AppDelegate openURL")
        }
        return true
    }

    func application(_ application: UIApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        guard let url = userActivity.webpageURL else {
            Task { @MainActor in
                IncomingLinkRouter.shared.note("AppDelegate 用户活动类型: \(userActivity.activityType)")
            }
            return false
        }
        Task { @MainActor in
            IncomingLinkRouter.shared.receive(url, from: "AppDelegate 用户活动")
        }
        return true
    }

    // SwiftUI's WindowGroup uses the UIScene lifecycle. A cold document/URL
    // launch may be delivered in connectionOptions, not AppDelegate's launchOptions.
    // Apple's SwiftUI documentation supports supplying a UIWindowSceneDelegate
    // through this configuration method without taking over SwiftUI's window.
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        IncomingLinkRouter.shared.note(
            "场景配置请求：URL \(options.urlContexts.count)，用户活动 \(options.userActivities.count)"
        )
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = DownloadSceneDelegate.self
        }
        return configuration
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == SegmentedDownloader.identifier {
            Self.segmentCompletionHandler = completionHandler
            Task { @MainActor in SegmentedDownloader.shared.reconnect() }
            return
        }
        guard identifier == BackgroundDownloader.sessionIdentifier else {
            completionHandler()
            return
        }
        Self.backgroundCompletionHandler = completionHandler
        Task { @MainActor in
            DownloadCoordinator.shared.reconnect()
            DownloadRetryManager.shared.resumePending()
        }
    }
}

@main
struct BackgroundDLApp: App {
    @UIApplicationDelegateAdaptor(DownloaderAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}


// Single link input router: share sheet, system document open, app delegate,
// SwiftUI URL activity and drag-and-drop all converge here.
@MainActor
final class IncomingLinkRouter: ObservableObject {
    static let shared = IncomingLinkRouter()
    @Published private(set) var latestURL: URL?
    @Published private(set) var revision = UUID()
    @Published private(set) var events: [String] = []

    private let recordKey = "bgdl.linkIngress.log.v1"
    private var lastDelivery: (url: String, time: Date)?

    private init() {
        events = UserDefaults.standard.stringArray(forKey: recordKey) ?? []
    }

    func note(_ event: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        events.insert("\(stamp)  \(event)", at: 0)
        if events.count > 22 { events.removeLast(events.count - 22) }
        UserDefaults.standard.set(events, forKey: recordKey)
    }

    func clear() {
        events.removeAll()
        UserDefaults.standard.removeObject(forKey: recordKey)
    }

    func receive(_ input: URL, from source: String) {
        note("\(source) 收到 \(input.isFileURL ? "文件" : (input.scheme ?? "未知协议"))")
        guard let url = IncomingLinkDecoder.resolve(input) else {
            note("\(source) 无法提取网页链接")
            return
        }
        let now = Date()
        if let lastDelivery, lastDelivery.url == url.absoluteString,
           now.timeIntervalSince(lastDelivery.time) < 1.0 {
            note("\(source) 同一次交付已处理")
            return
        }
        lastDelivery = (url.absoluteString, now)
        latestURL = url
        revision = UUID()
        note("已转交浏览器：\(url.host ?? "网页")")
    }
}

enum IncomingLinkDecoder {
    static func resolve(_ incoming: URL) -> URL? {
        if let scheme = incoming.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return validate(incoming)
        }
        guard incoming.isFileURL else { return nil }
        let allowed = incoming.startAccessingSecurityScopedResource()
        defer { if allowed { incoming.stopAccessingSecurityScopedResource() } }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: incoming.path),
              let length = attributes[.size] as? NSNumber, length.intValue <= 128_000,
              let data = try? Data(contentsOf: incoming) else { return nil }

        // Safari and Files may deliver Internet Location documents as XML/binary
        // property lists (webloc) or Windows-style .url text shortcuts.
        if let property = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dict = property as? [String: Any],
           let raw = dict["URL"] as? String,
           let url = extract(raw) { return url }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return extract(text)
    }

    static func resolvePayload(_ data: Data) -> URL? {
        guard data.count <= 128_000 else { return nil }
        if let property = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dict = property as? [String: Any],
           let raw = dict["URL"] as? String,
           let url = extract(raw) { return url }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return extract(text)
    }

    static func extract(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), let valid = validate(url) { return valid }
        if let line = value.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("URL=") }),
           let url = URL(string: String(line.dropFirst(4))),
           let valid = validate(url) { return valid }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let match = detector.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let url = match.url else { return nil }
        return validate(url)
    }

    private static func validate(_ url: URL) -> URL? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}


// UIScene handles launch-time URL/document payloads that don't reach the
// UIApplicationDelegate on SwiftUI scene-based applications. Keep this delegate
// diagnostic and additive; SwiftUI still manages the WindowGroup.
@MainActor
final class DownloadSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        let urlCount = connectionOptions.urlContexts.count
        let activityCount = connectionOptions.userActivities.count
        IncomingLinkRouter.shared.note(
            "Scene 冷启动：URL \(urlCount)，用户活动 \(activityCount)"
        )
        for context in connectionOptions.urlContexts {
            IncomingLinkRouter.shared.receive(context.url, from: "Scene 冷启动 URL")
        }
        for activity in connectionOptions.userActivities {
            receive(activity, source: "Scene 冷启动用户活动")
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        IncomingLinkRouter.shared.note("Scene 运行中 URL：\(URLContexts.count)")
        for context in URLContexts {
            IncomingLinkRouter.shared.receive(context.url, from: "Scene openURLContexts")
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        receive(userActivity, source: "Scene continue")
    }

    private func receive(_ activity: NSUserActivity, source: String) {
        guard let url = activity.webpageURL else {
            IncomingLinkRouter.shared.note("\(source) 收到 \(activity.activityType)，无网页 URL")
            return
        }
        IncomingLinkRouter.shared.receive(url, from: source)
    }
}

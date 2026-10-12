import SwiftUI
import GoogleSignIn
import UIKit

final class DownloaderAppDelegate: NSObject, UIApplicationDelegate {
    static var backgroundCompletionHandler: (() -> Void)?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 即使系统只为传递后台事件而启动进程，也要重建 URLSession。
        _ = BackgroundDownloader.shared
        BackgroundDownloader.shared.reconnect()
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundDownloader.sessionIdentifier else {
            completionHandler()
            return
        }
        Self.backgroundCompletionHandler = completionHandler
        BackgroundDownloader.shared.reconnect()
    }
}

@main
struct BackgroundDLApp: App {
    @UIApplicationDelegateAdaptor(DownloaderAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}

import Foundation
import UserNotifications

// Permission is opt-in in download settings. This does not keep the process alive.
enum DownloadNotifications {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "bgdl.notifyDownloads") }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func deliver(title: String, detail: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = detail
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("通知发送失败：%@", error.localizedDescription) }
        }
    }
}

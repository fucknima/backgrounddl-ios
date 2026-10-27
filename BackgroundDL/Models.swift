import Foundation

enum DownloadSource: String, Codable {
    case direct
    case browser
}

enum DownloadStatus: String, Codable {
    case running
    case paused
    case completed
    case failed
    case cancelled
}

struct DownloadItem: Identifiable, Codable {
    var id: UUID
    var originalURL: String
    var filename: String
    var source: DownloadSource
    var status: DownloadStatus
    var downloadedBytes: Int64
    var totalBytes: Int64
    var errorMessage: String?
    var savedFilename: String?
    var createdAt: Date
    var resumeDataBase64: String?
    var speedBytesPerSecond: Double?
    var etaSeconds: TimeInterval?
    var resumeFileName: String? = nil
    var retries: Int? = nil
    var nextRetryAt: Date? = nil
    var lastProgressAt: Date? = nil
    // Set only after a verified file has been saved; nil for older records.
    var completedAt: Date? = nil

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }

    var sourceLabel: String {
        switch source {
        case .direct: return "直链"
        case .browser: return "网页"
        }
    }

    var speedLabel: String {
        guard let speedBytesPerSecond, speedBytesPerSecond > 0,
              lastProgressAt.map({ Date().timeIntervalSince($0) < 18 }) ?? false else { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(speedBytesPerSecond), countStyle: .file) + "/s"
    }

    var etaLabel: String {
        guard let etaSeconds, etaSeconds.isFinite, etaSeconds > 0,
              lastProgressAt.map({ Date().timeIntervalSince($0) < 18 }) ?? false else { return "--" }
        let seconds = Int(etaSeconds.rounded())
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }
}

struct TaskMarker: Codable {
    let id: UUID
    let filename: String
    let source: DownloadSource

    var text: String {
        let bytes = (try? JSONEncoder().encode(self)) ?? Data()
        return bytes.base64EncodedString()
    }

    static func decode(_ text: String?) -> TaskMarker? {
        guard let text, let data = Data(base64Encoded: text) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

enum DownloadError: LocalizedError {
    case invalidLink
    case unsupportedLink(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidLink: return "请输入有效的 HTTPS 下载链接。"
        case .unsupportedLink(let reason): return reason
        case .invalidResponse: return "服务器没有返回有效的文件信息。"
        }
    }
}

extension Int64 {
    var readableSize: String {
        guard self >= 0 else { return "未知" }
        return ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

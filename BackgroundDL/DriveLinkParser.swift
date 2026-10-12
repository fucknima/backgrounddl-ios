import Foundation

struct DriveFileLink {
    let fileID: String
    let resourceKey: String?

    // 只处理单个文件，不把 Drive 文件夹链接误当作直链下载。
    static func parse(_ url: URL) throws -> DriveFileLink? {
        guard let host = url.host?.lowercased() else { return nil }
        guard host == "drive.google.com" || host == "docs.google.com" else { return nil }

        let parts = url.pathComponents
        if parts.contains("folders") {
            throw DownloadError.unsupportedLink("暂不支持 Google Drive 文件夹链接，请复制单个文件的分享链接。")
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let queryID = query.first { $0.name.lowercased() == "id" }?.value
        let resourceKey = query.first { $0.name.lowercased() == "resourcekey" }?.value

        var fileID: String? = queryID
        if let position = parts.firstIndex(of: "d"), position + 1 < parts.count {
            fileID = parts[position + 1]
        }
        guard let fileID,
              fileID.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else {
            throw DownloadError.unsupportedLink("无法从 Google Drive 链接提取文件 ID，请粘贴单个文件的完整分享链接。")
        }
        return DriveFileLink(fileID: fileID, resourceKey: resourceKey)
    }
}


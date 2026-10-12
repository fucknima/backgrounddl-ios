import ActivityKit
import Foundation

struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var fraction: Double
        var written: Int64
        var expected: Int64
        var phase: String
    }

    var downloadID: String
    var filename: String
}

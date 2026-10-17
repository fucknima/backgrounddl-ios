import Foundation

struct RangeProbeResult {
    let size: Int64
    let validator: String?
}

// A HEAD check first avoids accidentally fetching a whole multi-GB file if the
// server ignores Range. The second one-byte GET is cancelled on unexpected status
// before its response body can be transferred into memory.
final class RangeProbe: NSObject, URLSessionDataDelegate {
    private var continuation: CheckedContinuation<RangeProbeResult?, Never>?
    private var session: URLSession?
    private var wantedSize: Int64 = 0
    private var validator: String?
    private var answered = false

    static func check(request original: URLRequest) async -> RangeProbeResult? {
        guard let url = original.url, url.scheme?.lowercased() == "https" else { return nil }
        var head = original
        head.httpMethod = "HEAD"
        head.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        head.timeoutInterval = 15
        do {
            let (_, response) = try await URLSession.shared.data(for: head)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let length = http.value(forHTTPHeaderField: "Content-Length"),
                  let size = Int64(length), size >= 128 * 1024 * 1024,
                  (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes") else {
                return nil
            }
            let strongETag = http.value(forHTTPHeaderField: "ETag").flatMap {
                $0.hasPrefix("W/") ? nil : $0
            }
            let validator = strongETag ?? http.value(forHTTPHeaderField: "Last-Modified")
            // Without an entity validator, changed content could silently mix
            // versions across chunks despite each Content-Range being valid.
            guard validator != nil else { return nil }
            let probe = RangeProbe()
            probe.wantedSize = size
            probe.validator = validator
            return await withCheckedContinuation { continuation in
                probe.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 15
                let session = URLSession(configuration: config, delegate: probe, delegateQueue: nil)
                probe.session = session
                var request = original
                request.httpMethod = "GET"
                request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                session.dataTask(with: request).resume()
            }
        } catch { return nil }
    }

    private func finish(_ result: RangeProbeResult?) {
        guard !answered else { return }
        answered = true
        continuation?.resume(returning: result)
        continuation = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              let header = http.value(forHTTPHeaderField: "Content-Range"),
              let range = ContentRange(header),
              range.matches(ByteRange(start: 0, end: 0), totalBytes: wantedSize) else {
            completionHandler(.cancel)
            finish(nil)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // One-byte successful 206. Never retain a larger response in memory.
        finish(data.count == 1 ? RangeProbeResult(size: wantedSize, validator: validator) : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !answered { finish(nil) }
    }
}

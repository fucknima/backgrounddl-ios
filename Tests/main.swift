import Foundation

func check(_ condition: @autoclosure () -> Bool, _ context: String) {
    if !condition() { fatalError("FAIL: " + context) }
}

let ranges = ByteRange.plan(total: 19_900_000_001, count: 4)
check(ranges.count == 4, "four parts")
check(ranges[0].start == 0, "starts at zero")
check(ranges[3].end == 19_900_000_000, "last byte")
check(ranges.reduce(Int64(0)) { $0 + $1.length } == 19_900_000_001, "exact total")
for i in 1..<ranges.count { check(ranges[i].start == ranges[i-1].end + 1, "contiguous") }
check(ByteRange.plan(total: 1, count: 4).isEmpty, "reject impossible plan")
check(ContentRange("bytes 0-0/19900000001")?.matches(ByteRange(start: 0, end: 0), totalBytes: 19_900_000_001) == true, "valid 206")
check(ContentRange("bytes 0-0/*") == nil, "no unknown length")
check(ContentRange("bytes 0-19/10") == nil, "reject overrun")
check(ContentRange("bytes 0-1/10")?.matches(ByteRange(start: 0, end: 0), totalBytes: 10) == false, "reject mismatched range")
check(DownloadMode.smart.desiredParts == 2 && DownloadMode.fast.desiredParts == 4, "modes")
print("PASS: RangeSupport unit tests")


// Existing 2.0.1 records contain no completedAt key. Decoding must remain
// backwards compatible and a new timestamp must survive persistence.
let oldRecord = """
{"id":"DA3F576A-6E42-42A5-8EE5-2A9F9DC71111",
 "originalURL":"https://example.com/a.zip", "filename":"a.zip",
 "source":"direct", "status":"completed", "downloadedBytes":100,
 "totalBytes":100, "createdAt":0}
"""
let legacyItem = try JSONDecoder().decode(DownloadItem.self, from: Data(oldRecord.utf8))
check(legacyItem.completedAt == nil, "old completed record has no fabricated date")
var newItem = legacyItem
let finishDate = Date(timeIntervalSince1970: 1_800_000_000)
newItem.completedAt = finishDate
let decodedNewItem = try JSONDecoder().decode(DownloadItem.self,
    from: JSONEncoder().encode(newItem))
check(decodedNewItem.completedAt == finishDate, "completion time survives round trip")
print("PASS: completion date JSON compatibility")

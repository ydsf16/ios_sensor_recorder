import Foundation

@main
enum TimestampAlignmentTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("alignment.csv")
        let wide = (0..<8).map { TimestampAlignment.Sample(frame: $0, seconds: 100 + Double($0) / 30) }
        let front = (0..<7).map { TimestampAlignment.Sample(frame: $0, seconds: 100.01 + Double($0) / 30) }
        let summary = try TimestampAlignment.write(streams: ["wide": wide, "front": front], to: output)
        precondition(summary.rows == 8 && summary.reference == "wide")
        let text = try String(contentsOf: output)
        precondition(text.contains("no_media_resampling"))
        let rows = text.split(separator: "\n").dropFirst(2).map { $0.split(separator: ",", omittingEmptySubsequences: false) }
        precondition(rows.last![8] == "6", "The last correspondence must reference an existing front frame, without inventing one")
        precondition(abs(summary.maximumSkew - (1.0 / 30 - 0.01)) < 0.000001)
        do {
            _ = try TimestampAlignment.write(streams: ["wide": wide, "front": front.reversed()], to: output)
            preconditionFailure("Non-monotonic media must be rejected")
        } catch is TimestampAlignment.Failure { }
        do {
            _ = try TimestampAlignment.write(streams: ["wide": wide, "front": []], to: output)
            preconditionFailure("An absent camera stream must be rejected")
        } catch is TimestampAlignment.Failure { }
        print("PASS: timestamp alignment preserves unequal real-frame sequences and rejects invalid streams")
    }
}

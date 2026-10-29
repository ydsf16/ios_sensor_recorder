import Foundation

/// An index of existing frames. It never retimes, duplicates, or drops a media sample.
enum TimestampAlignment {
    struct Sample { let frame: Int; let seconds: Double }
    struct Summary { let reference: String; let rows: Int; let maximumSkew: Double }
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? { switch self { case .invalid(let reason): return reason } }
    }
    static func load(_ url: URL) throws -> [Sample] {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }
        guard let header = lines.first else { throw Failure.invalid("A camera index is empty.") }
        let fields = header.split(separator: ",").map(String.init)
        guard let time = fields.firstIndex(of: "sensor_sec"), let frame = fields.firstIndex(of: "frame_index") else { throw Failure.invalid("A camera index has no original timestamps.") }
        return try lines.dropFirst().map { line in
            let values = line.split(separator: ",", omittingEmptySubsequences: false)
            guard values.count > max(time, frame), let index = Int(values[frame]), let seconds = Double(values[time]), seconds.isFinite else { throw Failure.invalid("A camera index contains an invalid timestamp.") }
            return Sample(frame: index, seconds: seconds)
        }
    }
    static func write(streams: [String: [Sample]], to url: URL) throws -> Summary {
        let names = ["wide", "ultra", "tele", "front"].filter { streams[$0] != nil }
        guard let reference = names.first, names.count > 1 else { throw Failure.invalid("Timestamp alignment requires multiple camera streams.") }
        for name in names {
            let samples = streams[name]!
            guard !samples.isEmpty, samples.enumerated().allSatisfy({ $0.offset == $0.element.frame }),
                  zip(samples, samples.dropFirst()).allSatisfy({ $1.seconds > $0.seconds }) else { throw Failure.invalid("A camera index is empty or discontinuous.") }
        }
        var columns = ["reference_frame_index", "reference_sensor_sec"]
        for name in ["wide", "ultra", "tele", "front"] { columns += ["\(name)_frame_index", "\(name)_sensor_sec"] }
        columns.append("max_skew_sec")
        var lines = ["# nearest_existing_frames_by_original_sensor_sec; correspondence_only; no_media_resampling", columns.joined(separator: ",")]
        var positions = Dictionary(uniqueKeysWithValues: names.map { ($0, 0) })
        var maximumSkew = 0.0
        for sample in streams[reference]! {
            var selected: [String: Sample] = [:]
            for name in names {
                let samples = streams[name]!
                var position = positions[name]!
                while position + 1 < samples.count && abs(samples[position + 1].seconds - sample.seconds) < abs(samples[position].seconds - sample.seconds) { position += 1 }
                positions[name] = position; selected[name] = samples[position]
            }
            let times = selected.values.map(\.seconds)
            let skew = times.max()! - times.min()!
            maximumSkew = max(maximumSkew, skew)
            var row = [String(sample.frame), String(format: "%.9f", sample.seconds)]
            for name in ["wide", "ultra", "tele", "front"] {
                if let matched = selected[name] { row += [String(matched.frame), String(format: "%.9f", matched.seconds)] }
                else { row += ["", ""] }
            }
            row.append(String(format: "%.9f", skew)); lines.append(row.joined(separator: ","))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return Summary(reference: reference, rows: streams[reference]!.count, maximumSkew: maximumSkew)
    }
}

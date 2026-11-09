import Foundation

/// Familiar recording cadences plus native SDK range endpoints. Every displayed
/// cadence must still lie in a real SDK range and pass joint graph validation.
enum CaptureRateOptions {
    // Explicit product policy for this release, separate from SDK capabilities.
    static let maximumSelectableFPS: Double = 60
    static func isWithinProductLimit(_ fps: Double) -> Bool {
        fps.isFinite && fps > 0 && fps <= maximumSelectableFPS
    }
    /// Keep the current cadence when valid, then prefer the nearest lower SDK
    /// choice. If none is lower, use the lowest supported higher cadence.
    static func compatibleOrder(current: String, choices: [String]) -> [String] {
        let target = Double(current).flatMap { isWithinProductLimit($0) ? $0 : nil } ?? maximumSelectableFPS
        return choices.filter { Double($0).map(isWithinProductLimit) == true }.sorted {
            let a = Double($0)!, b = Double($1)!
            if (a <= target) != (b <= target) { return a <= target }
            return a <= target ? a > b : a < b
        }
    }
    static func choices(ranges: [ClosedRange<Double>], ceiling: Double = .greatestFiniteMagnitude) -> [String] {
        var candidates = Set<Double>()
        let commonRates: [Double] = [1, 2, 5, 10, 15, 20, 24, 25, 30, 48, 50, 60]
        for range in ranges {
            guard range.lowerBound.isFinite, range.upperBound.isFinite, range.lowerBound > 0 else { continue }
            candidates.insert(range.lowerBound)
            candidates.insert(range.upperBound)
            for value in commonRates where range.contains(value) { candidates.insert(value) }
        }
        let rates = candidates.filter { fps in
            guard isWithinProductLimit(fps), fps <= ceiling else { return false }
            return ranges.contains { $0.contains(fps) }
        }
        return rates.sorted().map { String(format: "%.9g", $0) }
    }
}

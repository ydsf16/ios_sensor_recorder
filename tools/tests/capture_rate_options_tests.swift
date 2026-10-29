import Foundation

@main
enum CaptureRateOptionsTests {
    static func main() {
        check([], CaptureRateOptions.choices(ranges: []), "no hardware must offer no rates")
        check(["30"], CaptureRateOptions.choices(ranges: [30...30]), "fixed-rate format")
        check(["30", "48", "50", "60"], CaptureRateOptions.choices(ranges: [30...60]), "exclude unsupported low rates")
        check(["1", "5", "10", "15"], CaptureRateOptions.choices(ranges: [1...30], ceiling: 15), "joint cadence ceiling")
        check(["24", "60"], CaptureRateOptions.choices(ranges: [24...24, 60...60]), "do not fill gaps between ranges")
        check([], CaptureRateOptions.choices(ranges: [120...120, 240...240]), "this release has an explicit 60fps product limit")
        precondition(!CaptureRateOptions.isWithinProductLimit(120))
        precondition(CaptureRateOptions.isWithinProductLimit(60))
        check(["12"], CaptureRateOptions.choices(ranges: [12...12]), "hardware-specific endpoint")
        check([], CaptureRateOptions.choices(ranges: [30...60], ceiling: 15), "incompatible Depth rate must not be invented")
        check(["37"], CaptureRateOptions.choices(ranges: [37...37]), "SDK rate outside common FPS presets")
        check(["29.97003"], CaptureRateOptions.choices(ranges: [29.97002997...29.97002997]), "fractional SDK endpoint")
        let choices = CaptureRateOptions.choices(ranges: [15...30, 24...60])
        precondition(Set(choices).count == choices.count, "duplicate ranges must not duplicate menu choices")
        check(["30", "24", "15"], CaptureRateOptions.compatibleOrder(current: "60", choices: ["15", "24", "30"]), "resolution change prefers nearest supported lower rate")
        check(["30", "24", "60"], CaptureRateOptions.compatibleOrder(current: "30", choices: ["24", "60", "30"]), "keep supported rate")
        check(["24", "30"], CaptureRateOptions.compatibleOrder(current: "10", choices: ["30", "24"]), "choose native minimum when necessary")
        check(["60", "30"], CaptureRateOptions.compatibleOrder(current: "240", choices: ["120", "30", "60"]), "compatibility never exceeds product ceiling")
        print("PASS: 17 SDK-range, product-limit and dependent-selection checks")
    }

    private static func check(_ expected: [String], _ actual: [String], _ description: String) {
        precondition(expected == actual, "\(description): expected \(expected), got \(actual)")
    }
}

import CoreGraphics
import Foundation

/// The last few minutes of one number, and nothing else.
///
/// A bare array with a cap on it, kept as a type because three graphs and a
/// sparkline per tab all need the same three questions answered -- what is it
/// now, what is the worst it has been, what does the line look like -- and
/// because the cap is the whole point: the task manager samples every two
/// seconds and is left open for hours, so a history that grew would be a slow
/// leak with a graph on top of it.
struct UsageHistory: Equatable {
    /// Two minutes at the two-second sample rate. Long enough to show a spike
    /// you did not have your eye on when it happened, short enough that the
    /// line still has the resolution to show one.
    static let capacity = 60

    private(set) var samples: [Double] = []

    /// Adds one reading, dropping the oldest once the window is full.
    mutating func record(_ value: Double) {
        samples.append(max(0, value))
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
    }

    var latest: Double { samples.last ?? 0 }
    var peak: Double { samples.max() ?? 0 }

    var average: Double {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0, +) / Double(samples.count)
    }

    var isEmpty: Bool { samples.isEmpty }
}

/// Turning a history into a line.
///
/// Separated from the view that draws it so the two things that are easy to get
/// wrong -- where the ceiling lands and where the points go -- are a test
/// rather than something only a screenshot can catch.
enum UsageGraph {
    /// The top of the graph, rounded up to a number a person can read.
    ///
    /// A graph scaled to its own peak is a graph where every line looks the
    /// same: idle noise fills the card exactly as a runaway tab does. Rounding
    /// to 1, 2 or 5 times a power of ten gives a top that holds still while the
    /// numbers underneath it wobble, so the *shape* means something -- and
    /// `floor` keeps a card that has never seen a reading from scaling to zero.
    ///
    /// `floor` is what the card is about: 100 for a percentage, so a quiet
    /// browser reads as quiet rather than as a full-height line of noise.
    static func ceiling(forPeak peak: Double, floor: Double) -> Double {
        let wanted = max(peak, floor)
        guard wanted > 0 else { return floor > 0 ? floor : 1 }
        let magnitude = pow(10, (log10(wanted)).rounded(.down))
        for step in [1.0, 2.0, 5.0, 10.0] where wanted <= step * magnitude {
            return step * magnitude
        }
        return 10 * magnitude
    }

    /// The line across `rect`, oldest sample at the leading edge.
    ///
    /// A single sample still gets a point rather than an empty path, so a graph
    /// that has just opened draws a dot where the reading is instead of looking
    /// broken for the first two seconds.
    static func points(for samples: [Double], in rect: CGRect, ceiling: Double) -> [CGPoint] {
        guard !samples.isEmpty, ceiling > 0, rect.width > 0, rect.height > 0 else { return [] }
        // Always plotted against the full window, so a graph fills from the
        // right as readings arrive rather than stretching four samples across
        // the whole card and then squashing them as more come in.
        let span = CGFloat(max(UsageHistory.capacity - 1, 1))
        let firstIndex = CGFloat(UsageHistory.capacity - samples.count)
        return samples.enumerated().map { offset, value in
            let x = rect.minX + (firstIndex + CGFloat(offset)) / span * rect.width
            let fraction = min(max(value / ceiling, 0), 1)
            return CGPoint(x: x, y: rect.minY + CGFloat(fraction) * rect.height)
        }
    }
}

/// How a number is written where a person reads it, rather than where a
/// formatter does.
enum UsageFormat {
    /// Bytes as MB up to a gigabyte, then GB. The same rule the per-tab rows
    /// use, kept in one place so a total and a row never disagree about what
    /// 1,024 MB is called.
    static func memory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / (1024 * 1024)
        if megabytes >= 1024 {
            return String(format: "%.2f GB", megabytes / 1024)
        }
        return String(format: "%.0f MB", megabytes)
    }

    static func megabytes(_ bytes: UInt64) -> Double {
        Double(bytes) / (1024 * 1024)
    }

    /// "1 tab", "3 tabs". Every line in the Task Manager is built out of counts
    /// and a window that says "1 tabs" is a window nobody proofread.
    static func count(_ number: Int, _ noun: String, plural: String? = nil) -> String {
        "\(number) \(number == 1 ? noun : plural ?? noun + "s")"
    }

    /// A percentage that can pass 100: CPU is counted per core, so a page
    /// burning two of them says 200% -- the same thing Activity Monitor says.
    static func percentage(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}

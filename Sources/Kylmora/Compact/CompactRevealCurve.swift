import QuartzCore

/// The sidebar's reveal easing: a sampled spring that overshoots slightly and
/// does not quite settle.
///
/// The reference curve is a 101-stop CSS `linear()` function. Only twelve of those
/// stops were recovered from the source, so the rest are reconstructed here by
/// shape-preserving cubic interpolation rather than invented as a bezier. The
/// distinction matters: the curve's character is the 1.1% overshoot peaking at
/// 73% and the deliberate 0.34% short landing, and no cubic bezier can express
/// either -- a bezier is confined to its control points' range, so it cannot
/// exceed 1 at all.
///
/// Why not `CASpringAnimation`: a spring is parameterised by mass and damping,
/// and fitting those to a sampled curve is guesswork that lands near the shape
/// rather than on it. Feeding the samples to a `CAKeyframeAnimation` reproduces
/// exactly the curve that was measured, and it is the same amount of code.
enum CompactRevealCurve {

    /// Paired duration.
    static let duration: Double = 0.25

    /// The recovered stops: time in the unit interval, progress at that time.
    ///
    /// Reproduced from the specification's reading of the `linear()` list, not
    /// from the original source.
    static let knots: [(time: Double, value: Double)] = [
        (0.00, 0.0),
        (0.10, 0.188662),
        (0.20, 0.497000),
        (0.30, 0.743381),
        (0.40, 0.894782),
        (0.50, 0.971397),
        (0.60, 1.002456),
        (0.70, 1.010649),
        (0.73, 1.010904),
        (0.80, 1.009681),
        (0.90, 1.006372),
        (1.00, 1.003423)
    ]

    /// Progress at a point in the animation, clamped outside the unit interval.
    ///
    /// Interpolation is Fritsch-Carlson: it never introduces a wiggle between
    /// two samples, which a natural cubic spline does and which here would show
    /// up as the sidebar visibly stuttering backwards halfway through its
    /// slide. The curve rises, turns over once and falls, and Fritsch-Carlson
    /// preserves exactly that.
    static func value(at time: Double) -> Double {
        guard time > 0 else { return knots[0].value }
        guard time < 1 else { return knots[knots.count - 1].value }

        let index = (1..<knots.count).first { time < knots[$0].time } ?? knots.count - 1
        let left = knots[index - 1]
        let right = knots[index]
        let h = right.time - left.time
        let t = (time - left.time) / h

        let mLeft = tangent(at: index - 1)
        let mRight = tangent(at: index)

        // Hermite basis.
        let t2 = t * t
        let t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * left.value
            + (t3 - 2 * t2 + t) * h * mLeft
            + (-2 * t3 + 3 * t2) * right.value
            + (t3 - t2) * h * mRight
    }

    /// `count` evenly spaced samples, which is what a keyframe animation wants.
    static func samples(count: Int = 101) -> [Double] {
        guard count > 1 else { return [value(at: 0)] }
        return (0..<count).map { value(at: Double($0) / Double(count - 1)) }
    }

    /// Secant slope of each segment between two knots.
    private static let secants: [Double] = (0..<(knots.count - 1)).map { i in
        (knots[i + 1].value - knots[i].value) / (knots[i + 1].time - knots[i].time)
    }

    /// Slope at a knot, limited so the segments either side stay monotone.
    ///
    /// Fritsch-Carlson's limiter: a tangent longer than three times the shorter
    /// neighbouring secant is what lets an interpolant bulge past its own
    /// samples, which here would read as the sidebar stuttering mid-slide.
    private static func tangent(at index: Int) -> Double {
        let raw: Double
        if index == 0 {
            raw = secants[0]
        } else if index == knots.count - 1 {
            raw = secants[secants.count - 1]
        } else {
            let before = secants[index - 1]
            let after = secants[index]
            // A sign change is the turning point at 73%; a zero tangent there
            // is what keeps the peak at the sampled height instead of above it.
            raw = before * after <= 0 ? 0 : (before + after) / 2
        }

        var limit = Double.greatestFiniteMagnitude
        if index > 0 { limit = min(limit, 3 * abs(secants[index - 1])) }
        if index < secants.count { limit = min(limit, 3 * abs(secants[index])) }
        return limit.isFinite ? max(-limit, min(limit, raw)) : raw
    }
}

extension CompactTimingCurve {
    /// The Core Animation timing function for the curves that have one.
    ///
    /// `revealSpring` has none -- it is not expressible as a bezier -- so it
    /// answers nil and the caller drives a keyframe animation instead. Making
    /// that an explicit nil rather than a nearest-bezier approximation keeps
    /// the one curve that cannot be faked from being quietly faked.
    var mediaTimingFunction: CAMediaTimingFunction? {
        switch self {
        case .linear: CAMediaTimingFunction(name: .linear)
        case .ease: CAMediaTimingFunction(name: .default)
        case .easeIn: CAMediaTimingFunction(name: .easeIn)
        case .easeOut: CAMediaTimingFunction(name: .easeOut)
        case .revealSpring: nil
        }
    }
}

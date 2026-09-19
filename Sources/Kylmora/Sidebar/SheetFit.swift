import CoreGraphics

/// How tall a panel-style sheet may grow before its content starts to scroll.
///
/// The New Space sheet sizes itself to whatever its sections add up to, which
/// is fine on the machine it was designed on and wrong on a Mac set to larger
/// text or a scaled resolution: the same sections come out taller, the sheet
/// runs off the bottom, and the buttons that dismiss it go with it. So the
/// sheet asks for its content height and takes whichever is smaller, this cap
/// or that -- the rest scrolls.
///
/// Two things cap it, because two things can be small. The screen is the
/// obvious one. The window the sheet hangs from is the other: a sheet is
/// attached to its parent, and one taller than the window it is attached to
/// hangs off the top and the bottom of it no matter how much screen there is.
enum SheetFit {
    /// The share of the screen a sheet may take.
    ///
    /// Generous, because the sheet's job is to be read in one go -- the cap is
    /// there to keep it on the screen and its buttons reachable, not to keep it
    /// small.
    static let screenFraction: CGFloat = 0.85
    /// How much of the parent window is left showing around a sheet.
    static let windowMargin: CGFloat = 24
    /// A floor under the cap, so a short screen or a small window still shows
    /// something worth reading rather than a sliver. Never taller than the
    /// thing it is measured against.
    static let minimumHeight: CGFloat = 360

    /// The height to give a sheet whose content wants `content` points, on a
    /// screen `screen` points tall, hanging from a window `window` points tall.
    /// A zero means "not known", and that measure simply does not apply.
    static func height(
        content: CGFloat,
        screen: CGFloat,
        window: CGFloat = 0,
        fraction: CGFloat = screenFraction,
        minimum: CGFloat = minimumHeight
    ) -> CGFloat {
        var cap = CGFloat.greatestFiniteMagnitude
        if screen > 0 {
            cap = min(cap, max(screen * fraction, min(minimum, screen)))
        }
        if window > 0 {
            cap = min(cap, max(window - windowMargin, min(minimum, window)))
        }
        return cap == .greatestFiniteMagnitude ? content : min(content, cap)
    }

    /// Whether a sheet of `height` has had to leave some of its `content`
    /// below the fold -- which is when the sections scroll, and when the sheet
    /// owes the reader a hint that they do.
    static func overflows(content: CGFloat, height: CGFloat) -> Bool {
        content > height + 0.5
    }
}

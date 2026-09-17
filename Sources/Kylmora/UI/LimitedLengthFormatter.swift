import Foundation

/// Stops a text field accepting more characters than the thing behind it will
/// keep.
///
/// The model clamps a name that is too long (`Space.clampName`), which is the
/// rule that matters -- a name can arrive from the companion iPhone or from a
/// session file as easily as from a keyboard. But a field that takes fifty
/// characters and then stores twenty-four is a field that lied: the user
/// watched their name go in and saw something else come back out.
///
/// So the field refuses the twenty-fifth character instead, which AppKit
/// signals with a beep. A formatter rather than a delegate, because this has to
/// catch a paste as well as a keystroke, and `isPartialStringValid` is the one
/// place both arrive.
final class LimitedLengthFormatter: Formatter, @unchecked Sendable {
    let limit: Int

    init(limit: Int) {
        self.limit = limit
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("LimitedLengthFormatter is created in code only")
    }

    override func string(for obj: Any?) -> String? {
        obj as? String
    }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
        for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        obj?.pointee = string as NSString
        return true
    }

    /// Counted in characters, the way a person counts them: `count` on a
    /// `String` is grapheme clusters, so an emoji or an accented letter is one
    /// character here and one character to whoever typed it.
    override func isPartialStringValid(
        _ partialString: String,
        newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        partialString.count <= limit
    }
}

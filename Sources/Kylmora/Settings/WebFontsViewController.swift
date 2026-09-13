import AppKit

/// The sheet behind "Customize…" on a space's default font: the standard
/// and fixed-width families and their sizes.
@MainActor
final class WebFontsViewController: NSViewController {
    var fonts: WebFonts
    var onDone: ((WebFonts) -> Void)?

    private let standardFamily = NSPopUpButton()
    private let standardSize = NSTextField()
    private let standardStepper = NSStepper()
    private let fixedFamily = NSPopUpButton()
    private let fixedSize = NSTextField()
    private let fixedStepper = NSStepper()

    init(fonts: WebFonts) {
        self.fonts = fonts
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("WebFontsViewController is created in code only")
    }

    override func loadView() {
        let form = SettingsForm()
        view = form

        Self.fill(standardFamily, selecting: fonts.standardFamily)
        Self.fill(fixedFamily, selecting: fonts.fixedFamily)
        for (field, stepper, value) in [(standardSize, standardStepper, fonts.standardSize), (fixedSize, fixedStepper, fonts.fixedSize)] {
            field.integerValue = value
            field.alignment = .right
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 44).isActive = true
            field.target = self
            field.action = #selector(sizeTyped(_:))
            stepper.minValue = Double(WebFonts.sizeRange.lowerBound)
            stepper.maxValue = Double(WebFonts.sizeRange.upperBound)
            stepper.integerValue = value
            stepper.target = self
            stepper.action = #selector(sizeStepped(_:))
        }
        standardFamily.target = self
        standardFamily.action = #selector(familyChanged)
        fixedFamily.target = self
        fixedFamily.action = #selector(familyChanged)
        standardSize.setAccessibilityLabel("Standard font size")
        fixedSize.setAccessibilityLabel("Fixed-width font size")

        form.addRow("Standard font", [SettingsForm.fill(standardFamily), standardSize, standardStepper])
        form.addRow("Fixed-width font", [SettingsForm.fill(fixedFamily), fixedSize, fixedStepper])
        form.addNote("Pages that choose their own fonts keep them. These are what a page gets when it does not.")

        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(reset))
        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        form.addRow("", [reset, done])
    }

    private static func fill(_ popUp: NSPopUpButton, selecting family: String) {
        let families = NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        popUp.removeAllItems()
        popUp.addItems(withTitles: families)
        if !families.contains(family) { popUp.addItem(withTitle: family) }
        popUp.selectItem(withTitle: family)
    }

    private func read() {
        fonts.standardFamily = standardFamily.titleOfSelectedItem ?? fonts.standardFamily
        fonts.fixedFamily = fixedFamily.titleOfSelectedItem ?? fonts.fixedFamily
        fonts.standardSize = Self.clamp(standardSize.integerValue)
        fonts.fixedSize = Self.clamp(fixedSize.integerValue)
        standardSize.integerValue = fonts.standardSize
        fixedSize.integerValue = fonts.fixedSize
        standardStepper.integerValue = fonts.standardSize
        fixedStepper.integerValue = fonts.fixedSize
    }

    private static func clamp(_ size: Int) -> Int {
        min(max(size, WebFonts.sizeRange.lowerBound), WebFonts.sizeRange.upperBound)
    }

    @objc private func familyChanged() { read() }

    @objc private func sizeTyped(_ sender: NSTextField) { read() }

    @objc private func sizeStepped(_ sender: NSStepper) {
        (sender === standardStepper ? standardSize : fixedSize).integerValue = sender.integerValue
        read()
    }

    @objc private func reset() {
        fonts = .webKitDefaults
        Self.fill(standardFamily, selecting: fonts.standardFamily)
        Self.fill(fixedFamily, selecting: fonts.fixedFamily)
        standardSize.integerValue = fonts.standardSize
        fixedSize.integerValue = fonts.fixedSize
        standardStepper.integerValue = fonts.standardSize
        fixedStepper.integerValue = fonts.fixedSize
    }

    @objc private func finish() {
        read()
        onDone?(fonts)
        dismiss(nil)
    }
}

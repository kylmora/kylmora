import AppKit
import Foundation
import WebKit

/// The live Boost editor: inspect, customize, and edit CSS, JavaScript, and Dark Mode
/// for the current website in real-time.
@MainActor
final class BoostEditorViewController: NSViewController {
    private let url: URL?
    private weak var webView: WKWebView?
    private var boost: Boost

    private let hostLabel = NSTextField(labelWithString: "")
    private let enableSwitch = NSSwitch()
    private let darkModeButton = NSButton()
    private let segmentedControl = NSSegmentedControl(labels: ["CSS", "JavaScript", "Presets"], trackingMode: .selectOne, target: nil, action: nil)

    private let containerView = NSView()
    private var cssScrollView: NSScrollView!
    private var cssTextView: NSTextView!

    private var jsScrollView: NSScrollView!
    private var jsTextView: NSTextView!

    private var presetsView: NSView!

    init(url: URL?, webView: WKWebView?) {
        self.url = url
        self.webView = webView
        let host = SiteSettings.normalise(url?.host() ?? "this-site")
        self.boost = BoostStore.shared.boost(forHost: host) ?? Boost(host: host)
        super.init(nibName: nil, bundle: nil)
    }

    convenience init(host: String, webView: WKWebView?) {
        self.init(url: URL(string: "https://\(host)"), webView: webView)
    }

    required init?(coder: NSCoder) {
        fatalError("BoostEditorViewController is created in code only")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 460))
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        buildLayout()
    }

    private func buildLayout() {
        // Header
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Boost")
        icon.contentTintColor = .systemPurple
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 24).isActive = true

        hostLabel.font = .systemFont(ofSize: 15, weight: .bold)
        hostLabel.stringValue = "Boost for \(boost.host)"

        enableSwitch.state = boost.isEnabled ? .on : .off
        enableSwitch.target = self
        enableSwitch.action = #selector(enableToggled)

        let switchStack = NSStackView(views: [NSTextField(labelWithString: "Enabled"), enableSwitch])
        switchStack.orientation = .horizontal
        switchStack.alignment = .centerY
        switchStack.spacing = 6

        let topRow = NSStackView(views: [icon, hostLabel, NSView(), switchStack])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8
        topRow.translatesAutoresizingMaskIntoConstraints = false

        // Dark Mode Quick Toggle
        darkModeButton.title = boost.isDarkModeEnabled ? "🌙 Dark Mode: Active" : "☀️ Dark Mode: Off"
        darkModeButton.bezelStyle = .rounded
        darkModeButton.state = boost.isDarkModeEnabled ? .on : .off
        darkModeButton.target = self
        darkModeButton.action = #selector(darkModeToggled)

        segmentedControl.selectedSegment = 0
        segmentedControl.target = self
        segmentedControl.action = #selector(segmentChanged)
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false

        let controlRow = NSStackView(views: [segmentedControl, NSView(), darkModeButton])
        controlRow.orientation = .horizontal
        controlRow.alignment = .centerY
        controlRow.translatesAutoresizingMaskIntoConstraints = false

        // Content areas
        containerView.translatesAutoresizingMaskIntoConstraints = false
        buildEditors()

        // Footer buttons
        let resetBtn = NSButton(title: "Clear", target: self, action: #selector(resetTapped))
        resetBtn.bezelStyle = .rounded
        resetBtn.controlSize = .small

        let applyBtn = NSButton(title: "Apply Live", target: self, action: #selector(applyLiveTapped))
        applyBtn.bezelStyle = .rounded
        applyBtn.keyEquivalent = "\r"

        let doneBtn = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        doneBtn.bezelStyle = .rounded

        let footer = NSStackView(views: [resetBtn, NSView(), applyBtn, doneBtn])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [topRow, controlRow, containerView, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 480),
            view.heightAnchor.constraint(equalToConstant: 460),

            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),

            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            controlRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            containerView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func buildEditors() {
        // CSS Editor
        let (cssScroll, cssText) = makeCodeEditor(
            placeholder: "/* Custom CSS for \(boost.host) */\n\n/* Example:\nbody {\n  font-family: -apple-system, sans-serif;\n}\n*/",
            content: boost.customCSS
        )
        cssScrollView = cssScroll
        cssTextView = cssText
        containerView.addSubview(cssScroll)

        // JS Editor
        let (jsScroll, jsText) = makeCodeEditor(
            placeholder: "// Custom JavaScript for \(boost.host)\n\n// Example:\n// console.log('Boost active on', window.location.href);\n",
            content: boost.customJS
        )
        jsScrollView = jsScroll
        jsTextView = jsText
        containerView.addSubview(jsScroll)

        // Presets view
        buildPresetsView()
        containerView.addSubview(presetsView)

        for subview in [cssScroll, jsScroll, presetsView!] {
            NSLayoutConstraint.activate([
                subview.topAnchor.constraint(equalTo: containerView.topAnchor),
                subview.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                subview.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
            ])
        }

        updateSegmentVisibility()
    }

    private func makeCodeEditor(placeholder: String, content: String) -> (NSScrollView, NSTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = content.isEmpty ? "" : content
        textView.delegate = self
        scroll.documentView = textView

        return (scroll, textView)
    }

    private func buildPresetsView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let blurb = NSTextField(wrappingLabelWithString: "Quick styling presets. Click any preset to append it into your Custom CSS:")
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = .secondaryLabelColor

        let p1 = makePresetButton(title: "Clean Reading Mode (Centered 720px width)", css: "\n/* Clean Reading View */\nmain, article, .content, #content {\n  max-width: 720px !important;\n  margin: 0 auto !important;\n  font-size: 18px !important;\n  line-height: 1.65 !important;\n}\n")
        let p2 = makePresetButton(title: "Unstick Headers & Navbars", css: "\n/* Unstick Fixed Headers */\nheader[style*='fixed'], nav[style*='fixed'], [class*='sticky'], [class*='fixed-top'] {\n  position: relative !important;\n}\n")
        let p3 = makePresetButton(title: "Native Apple San Francisco Font", css: "\n/* Apple System Font */\n* {\n  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif !important;\n}\n")
        let p4 = makePresetButton(title: "Hide Cookie Notices & Modals", css: "\n/* Hide Annoying Popups */\n[id*='cookie'], [class*='cookie'], [id*='consent'], [class*='consent'], [id*='modal-newsletter'] {\n  display: none !important;\n}\n")

        let stack = NSStackView(views: [blurb, p1, p2, p3, p4])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])

        presetsView = root
    }

    private func makePresetButton(title: String, css: String) -> NSButton {
        let btn = NSButton(title: "+ \(title)", target: self, action: #selector(presetClicked(_:)))
        btn.bezelStyle = .rounded
        btn.identifier = NSUserInterfaceItemIdentifier(css)
        return btn
    }

    @objc private func presetClicked(_ sender: NSButton) {
        guard let css = sender.identifier?.rawValue else { return }
        var current = cssTextView.string
        current += css
        cssTextView.string = current
        segmentedControl.selectedSegment = 0
        updateSegmentVisibility()
        applyLive()
    }

    private func updateSegmentVisibility() {
        let idx = segmentedControl.selectedSegment
        cssScrollView.isHidden = idx != 0
        jsScrollView.isHidden = idx != 1
        presetsView.isHidden = idx != 2
    }

    @objc private func segmentChanged() {
        updateSegmentVisibility()
    }

    @objc private func enableToggled() {
        boost.isEnabled = enableSwitch.state == .on
        applyLive()
    }

    @objc private func darkModeToggled() {
        boost.isDarkModeEnabled.toggle()
        darkModeButton.title = boost.isDarkModeEnabled ? "🌙 Dark Mode: Active" : "☀️ Dark Mode: Off"
        darkModeButton.state = boost.isDarkModeEnabled ? .on : .off
        applyLive()
    }

    @objc private func applyLiveTapped() {
        applyLive()
    }

    @objc private func resetTapped() {
        cssTextView.string = ""
        jsTextView.string = ""
        boost.isDarkModeEnabled = false
        darkModeButton.title = "☀️ Dark Mode: Off"
        darkModeButton.state = .off
        applyLive()
    }

    @objc private func doneTapped() {
        saveAndApply()
        dismiss(nil)
    }

    private func saveAndApply() {
        boost.customCSS = cssTextView.string
        boost.customJS = jsTextView.string
        BoostStore.shared.save(boost)
        if let webView {
            BoostCoordinator.shared.applyLive(boost: boost, to: webView)
        }
    }

    private func applyLive() {
        boost.customCSS = cssTextView.string
        boost.customJS = jsTextView.string
        BoostStore.shared.save(boost)
        if let webView {
            BoostCoordinator.shared.applyLive(boost: boost, to: webView)
        }
    }
}

extension BoostEditorViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        applyLive()
    }
}

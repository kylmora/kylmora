import AppKit
import WebKit

/// Hosts the live pages of a split, side by side or stacked, with draggable
/// dividers between them.
///
/// The tree of `SplitLayout.Node`s maps one-for-one onto nested `NSSplitView`s,
/// which is the whole reason this file is short: divider dragging, the resize
/// cursor, hit-testing the gap and proportional behaviour on a window resize are
/// all AppKit's, rather than hand-rolled in JavaScript over
/// `style.inset` and raw pointer maths.
///
/// This view renders and reports. It never changes the model: which tab is
/// focused and which panes exist are `BrowserSession`'s to decide, so
/// every gesture here comes back out as a callback.
@MainActor
final class SplitContainerView: NSView {

    /// A click landed in a pane that is not the focused one.
    var onFocusPane: ((Tab.ID) -> Void)?
    /// The pane's close button was pressed.
    var onClosePane: ((Tab.ID) -> Void)?
    /// Toggles the sticky/pinned state of a pane.
    var onToggleStickPane: ((Tab.ID) -> Void)?
    /// Separates a pane into a standalone tab (unsplit).
    var onUnsplitPane: ((Tab.ID) -> Void)?
    /// Double-click on divider or command to equalize split panes.
    var onEqualize: (([Int]) -> Void)?
    /// A divider was dragged. Carries the whole layout, because the proportions
    /// of one node are only meaningful inside the tree they belong to.
    var onLayoutChange: ((SplitLayout) -> Void)?

    private var splitLayout: SplitLayout?
    private var focusedTabID: Tab.ID?
    private var isStickyChecker: ((Tab.ID) -> Bool)?
    private var panes: [Tab.ID: SplitPaneView] = [:]
    private var splitViews: [PaneSplitView] = []
    private var rootView: NSView?
    /// What the currently built view tree is a rendering of. A drag changes
    /// proportions many times a second and must not rebuild anything.
    private var builtStructure: String?

    private var clickMonitor: Any?
    /// `setPosition(_:ofDividerAt:)` resizes subviews, which calls back into the
    /// delegate. Without this the applied shares would be read straight back out
    /// and reported as if the user had dragged something.
    private var isApplyingShares = false
    /// Split views whose divider the user is currently dragging, identified in
    /// `constrainSplitPosition`, which AppKit calls only for a real drag.
    private var draggingSplitViews: Set<ObjectIdentifier> = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("SplitContainerView is created in code only")
    }

    // MARK: - Showing a split

    /// Renders `layout` using the pages of `tabs`, with `focused` outlined.
    ///
    /// Tabs missing from `tabs` are ignored rather than drawn empty: the only
    /// way that can happen is a model change racing a redraw, and an empty pane
    /// would be exactly the fake state that must never be shown.
    func show(tabs: [Tab], layout: SplitLayout, focused: Tab.ID?, isSticky: ((Tab.ID) -> Bool)? = nil) {
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        guard layout.tabIDs.allSatisfy({ byID[$0] != nil }) else { return }

        self.splitLayout = layout
        self.isStickyChecker = isSticky
        let structure = Self.structure(of: layout.root)
        if structure != builtStructure {
            rebuild(layout: layout, tabs: byID)
            builtStructure = structure
        }

        // Every pane of a visible split is live. This is the point where a
        // suspended member comes back, and the reason `visibleTabIDs` must
        // report all of them.
        for id in layout.tabIDs {
            guard let pane = panes[id], let tab = byID[id] else { continue }
            tab.markActive()
            pane.adopt(tab.webView(), document: tab.contentOverlay)
            pane.setSticky(isSticky?(id) ?? false)
        }

        setFocused(focused)
        needsLayout = true
    }

    /// Called when the split goes away, so each tab keeps its page for whatever
    /// shows it next. The web views are not unloaded: a tab leaving a split is
    /// still a tab, and reloading it would lose scroll position and form state
    /// for a layout change the user did not think of as navigation.
    func tearDown() {
        for pane in panes.values { pane.releaseWebView() }
        panes.removeAll()
        splitViews.removeAll()
        rootView?.removeFromSuperview()
        rootView = nil
        builtStructure = nil
        splitLayout = nil
        focusedTabID = nil
    }

    private func setFocused(_ focused: Tab.ID?) {
        focusedTabID = focused
        for (id, pane) in panes { pane.setFocused(id == focused) }
    }

    // MARK: - Building

    /// The part of a layout that decides what views exist: the tabs, their
    /// order and the axes above them. Proportions are deliberately absent.
    private static func structure(of node: SplitLayout.Node) -> String {
        switch node {
        case .pane(let id, _):
            return id.uuidString
        case .split(let axis, let children, _):
            let axisName = axis == .horizontal ? "h" : "v"
            return "\(axisName)(\(children.map(structure(of:)).joined(separator: ",")))"
        }
    }

    private func rebuild(layout: SplitLayout, tabs: [Tab.ID: Tab]) {
        // Detach first so a pane that survives the rebuild keeps its web view
        // and its page is never torn down by a mere rearrangement.
        for pane in panes.values { pane.removeFromSuperview() }
        splitViews.removeAll()
        rootView?.removeFromSuperview()

        let live = Set(layout.tabIDs)
        for (id, pane) in panes where !live.contains(id) {
            pane.releaseWebView()
            panes[id] = nil
        }

        let root = makeView(for: layout.root, path: [])
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        rootView = root
    }

    private func makeView(for node: SplitLayout.Node, path: [Int]) -> NSView {
        switch node {
        case .pane(let id, _):
            if let existing = panes[id] { return existing }
            let pane = SplitPaneView(tabID: id)
            pane.onClose = { [weak self] in self?.onClosePane?(id) }
            pane.onToggleStick = { [weak self] in self?.onToggleStickPane?(id) }
            pane.onUnsplit = { [weak self] in self?.onUnsplitPane?(id) }
            panes[id] = pane
            return pane

        case .split(let axis, let children, _):
            let splitView = PaneSplitView(axis: axis, path: path)
            splitView.delegate = self
            splitView.onEqualize = { [weak self] path in self?.onEqualize?(path) }
            for (index, child) in children.enumerated() {
                splitView.addArrangedSubview(makeView(for: child, path: path + [index]))
            }
            splitViews.append(splitView)
            return splitView
        }
    }

    // MARK: - Proportions

    /// Shares are applied on every layout pass rather than only when they
    /// change. `NSSplitView`'s own proportional resizing rounds to whole points,
    /// so reasserting the model's percentages is what stops a pane drifting a
    /// point per window resize until a 50/50 split is visibly not.
    override func layout() {
        super.layout()
        guard let splitLayout, !isApplyingShares else { return }

        isApplyingShares = true
        defer { isApplyingShares = false }

        for splitView in splitViews {
            guard case .split(_, let children, _) = splitLayout.node(at: splitView.path) else { continue }
            guard children.count == splitView.arrangedSubviews.count else { continue }

            let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
            let content = length - CGFloat(children.count - 1) * splitView.dividerThickness
            guard content > 0 else { continue }

            var offset: CGFloat = 0
            for index in 0..<(children.count - 1) {
                offset += content * children[index].share
                splitView.setPosition(offset, ofDividerAt: index)
                offset += splitView.dividerThickness
            }
        }
    }

    private func readShares(from splitView: PaneSplitView) {
        guard let splitLayout else { return }
        let sizes = splitView.arrangedSubviews.map { splitView.isVertical ? $0.frame.width : $0.frame.height }
        let total = sizes.reduce(0, +)
        guard total > 0 else { return }

        let shares = sizes.map { Double($0 / total) }
        let updated = splitLayout.settingShares(at: splitView.path, to: shares)
        guard updated != splitLayout else { return }
        self.splitLayout = updated
        onLayoutChange?(updated)
    }

    // MARK: - Focus

    /// A click anywhere in an unfocused pane focuses it, and still reaches the
    /// page.
    ///
    /// A local monitor rather than `mouseDown`, because the web view is a
    /// first-class responder that consumes the event before any superview sees
    /// it, and rather than `hitTest`, which AppKit also calls for cursor updates
    /// and would move focus on hover. Returning the event unchanged is what
    /// keeps the click a click: focusing a pane must not eat the gesture that
    /// focused it, and the previously focused pane stays live.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeClickMonitor()
        } else if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.focusPane(under: event) }
                return event
            }
        }
    }

    /// The monitor is torn down when the view leaves its window rather than in
    /// `deinit`: a view is always removed from its window before it is released,
    /// and a `deinit` cannot touch main-actor state under strict concurrency.
    private func removeClickMonitor() {
        guard let clickMonitor else { return }
        NSEvent.removeMonitor(clickMonitor)
        self.clickMonitor = nil
    }

    private func focusPane(under event: NSEvent) {
        guard event.window === window, window != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }

        for (id, pane) in panes where id != focusedTabID {
            if pane.convert(point, from: self).isInside(pane.bounds) {
                onFocusPane?(id)
                return
            }
        }
    }
}

private extension NSPoint {
    /// `NSRect.contains` on a point converted from a superview, spelled as an
    /// extension only so the loop above reads as a sentence.
    func isInside(_ rect: NSRect) -> Bool { rect.contains(self) }
}

// MARK: - NSSplitViewDelegate

extension SplitContainerView: NSSplitViewDelegate {

    /// Called only while a divider is actually being dragged, which is what
    /// makes it a reliable signal that the next resize is the user's doing and
    /// not a window resize or our own `setPosition`.
    func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        draggingSplitViews.insert(ObjectIdentifier(splitView))
        // Smart snapping: Snap to exact 50/50 center when within 14pt threshold
        let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let center = total / 2.0
        if abs(proposedPosition - center) < 14.0 {
            return center
        }
        return proposedPosition
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard let pane = minimumPaneLength(in: splitView) else { return proposedMinimumPosition }
        let thickness = splitView.dividerThickness
        return max(proposedMinimumPosition, CGFloat(dividerIndex + 1) * pane + CGFloat(dividerIndex) * thickness)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard let pane = minimumPaneLength(in: splitView) else { return proposedMaximumPosition }
        let count = splitView.arrangedSubviews.count
        let after = CGFloat(count - 1 - dividerIndex)
        let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return min(proposedMaximumPosition, length - after * (pane + splitView.dividerThickness))
    }

    /// The 7% floor, in points for this split view's current size. Enforcing a
    /// percentage rather than a pixel width is what makes "how far can I squash
    /// a pane" the same gesture on a laptop and on a 6K display.
    private func minimumPaneLength(in splitView: NSSplitView) -> CGFloat? {
        let count = splitView.arrangedSubviews.count
        guard count > 1 else { return nil }
        let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let content = length - CGFloat(count - 1) * splitView.dividerThickness
        guard content > 0 else { return nil }
        return content * SplitLayout.minimumShare
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isApplyingShares,
              let splitView = notification.object as? PaneSplitView,
              draggingSplitViews.remove(ObjectIdentifier(splitView)) != nil
        else { return }
        readShares(from: splitView)
    }
}

// MARK: - The split view itself

/// An `NSSplitView` that knows which model node it renders and draws its
/// divider with a subtle centered drag handle pill.
private final class PaneSplitView: NSSplitView {
    let path: [Int]
    private let gap: CGFloat
    var onEqualize: (([Int]) -> Void)?

    init(axis: SplitLayout.Axis, path: [Int]) {
        self.path = path
        self.gap = SplitMetrics.dividerThickness(for: axis)
        super.init(frame: .zero)
        // `isVertical` names the divider, not the flow: a vertical divider puts
        // the panes beside each other.
        isVertical = axis == .horizontal
        dividerStyle = .thin
    }

    required init?(coder: NSCoder) {
        fatalError("PaneSplitView is created in code only")
    }

    override var dividerThickness: CGFloat { gap }

    override func drawDivider(in rect: NSRect) {
        super.drawDivider(in: rect)

        let pillColor = NSColor.separatorColor.withAlphaComponent(0.65)
        pillColor.setFill()

        let handleRect: NSRect
        if isVertical {
            let width: CGFloat = 3
            let height: CGFloat = min(36, max(0, rect.height - 16))
            guard height > 0 else { return }
            handleRect = NSRect(
                x: rect.midX - width / 2.0,
                y: rect.midY - height / 2.0,
                width: width,
                height: height
            )
        } else {
            let height: CGFloat = 3
            let width: CGFloat = min(36, max(0, rect.width - 16))
            guard width > 0 else { return }
            handleRect = NSRect(
                x: rect.midX - width / 2.0,
                y: rect.midY - height / 2.0,
                width: width,
                height: height
            )
        }
        let pillPath = NSBezierPath(roundedRect: handleRect, xRadius: 1.5, yRadius: 1.5)
        pillPath.fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onEqualize?(path)
            return
        }
        super.mouseDown(with: event)
    }
}

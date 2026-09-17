import AppKit
import Testing
@testable import Kylmora

// Swiping between spaces was making the sidebar creep wider: a little on each
// swipe, never coming back. Reproduced here rather than by hand, because a
// trackpad swipe cannot be sent from a script.

@Suite("Swiping spaces does not widen the sidebar")
@MainActor
struct SidebarSwipeWidthTests {
    private func sidebar(width: CGFloat = 245) -> SidebarViewController {
        let session = TestSession.make().0
        session.addSpace(named: "Work")
        session.addSpace(named: "Studio")
        // Standing on the first space, so there is a neighbour to swipe
        // towards: `addSpace` leaves the new one active, and the last space has
        // nothing to its right.
        session.selectSpace(session.spaces[0])
        let sidebar = SidebarViewController(session: session)
        let view = sidebar.view
        view.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        view.layoutSubtreeIfNeeded()
        return sidebar
    }

    @Test("A swipe in flight does not ask for a wider sidebar")
    func swipeDoesNotDemandWidth() {
        // The still of the neighbouring space is parked one whole sidebar to
        // the side. Laid out by frame, it is also -- unless told otherwise --
        // laid out by Auto Layout, and a subview sitting 245 points to the
        // right of a 245-point view says the view needs to be 490 wide. The
        // split view grants some of that, and the sidebar is wider than it was
        // before the swipe. Every swipe, a little more.
        let sidebar = self.sidebar()
        let atRest = sidebar.view.fittingSize.width

        sidebar.applySwipe(translation: -40, crossfade: 0.2)
        sidebar.view.layoutSubtreeIfNeeded()
        let midSwipe = sidebar.view.fittingSize.width

        // The test is worthless unless the swipe actually put a still on the
        // sidebar, which is the thing suspected of demanding the width -- so
        // say which case is being exercised rather than passing either way.
        //
        // Both branches are real: a machine that reduces motion has no
        // filmstrip to drag, and `applySwipe` returns before making one. CI
        // runs that way, which is how this test first failed there while
        // passing on a desk.
        func stills(in view: NSView) -> [NSView] {
            view.subviews.filter { "\(type(of: $0))".contains("SpaceStill") }
                + view.subviews.flatMap { stills(in: $0) }
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(stills(in: sidebar.view).isEmpty, "reduced motion slides nothing")
        } else {
            #expect(!stills(in: sidebar.view).isEmpty, "the swipe should have made a still")
        }

        #expect(
            midSwipe <= atRest + 1,
            "mid-swipe the sidebar asks for \(midSwipe) where at rest it asked for \(atRest)"
        )
    }

    @Test("And the demand does not survive the swipe")
    func widthIsGivenBack() {
        let sidebar = self.sidebar()
        let atRest = sidebar.view.fittingSize.width
        sidebar.applySwipe(translation: -40, crossfade: 0.2)
        sidebar.view.layoutSubtreeIfNeeded()
        sidebar.cancelSwipe()
        sidebar.view.layoutSubtreeIfNeeded()
        #expect(sidebar.view.fittingSize.width <= atRest + 1)
    }
}

@Suite("A space's name never widens the sidebar")
@MainActor
struct SidebarNameWidthTests {
    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? all(type, in: $0) }
    }

    /// The name pill at the top of the sidebar.
    private func namePill(in view: NSView) -> MenuLabelButton? {
        all(MenuLabelButton.self, in: view).first
    }

    @Test("The name yields rather than pushing the divider out")
    func nameDoesNotResistCompression() {
        // Measured in the running browser before this was fixed: walking
        // through eleven spaces, the sidebar sat at 199.5 for most of them,
        // jumped to 220.5 on "Daily Dashboard" and to 240 on "Read Later
        // BF9059", and stayed there -- the long name asked for its full width
        // at the default resistance, and the split view granted the ask.
        //
        // Priorities rather than a measured width, because what the split view
        // honours is the *required* minimum, and AppKit's `fittingSize`
        // reports what the content would prefer as well.
        let session = TestSession.make().0
        let sidebar = SidebarViewController(session: session)
        let view = sidebar.view
        view.frame = NSRect(x: 0, y: 0, width: 245, height: 800)
        view.layoutSubtreeIfNeeded()

        guard let pill = namePill(in: view) else {
            Issue.record("the sidebar should show the space's name")
            return
        }
        #expect(
            pill.contentCompressionResistancePriority(for: .horizontal) < .defaultHigh,
            "the pill passes the label's width on, so it has to yield too"
        )
        for label in all(NSTextField.self, in: pill) {
            #expect(label.contentCompressionResistancePriority(for: .horizontal) < .defaultHigh)
            #expect(label.lineBreakMode == .byTruncatingTail, "and it has to have somewhere to go")
        }
    }

    @Test("A long name still reaches the sidebar, it is just not allowed to stretch it")
    func longNameIsStillShown() {
        let session = TestSession.make().0
        session.rename(session.activeSpace, to: "Read Later BF9059")
        let sidebar = SidebarViewController(session: session)
        let view = sidebar.view
        view.frame = NSRect(x: 0, y: 0, width: 245, height: 800)
        view.layoutSubtreeIfNeeded()

        guard let pill = namePill(in: view) else {
            Issue.record("the sidebar should show the space's name")
            return
        }
        let shown = all(NSTextField.self, in: pill).map(\.stringValue)
        #expect(shown.contains("Read Later BF9059"))
    }
}

@Suite("The divider stays where it was put")
@MainActor
struct SidebarDividerStabilityTests {
    /// The sidebar inside something that behaves like the split view: a host
    /// that would *prefer* to be `wanted` points wide, at a priority a piece of
    /// content can outrank.
    ///
    /// This is the shape of the real bug. `NSSplitViewItem` holds its position
    /// at `holdingPriority` -- the sidebar's is `.defaultLow` -- so any content
    /// that resists compression harder than that wins, and the divider moves to
    /// give it room. A headless `BrowserWindowController` does not reproduce
    /// this: its split view never solves for a real screen, and the sidebar
    /// stays at whatever it was set to whether the bug is present or not. So
    /// the pressure is applied here directly.
    private func widthUnderPressure(of sidebar: SidebarViewController, wanting wanted: CGFloat) -> CGFloat {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let view = sidebar.view
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)

        let prefers = view.widthAnchor.constraint(equalToConstant: wanted)
        prefers.priority = .defaultLow
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor),
            prefers
        ])
        host.layoutSubtreeIfNeeded()
        return view.frame.width
    }

    @Test("A space with a long name does not push the sidebar wider")
    func longNamesDoNotPush() {
        // Measured in the running browser: the sidebar sat at 199.5 in most
        // spaces, 220.5 in "Daily Dashboard" and 240 in "Read Later BF9059",
        // and never came back down.
        let wanted: CGFloat = 169

        let short = TestSession.make().0
        short.rename(short.activeSpace, to: "hj")
        let narrow = widthUnderPressure(of: SidebarViewController(session: short), wanting: wanted)

        let long = TestSession.make().0
        long.rename(long.activeSpace, to: "Read Later BF9059")
        let wide = widthUnderPressure(of: SidebarViewController(session: long), wanting: wanted)

        #expect(
            abs(wide - narrow) <= 1,
            "a long name gives a sidebar of \(wide) where a short one gives \(narrow)"
        )
        #expect(wide <= wanted + 1, "and neither may exceed what the window asked for")
    }
}

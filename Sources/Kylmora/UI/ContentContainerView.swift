import AppKit

/// The page side of the window: the top bar, then the page, inside a single
/// rounded card.
///
/// The card's leading corners are rounded and the other three edges are flush
/// with the window. That is what the screenshot shows and it is also the only
/// arrangement that makes sense: the sidebar's material is what the rounded
/// corner reveals, and there is no material to reveal on the outer edges --
/// rounding those would show the desktop through a hole in the window.
///
/// Clipping is done with a layer mask rather than by insetting the web view,
/// because a `WKWebView` inset from its container leaves a strip of container
/// colour that scrolls independently of the page and looks like a rendering
/// bug.
///
/// The card sits on a `.sidebar` visual-effect view rather than on whatever
/// happens to be behind the window. Both places the card does not cover -- the
/// band along its top and the notch each rounded corner cuts out -- have to
/// read as the sidebar continuing behind the page, and an inherited window
/// background is a flat grey that does not. It is the material showing through
/// that makes the corner legible as a corner at all.
@MainActor
final class ContentContainerView: NSView {
    let topBar = ContentTopBar()
    /// Under the top bar, inside the card; shown per space.
    let bookmarksBar = BookmarksBarView()
    private var bookmarksBarHeight: NSLayoutConstraint!

    /// The row of tabs above the page, for those who want one.
    let tabStrip = TabStripView()
    private var tabStripHeight: NSLayoutConstraint!

    var showsTabStrip: Bool = false {
        didSet {
            guard showsTabStrip != oldValue else { return }
            tabStrip.isHidden = !showsTabStrip
            tabStripHeight.constant = showsTabStrip ? TabStripView.height : 0
        }
    }

    var showsBookmarksBar: Bool = false {
        didSet {
            guard showsBookmarksBar != oldValue else { return }
            bookmarksBar.isHidden = !showsBookmarksBar
            bookmarksBarHeight.constant = showsBookmarksBar ? BookmarksBarView.height : 0
        }
    }

    private let card = NSView()
    private(set) var topBarTopConstraint: NSLayoutConstraint!
    private var cardLeadingConstraint: NSLayoutConstraint!

    /// The gutter on the page's leading edge, which depends on whether the
    /// sidebar is there to supply one.
    var cardLeadingInset: CGFloat {
        get { cardLeadingConstraint.constant }
        set { cardLeadingConstraint.constant = newValue }
    }

    private let underlay = NSVisualEffectView()
    private let tint = TintView()
    private var page: NSView?

    /// The colour of the space in front. It goes on the strip around the page
    /// card, not on the card: the page is the site's, and washing it would be
    /// colouring somebody else's document.
    /// See `SidebarViewController.setOpaque`.
    func setOpaque(_ opaque: Bool) {
        underlay.blendingMode = opaque ? .withinWindow : .behindWindow
    }

    var spaceWash: NSColor? {
        get { tint.wash }
        set { tint.wash = newValue }
    }

    /// The gradient wash on the strip, for a space washed with two colours. Nil
    /// is the plain solid `spaceWash`.
    var spaceGradient: WashGradient? {
        get { tint.gradientWash }
        set { tint.gradientWash = newValue }
    }

    func showSpaceGradient(_ gradient: WashGradient?, animatedOver duration: TimeInterval) {
        tint.transitionDuration = duration
        tint.gradientWash = gradient
        tint.transitionDuration = 0
    }

    /// The strip follows the sidebar through a space switch: part-way between
    /// two colours during the drag, and the rest of the way on release.
    func blendSpaceWash(toward other: NSColor?, fraction: CGFloat) {
        tint.blend(toward: other, fraction: fraction)
    }

    func showSpaceWash(_ wash: NSColor?, animatedOver duration: TimeInterval) {
        tint.transitionDuration = duration
        tint.wash = wash
        tint.transitionDuration = 0
        // The same colour again after a blend has to travel back too, and the
        // setter ignores an unchanged value.
        tint.show(wash, animatedOver: duration)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        underlay.material = .sidebar
        underlay.blendingMode = .behindWindow
        // Otherwise the strip beside the card stays saturated while the sidebar
        // it is meant to be part of greys out with the rest of the window.
        underlay.state = .followsWindowActiveState
        underlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(underlay)
        addSubview(tint)

        card.wantsLayer = true
        card.layer?.cornerRadius = Style.Metrics.contentCornerRadius
        // The measured corner is a squircle, not a circular arc: a circle of the
        // measured radius runs about a pixel wide of the reference at every
        // point on the curve, and `.continuous` lands on it.
        card.layer?.cornerCurve = .continuous
        // All four corners now, because the card is inset on three edges and
        // meets only the top of the window (margins: 0 on top, the gutter
        // everywhere else).
        card.layer?.maskedCorners = [
            .layerMinXMinYCorner, .layerMinXMaxYCorner,
            .layerMaxXMinYCorner, .layerMaxXMaxYCorner
        ]
        card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        card.addSubview(topBar)
        card.addSubview(tabStrip)
        tabStrip.isHidden = true
        let stripHeight = tabStrip.heightAnchor.constraint(equalToConstant: 0)
        stripHeight.priority = .required
        tabStripHeight = stripHeight
        card.addSubview(bookmarksBar)
        bookmarksBar.isHidden = true
        let barHeight = bookmarksBar.heightAnchor.constraint(equalToConstant: 0)
        barHeight.priority = .required
        bookmarksBarHeight = barHeight

        // The bar's offset from the top of the card. Compact mode animates it
        // so the bar slides out and the card's own mask clips it; the page
        // follows because it is pinned to the bar's bottom edge.
        // Flush while the sidebar is showing: the divider between the two is
        // what the user drags to resize, so the page has to begin exactly where
        // that divider ends or the drag target is not the edge it looks like.
        // With the sidebar hidden there is no divider, and the page needs the
        // same gutter here as it has on its other three sides.
        let cardLeading = card.leadingAnchor.constraint(equalTo: leadingAnchor)
        cardLeadingConstraint = cardLeading

        let topBarTop = topBar.topAnchor.constraint(equalTo: card.topAnchor)
        topBarTopConstraint = topBarTop

        NSLayoutConstraint.activate([
            underlay.topAnchor.constraint(equalTo: topAnchor),
            underlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            underlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            underlay.bottomAnchor.constraint(equalTo: bottomAnchor),

            tint.topAnchor.constraint(equalTo: topAnchor),
            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor),
            tint.bottomAnchor.constraint(equalTo: bottomAnchor),

            card.topAnchor.constraint(equalTo: topAnchor, constant: Style.Metrics.contentTopInset),
            // The card owns its own gutter on every edge rather than borrowing
            // the leading one from the split view's divider. Otherwise hiding
            // the sidebar takes the divider away with it and the card runs
            // flush into the window edge on that side alone.
            cardLeading,
            card.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Style.Metrics.elementSeparation
            ),
            card.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -Style.Metrics.elementSeparation
            ),

            topBarTop,
            topBar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            tabStrip.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stripHeight,

            bookmarksBar.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            bookmarksBar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            bookmarksBar.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            barHeight
        ])

        updateBackground()
    }

    required init?(coder: NSCoder) {
        fatalError("ContentContainerView is created in code only")
    }

    /// Puts a view -- in practice the existing web content view -- below the
    /// top bar. Passing `nil` empties the card, which is what a window with no
    /// tabs shows.
    func setPage(_ view: NSView?) {
        page?.removeFromSuperview()
        page = view
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: bookmarksBar.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
    }

    /// A `CALayer` background colour is a fixed `CGColor`, so unlike an
    /// `NSColor` it does not follow the appearance on its own.
    override func updateLayer() {
        super.updateLayer()
        updateBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    var onPinchToOverview: (() -> Void)?

    override func magnify(with event: NSEvent) {
        if event.magnification < -0.15 {
            onPinchToOverview?()
        } else {
            super.magnify(with: event)
        }
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = Style.Colors.pageFill.cgColor
        }
    }
}


import AppKit

enum ButtonKind { case primary, secondary, warn, danger }

/// Flat rounded button (radius 8; compact: 9 pt text, radius 7, tighter padding). The action fires on mouse-up inside
/// the button. An icon button (refresh) is square, as high as its neighbours, and draws a circular arrow.
final class RoundButton: NSView {
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var kind: ButtonKind { didSet { needsDisplay = true } }
    var font: NSFont = Theme.font { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var minChars = 0
    var compact = false { didSet { font = compact ? Theme.font9 : Theme.font } }
    private(set) var isIcon = false
    var isEnabled = true { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var onClick: (() -> Void)?
    var tip: String? { didSet { toolTip = tip } }
    /// Accent outline: the button Return presses in a dialog.
    var ring = false { didSet { needsDisplay = true } }
    private var hover = false, pressed = false

    init(_ title: String, _ kind: ButtonKind, _ action: (() -> Void)? = nil) {
        self.title = title; self.kind = kind; self.onClick = action
        super.init(frame: .zero)
    }

    /// Icon-only refresh button (circular arrow), secondary colours.
    init(refresh action: (() -> Void)?) {
        self.title = ""; self.kind = .secondary; self.onClick = action; self.isIcon = true
        super.init(frame: .zero)
    }

    /// Icon-only button that draws its own glyph (e.g. the back / forward arrows), secondary colours.
    init(icon draw: @escaping (NSRect, NSColor) -> Void, _ action: (() -> Void)?) {
        self.title = ""; self.kind = .secondary; self.onClick = action; self.isIcon = true; self.glyph = draw
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Glyph of an icon button (nil = the circular refresh arrow).
    private var glyph: ((NSRect, NSColor) -> Void)?

    override var isFlipped: Bool { true }

    var preferredSize: NSSize {
        let h = compact ? Theme.lineHeight(font) + 10 : ceil(font.ascender - font.descender) + 14
        if isIcon { return NSSize(width: h, height: h) }
        let sample = minChars > 0 ? String(repeating: "0", count: minChars) : title
        return NSSize(width: max(Theme.textWidth(sample, font), Theme.textWidth(title, font)) + (compact ? 20 : 32), height: h)
    }
    override var intrinsicContentSize: NSSize { preferredSize }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { if isEnabled { pressed = true } }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let fire = pressed && isEnabled && inside
        pressed = false
        if fire { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor, fore: NSColor
        if !isEnabled { fill = T.DISABLED_BG; fore = T.DISABLED_FG }
        else {
            switch kind {
            case .primary: fill = hover ? T.ACCENT_ACTIVE : T.ACCENT; fore = T.BG
            case .warn: fill = hover ? T.WARN_FG : T.WARN; fore = T.BG
            case .danger: fill = hover ? T.DANGER_HOVER : T.DANGER; fore = T.BG
            case .secondary: fill = hover ? T.SECONDARY_HOVER : T.BORDER; fore = T.FG
            }
        }
        Theme.fillRound(bounds, compact ? 7 : 8, fill: fill, outline: ring && isEnabled ? T.ACCENT : nil)
        if isIcon {
            if let g = glyph { g(bounds, fore) } else { RoundButton.drawRefresh(bounds, fore) }
            return
        }
        Theme.drawText(title, in: bounds.insetBy(dx: compact ? 6 : 8, dy: 0), font: font, color: fore, align: .center)
    }

    /// Circular arrow: a 300 degree arc with its gap at the top right and an arrowhead at its end (flipped view).
    static func drawRefresh(_ b: NSRect, _ c: NSColor) {
        let side = min(b.width, b.height)
        let s = side / 26
        let r = side * 0.24
        let ctr = NSPoint(x: b.midX, y: b.midY)
        let start: CGFloat = -15, end: CGFloat = 285          // in a flipped view angles grow clockwise on screen
        let p = NSBezierPath()
        p.appendArc(withCenter: ctr, radius: r, startAngle: start, endAngle: end, clockwise: false)
        p.lineWidth = 1.8 * s
        p.lineCapStyle = .round
        c.setStroke(); p.stroke()
        let a = end * .pi / 180
        let e = NSPoint(x: ctr.x + r * cos(a), y: ctr.y + r * sin(a))
        let t = NSPoint(x: -sin(a), y: cos(a)), n = NSPoint(x: cos(a), y: sin(a))
        let k = 3.2 * s
        let head = NSBezierPath()
        head.move(to: NSPoint(x: e.x + t.x * k * 1.1, y: e.y + t.y * k * 1.1))
        head.line(to: NSPoint(x: e.x + n.x * k - t.x * k * 0.35, y: e.y + n.y * k - t.y * k * 0.35))
        head.line(to: NSPoint(x: e.x - n.x * k - t.x * k * 0.35, y: e.y - n.y * k - t.y * k * 0.35))
        head.close()
        c.setFill(); head.fill()
    }
}

/// Comet arc spinner (Theme.drawCometArc): 270 degree fading tail, glowing head, one turn per second.
final class Spinner: NSView {
    private var timer: Timer?
    var background: NSColor = T.SURFACE { didSet { needsDisplay = true } }
    var color: NSColor = T.ACCENT { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    var spinning: Bool {
        get { timer != nil }
        set {
            if newValue == spinning { return }
            if newValue {
                timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in self?.needsDisplay = true }
            } else { timer?.invalidate(); timer = nil }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill(); bounds.fill()
        let w = max(2.5, 5 * bounds.width / 64), inset = w * 1.5
        let head = CGFloat((Theme.now * 360).truncatingRemainder(dividingBy: 360))
        Theme.drawCometArc(in: bounds.insetBy(dx: inset, dy: inset), head: head, sweep: 270, width: w, color: color)
    }
}

/// Non-blocking progress strip under the toolbar: spinner, status line, detail line, pill bar (when the total is
/// known) and Cancel. The rest of the window stays usable while it shows. The danger variant (deleting) has a red
/// outline on a dark red fill, a red spinner and bar, and a Stop button.
final class ScanBar: NSView {
    let spinner = Spinner()
    let cancelButton = RoundButton("Cancel", .secondary)
    private(set) var status = "", detail = ""
    private(set) var fraction: Double = -1
    var danger = false {
        didSet {
            spinner.color = danger ? T.DANGER : T.ACCENT
            spinner.background = danger ? T.DANGER_BG : T.SURFACE
            cancelButton.title = danger ? "Stop" : "Cancel"
            needsDisplay = true
        }
    }
    var fillColor: NSColor { danger ? T.DANGER_BG : T.SURFACE }
    var outlineColor: NSColor { danger ? T.DANGER_BORDER : T.BORDER }
    var barColor: NSColor { danger ? T.DANGER : T.ACCENT }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        cancelButton.minChars = 8
        addSubview(spinner); addSubview(cancelButton)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    static let height: CGFloat = 64
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }

    func start(_ text: String) {
        status = text; detail = ""; fraction = -1
        cancelButton.isEnabled = true
        isHidden = false
        spinner.spinning = true
        setSweeping(true)
        needsLayout = true; needsDisplay = true
    }

    func stop() { spinner.spinning = false; setSweeping(false); isHidden = true }

    func set(_ text: String, _ detailText: String, _ frac: Double) {
        status = text; detail = detailText; fraction = frac
        needsDisplay = true
    }

    private var box: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 10) }

    // Status and detail cut off with "..." show in full on hover.
    private let cuts = CutTips()
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { cuts.track(self, event) }
    override func mouseExited(with event: NSEvent) { cuts.exit(self) }

    override func layout() {
        super.layout()
        let b = box
        spinner.frame = NSRect(x: b.minX + 14, y: b.minY + (b.height - 22) / 2, width: 22, height: 22)
        let cs = cancelButton.preferredSize
        cancelButton.frame = NSRect(x: b.maxX - 12 - cs.width, y: b.minY + (b.height - cs.height) / 2, width: cs.width, height: cs.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        T.BG.setFill(); bounds.fill()
        let b = box
        Theme.fillRound(b, 12, fill: fillColor, outline: outlineColor)
        cuts.begin()
        let x = spinner.frame.maxX + 12, right = cancelButton.frame.minX - 16
        let lineH: CGFloat = 17, smallH: CGFloat = 15, barH: CGFloat = 6
        let total = lineH + 2 + smallH + (fraction >= 0 ? 6 + barH : 0)
        var y = b.minY + (b.height - total) / 2
        cuts.draw(status, in: NSRect(x: x, y: y, width: max(0, right - x), height: lineH), font: Theme.font, color: T.FG)
        y += lineH + 2
        cuts.draw(detail, in: NSRect(x: x, y: y, width: max(0, right - x), height: smallH), font: Theme.font9, color: T.MUTED)
        if fraction >= 0 {
            y += smallH + 6
            let bar = NSRect(x: x, y: y, width: max(0, right - x), height: barH)
            Theme.fillRound(bar, barH / 2, fill: outlineColor)
            let w = (bar.width * CGFloat(min(1, fraction))).rounded()
            if w > 0 {
                let done = NSRect(x: bar.minX, y: bar.minY, width: max(w, barH), height: barH)
                Theme.fillRound(done, barH / 2, fill: barColor)
                // Flair: a light sweep along the filled part (no glow at its end).
                Theme.drawSweep(done, seg: 90, period: 1.6, color: (danger ? T.DANGER_FG : T.ACCENT_LIGHT).withAlphaComponent(0.6),
                                clip: Theme.roundRect(done, barH / 2))
            }
            barArea = bar
        }
    }

    // Repaints only the progress bar, for its sweep.
    private var barArea = NSRect.zero
    private var sweepTimer: Timer?
    private func setSweeping(_ on: Bool) {
        if on, sweepTimer == nil {
            sweepTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
                guard let s = self, s.fraction > 0, !s.barArea.isEmpty else { return }
                s.setNeedsDisplay(s.barArea)
            }
        } else if !on { sweepTimer?.invalidate(); sweepTimer = nil }
    }
}

/// Vertical list of views on the left of the window (same as NavRail in src/NavRail.cs): one row per view, a line icon
/// with the label right of it. The current view sits on a SURFACE pill with an ACCENT marker on its left edge and ACCENT
/// icon and label; the others are MUTED (FG on a BORDER pill while hovered). A title ending in " (n)" shows n in an
/// accent pill at the right end of its row. When the rows do not fit, the rail scrolls (wheel / trackpad). A view can have
/// a colour of its own (colors[i]).
final class NavRail: NSView {
    static let width: CGFloat = 150
    static let itemHeight: CGFloat = 36
    static let gap: CGFloat = 2
    private(set) var titles: [String]
    private var hover = -1
    private var scrollY: CGFloat = 0
    private let cuts = CutTips()
    var colors: [Int: NSColor] = [:] { didSet { needsDisplay = true } }
    /// The view shown (-1 = a view that is not in the rail, e.g. the delete list). Setting it does not call onChange.
    var selectedIndex = 0 { didSet { if oldValue != selectedIndex { scrollToItem(selectedIndex); needsDisplay = true } } }
    /// The user picked row i.
    var onChange: ((Int) -> Void)?
    var background: NSColor = T.BG { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    init(_ titles: [String]) { self.titles = titles; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ i: Int, _ t: String) { guard i >= 0 && i < titles.count else { return }; titles[i] = t; needsDisplay = true }
    func setColor(_ i: Int, _ c: NSColor) { colors[i] = c }

    private var contentHeight: CGFloat { max(0, CGFloat(titles.count) * (NavRail.itemHeight + NavRail.gap) - NavRail.gap) }
    private var maxScroll: CGFloat { max(0, contentHeight - bounds.height) }

    func itemRect(_ i: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(i) * (NavRail.itemHeight + NavRail.gap) - scrollY, width: bounds.width, height: NavRail.itemHeight)
    }

    private func setScroll(_ y: CGFloat) {
        let v = min(maxScroll, max(0, y))
        if v == scrollY { return }
        scrollY = v
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Scrolls so that row i is in full view.
    func scrollToItem(_ i: Int) {
        guard i >= 0 && i < titles.count else { return }
        let r = itemRect(i)
        if r.minY < 0 { setScroll(scrollY + r.minY) } else if r.maxY > bounds.height { setScroll(scrollY + r.maxY - bounds.height) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setScroll(scrollY)
        scrollToItem(selectedIndex)
    }

    /// "Delete list (4)" -> ("Delete list", "4").
    static func split(_ title: String) -> (label: String, badge: String?) {
        guard title.hasSuffix(")"), let r = title.range(of: " (", options: .backwards), r.lowerBound > title.startIndex else { return (title, nil) }
        let label = String(title[..<r.lowerBound])
        let badge = String(title[r.upperBound..<title.index(before: title.endIndex)])
        return (label, badge)
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill(); bounds.fill()
        cuts.begin()
        for i in titles.indices {
            let r = itemRect(i)
            if r.maxY < 0 { continue }
            if r.minY > bounds.height { break }
            let own = colors[i]
            let sel = i == selectedIndex
            let behind: NSColor
            if sel {
                Theme.fillRound(r, 8, fill: T.SURFACE)
                Theme.fillRound(NSRect(x: r.minX, y: r.minY + 9, width: 3, height: r.height - 18), 1.5, fill: own ?? T.ACCENT)
                behind = T.SURFACE
            } else if i == hover {
                Theme.fillRound(r, 8, fill: T.BORDER)
                behind = T.BORDER
            } else { behind = background }
            let c: NSColor = sel ? (own ?? T.ACCENT) : (i == hover ? T.FG : (own ?? T.MUTED))
            let parts = NavRail.split(titles[i])
            let ic: CGFloat = 18
            let ir = NSRect(x: r.minX + 14, y: r.minY + ((r.height - ic) / 2).rounded(), width: ic, height: ic)
            NavRail.drawIcon(parts.label, ir, c, behind: behind)
            var right = r.maxX - 8
            if let b = parts.badge {
                let bh: CGFloat = 18
                let bw = max(bh, Theme.textWidth(b, Theme.font9Bold) + 10)
                let br = NSRect(x: right - bw, y: r.minY + ((r.height - bh) / 2).rounded(), width: bw, height: bh)
                Theme.fillRound(br, bh / 2, fill: T.ACCENT)
                Theme.drawText(b, in: br, font: Theme.font9Bold, color: T.BG, align: .center)
                right = br.minX - 6
            }
            let tx = ir.maxX + 10
            cuts.draw(parts.label, in: NSRect(x: tx, y: r.minY, width: max(0, right - tx), height: r.height), font: Theme.font, color: c)
        }
    }

    /// One line icon per view (same shapes as NavRail.DrawIcon in src/NavRail.cs), drawn in c inside r (flipped view).
    static func drawIcon(_ label: String, _ r: NSRect, _ c: NSColor, behind: NSColor) {
        let x = r.minX, y = r.minY, s = r.width
        let p = NSBezierPath()
        p.lineWidth = max(1.4, s * 0.08)
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            p.move(to: NSPoint(x: x + s * x1, y: y + s * y1))
            p.line(to: NSPoint(x: x + s * x2, y: y + s * y2))
        }
        func oval(_ ox: CGFloat, _ oy: CGFloat, _ d: CGFloat) {
            p.appendOval(in: NSRect(x: x + s * ox, y: y + s * oy, width: s * d, height: s * d))
        }
        func rrect(_ rx: CGFloat, _ ry: CGFloat, _ rw: CGFloat, _ rh: CGFloat, _ rad: CGFloat) {
            p.append(Theme.roundRect(NSRect(x: x + s * rx, y: y + s * ry, width: s * rw, height: s * rh), s * rad))
        }
        func document(_ dx: CGFloat, _ dy: CGFloat, _ dw: CGFloat, _ dh: CGFloat) {
            let px = x + s * dx, py = y + s * dy, w = s * dw, h = s * dh, f = w * 0.32
            p.move(to: NSPoint(x: px, y: py))
            p.line(to: NSPoint(x: px + w - f, y: py))
            p.line(to: NSPoint(x: px + w, y: py + f))
            p.line(to: NSPoint(x: px + w, y: py + h))
            p.line(to: NSPoint(x: px, y: py + h))
            p.close()
            p.move(to: NSPoint(x: px + w - f, y: py))
            p.line(to: NSPoint(x: px + w - f, y: py + f))
            p.line(to: NSPoint(x: px + w, y: py + f))
        }
        func sparkle(_ cx0: CGFloat, _ cy0: CGFloat, _ r0: CGFloat) {
            let cx = x + s * cx0, cy = y + s * cy0, rr = s * r0, k = rr * 0.28
            let st = NSBezierPath()
            st.move(to: NSPoint(x: cx, y: cy - rr))
            st.line(to: NSPoint(x: cx + k, y: cy - k)); st.line(to: NSPoint(x: cx + rr, y: cy)); st.line(to: NSPoint(x: cx + k, y: cy + k))
            st.line(to: NSPoint(x: cx, y: cy + rr)); st.line(to: NSPoint(x: cx - k, y: cy + k)); st.line(to: NSPoint(x: cx - rr, y: cy))
            st.line(to: NSPoint(x: cx - k, y: cy - k))
            st.close()
            c.setFill(); st.fill()
        }
        switch label.lowercased() {
        case "contents":
            Theme.drawFolder(NSRect(x: x, y: y + s * 0.04, width: s, height: s), c)
            return
        case "suggestions":
            sparkle(0.42, 0.52, 0.36)
            sparkle(0.80, 0.20, 0.16)
            return
        case "apps":
            let q: CGFloat = 0.40, g: CGFloat = 0.12, o = (1 - 2 * q - g) / 2
            for i in 0..<4 { rrect(o + CGFloat(i % 2) * (q + g), o + CGFloat(i / 2) * (q + g), q, q, q * 0.28) }
        case "system":
            rrect(0.08, 0.14, 0.84, 0.56, 0.08)
            line(0.5, 0.70, 0.5, 0.84)
            line(0.32, 0.86, 0.68, 0.86)
        case "files":
            oval(0.12, 0.12, 0.54)
            line(0.60, 0.60, 0.88, 0.88)
        case "file types":
            document(0.18, 0.08, 0.64, 0.84)
            line(0.34, 0.50, 0.66, 0.50)
            line(0.34, 0.68, 0.58, 0.68)
        case "duplicates":
            document(0.30, 0.06, 0.56, 0.70)
            c.setStroke(); p.stroke()
            let front = Theme.roundRect(NSRect(x: x + s * 0.14, y: y + s * 0.24, width: s * 0.56, height: s * 0.70), s * 0.08)
            front.lineWidth = p.lineWidth
            behind.setFill(); front.fill()
            c.setStroke(); front.stroke()
            return
        case "changes":
            oval(0.10, 0.10, 0.80)
            line(0.5, 0.5, 0.5, 0.26)
            line(0.5, 0.5, 0.68, 0.60)
        case "delete list":
            line(0.14, 0.24, 0.86, 0.24)
            line(0.40, 0.12, 0.60, 0.12)
            p.move(to: NSPoint(x: x + s * 0.22, y: y + s * 0.24))
            p.line(to: NSPoint(x: x + s * 0.28, y: y + s * 0.90))
            p.line(to: NSPoint(x: x + s * 0.72, y: y + s * 0.90))
            p.line(to: NSPoint(x: x + s * 0.78, y: y + s * 0.24))
            line(0.42, 0.40, 0.43, 0.74)
            line(0.58, 0.40, 0.57, 0.74)
        default:
            oval(0.2, 0.2, 0.6)
        }
        c.setStroke(); p.stroke()
    }

    private func hit(_ e: NSEvent) -> Int {
        let p = convert(e.locationInWindow, from: nil)
        if !bounds.contains(p) { return -1 }
        return titles.indices.first { itemRect($0).contains(p) } ?? -1
    }

    override func resetCursorRects() {
        for i in titles.indices { let r = itemRect(i).intersection(bounds); if !r.isEmpty { addCursorRect(r, cursor: .pointingHand) } }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let h = hit(event)
        if h != hover { hover = h; needsDisplay = true }
        cuts.track(self, event)
    }
    override func mouseExited(with event: NSEvent) { hover = -1; needsDisplay = true; cuts.exit(self) }
    override func mouseDown(with event: NSEvent) {
        HoverTip.shared.hide()
        let h = hit(event)
        guard h >= 0 else { return }
        selectedIndex = h
        onChange?(h)
    }
    override func scrollWheel(with event: NSEvent) {
        if maxScroll <= 0 { super.scrollWheel(with: event); return }
        HoverTip.shared.reset(owner: self)
        let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        setScroll(scrollY - d)
        let h = hit(event)
        if h != hover { hover = h; needsDisplay = true }
    }
}

/// Slim, calm notice line at the top of a view (same as Banner in src/Widgets.cs): a small amber warning sign, the
/// message in MUTED (in full on hover when it is cut off), compact buttons, and a close button (x) on the right.
/// Hidden while it has no text or after it was closed.
final class Banner: NSView, PageStrip {
    private var buttons: [RoundButton] = []
    private let cuts = CutTips()
    private var closeRect = NSRect.zero
    private var closeHover = false
    /// The user closed the banner with x.
    var onClose: (() -> Void)?
    /// The text; empty hides the banner.
    var message = "" {
        didSet {
            if message == oldValue { return }
            isHidden = message.isEmpty
            needsLayout = true
            needsDisplay = true
            superview?.needsLayout = true
        }
    }
    override var isFlipped: Bool { true }
    var stripHeight: CGFloat { Theme.lineHeight(Theme.font9) + 22 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    func addButton(_ title: String, tip: String, _ action: @escaping () -> Void) -> RoundButton {
        let b = RoundButton(title, .secondary, action)
        b.compact = true
        b.tip = tip
        buttons.append(b)
        addSubview(b)
        needsLayout = true
        return b
    }

    private var box: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 6)) }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }

    override func layout() {
        super.layout()
        let r = box
        let cs: CGFloat = 22
        closeRect = NSRect(x: r.maxX - 6 - cs, y: r.minY + ((r.height - cs) / 2).rounded(), width: cs, height: cs)
        var x = closeRect.minX - 6
        for b in buttons.reversed() where !b.isHidden {
            let s = b.preferredSize
            let h = min(s.height, max(10, r.height - 6))
            x -= s.width
            b.frame = NSRect(x: x, y: r.minY + ((r.height - h) / 2).rounded(), width: s.width, height: h)
            x -= 6
        }
        needsDisplay = true
    }

    /// Closes the banner as the x does.
    func close() {
        message = ""
        onClose?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func resetCursorRects() { addCursorRect(closeRect, cursor: .pointingHand) }
    override func mouseMoved(with event: NSEvent) {
        let h = closeRect.contains(convert(event.locationInWindow, from: nil))
        if h != closeHover { closeHover = h; setNeedsDisplay(closeRect) }
        cuts.track(self, event)
    }
    override func mouseExited(with event: NSEvent) {
        if closeHover { closeHover = false; setNeedsDisplay(closeRect) }
        cuts.exit(self)
    }
    override func mouseDown(with event: NSEvent) { HoverTip.shared.hide() }
    override func mouseUp(with event: NSEvent) {
        if closeRect.contains(convert(event.locationInWindow, from: nil)) { closeHover = false; close() }
    }

    override func draw(_ dirtyRect: NSRect) {
        T.SURFACE.setFill(); bounds.fill()
        cuts.begin()
        let r = box
        Theme.fillRound(r, 8, fill: T.BG)
        let ic: CGFloat = 14
        Theme.drawWarningSign(NSRect(x: 10, y: r.minY + ((r.height - ic) / 2).rounded(), width: ic, height: ic), T.WARN, cut: T.BG)
        let x: CGFloat = 10 + ic + 8
        var right = closeRect.minX - 8
        for b in buttons where !b.isHidden { right = min(right, b.frame.minX - 8) }
        cuts.draw(message, in: NSRect(x: x, y: r.minY, width: max(0, right - x), height: r.height), font: Theme.font9, color: T.MUTED)
        if closeHover { Theme.fillRound(closeRect, 6, fill: T.BORDER) }
        let k: CGFloat = 4
        let p = NSBezierPath()
        p.move(to: NSPoint(x: closeRect.midX - k, y: closeRect.midY - k)); p.line(to: NSPoint(x: closeRect.midX + k, y: closeRect.midY + k))
        p.move(to: NSPoint(x: closeRect.midX - k, y: closeRect.midY + k)); p.line(to: NSPoint(x: closeRect.midX + k, y: closeRect.midY - k))
        p.lineWidth = 1.5
        p.lineCapStyle = .round
        (closeHover ? T.FG : T.MUTED).setStroke()
        p.stroke()
    }
}

/// What a path bar segment opens: This PC (every drive), a drive that is not scanned, or a scanned folder.
enum CrumbTarget {
    case thisPc
    case root(ScanRoot)
    case dir(DirNode)
}

/// Path bar: "This PC", then one clickable segment per folder from the scanned root down to the folder shown (MUTED, FG
/// on hover, the last one FG and not clickable), separated by chevrons. When it does not fit, the segments after the
/// first collapse into "...". A segment cut off shows its full text on hover.
final class Breadcrumb: NSView, PageStrip {
    private var parts: [(text: String, target: CrumbTarget)] = []
    private var hits: [(rect: NSRect, index: Int)] = []
    private var hover = -1
    private let cuts = CutTips()
    var onPick: ((CrumbTarget) -> Void)?
    override var isFlipped: Bool { true }
    var stripHeight: CGFloat { Theme.lineHeight(Theme.font) + 12 }
    var count: Int { parts.count }
    var texts: [String] { parts.map { $0.text } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Segments from the top down: the text shown and what it opens.
    func setParts(_ items: [(text: String, target: CrumbTarget)]) {
        parts = items
        hover = -1
        let hide = items.isEmpty
        if isHidden != hide { isHidden = hide; superview?.needsLayout = true }
        needsDisplay = true
    }

    /// Clicks segment i (self-test).
    func pick(_ i: Int) { if i >= 0 && i < parts.count { onPick?(parts[i].target) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func chevron(_ x: CGFloat, _ gap: CGFloat, _ chev: CGFloat) -> CGFloat {
        Theme.drawChevron(NSRect(x: x + gap, y: ((bounds.height - chev) / 2).rounded(), width: chev, height: chev), T.MUTED, down: false)
        return x + gap + chev + gap
    }

    override func draw(_ dirtyRect: NSRect) {
        T.SURFACE.setFill(); bounds.fill()
        hits = []
        cuts.begin()
        if parts.isEmpty { return }
        let gap: CGFloat = 4, chev: CGFloat = 10, pad: CGFloat = 5
        let widths: [CGFloat] = parts.map { Theme.textWidth($0.text, Theme.font) + 2 * pad }
        let dots = Theme.textWidth("...", Theme.font) + 2 * pad
        let avail = bounds.width - 8
        // Drop leading segments (after the first) until the rest fits.
        func need(_ start: Int) -> CGFloat {
            var w = widths[0]
            if start > 1 { w += gap + chev + gap + dots }
            var i = start
            while i < parts.count { w += gap + chev + gap + widths[i]; i += 1 }
            return w
        }
        var first = 1
        while first < parts.count - 1 && need(first) > avail { first += 1 }
        var x: CGFloat = 4
        for i in 0..<parts.count {
            if i > 0 && i < first { continue }
            if i > 0 {
                if i == first && first > 1 {
                    x = chevron(x, gap, chev)
                    Theme.drawText("...", in: NSRect(x: x, y: 0, width: dots, height: bounds.height), font: Theme.font, color: T.MUTED, align: .center)
                    x += dots
                }
                x = chevron(x, gap, chev)
            }
            let last = i == parts.count - 1
            let w = min(widths[i], max(20, bounds.width - x - 4))
            let r = NSRect(x: x, y: 3, width: w, height: bounds.height - 6)
            if !last && i == hover { Theme.fillRound(r, 6, fill: T.BORDER) }
            cuts.draw(parts[i].text, in: r.insetBy(dx: pad, dy: 0), font: Theme.font, color: last || i == hover ? T.FG : T.MUTED, align: .center)
            if !last { hits.append((rect: r, index: i)) }
            x += w
        }
    }

    private func hit(_ e: NSEvent) -> Int {
        let p = convert(e.locationInWindow, from: nil)
        for h in hits where h.rect.contains(p) { return h.index }
        return -1
    }

    override func mouseMoved(with event: NSEvent) {
        let h = hit(event)
        if h >= 0 { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        if h != hover { hover = h; needsDisplay = true }
        cuts.track(self, event)
    }
    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        if hover != -1 { hover = -1; needsDisplay = true }
        cuts.exit(self)
    }
    override func mouseDown(with event: NSEvent) { HoverTip.shared.hide() }
    override func mouseUp(with event: NSEvent) {
        let h = hit(event)
        if h >= 0 && h < parts.count { onPick?(parts[h].target) }
    }
}

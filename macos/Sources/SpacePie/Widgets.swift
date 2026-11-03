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
        let x = spinner.frame.maxX + 12, right = cancelButton.frame.minX - 16
        let lineH: CGFloat = 17, smallH: CGFloat = 15, barH: CGFloat = 6
        let total = lineH + 2 + smallH + (fraction >= 0 ? 6 + barH : 0)
        var y = b.minY + (b.height - total) / 2
        Theme.drawText(status, in: NSRect(x: x, y: y, width: max(0, right - x), height: lineH), font: Theme.font, color: T.FG)
        y += lineH + 2
        Theme.drawText(detail, in: NSRect(x: x, y: y, width: max(0, right - x), height: smallH), font: Theme.font9, color: T.MUTED)
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

/// Text tabs: the current one in accent with an underline pill, the others muted. A tab can have a colour of its own
/// (colors[i]): its title is drawn in it always, and so is its pill when it is the current one.
final class TabStrip: NSView {
    private(set) var titles: [String]
    private var rects: [NSRect] = []
    private var hover = -1
    var colors: [Int: NSColor] = [:] { didSet { needsDisplay = true } }
    var selectedIndex = 0 { didSet { if oldValue != selectedIndex { needsDisplay = true; onChange?(selectedIndex) } } }
    var onChange: ((Int) -> Void)?
    var background: NSColor = T.SURFACE
    override var isFlipped: Bool { true }

    init(_ titles: [String]) { self.titles = titles; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ i: Int, _ t: String) { titles[i] = t; needsDisplay = true }
    override func resetCursorRects() { measure(); for r in rects { addCursorRect(r, cursor: .pointingHand) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func measure() {
        rects = []
        var x: CGFloat = 0
        for t in titles {
            let w = min(Theme.textWidth(t, Theme.font) + 12, max(40, bounds.width - x))
            rects.append(NSRect(x: x, y: 0, width: w, height: bounds.height))
            x += w + 10
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill(); bounds.fill()
        measure()
        for (i, r) in rects.enumerated() {
            let own = colors[i]
            let c = i == selectedIndex ? (own ?? T.ACCENT) : i == hover ? T.FG : (own ?? T.MUTED)
            Theme.drawText(titles[i], in: NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - 4), font: Theme.font, color: c, align: .center)
            if i == selectedIndex { Theme.fillRound(NSRect(x: r.minX + 6, y: r.maxY - 4, width: r.width - 12, height: 3), 1.5, fill: own ?? T.ACCENT) }
        }
    }

    private func hit(_ e: NSEvent) -> Int {
        let p = convert(e.locationInWindow, from: nil)
        return rects.firstIndex { $0.contains(p) } ?? -1
    }
    override func mouseMoved(with event: NSEvent) { let h = hit(event); if h != hover { hover = h; needsDisplay = true } }
    override func mouseExited(with event: NSEvent) { hover = -1; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { let h = hit(event); if h >= 0 { selectedIndex = h } }
}

/// Amber attention line at the top of a view (WARN_BG fill, WARN_BORDER outline, warning sign, WARN_FG text) with
/// compact buttons on the right. Hidden while it has no text.
final class Banner: NSView, PageStrip {
    private var buttons: [RoundButton] = []
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
    var stripHeight: CGFloat { Theme.lineHeight(Theme.font) + 26 }

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

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }

    override func layout() {
        super.layout()
        var x = bounds.width - 10
        let boxH = bounds.height - 6
        for b in buttons.reversed() where !b.isHidden {
            let s = b.preferredSize
            x -= s.width
            b.frame = NSRect(x: x, y: ((boxH - s.height) / 2).rounded(), width: s.width, height: s.height)
            x -= 6
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        T.SURFACE.setFill(); bounds.fill()
        let r = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 6)
        Theme.fillRound(r, 8, fill: T.WARN_BG, outline: T.WARN_BORDER)
        let ic: CGFloat = 18
        Theme.drawWarningSign(NSRect(x: 10, y: ((r.height - ic) / 2).rounded(), width: ic, height: ic), T.WARN, cut: T.WARN_BG)
        let x: CGFloat = 10 + ic + 10
        var right = bounds.width - 10
        for b in buttons where !b.isHidden { right = min(right, b.frame.minX) }
        Theme.drawText(message, in: NSRect(x: x, y: 0, width: max(0, right - x - 10), height: r.height), font: Theme.font, color: T.WARN_FG)
    }
}

/// Path bar: one clickable segment per folder from the scanned root down to the folder shown (MUTED, FG on hover, the
/// last one FG and not clickable), separated by chevrons. When it does not fit, the first segments collapse into "...".
final class Breadcrumb: NSView, PageStrip {
    private var parts: [(text: String, dir: DirNode)] = []
    private var hits: [(rect: NSRect, index: Int)] = []
    private var hover = -1
    var onPick: ((DirNode) -> Void)?
    override var isFlipped: Bool { true }
    var stripHeight: CGFloat { Theme.lineHeight(Theme.font) + 12 }
    var count: Int { parts.count }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Segments from the top down: the text shown and the folder it opens.
    func setParts(_ items: [(text: String, dir: DirNode)]) {
        parts = items
        hover = -1
        let hide = items.isEmpty
        if isHidden != hide { isHidden = hide; superview?.needsLayout = true }
        needsDisplay = true
    }

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
            Theme.drawText(parts[i].text, in: r, font: Theme.font, color: last || i == hover ? T.FG : T.MUTED, align: .center)
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
    }
    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        if hover != -1 { hover = -1; needsDisplay = true }
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let h = hit(event)
        if h >= 0 && h < parts.count { onPick?(parts[h].dir) }
    }
}
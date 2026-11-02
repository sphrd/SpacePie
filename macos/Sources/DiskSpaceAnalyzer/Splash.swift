import AppKit
import QuartzCore

/// Splash shown from the first moment of a normal start until the main window is on screen: 520x300, bg, 2 px surface
/// frame, a soft accent glow behind the logo, name, "by sphrd" with a version pill, an accent bar, a divider, a one-line
/// description and a short log of the startup steps (finished ones with a check mark, the current one with a spinner
/// arc). It is drawn and flushed to the window server at once (no run-loop turn), so building the main window right
/// after it is not delayed.
final class SplashView: NSView {
    static let size = NSSize(width: 520, height: 300)
    static let radius: CGFloat = 10
    private(set) var log = ["Starting..."]

    /// Adds a step to the log (keeps the last four).
    func step(_ text: String) {
        if log.last == text { return }
        log.append(text)
        if log.count > 4 { log.removeFirst(log.count - 4) }
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill()
        Theme.fillRound(bounds, SplashView.radius, fill: T.SURFACE)
        Theme.fillRound(bounds.insetBy(dx: 2, dy: 2), SplashView.radius - 2, fill: T.BG)
        Theme.drawLogoGlow(in: NSRect(x: 36, y: 44, width: 96, height: 96))
        let name = "Disk Space Analyzer"
        let nameWidth = bounds.width - 192
        var size: CGFloat = 30
        var font = NSFont.boldSystemFont(ofSize: size)
        while size > 20 && (name as NSString).size(withAttributes: [.font: font]).width > nameWidth {
            size -= 1
            font = NSFont.boldSystemFont(ofSize: size)
        }
        line(name, 156, 50, font, T.FG, width: nameWidth)
        let byFont = NSFont.systemFont(ofSize: 14)
        let byW = ceil(("by sphrd" as NSString).size(withAttributes: [.font: byFont]).width)
        line("by sphrd", 158, 97, byFont, T.MUTED, width: byW + 4)
        let pillFont = NSFont.boldSystemFont(ofSize: 12)
        let version = "v" + Updater.currentString
        let verW = ceil((version as NSString).size(withAttributes: [.font: pillFont]).width)
        let pill = NSRect(x: 158 + byW + 12, y: 96, width: verW + 18, height: 22)
        Theme.fillRound(pill, pill.height / 2, fill: T.SURFACE, outline: T.BORDER)
        line(version, pill.minX + 9, pill.minY + (pill.height - Theme.lineHeight(pillFont)) / 2, pillFont, T.ACCENT, width: verW + 2)
        Theme.fillRound(NSRect(x: 158, y: 130, width: 44, height: 4), 2, fill: T.ACCENT)
        T.SURFACE.setFill()
        NSRect(x: 36, y: 158, width: bounds.width - 72, height: 2).fill()
        line("Fast, free and open-source disk space analyzer and cleaner", 36, 172, NSFont.systemFont(ofSize: 14), T.FG)
        let logFont = NSFont.systemFont(ofSize: 12)
        for (i, text) in log.enumerated() {
            let y = 206 + CGFloat(i) * 18
            let last = i == log.count - 1
            let icon = NSRect(x: 37, y: y + 2, width: 11, height: 11)
            if last {
                Theme.drawCometArc(in: icon.insetBy(dx: 1, dy: 1), head: CGFloat((Theme.now * 360).truncatingRemainder(dividingBy: 360)),
                                   sweep: 270, width: 2, color: T.ACCENT)
            } else {
                let p = NSBezierPath()
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
                p.lineWidth = 1.6
                p.move(to: NSPoint(x: icon.minX + icon.width * 0.1, y: icon.minY + icon.height * 0.55))
                p.line(to: NSPoint(x: icon.minX + icon.width * 0.4, y: icon.minY + icon.height * 0.85))
                p.line(to: NSPoint(x: icon.minX + icon.width * 0.95, y: icon.minY + icon.height * 0.15))
                T.ACCENT.withAlphaComponent(0.63).setStroke()
                p.stroke()
            }
            line(text, 56, y, logFont, last ? T.MUTED : T.DISABLED_FG)
        }
    }

    private func line(_ s: String, _ x: CGFloat, _ y: CGFloat, _ font: NSFont, _ color: NSColor, width: CGFloat? = nil) {
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingTail
        let h = ceil(font.ascender - font.descender + font.leading)
        (s as NSString).draw(with: NSRect(x: x, y: y, width: width ?? bounds.width - x - 36, height: h),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             attributes: [.font: font, .foregroundColor: color, .paragraphStyle: ps])
    }

    /// The splash as a bitmap (screenshots, self-test); it does not need to be on screen.
    static func render() -> NSBitmapImageRep? {
        let v = SplashView(frame: NSRect(origin: .zero, size: size))
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep
    }
}

/// The borderless splash window, centred on the main screen.
final class SplashWindow: NSWindow {
    private(set) static var wasShown = false
    let view = SplashView(frame: NSRect(origin: .zero, size: SplashView.size))

    init() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let s = SplashView.size
        let frame = NSRect(x: (screen.midX - s.width / 2).rounded(), y: (screen.midY - s.height / 2).rounded(), width: s.width, height: s.height)
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        level = .floating
        title = "Disk Space Analyzer"
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Puts the splash on screen now: drawn and committed to the window server without waiting for the run loop.
    func present() {
        orderFrontRegardless()
        display()
        CATransaction.flush()
        SplashWindow.wasShown = true
    }

    /// Logs a startup step and puts it on screen at once (the main thread is busy building the window).
    func step(_ text: String) {
        view.step(text)
        display()
        CATransaction.flush()
    }
}

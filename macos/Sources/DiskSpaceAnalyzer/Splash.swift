import AppKit
import QuartzCore

/// Splash shown from the first moment of a normal start until the main window is on screen: 520x300, bg, 2 px surface
/// frame, the logo, name, tagline, two lines saying what happens next and a status line. It is drawn and flushed to the
/// window server at once (no run-loop turn), so building the main window right after it is not delayed.
final class SplashView: NSView {
    static let size = NSSize(width: 520, height: 300)
    static let radius: CGFloat = 10
    var status = "Starting..." { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill()
        Theme.fillRound(bounds, SplashView.radius, fill: T.SURFACE)
        Theme.fillRound(bounds.insetBy(dx: 2, dy: 2), SplashView.radius - 2, fill: T.BG)
        Theme.drawLogo(in: NSRect(x: 36, y: 48, width: 96, height: 96))
        let name = "Disk Space Analyzer"
        let nameWidth = bounds.width - 176
        var size: CGFloat = 30
        var font = NSFont.boldSystemFont(ofSize: size)
        while size > 16 && (name as NSString).size(withAttributes: [.font: font]).width > nameWidth {
            size -= 1
            font = NSFont.boldSystemFont(ofSize: size)
        }
        line(name, 156, 54, font, T.FG, width: nameWidth)
        line("Drives  \u{2192}  where the space went", 158, 100, NSFont.systemFont(ofSize: 14), T.MUTED, width: bounds.width - 170)
        T.SURFACE.setFill()
        NSRect(x: 36, y: 186, width: bounds.width - 72, height: 1).fill()
        let small = NSFont.systemFont(ofSize: 12)
        line("Opening the window. The startup disk is analyzed right away;", 36, 198, small, T.MUTED)
        line("you can browse while it runs.", 36, 222, small, T.MUTED)
        line(status, 36, 262, small, T.FG)
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
}

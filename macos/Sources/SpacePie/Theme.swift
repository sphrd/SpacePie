import AppKit
import QuartzCore

/// Danger tokens (permanent deletes, uninstall, the delete progress strip). gen_tokens.py leaves out any token defined
/// here, so src/Theme.cs may define the same names without a clash.
extension T {
    static let DANGER = rgb(0xe5534b)
    static let DANGER_HOVER = rgb(0xf47067)
    static let DANGER_BG = rgb(0x3b2427)
    static let DANGER_BORDER = rgb(0x6b2e30)
    static let DANGER_FG = rgb(0xffb3ad)
}

/// Fonts, spacing and drawing helpers shared by all views. Colours come from Tokens.swift (generated from src/Theme.cs).
enum Theme {
    // Design language sizes are given in points on Windows (Segoe UI); macOS uses the system font at the same sizes + 3
    // so the visual weight matches (Windows pt at 96 dpi vs. macOS pt at 72 dpi).
    static let font = NSFont.systemFont(ofSize: 13)
    static let font11 = NSFont.systemFont(ofSize: 14)
    static let font9 = NSFont.systemFont(ofSize: 11.5)
    static let font9Bold = NSFont.boldSystemFont(ofSize: 11.5)
    static let font11Bold = NSFont.boldSystemFont(ofSize: 14)
    static let fontBold = NSFont.boldSystemFont(ofSize: 13)
    static let font15Bold = NSFont.boldSystemFont(ofSize: 18)

    static func lineHeight(_ f: NSFont) -> CGFloat { ceil(f.ascender - f.descender + f.leading) }

    static func roundRect(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: r, xRadius: min(radius, r.width / 2, r.height / 2), yRadius: min(radius, r.width / 2, r.height / 2))
    }

    /// Rounded rectangle with a 1 px outline (pass outline == fill for none).
    static func fillRound(_ r: NSRect, _ radius: CGFloat, fill: NSColor, outline: NSColor? = nil) {
        guard r.width > 0, r.height > 0 else { return }
        if let o = outline, o != fill {
            o.setFill(); roundRect(r, radius).fill()
            fill.setFill(); roundRect(r.insetBy(dx: 1, dy: 1), max(0, radius - 1)).fill()
        } else {
            fill.setFill(); roundRect(r, radius).fill()
        }
    }

    // ---- flair (busy states only), the same as src/Theme.cs: comet arc, glow, shared clock

    /// Animation clock (seconds) shared by spinners, the orbit and the splash, so they move in step.
    static var now: Double { CACurrentMediaTime() }

    /// Trailing arc on a circle (every spinner; same as Theme.DrawCometArc in src/Theme.cs): the tail `sweep` degrees
    /// behind the head fades to transparent, ending in a lighter head dot no wider than the line. No glow. Flipped view.
    static func drawCometArc(in circle: NSRect, head: CGFloat, sweep: CGFloat, width: CGFloat, color: NSColor) {
        let c = NSPoint(x: circle.midX, y: circle.midY), r = circle.width / 2
        let steps = 28, step = sweep / CGFloat(steps)
        for i in 0..<steps {
            let k = CGFloat(i + 1) / CGFloat(steps)
            let start = head - sweep + CGFloat(i) * step
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: r, startAngle: start, endAngle: start + step + 0.6, clockwise: false)
            p.lineWidth = width
            color.withAlphaComponent(k * k).setStroke()
            p.stroke()
        }
        let rad = head * .pi / 180
        let hx = c.x + cos(rad) * r, hy = c.y + sin(rad) * r
        (color.blended(withFraction: 0.3, of: .white) ?? color).setFill()
        NSBezierPath(ovalIn: NSRect(x: hx - width / 2, y: hy - width / 2, width: width, height: width)).fill()
    }

    /// Sweep: a `seg`-wide highlight fading transparent -> colour -> transparent glides left to right along `track`, one
    /// pass per `period` seconds, clipped to `clip` (the track itself if nil).
    static func drawSweep(_ track: NSRect, seg: CGFloat, period: Double, color: NSColor, clip: NSBezierPath? = nil) {
        guard track.width > 0, track.height > 0 else { return }
        let pos = track.minX - seg + CGFloat(now.truncatingRemainder(dividingBy: period) / period) * (track.width + seg)
        NSGraphicsContext.saveGraphicsState()
        (clip ?? NSBezierPath(rect: track)).addClip()
        NSGradient(colors: [color.withAlphaComponent(0), color, color.withAlphaComponent(0)])?
            .draw(in: NSRect(x: pos, y: track.minY, width: seg, height: track.height), angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Working state of the logo (same as Theme.DrawMouthLoop in src/Theme.cs): the mouth read as a 3D cone opening left;
    /// a tail runs round its base circle, seen in perspective as an oval centred on the mouth's chord (half-axes 0.11 R
    /// across, 0.36 R high: inside the logo's circle). Only the tail is drawn: alpha 0 -> full over 40 % of the loop,
    /// ending in a lighter head dot no wider than the line; even phase round the 3D circle, so the motion follows sin/cos
    /// (quick across the front and back, slow at the top and bottom). Flipped view.
    static let logoMouth: CGFloat = 30
    static func drawMouthLoop(in circle: NSRect, seconds: Double, color: NSColor) {
        let R = Double(circle.width / 2), cx = Double(circle.midX), cy = Double(circle.midY)
        let xc = cx - 0.8 * R * cos(Double(logoMouth) * .pi / 180)
        let a = 0.09 * R, b = 0.3 * R
        func at(_ phi: Double) -> NSPoint { NSPoint(x: xc - a * cos(phi), y: cy - b * sin(phi)) }
        let w = max(2, CGFloat(R) / 15)
        let period = 1.0, span = 0.4 * 2 * Double.pi, pieces = 48
        let head = seconds.truncatingRemainder(dividingBy: period) / period * 2 * .pi
        for i in 0..<pieces {
            let t0 = Double(i) / Double(pieces), t1 = Double(i + 1) / Double(pieces)
            let k = CGFloat((t0 + t1) / 2)          // 0 at the tail end, 1 at the head
            let seg = NSBezierPath()
            seg.move(to: at(head - span + t0 * span))
            seg.line(to: at(head - span + t1 * span))
            seg.lineWidth = w; seg.lineCapStyle = .round
            color.withAlphaComponent(k * k).setStroke(); seg.stroke()
        }
        let hp = at(head), d = w
        (color.blended(withFraction: 0.3, of: .white) ?? color).setFill()
        NSBezierPath(ovalIn: NSRect(x: hp.x - d / 2, y: hp.y - d / 2, width: d, height: d)).fill()
    }

    /// The brand logo: drawLogo with the soft accent glow behind it (as on the splash); glowAlpha ~0.18 on bg, ~0.13 on surface.
    static func drawLogoGlow(in circle: NSRect, alpha: CGFloat = 1, glowAlpha: CGFloat = 0.18, glowFactor: CGFloat = 1.15) {
        guard alpha > 0 else { return }
        drawGlow(at: NSPoint(x: circle.midX, y: circle.midY), radius: circle.width * glowFactor, color: T.ACCENT, alpha: glowAlpha * min(1, alpha))
        drawLogo(in: circle, alpha: alpha)
    }

    /// Soft radial glow: `color` at `alpha` in the centre, transparent at `radius`.
    static func drawGlow(at center: NSPoint, radius: CGFloat, color: NSColor, alpha: CGFloat) {
        guard radius >= 1 else { return }
        NSGradient(colors: [color.withAlphaComponent(alpha), color.withAlphaComponent(0)])?
            .draw(in: NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)),
                  relativeCenterPosition: .zero)
    }

    /// Pie slice path in a flipped view: angles in degrees, 0 = 3 o'clock, clockwise positive (like GDI+ FillPie).
    static func pie(_ r: NSRect, start: CGFloat, sweep: CGFloat) -> NSBezierPath {
        let c = NSPoint(x: r.midX, y: r.midY), rad = r.width / 2
        let p = NSBezierPath()
        p.move(to: c)
        // In a flipped view, increasing angles run clockwise on screen, matching the Windows code.
        p.appendArc(withCenter: c, radius: rad, startAngle: start, endAngle: start + sweep, clockwise: false)
        p.close()
        return p
    }

    /// App logo: Pac-Man pie facing left, LOGO_TOP_LEFT upper-left, LOGO_RIGHT right half, LOGO_BOTTOM_LEFT lower-left.
    /// Must be drawn in a flipped view.
    static func drawLogo(in circle: NSRect, alpha: CGFloat = 1) {
        guard alpha > 0 else { return }
        let mouth: CGFloat = 30, under: CGFloat = 6
        T.LOGO_TOP_LEFT.withAlphaComponent(alpha).setFill()
        pie(circle, start: 180 + mouth, sweep: 90 - mouth + under).fill()
        T.LOGO_BOTTOM_LEFT.withAlphaComponent(alpha).setFill()
        pie(circle, start: 90 - under, sweep: 90 - mouth + under).fill()
        T.LOGO_RIGHT.withAlphaComponent(alpha).setFill()
        pie(circle, start: -90, sweep: 180).fill()
    }

    /// Logo as an image (for the Dock while running from the command line, About, etc.).
    static func logoImage(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
            drawLogo(in: r.insetBy(dx: r.width * 0.03, dy: r.width * 0.03))
            return true
        }
    }

    static func drawFolder(_ r: NSRect, _ c: NSColor) {
        let x = r.minX, y = r.minY, w = r.width, h = r.height
        c.setFill()
        roundRect(NSRect(x: x + w * 0.08, y: y + h * 0.16, width: w * 0.40, height: h * 0.24), w * 0.07).fill()
        roundRect(NSRect(x: x + w * 0.08, y: y + h * 0.28, width: w * 0.84, height: h * 0.56), w * 0.10).fill()
    }

    static func drawFile(_ r: NSRect, _ c: NSColor) {
        let x = r.minX, y = r.minY, w = r.width, h = r.height
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x + w * 0.24, y: y + h * 0.10))
        p.line(to: NSPoint(x: x + w * 0.58, y: y + h * 0.10))
        p.line(to: NSPoint(x: x + w * 0.78, y: y + h * 0.30))
        p.line(to: NSPoint(x: x + w * 0.78, y: y + h * 0.90))
        p.line(to: NSPoint(x: x + w * 0.24, y: y + h * 0.90))
        p.close()
        p.move(to: NSPoint(x: x + w * 0.58, y: y + h * 0.10))
        p.line(to: NSPoint(x: x + w * 0.58, y: y + h * 0.30))
        p.line(to: NSPoint(x: x + w * 0.78, y: y + h * 0.30))
        p.lineWidth = max(1.2, w * 0.09)
        p.lineJoinStyle = .round
        c.setStroke(); p.stroke()
    }

    /// Arrow (back / forward, as Theme.DrawArrow in src/Theme.cs): a horizontal shaft with an open head, pointing left or
    /// right, in the middle of r (a button: drawn at about 60 % of its height). Flipped view.
    static func drawArrow(_ r: NSRect, _ c: NSColor, left: Bool) {
        drawArrow(r, c, dx: left ? -1 : 1, dy: 0)
    }

    /// Arrow pointing along (dx, dy) (one of them 0, the other +-1; flipped view: dy -1 = up).
    static func drawArrow(_ r: NSRect, _ c: NSColor, dx: CGFloat, dy: CGFloat) {
        let side = min(r.width, r.height) * (r.width > 22 ? 0.6 : 1)
        let cx = r.midX, cy = r.midY, a = side * 0.40
        let nx = -dy, ny = dx                                 // across the shaft
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx - dx * a, y: cy - dy * a))
        p.line(to: NSPoint(x: cx + dx * a, y: cy + dy * a))
        p.move(to: NSPoint(x: cx + dx * a * 0.15 + nx * a * 0.8, y: cy + dy * a * 0.15 + ny * a * 0.8))
        p.line(to: NSPoint(x: cx + dx * a, y: cy + dy * a))
        p.line(to: NSPoint(x: cx + dx * a * 0.15 - nx * a * 0.8, y: cy + dy * a * 0.15 - ny * a * 0.8))
        p.lineWidth = max(1.6, side / 10)
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        c.setStroke(); p.stroke()
    }

    /// Warning sign: a triangle with rounded corners and an exclamation mark cut out in `cut` (as WarningSignView).
    static func drawWarningSign(_ b: NSRect, _ color: NSColor, cut: NSColor) {
        let lw = b.width * 0.14
        let r = b.insetBy(dx: lw / 2 + 1, dy: lw / 2 + 1)
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: r.midX, y: r.minY))
        tri.line(to: NSPoint(x: r.maxX, y: r.maxY))
        tri.line(to: NSPoint(x: r.minX, y: r.maxY))
        tri.close()
        tri.lineWidth = lw
        tri.lineJoinStyle = .round
        color.setFill(); color.setStroke()
        tri.fill(); tri.stroke()
        let bw = b.width * 0.1
        cut.setFill()
        roundRect(NSRect(x: b.midX - bw / 2, y: r.minY + r.height * 0.32, width: bw, height: r.height * 0.36), bw / 2).fill()
        let d = bw * 1.15
        NSBezierPath(ovalIn: NSRect(x: b.midX - d / 2, y: r.minY + r.height * 0.76, width: d, height: d)).fill()
    }

    static func drawChevron(_ r: NSRect, _ c: NSColor, down: Bool) {
        let cx = r.midX, cy = r.midY, a = r.width * 0.22
        let p = NSBezierPath()
        if down {
            p.move(to: NSPoint(x: cx - 1.6 * a, y: cy - 0.8 * a)); p.line(to: NSPoint(x: cx, y: cy + 0.8 * a)); p.line(to: NSPoint(x: cx + 1.6 * a, y: cy - 0.8 * a))
        } else {
            p.move(to: NSPoint(x: cx - 0.8 * a, y: cy - 1.6 * a)); p.line(to: NSPoint(x: cx + 0.8 * a, y: cy)); p.line(to: NSPoint(x: cx - 0.8 * a, y: cy + 1.6 * a))
        }
        p.lineWidth = 2; p.lineCapStyle = .round; p.lineJoinStyle = .round
        c.setStroke(); p.stroke()
    }

    /// Single-line text, vertically centred in r, truncated with "..." at the end.
    static func drawText(_ s: String, in r: NSRect, font: NSFont = Theme.font, color: NSColor, align: NSTextAlignment = .left) {
        let ps = NSMutableParagraphStyle()
        ps.alignment = align
        ps.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: ps]
        let h = ceil(font.ascender - font.descender + font.leading)
        let tr = NSRect(x: r.minX, y: r.minY + (r.height - h) / 2, width: r.width, height: h)
        (s as NSString).draw(with: tr, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    static func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    /// True when s does not fit in width on one line (drawText then cuts it off with "...").
    static func isCut(_ s: String, _ font: NSFont, _ width: CGFloat) -> Bool {
        !s.isEmpty && (s as NSString).size(withAttributes: [.font: font]).width > width + 0.01
    }
}

enum Fmt {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// Same format as the Windows app: binary units, 3 significant digits.
    static func size(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        var v = Double(bytes), u = 0
        while v >= 1024 && u < units.count - 1 { v /= 1024; u += 1 }
        let f = v < 10 ? "%.2f" : v < 100 ? "%.1f" : "%.0f"
        return String(format: f, v) + " " + units[u]
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func date(_ d: Date) -> String { dateFormatter.string(from: d) }

    /// Seconds since 1970 (0 = unknown: empty).
    static func date(_ secs: Int64) -> String { secs > 0 ? date(Date(timeIntervalSince1970: TimeInterval(secs))) : "" }

    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func shorten(_ s: String, _ max: Int) -> String {
        if s.count <= max { return s }
        let half = (max - 3) / 2
        return String(s.prefix(half)) + "..." + String(s.suffix(half))
    }

    static func pct(_ v: Double) -> String { String(format: "%.1f %%", v) }

    private static let countFormatter: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; return f }()

    static func count(_ n: Int64) -> String { countFormatter.string(from: NSNumber(value: n)) ?? "\(n)" }

    static func count(_ n: Int) -> String { count(Int64(n)) }

    /// "+1.2 GB" / "-300 MB" / "-" for no change.
    static func delta(_ d: Int64) -> String { d == 0 ? "-" : (d > 0 ? "+" : "-") + size(abs(d)) }
}

/// Flipped view with a solid background colour.
class FlatView: NSView {
    var fill: NSColor = T.BG { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    // Only inside the view: since macOS 14 views do not clip to their bounds by default and dirtyRect may reach beyond
    // them, so filling dirtyRect could paint over neighbouring views (it hid the toolbar above the main area).
    override func draw(_ dirtyRect: NSRect) { fill.setFill(); dirtyRect.intersection(bounds).fill() }
}

/// Rounded panel: surface fill, 1 px border outline (accent while `highlight`).
class PanelView: NSView {
    var highlight = false { didSet { needsDisplay = true } }
    var radius: CGFloat = 12
    var panelFill: NSColor = T.SURFACE
    var outline: NSColor = T.BORDER
    var backFill: NSColor = T.BG
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        backFill.setFill(); bounds.fill()
        Theme.fillRound(bounds, radius, fill: panelFill, outline: highlight ? T.ACCENT : outline)
    }
}

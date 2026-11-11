import AppKit

/// Line icons for the toolbar buttons (same shapes as src/Icons.cs), drawn in the button's text colour inside a square
/// in a flipped view, in the style of the views rail icons: round caps and joins.
enum Icons {
    private static func pen(_ s: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.lineWidth = max(1.4, s * 0.09)
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        return p
    }

    private static func pt(_ r: NSRect, _ fx: CGFloat, _ fy: CGFloat) -> NSPoint { NSPoint(x: r.minX + r.width * fx, y: r.minY + r.width * fy) }

    private static func poly(_ p: NSBezierPath, _ r: NSRect, _ pts: [(CGFloat, CGFloat)], close: Bool = false) {
        guard let first = pts.first else { return }
        p.move(to: pt(r, first.0, first.1))
        for q in pts.dropFirst() { p.line(to: pt(r, q.0, q.1)) }
        if close { p.close() }
    }

    /// Choose...: a folder.
    static func folder(_ r: NSRect, _ c: NSColor) {
        let p = pen(r.width)
        poly(p, r, [(0.08, 0.80), (0.08, 0.20), (0.38, 0.20), (0.48, 0.32), (0.92, 0.32), (0.92, 0.80)], close: true)
        c.setStroke(); p.stroke()
    }

    /// Scan: the logo's outline, a circle with its mouth open to the left (half-angle Theme.logoMouth, as in the logo).
    static func scan(_ r: NSRect, _ c: NSColor) {
        let s = r.width, ctr = pt(r, 0.5, 0.5), mouth = Theme.logoMouth
        let p = pen(s)
        p.move(to: ctr)
        // Flipped view: angles grow clockwise on screen; from the mouth's lower lip round the right to its upper lip.
        p.appendArc(withCenter: ctr, radius: s * 0.40, startAngle: 180 + mouth, endAngle: 180 - mouth, clockwise: false)
        p.close()
        c.setStroke(); p.stroke()
    }

    /// Full Disk Access (as Run as administrator on Windows): a shield.
    static func shield(_ r: NSRect, _ c: NSColor) {
        let p = pen(r.width)
        p.move(to: pt(r, 0.50, 0.08))
        p.line(to: pt(r, 0.86, 0.22))
        p.curve(to: pt(r, 0.50, 0.92), controlPoint1: pt(r, 0.86, 0.62), controlPoint2: pt(r, 0.72, 0.80))
        p.curve(to: pt(r, 0.14, 0.22), controlPoint1: pt(r, 0.28, 0.80), controlPoint2: pt(r, 0.14, 0.62))
        p.close()
        p.move(to: pt(r, 0.50, 0.24)); p.line(to: pt(r, 0.50, 0.76))
        c.setStroke(); p.stroke()
    }

    /// Show in Finder: an open folder (the back with its tab, the front flap tilted open).
    static func reveal(_ r: NSRect, _ c: NSColor) {
        let p = pen(r.width)
        poly(p, r, [(0.08, 0.82), (0.08, 0.18), (0.36, 0.18), (0.46, 0.30), (0.82, 0.30), (0.82, 0.42)])
        poly(p, r, [(0.08, 0.82), (0.24, 0.42), (0.96, 0.42), (0.80, 0.82)], close: true)
        c.setStroke(); p.stroke()
    }

    private static func trashLines(_ p: NSBezierPath, _ r: NSRect) {
        poly(p, r, [(0.14, 0.24), (0.86, 0.24)])
        poly(p, r, [(0.40, 0.12), (0.60, 0.12)])
        poly(p, r, [(0.22, 0.24), (0.28, 0.90), (0.72, 0.90), (0.78, 0.24)])
        poly(p, r, [(0.42, 0.40), (0.43, 0.74)])
        poly(p, r, [(0.58, 0.40), (0.57, 0.74)])
    }

    /// Delete list: a trash can.
    static func trash(_ r: NSRect, _ c: NSColor) {
        let p = pen(r.width)
        trashLines(p, r)
        c.setStroke(); p.stroke()
    }

    /// Add to delete list: a smaller trash can with a plus at its top right.
    static func trashAdd(_ r: NSRect, _ c: NSColor) {
        let s = r.width
        let p = pen(s)
        trashLines(p, NSRect(x: r.minX - s * 0.06, y: r.minY + s * 0.12, width: s * 0.84, height: s * 0.84))
        poly(p, r, [(0.80, 0.02), (0.80, 0.34)])
        poly(p, r, [(0.64, 0.18), (0.96, 0.18)])
        c.setStroke(); p.stroke()
    }

    /// Delete permanently: a warning triangle with an exclamation mark (lines, for a coloured button).
    static func danger(_ r: NSRect, _ c: NSColor) {
        let s = r.width
        let p = pen(s)
        poly(p, r, [(0.50, 0.10), (0.94, 0.88), (0.06, 0.88)], close: true)
        poly(p, r, [(0.50, 0.38), (0.50, 0.62)])
        c.setStroke(); p.stroke()
        c.setFill(); NSBezierPath(ovalIn: NSRect(x: r.minX + s * 0.43, y: r.minY + s * 0.70, width: s * 0.14, height: s * 0.14)).fill()
    }

    /// Import...: an arrow coming down into an open tray (the reverse of Export).
    static func importScan(_ r: NSRect, _ c: NSColor) {
        let p = pen(r.width)
        poly(p, r, [(0.10, 0.56), (0.10, 0.90), (0.90, 0.90), (0.90, 0.56)])
        poly(p, r, [(0.50, 0.08), (0.50, 0.68)])
        poly(p, r, [(0.28, 0.46), (0.50, 0.68), (0.72, 0.46)])
        c.setStroke(); p.stroke()
    }

    /// Export...: an open tray with an arrow rising out of it.
    static func export(_ r: NSRect, _ c: NSColor) {
        let p = pen(r.width)
        poly(p, r, [(0.10, 0.56), (0.10, 0.90), (0.90, 0.90), (0.90, 0.56)])
        poly(p, r, [(0.50, 0.68), (0.50, 0.08)])
        poly(p, r, [(0.28, 0.30), (0.50, 0.08), (0.72, 0.30)])
        c.setStroke(); p.stroke()
    }
}

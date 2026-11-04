import AppKit

final class ChartSlice {
    var label = "", detail = ""
    var size: Int64 = 0
    var color: NSColor = T.ACCENT
    var dir: DirNode?           // folder opened on click (single-folder slices only)
    var empty = false           // free space: nothing drawn
    var rows: [Int] = []        // rows of the open list this slice stands for
    init(_ label: String, _ size: Int64, _ color: NSColor) { self.label = label; self.size = size; self.color = color }
}

/// A section of an outer ring: a subfolder (ring 1) or a sub-subfolder (ring 2) of a folder slice.
final class ChartArc {
    var start: CGFloat = 0, sweep: CGFloat = 0
    var level = 1
    var owner = 0
    var color: NSColor = T.ACCENT
    var dir: DirNode
    var parentSize: Int64 = 0
    init(_ dir: DirNode) { self.dir = dir }
}

/// Donut chart of the open list. Slices follow the list row for row (same order); runs of small rows are merged. For a
/// folder's contents up to two thin outer rings show the subfolders and sub-subfolders of folder slices (sunburst). Free
/// space is an empty gap ending at 12 o'clock. Before data exists the app logo is shown on the same circle; when data
/// arrives it fades out while the slices sweep in. Hover is linked with the list both ways.
final class PieChart: NSView {
    private(set) var slices: [ChartSlice] = []
    private var arcs: [ChartArc] = []
    private var rings = 0
    private var hoverArc = -1
    private(set) var total: Int64 = 0
    private var title = "", subtitle = ""
    private var hover = -1, reported = -1
    private var pieRect = NSRect.zero
    private var logoMode = false
    private var logoNote = ""
    private var anim: CGFloat = 1
    private var animStart = Date()
    private var animTimer: Timer?
    private let animSeconds = 0.65
    private var lastTick = Date()
    // Centre when nothing is hovered: the folder shown; clicking it goes up one level (the reverse of clicking a slice).
    private var centerName: String?
    private var canGoUp = false, hoverCenter = false
    var onCenterClick: (() -> Void)?
    private let startAngle: CGFloat = -90

    var onHover: ((Int) -> Void)?
    var onClick: ((ChartSlice) -> Void)?
    override var isFlipped: Bool { true }

    // Treemap (the extension below): the same slices as rectangles.
    private var treemapOn = false
    private var tilesDirty = true
    private var tiles: [TreemapTile] = []
    private var hoverTile = -1
    private var hoverUp = false
    private var mapRect = NSRect.zero
    private var upRect = NSRect.zero
    /// Right margin of the title lines (room for the Pie / Treemap switch placed over the chart).
    /// Title, subtitle, centre and treemap texts cut off with "..." (shown in full on hover).
    private let cuts = CutTips()
    var titleRightMargin: CGFloat = 0 { didSet { if oldValue != titleRightMargin { needsDisplay = true } } }

    /// Rectangles instead of rings.
    var treemap: Bool {
        get { treemapOn }
        set {
            if treemapOn == newValue { return }
            treemapOn = newValue
            tilesDirty = true
            hover = -1; reported = -1; hoverTile = -1; hoverArc = -1; hoverUp = false
            needsDisplay = true
        }
    }

    /// Rectangles laid out at the last paint (self-test).
    var tileCount: Int { tiles.count }

    /// Lays the treemap out for the current size without drawing (self-test: a hidden window may never draw).
    func layoutTreemapNow() {
        let pad: CGFloat = 10, top: CGFloat = 70, infoH: CGFloat = 44
        let map = NSRect(x: pad, y: top, width: max(0, bounds.width - 2 * pad), height: max(40, bounds.height - top - pad - infoH))
        if mapRect.width < 10 || mapRect.height < 10 { mapRect = map }
        layoutTiles()
    }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); tilesDirty = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private var animating: Bool { anim < 1 }
    /// Logo shown instead of a chart; morphs counts the logo-to-chart transitions (self-test).
    var showingLogo: Bool { logoMode }
    private(set) var morphs = 0

    func showLogo(_ title: String, _ subtitle: String, _ note: String, working: Bool = false) {
        self.title = title; self.subtitle = subtitle; logoNote = note
        slices = []; arcs = []; rings = 0; total = 0; hover = -1; hoverArc = -1; reported = -1
        tiles = []; tilesDirty = true; hoverTile = -1; hoverUp = false
        logoMode = true
        animTimer?.invalidate(); animTimer = nil; anim = 1
        setWorking(working)
        needsDisplay = true
    }

    // While a scan runs a fading tail runs round a loop in the logo's mouth (Theme.drawMouthLoop).
    private var working = false
    private var orbitTimer: Timer?
    private func setWorking(_ on: Bool) {
        working = on
        if on, orbitTimer == nil {
            orbitTimer = Timer.scheduledTimer(withTimeInterval: 0.010, repeats: true) { [weak self] _ in
                guard let s = self else { return }
                s.setNeedsDisplay(NSRect(x: s.pieRect.minX - 20, y: s.pieRect.minY, width: s.pieRect.width / 2, height: s.pieRect.height))
            }
        } else if !on { orbitTimer?.invalidate(); orbitTimer = nil }
    }

    /// Shows slices; rings > 0 adds that many outer rings with the subfolders of folder slices.
    func setData(_ title: String, _ subtitle: String, _ slices: [ChartSlice], rings: Int = 0) {
        self.title = title; self.subtitle = subtitle; self.slices = slices
        total = slices.reduce(Int64(0)) { $0 + max(0, $1.size) }
        self.rings = rings
        arcs = []
        hoverArc = -1
        tilesDirty = true
        hoverTile = -1
        hoverUp = false
        centerName = nil; canGoUp = false; hoverCenter = false
        if rings > 0 && total > 0 {
            var a = startAngle
            for (i, s) in slices.enumerated() {
                let sweep = CGFloat(360 * Double(max(0, s.size)) / Double(total))
                if let d = s.dir { addArcs(d, a, sweep, 1, i, s.color) }
                a += sweep
            }
        }
        hover = -1; reported = -1
        if logoMode && total > 0 && window != nil {
            morphs += 1
            anim = 0
            animStart = Date()
            lastTick = Date()
            animTimer?.invalidate()
            animTimer = Timer.scheduledTimer(withTimeInterval: 0.010, repeats: true) { [weak self] t in
                guard let s = self else { t.invalidate(); return }
                // Advance by frame, at most 50 ms per step: a busy moment right after a scan must not skip the morph.
                let now = Date(), dt = min(0.05, now.timeIntervalSince(s.lastTick))
                s.lastTick = now
                s.anim = CGFloat(min(1, Double(s.anim) + dt / s.animSeconds))
                if s.anim >= 1 { t.invalidate(); s.animTimer = nil }
                s.needsDisplay = true
            }
        }
        logoMode = false
        setWorking(false)
        needsDisplay = true
    }

    private func addArcs(_ dir: DirNode, _ start: CGFloat, _ sweep: CGFloat, _ level: Int, _ owner: Int, _ base: NSColor) {
        if level > rings || dir.children.isEmpty || dir.size <= 0 || sweep < 1 { return }
        var a = start
        var k = 0
        for c in dir.children {
            let s = CGFloat(Double(sweep) * Double(c.size) / Double(dir.size))
            if s < 1.5 { break }                   // children are sorted by size: the rest are smaller still
            let arc = ChartArc(c)
            arc.start = a; arc.sweep = s; arc.level = level; arc.owner = owner; arc.parentSize = dir.size
            arc.color = PieChart.blend(base, T.SURFACE, (level == 1 ? 0.28 : 0.5) + (k % 2 == 0 ? 0 : 0.12))
            k += 1
            arcs.append(arc)
            addArcs(c, a, s, level + 1, owner, base)
            a += s
        }
    }

    static func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor { a.blended(withFraction: t, of: b) ?? a }

    // Radii as fractions of the chart radius (with outer rings): hole, inner ring, then one band per outer ring.
    private var holeRatio: CGFloat { rings > 0 ? 0.48 : 0.58 }
    private var innerOuterRatio: CGFloat { rings > 0 ? 1 - 0.15 * CGFloat(rings) : 1 }
    private func ringInner(_ level: Int) -> CGFloat { innerOuterRatio + 0.02 + 0.15 * CGFloat(level - 1) }
    private func ringOuter(_ level: Int) -> CGFloat { innerOuterRatio + 0.15 * CGFloat(level) }

    /// Highlight from the list (does not call onHover).
    func setHover(_ i: Int) {
        let v = (i >= slices.count || animating) ? -1 : i
        if v != hover || hoverArc != -1 || hoverTile != -1 { hover = v; hoverArc = -1; hoverTile = -1; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        T.SURFACE.setFill(); bounds.fill()
        cuts.begin()
        guard !title.isEmpty else { return }
        let pad: CGFloat = 12
        var y = pad
        let titleW = max(10, bounds.width - 2 * pad - titleRightMargin)
        cuts.draw(title, in: NSRect(x: pad, y: y, width: titleW, height: 20), font: Theme.font11, color: T.FG)
        y += 22
        if !subtitle.isEmpty {
            cuts.draw(subtitle, in: NSRect(x: pad, y: y, width: titleW, height: 16), font: Theme.font9, color: T.MUTED)
            y += 16
        }
        y += 16
        let grow: CGFloat = 6
        var d = min(bounds.width - 2 * pad - 2 * grow, bounds.height - y - pad - 2 * grow)
        d = max(60, d)
        let top = y + max(0, (bounds.height - y - pad - d) / 3)
        pieRect = NSRect(x: ((bounds.width - d) / 2).rounded(), y: top.rounded(), width: d, height: d)
        if logoMode {
            drawBrandLogo(pieRect, alpha: 1)
            if working { Theme.drawMouthLoop(in: pieRect, seconds: Theme.now, color: T.ACCENT) }
            if !logoNote.isEmpty {
                let ps = NSMutableParagraphStyle(); ps.alignment = .center
                (logoNote as NSString).draw(in: NSRect(x: 10, y: pieRect.maxY + 14, width: bounds.width - 20, height: 40),
                                            withAttributes: [.font: Theme.font9, .foregroundColor: T.MUTED, .paragraphStyle: ps])
            }
        } else if treemapOn { drawTreemap(NSRect(x: pad, y: y, width: bounds.width - 2 * pad, height: max(0, bounds.height - y - pad))) }
        else if animating { drawMorph() }
        else { drawDonut() }
    }

    private static func ease(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }

    private static func band(_ c: NSPoint, _ r0: CGFloat, _ r1: CGFloat, _ start: CGFloat, _ sweep: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: r1, startAngle: start, endAngle: start + sweep, clockwise: false)
        p.appendArc(withCenter: c, radius: r0, startAngle: start + sweep, endAngle: start, clockwise: true)
        p.close()
        return p
    }

    private func fillBand(_ r0: CGFloat, _ r1: CGFloat, _ start: CGFloat, _ sweep: CGFloat, _ color: NSColor) {
        if r1 - r0 < 0.5 || sweep <= 0 { return }
        color.setFill()
        PieChart.band(NSPoint(x: pieRect.midX, y: pieRect.midY), r0, r1, start, sweep).fill()
    }

    /// The logo on the chart's circle, without a glow (owner: the halo around it looked bad); fades during the morph.
    private func drawBrandLogo(_ r: NSRect, alpha: CGFloat) {
        Theme.drawLogo(in: r, alpha: alpha)
    }

    private func drawMorph() {
        let e = PieChart.ease(anim), r = pieRect
        drawBrandLogo(r, alpha: 1 - e)
        let shrink = r.width * (1 - innerOuterRatio) / 2
        let pr = r.insetBy(dx: shrink, dy: shrink)
        let reveal = 360 * e, alpha = min(1, anim * 2.5)
        var start = startAngle
        for s in slices {
            let sweep = CGFloat(360 * Double(s.size) / Double(total))
            if sweep <= 0 { continue }
            let visible = min(sweep, reveal - (start - startAngle))
            if visible <= 0 { break }
            if !s.empty { s.color.withAlphaComponent(alpha).setFill(); Theme.pie(pr, start: start, sweep: max(0.01, visible)).fill() }
            start += sweep
        }
        if rings > 0 {
            let R = r.width / 2
            for a in arcs {
                let visible = min(a.sweep, reveal - (a.start - startAngle))
                if visible > 0 { fillBand(R * ringInner(a.level), R * ringOuter(a.level), a.start, visible, a.color.withAlphaComponent(alpha * e)) }
            }
        }
        let hole = r.width * holeRatio * e
        if hole > 0 { T.SURFACE.setFill(); NSBezierPath(ovalIn: NSRect(x: r.midX - hole / 2, y: r.midY - hole / 2, width: hole, height: hole)).fill() }
    }

    private func drawDonut() {
        let r = pieRect, R = r.width / 2
        if total <= 0 {
            T.BORDER.setFill(); NSBezierPath(ovalIn: r).fill()
        } else {
            var start = startAngle
            for (i, s) in slices.enumerated() {
                let sweep = CGFloat(360 * Double(s.size) / Double(total))
                if sweep <= 0 { continue }
                if !s.empty {
                    if rings > 0 {
                        let col = i == hover && hoverArc < 0 ? PieChart.blend(s.color, .white, 0.25) : s.color
                        fillBand(R * holeRatio, R * innerOuterRatio, start, max(0.01, sweep), col)
                    } else {
                        let rr = i == hover ? r.insetBy(dx: -6, dy: -6) : r
                        s.color.setFill(); Theme.pie(rr, start: start, sweep: max(0.01, sweep)).fill()
                    }
                } else if i == hover {
                    fillBand(R * holeRatio, R, start, sweep, T.BORDER)
                }
                start += sweep
            }
            for (i, a) in arcs.enumerated() {
                fillBand(R * ringInner(a.level), R * ringOuter(a.level), a.start, a.sweep, i == hoverArc ? PieChart.blend(a.color, .white, 0.3) : a.color)
            }
            // Thin separators in the panel colour between visible slices.
            if slices.filter({ $0.size > 0 }).count > 1 {
                start = startAngle
                let c = NSPoint(x: r.midX, y: r.midY), rad = R + 7
                T.SURFACE.setStroke()
                for s in slices where s.size > 0 {
                    let a = start * .pi / 180
                    let p = NSBezierPath(); p.move(to: c); p.line(to: NSPoint(x: c.x + rad * cos(a), y: c.y + rad * sin(a)))
                    p.lineWidth = 1.5; p.stroke()
                    start += CGFloat(360 * Double(s.size) / Double(total))
                }
            }
        }
        let hole = r.width * holeRatio
        let hr = NSRect(x: r.midX - hole / 2, y: r.midY - hole / 2, width: hole, height: hole)
        T.SURFACE.setFill(); NSBezierPath(ovalIn: hr).fill()
        var l1 = "Total", l2 = Fmt.size(total), l3 = ""
        if hoverArc >= 0 && hoverArc < arcs.count {
            let a = arcs[hoverArc]
            l1 = a.dir.name; l2 = Fmt.size(a.dir.size)
            l3 = String(format: "%.1f %%", 100 * Double(a.dir.size) / Double(max(1, a.parentSize))) + " of " + (a.dir.parent?.name ?? "parent")
        } else if hover >= 0 && hover < slices.count { l1 = slices[hover].label; l2 = Fmt.size(slices[hover].size); l3 = slices[hover].detail }
        else if let c = centerName { l1 = c; l3 = canGoUp && hoverCenter ? "Click to go up" : "" }
        let up = hoverCenter && hover < 0 && hoverArc < 0
        let inner = hr.insetBy(dx: 16, dy: 0)
        let h1: CGFloat = 15, h2: CGFloat = 19, h3: CGFloat = l3.isEmpty ? 0 : 15
        let ty = hr.minY + (hr.height - h1 - h2 - h3) / 2
        cuts.draw(l1, in: NSRect(x: inner.minX, y: ty, width: inner.width, height: h1), font: Theme.font9, color: up ? T.ACCENT : T.MUTED, align: .center)
        cuts.draw(l2, in: NSRect(x: inner.minX, y: ty + h1, width: inner.width, height: h2), font: Theme.font11, color: up ? T.ACCENT : T.FG, align: .center)
        if h3 > 0 { cuts.draw(l3, in: NSRect(x: inner.minX, y: ty + h1 + h2, width: inner.width, height: h3), font: Theme.font9, color: T.MUTED, align: .center) }
    }

    /// Names the folder in the centre (instead of "Total"); with canGoUp the centre is clickable. Call after setData.
    func setCenter(_ name: String, canGoUp: Bool) {
        centerName = name; self.canGoUp = canGoUp
        needsDisplay = true
    }

    private func inCenter(_ p: NSPoint) -> Bool {
        if total <= 0 || pieRect.width <= 0 || logoMode || animating { return false }
        return angleAt(p).dist < Double(pieRect.width / 2 * holeRatio)
    }

    private func angleAt(_ p: NSPoint) -> (dist: Double, angle: Double) {
        let dx = Double(p.x - pieRect.midX), dy = Double(p.y - pieRect.midY)
        return ((dx * dx + dy * dy).squareRoot(), atan2(dy, dx) * 180 / .pi)
    }

    /// Outer-ring section under the point (-1 = none).
    private func arcAt(_ p: NSPoint) -> Int {
        if rings == 0 || arcs.isEmpty || logoMode || animating || pieRect.width <= 0 { return -1 }
        let (d, ang) = angleAt(p)
        let dist = d / Double(pieRect.width / 2)
        if dist <= Double(innerOuterRatio) || dist > 1.02 { return -1 }
        for (i, a) in arcs.enumerated() {
            if dist < Double(ringInner(a.level)) - 0.01 || dist > Double(ringOuter(a.level)) + 0.01 { continue }
            let rel = ((ang - Double(a.start)).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            if rel <= Double(a.sweep) { return i }
        }
        return -1
    }

    private func sliceAt(_ p: NSPoint) -> Int {
        if total <= 0 || pieRect.width <= 0 || logoMode || animating { return -1 }
        let (dist, a0) = angleAt(p)
        let R = Double(pieRect.width) / 2
        if dist > R + 6 || dist < R * Double(holeRatio) { return -1 }
        if rings > 0 && dist > R * Double(innerOuterRatio) {
            let a = arcAt(p)
            return a >= 0 ? arcs[a].owner : -1
        }
        var ang = a0 - Double(startAngle)
        ang = (ang.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        var acc = 0.0
        for (i, s) in slices.enumerated() where s.size > 0 {
            acc += 360 * Double(s.size) / Double(total)
            if ang <= acc { return i }
        }
        return -1
    }

    override func mouseMoved(with event: NSEvent) {
        cuts.track(self, event)
        let p = convert(event.locationInWindow, from: nil)
        if treemapOn { treemapMouseMoved(p); return }
        let h = sliceAt(p), ha = arcAt(p)
        let hc = canGoUp && inCenter(p)
        if hc || ha >= 0 || (h >= 0 && slices[h].dir != nil) { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        if h != hover || ha != hoverArc || hc != hoverCenter { hover = h; hoverArc = ha; hoverCenter = hc; needsDisplay = true }
        if h != reported { reported = h; onHover?(h) }
    }

    override func mouseExited(with event: NSEvent) {
        cuts.exit(self)
        NSCursor.arrow.set()
        if hover != -1 || hoverArc != -1 || hoverCenter || hoverTile != -1 || hoverUp {
            hover = -1; hoverArc = -1; hoverCenter = false; hoverTile = -1; hoverUp = false; needsDisplay = true
        }
        if reported != -1 { reported = -1; onHover?(-1) }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if treemapOn { treemapClick(p); return }
        if canGoUp && inCenter(p) { onCenterClick?(); return }
        let ha = arcAt(p)
        if ha >= 0 {
            let s = ChartSlice(arcs[ha].dir.name, arcs[ha].dir.size, arcs[ha].color)
            s.dir = arcs[ha].dir
            onClick?(s)
            return
        }
        let h = sliceAt(p)
        if h >= 0, slices[h].dir != nil { onClick?(slices[h]) }
    }
}

/// One rectangle of the treemap: a slice (level 0) or a subfolder inside a folder slice (levels 1 and 2).
final class TreemapTile {
    var rect = NSRect.zero
    var slice = 0                // index of the slice it belongs to
    var level = 0                // 0 = the slice itself
    var dir: DirNode?
    var color: NSColor = T.ACCENT
    var label = ""
    var size: Int64 = 0, parentSize: Int64 = 0
    var parentName: String?
}

/// Treemap view of the same slices as the pie chart: one rectangle per slice, area in true proportion (squarified so
/// rectangles stay close to square). Folder slices hold their subfolders, two levels deep (like the outer rings). Hover,
/// click (open a folder) and the link to the list work as for the rings; the area below the map shows the hovered item,
/// and "Up" goes to the parent folder. Free space is an outlined empty rectangle.
extension PieChart {
    /// Squarified treemap (Bruls et al.): sizes in any order; returns one rectangle per size, in the same order.
    static func squarify(_ sizes: [Double], _ area: NSRect) -> [NSRect] {
        var result = [NSRect](repeating: .zero, count: sizes.count)
        var order: [Int] = []
        var sum = 0.0
        for i in sizes.indices where sizes[i] > 0 { order.append(i); sum += sizes[i] }
        if sum <= 0 || area.width <= 0 || area.height <= 0 { return result }
        order.sort { sizes[$0] > sizes[$1] }
        let scale = Double(area.width) * Double(area.height) / sum
        var rect = area
        var start = 0
        while start < order.count {
            let side = Double(min(rect.width, rect.height))
            var end = start
            var rowSum = 0.0, worst = Double.greatestFiniteMagnitude
            while end < order.count {
                let a = sizes[order[end]] * scale, s = rowSum + a
                let maxA = max(a, end > start ? sizes[order[start]] * scale : a), minA = a
                let w = max(side * side * maxA / (s * s), s * s / (side * side * minA))
                if end > start && w > worst { break }
                worst = w
                rowSum = s
                end += 1
            }
            // Lay out order[start..<end] along the shorter side.
            let horizontal = rect.width >= rect.height        // a column on the left, stacked from the top
            let thick = side > 0 ? rowSum / side : 0
            var pos = Double(horizontal ? rect.minY : rect.minX)
            for k in start..<end {
                let len = thick > 0 ? sizes[order[k]] * scale / thick : 0
                result[order[k]] = horizontal
                    ? NSRect(x: rect.minX, y: CGFloat(pos), width: CGFloat(thick), height: CGFloat(len))
                    : NSRect(x: CGFloat(pos), y: rect.minY, width: CGFloat(len), height: CGFloat(thick))
                pos += len
            }
            let t = CGFloat(thick)
            rect = horizontal
                ? NSRect(x: rect.minX + t, y: rect.minY, width: max(0, rect.width - t), height: rect.height)
                : NSRect(x: rect.minX, y: rect.minY + t, width: rect.width, height: max(0, rect.height - t))
            start = end
        }
        return result
    }

    private func layoutTiles() {
        tiles = []
        tilesDirty = false
        if total <= 0 || mapRect.width < 10 || mapRect.height < 10 { return }
        let rects = PieChart.squarify(slices.map { Double(max(0, $0.size)) }, mapRect)
        for (i, s) in slices.enumerated() {
            let r = rects[i]
            if r.width <= 0 || r.height <= 0 { continue }
            let t = TreemapTile()
            t.rect = r; t.slice = i; t.level = 0; t.dir = s.dir; t.color = s.color; t.label = s.label; t.size = s.size; t.parentSize = total
            tiles.append(t)
        }
        let count = tiles.count
        for i in 0..<count where tiles[i].dir != nil && !slices[tiles[i].slice].empty { addChildTiles(tiles[i], 1) }
    }

    /// Subfolders inside a folder's tile (below its name), down to level 2; small ones are left out. The folder's own
    /// files take their share too (as a gap), so every subfolder keeps its true proportion.
    private func addChildTiles(_ parent: TreemapTile, _ level: Int) {
        guard level <= 2, let dir = parent.dir, !dir.children.isEmpty, dir.size > 0 else { return }
        let r = parent.rect
        let lh = Theme.lineHeight(Theme.font9)
        let head: CGFloat = level == 1 && r.height > lh * 3 ? lh + 6 : 0
        let inset: CGFloat = level == 1 ? 3 : 2
        let inner = NSRect(x: r.minX + inset, y: r.minY + head + inset, width: r.width - 2 * inset, height: r.height - head - 2 * inset)
        if inner.width < 12 || inner.height < 12 { return }
        var kids: [DirNode] = []
        var sizes: [Double] = []
        for c in dir.children {
            if c.size <= 0 || kids.count >= 200 { break }      // children are sorted by size
            kids.append(c)
            sizes.append(Double(c.size))
        }
        if kids.isEmpty { return }
        let kidsSum = kids.reduce(Int64(0)) { $0 + $1.size }
        if dir.size - kidsSum > 0 { sizes.append(Double(dir.size - kidsSum)) }
        let rects = PieChart.squarify(sizes, inner)
        let base = slices[parent.slice].color
        var k = 0
        for (i, c) in kids.enumerated() {
            let cr = rects[i]
            if cr.width < 4 || cr.height < 4 { continue }
            let t = TreemapTile()
            t.rect = cr; t.slice = parent.slice; t.level = level; t.dir = c
            t.color = PieChart.blend(base, T.SURFACE, (level == 1 ? 0.28 : 0.5) + (k % 2 == 0 ? 0 : 0.12))
            k += 1
            t.label = c.name; t.size = c.size; t.parentSize = dir.size; t.parentName = dir.name
            tiles.append(t)
            addChildTiles(t, level + 1)
        }
    }

    private func drawTreemap(_ area: NSRect) {
        let lh = Theme.lineHeight(Theme.font9)
        let infoH = lh * 2 + 10
        let map = NSRect(x: area.minX, y: area.minY, width: area.width, height: max(40, area.height - infoH)).integral
        if map != mapRect { mapRect = map; tilesDirty = true }
        if tilesDirty { layoutTiles() }
        // Logo -> treemap: the logo fades out while the tiles fade in.
        let alpha: CGFloat = animating ? PieChart.ease(anim) : 1
        if animating { drawBrandLogo(pieRect, alpha: 1 - alpha) }
        if total <= 0 { T.BORDER.setFill(); NSBezierPath(rect: mapRect).fill() }
        for (i, t) in tiles.enumerated() {
            let s = slices[t.slice]
            let hot = i == hoverTile || (t.level == 0 && t.slice == hover && hoverTile < 0)
            let rr = t.rect
            let edge = NSBezierPath(rect: rr.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = 1
            if s.empty && t.level == 0 {
                // Free space: nothing drawn but an outline (a faint fill while hovered), like the gap in the ring.
                if hot { T.BORDER.withAlphaComponent(alpha).setFill(); NSBezierPath(rect: rr).fill() }
                T.BORDER.withAlphaComponent(alpha).setStroke()
                edge.stroke()
            } else {
                let col = hot ? PieChart.blend(t.color, .white, 0.25) : t.color
                col.withAlphaComponent(alpha).setFill()
                NSBezierPath(rect: rr).fill()
                T.SURFACE.withAlphaComponent(alpha).setStroke()
                edge.stroke()
            }
            // Names where they fit: every slice, and level-1 folders that are large enough.
            if alpha < 1 || t.level > 1 { continue }
            if rr.width < 44 || rr.height < lh + 6 { continue }
            if t.level == 1 && (rr.width < 70 || rr.height < lh * 2 + 6) { continue }
            let fg = s.empty ? T.MUTED : PieChart.readable(t.color)
            let tr = NSRect(x: rr.minX + 5, y: rr.minY + 3, width: rr.width - 10, height: lh)
            cuts.draw(t.label, in: tr, font: Theme.font9, color: fg)
            if t.level == 0 && t.dir == nil && rr.height >= lh * 2 + 8 {
                Theme.drawText(Fmt.size(t.size), in: NSRect(x: tr.minX, y: tr.minY + lh, width: tr.width, height: lh), font: Theme.font9, color: fg)
            }
        }
        drawTreemapInfo(NSRect(x: area.minX, y: mapRect.maxY + 6, width: area.width, height: infoH - 6))
    }

    /// Dark text on light tiles, white on dark ones.
    static func readable(_ c: NSColor) -> NSColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        let lum = 0.299 * s.redComponent + 0.587 * s.greenComponent + 0.114 * s.blueComponent
        return lum > 0.6 ? T.BG : T.FG
    }

    /// Below the map: the hovered item (name; size and share), or the folder shown; "Up" on the right.
    private func drawTreemapInfo(_ r: NSRect) {
        var l1 = "", l2 = ""
        if hoverTile >= 0 && hoverTile < tiles.count && tiles[hoverTile].level > 0 {
            let t = tiles[hoverTile]
            let share = String(format: "%.1f %%", 100 * Double(t.size) / Double(max(1, t.parentSize)))
            l1 = t.label
            l2 = Fmt.size(t.size) + "  -  " + share + " of " + (t.parentName.map { PathUtil.name($0) } ?? "parent")
        } else if hover >= 0 && hover < slices.count {
            l1 = slices[hover].label
            l2 = Fmt.size(slices[hover].size) + (slices[hover].detail.isEmpty ? "" : "  -  " + slices[hover].detail)
        } else {
            l1 = centerName ?? "Total"
            l2 = Fmt.size(total)
        }
        upRect = .zero
        var right = r.maxX
        if canGoUp {
            let tw = Theme.textWidth("Up", Theme.font9)
            let h = Theme.lineHeight(Theme.font9) + 8
            upRect = NSRect(x: r.maxX - tw - 30, y: r.minY + ((r.height - h) / 2).rounded(), width: tw + 30, height: h)
            Theme.fillRound(upRect, 7, fill: hoverUp ? T.SECONDARY_HOVER : T.BORDER)
            let a: CGFloat = 10
            // An arrow pointing up: the back arrow turned by 90 degrees.
            Theme.drawArrow(NSRect(x: upRect.minX + 8, y: upRect.midY - a / 2, width: a, height: a), T.FG, dx: 0, dy: -1)
            Theme.drawText("Up", in: NSRect(x: upRect.minX + 20, y: upRect.minY, width: upRect.width - 24, height: upRect.height),
                           font: Theme.font9, color: T.FG, align: .center)
            right = upRect.minX - 8
        }
        let h = Theme.lineHeight(Theme.font9)
        cuts.draw(l1, in: NSRect(x: r.minX, y: r.minY + 2, width: max(0, right - r.minX), height: h), font: Theme.font9, color: T.FG)
        cuts.draw(l2, in: NSRect(x: r.minX, y: r.minY + 2 + h, width: max(0, right - r.minX), height: h), font: Theme.font9, color: T.MUTED)
    }

    // children come after their parents: the deepest tile first
    private func hitTile(_ p: NSPoint) -> Int {
        if logoMode || animating { return -1 }
        var i = tiles.count - 1
        while i >= 0 {
            if tiles[i].rect.contains(p) { return i }
            i -= 1
        }
        return -1
    }

    private func treemapMouseMoved(_ p: NSPoint) {
        let t = hitTile(p)
        let up = canGoUp && upRect.contains(p)
        let slice = t >= 0 ? tiles[t].slice : -1
        let shown = t >= 0 && tiles[t].level > 0 ? t : -1
        if up || (t >= 0 && tiles[t].dir != nil) { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        if slice != hover || shown != hoverTile || up != hoverUp { hover = slice; hoverTile = shown; hoverUp = up; needsDisplay = true }
        if slice != reported { reported = slice; onHover?(slice) }
    }

    private func treemapClick(_ p: NSPoint) {
        if canGoUp && upRect.contains(p) { onCenterClick?(); return }
        let t = hitTile(p)
        guard t >= 0, let d = tiles[t].dir else { return }
        if tiles[t].level == 0 { onClick?(slices[tiles[t].slice]); return }
        let s = ChartSlice(d.name, d.size, tiles[t].color)
        s.dir = d
        onClick?(s)
    }
}
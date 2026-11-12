import AppKit

/// One row in a view's list: a folder (dir), a file (file), a cleanup target (targets: a suggestion or a delete-list
/// entry), a group head (duplicates) or a plain row (file types, changes, "N smaller files" summaries).
final class ItemInfo {
    var isDir = false, isSummary = false, isGroup = false, folderIcon = false
    var dir: DirNode?
    var file: FileEntry?
    var targets: [DeleteTarget]?
    var groupOf: ItemInfo?             // member of a group: shares the group's chart slice
    var name = "", folder = "", category = "", note = ""
    var path: String?
    var ext: String?
    var size: Int64 = 0, files: Int64 = 0, dirs: Int64 = 0, modified: Int64 = 0
    var used: Int64 = 0                // last opened (never earlier than modified); 0 = not shown
    var change: Int64 = Int64.min      // compared with the previous scan; min = unknown
    var chartValue: Int64 = -1         // size used by the chart when it differs from size
    var percent: Double = 0
    var cells: [String] = []
    var color: NSColor?
    var check = -1                     // checkbox: -1 none, 0 unchecked, 1 checked, 2 mixed
    var chevron = -1                   // expand chevron: -1 none, 0 collapsed, 1 expanded
    var suggestion: Suggestion?        // suggestions: the suggestion of the row (head or one of its targets)
    var app: InstalledApp?             // apps: the app of the row (head or one of its leftovers)
    var leftover: AppLeftover?         // apps: the leftover of a member row
    var sys: SysItem?                  // system: the item of a member row
    var sysGroup: SysGroup?            // system: the group of the row (head or member)
    var hideBar = false                // no percentage bar (the bar column's cell stays empty)
    var icon: NSImage?                 // drawn instead of the folder/file icon (apps: the app's own icon)
    /// Row of a tree-list (Contents): indented by depth levels; keeps the chevron space even when it cannot expand.
    var treeRow = false
    var depth = 0
    var expandable = false, expanded = false
    var scanRoot: ScanRoot?            // This PC: the drive or scanned folder of the row
    var noSlice = false                // left out of the chart (This PC: scanned folders and saved scans)
    var chartSize: Int64 { chartValue >= 0 ? chartValue : size }
    var canDelete: Bool { !isSummary && !isGroup && scanRoot == nil && (isDir || file != nil || targets != nil) }
    var fullPath: String? { isDir ? dir?.fullPath : (file?.fullPath ?? path) }
    var tip: String?                   // tooltip set by the view (file types, summaries, group heads, removed folders)

    /// Shown when hovering the row: the full name on the first line, the full path on the second (a folder's own path,
    /// a file's folder; a suggestion the path of each of its locations, at most maxTipPaths; the Trash "Trash").
    static let maxTipPaths = 8
    var toolTip: String {
        if let t = tip { return t }
        if let s = suggestion, groupOf == nil {
            if s.targets.contains(where: { $0.emptyTrash }) { return s.name + "\n" + "Trash" }
            if s.targets.isEmpty { return s.name + "\n" + s.location }
            let paths = s.targets.map { PathUtil.trim($0.path) }
            let shown = paths.prefix(ItemInfo.maxTipPaths).joined(separator: "\n")
            let more = paths.count - ItemInfo.maxTipPaths
            return s.name + "\n" + shown + (more > 0 ? "\n... and \(Fmt.count(more)) more" : "")
        }
        if let ts = targets, ts.count == 1 {
            let t = ts[0]
            if t.emptyTrash { return t.label + "\n" + "Trash" }
            return ItemInfo.nameOf(t.path) + "\n" + (t.isDir ? PathUtil.trim(t.path) : PathUtil.parent(t.path))
        }
        if let f = file { return f.name + "\n" + f.dir.fullPath }
        if let d = dir { let p = d.fullPath; return ItemInfo.nameOf(p) + "\n" + p }
        if let p = path { return ItemInfo.nameOf(p) + "\n" + (isDir || folderIcon ? PathUtil.trim(p) : PathUtil.parent(p)) }
        return folder.isEmpty ? name : name + "\n" + folder
    }

    static func nameOf(_ p: String) -> String { let n = PathUtil.name(p); return n.isEmpty ? p : n }

    static func forDir(_ d: DirNode, _ parentSize: Int64) -> ItemInfo {
        let it = ItemInfo()
        it.isDir = true; it.dir = d; it.name = d.displayName; it.size = d.size; it.files = d.files; it.dirs = d.dirs; it.modified = d.modified
        it.percent = parentSize > 0 ? 100 * Double(d.size) / Double(parentSize) : 0
        return it
    }

    static func forFile(_ f: FileEntry, _ parentSize: Int64) -> ItemInfo {
        let it = ItemInfo()
        it.file = f; it.name = f.dataless ? f.name + "  (not downloaded)" : f.name; it.size = f.size; it.files = 1; it.modified = f.modified
        it.used = f.lastUse
        it.percent = parentSize > 0 ? 100 * Double(f.size) / Double(parentSize) : 0
        return it
    }

    /// Sort order of the lists (same keys as the Windows app).
    static func compare(_ a: ItemInfo, _ b: ItemInfo, _ key: String, _ ascending: Bool) -> Bool {
        if a.isSummary != b.isSummary { return b.isSummary }
        var r: ComparisonResult
        func cmp<V: Comparable>(_ x: V, _ y: V) -> ComparisonResult { x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending) }
        switch key {
        case "name": r = a.name.localizedStandardCompare(b.name)
        case "folder": r = a.folder.localizedStandardCompare(b.folder)
        case "files": r = cmp(a.files, b.files)
        case "dirs": r = cmp(a.dirs, b.dirs)
        case "mod": r = cmp(a.modified, b.modified)
        case "used": r = cmp(a.used, b.used)
        case "change": r = cmp(a.change, b.change)
        case "cat": r = a.category.localizedStandardCompare(b.category)
        case "note": r = a.note.localizedStandardCompare(b.note)
        case "free": r = cmp(a.chartSize, b.chartSize)
        case "pct": r = cmp(a.percent, b.percent)
        default: r = cmp(a.size, b.size)
        }
        if r == .orderedSame && key != "size" { r = cmp(b.size, a.size) }
        return ascending ? r == .orderedAscending : r == .orderedDescending
    }
}

struct Column {
    let key: String, title: String, width: CGFloat, right: Bool
    init(_ key: String, _ title: String, _ width: CGFloat, _ right: Bool = false) { self.key = key; self.title = title; self.width = width; self.right = right }
}

/// A full-width strip a page shows above its caption (banner, path bar) or between its bar and its list (timeline).
protocol PageStrip: NSView {
    var stripHeight: CGFloat { get }
}

/// Muted caption text above a list: one line, or two when it needs them (then the last line ends in an ellipsis).
final class CaptionView: NSView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true; updateTip() } } }
    override var isFlipped: Bool { true }
    static let lineH = ceil(Theme.font9.ascender - Theme.font9.descender + Theme.font9.leading)

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateTip() }

    /// The full text as the tooltip when it does not fit (the last line then ends in "...").
    private func updateTip() {
        guard bounds.width > 0, !text.isEmpty else { toolTip = nil; return }
        let need = (text as NSString).boundingRect(with: NSSize(width: bounds.width, height: 10000), options: [.usesLineFragmentOrigin], attributes: attributes).height
        toolTip = need > bounds.height + 1 ? text : nil
    }

    private var attributes: [NSAttributedString.Key: Any] {
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byWordWrapping
        return [.font: Theme.font9, .foregroundColor: T.MUTED, .paragraphStyle: ps]
    }

    func lines(width: CGFloat) -> CGFloat {
        let h = (text as NSString).boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin], attributes: attributes).height
        return h > CaptionView.lineH * 1.5 ? 2 : 1
    }

    override func draw(_ dirtyRect: NSRect) {
        (text as NSString).draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }
}

/// Large bold line above a page's caption (the Suggestions amount), then a smaller MUTED remark (sub) on the same
/// baseline; an action button at the right end, vertically centred.
final class HeadlineView: NSView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true; updateTip() } } }
    var sub = "" { didSet { if sub != oldValue { needsDisplay = true } } }
    var color: NSColor = T.FG
    var action: NSView? {
        didSet { oldValue?.removeFromSuperview(); if let a = action { addSubview(a) }; needsLayout = true }
    }
    override var isFlipped: Bool { true }
    static let font = Theme.font15Bold
    static let height = Theme.lineHeight(HeadlineView.font)
    /// Height of the row: the text, or the action button with room around it.
    var rowHeight: CGFloat { max(HeadlineView.height, (action?.intrinsicContentSize.height ?? 0) + 8) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateTip(); needsLayout = true }
    override func layout() {
        super.layout()
        if let a = action {
            let s = a.intrinsicContentSize
            a.frame = NSRect(x: bounds.width - s.width, y: ((bounds.height - s.height) / 2).rounded(), width: s.width, height: s.height)
        }
    }
    private var textRight: CGFloat { action.map { $0.frame.minX - 12 } ?? bounds.width }
    private func updateTip() { toolTip = Theme.isCut(text, HeadlineView.font, textRight) ? text : nil }
    override func draw(_ dirtyRect: NSRect) {
        let ty = ((bounds.height - HeadlineView.height) / 2).rounded()
        let w = min(Theme.textWidth(text, HeadlineView.font), textRight)
        Theme.drawText(text, in: NSRect(x: 0, y: ty, width: w, height: HeadlineView.height), font: HeadlineView.font, color: color)
        if sub.isEmpty { return }
        let f = Theme.font11
        let sx = w + 8
        // The same baseline as the large text.
        let sy = ty + HeadlineView.font.ascender - f.ascender
        if sx < textRight { Theme.drawText(sub, in: NSRect(x: sx, y: sy, width: textRight - sx, height: Theme.lineHeight(f)), font: f, color: T.MUTED) }
    }
}

/// Flipped view that lays out its subviews through a closure.
final class LayoutView: FlatView {
    var onLayout: ((NSRect) -> Void)?
    override func layout() { super.layout(); onLayout?(bounds) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
}

/// Table with hover tracking (reported to the chart) and a set of rows linked from the chart.
final class HoverTable: NSTableView {
    var hotRow = -1
    var linkedRows = Set<Int>()
    var onHot: ((Int) -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var emptyText: String? { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func setHot(_ r: Int) {
        if r == hotRow { return }
        let old = hotRow
        hotRow = r
        for i in [old, r] where i >= 0 && i < numberOfRows { rowView(atRow: i, makeIfNecessary: false)?.needsDisplay = true }
        onHot?(r)
    }

    override func mouseMoved(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil))
        setHot(r)
        HoverTip.shared.track(self, key: r, text: r >= 0 ? tipFor?(r) : nil, event: event)
    }
    override func mouseExited(with event: NSEvent) { setHot(-1); HoverTip.shared.reset(owner: self) }
    override func scrollWheel(with event: NSEvent) { HoverTip.shared.reset(owner: self); super.scrollWheel(with: event) }

    /// The hover tip of a row.
    var tipFor: ((Int) -> String?)?

    func setHighlight(_ rows: [Int]) {
        let old = linkedRows
        linkedRows = Set(rows)
        for i in old.union(linkedRows) where i < numberOfRows { rowView(atRow: i, makeIfNecessary: false)?.needsDisplay = true }
        if let first = rows.min(), !rows.contains(where: { visibleRect.intersects(rect(ofRow: $0)) }) { scrollRowToVisible(first) }
    }

    func resetHover() { hotRow = -1; linkedRows = []; HoverTip.shared.reset(owner: self) }

    override func keyDown(with event: NSEvent) { HoverTip.shared.hide(); if onKey?(event) != true { super.keyDown(with: event) } }

    /// Clicks on a row that the page handles itself (checkboxes, chevrons): true = consumed, the selection stays.
    var onClickAt: ((Int, NSPoint) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        HoverTip.shared.hide()
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p)
        if r >= 0, let f = onClickAt, f(r, p) { return }
        // A plain click on the only selected row deselects it (a double-click still opens it).
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.clickCount == 1, mods.isEmpty, r >= 0, selectedRowIndexes.count == 1, selectedRowIndexes.contains(r) {
            window?.makeFirstResponder(self)
            deselectAll(nil)
            return
        }
        super.mouseDown(with: event)
    }

    /// Redraws the visible cells (their items changed in place).
    func redrawCells() {
        enumerateAvailableRowViews { rv, _ in
            rv.needsDisplay = true
            for v in rv.subviews { v.needsDisplay = true }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        HoverTip.shared.hide()
        let r = row(at: convert(event.locationInWindow, from: nil))
        if r >= 0 && !selectedRowIndexes.contains(r) { selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false) }
        window?.makeFirstResponder(self)
        return super.menu(for: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if numberOfRows == 0, let t = emptyText {
            let ps = NSMutableParagraphStyle(); ps.alignment = .center
            let vis = enclosingScrollView?.documentVisibleRect ?? visibleRect
            (t as NSString).draw(in: NSRect(x: vis.minX + 16, y: 30, width: vis.width - 32, height: 80),
                                 withAttributes: [.font: Theme.font, .foregroundColor: T.MUTED, .paragraphStyle: ps])
        }
    }
}

final class ListRowView: NSTableRowView {
    weak var table: HoverTable?
    var index = -1
    override var isFlipped: Bool { true }
    override func drawBackground(in dirtyRect: NSRect) {
        T.SURFACE.setFill(); bounds.fill()
        guard let t = table else { return }
        let r = bounds.insetBy(dx: 2, dy: 1)
        if !isSelected {
            if t.linkedRows.contains(index) { Theme.fillRound(r, 6, fill: T.BORDER, outline: T.ACCENT) }
            else if t.hotRow == index { Theme.fillRound(r, 6, fill: T.BORDER) }
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        // Selected rows are always drawn in full (also while another view has the focus): a click away deselects them.
        Theme.fillRound(bounds.insetBy(dx: 2, dy: 1), 6, fill: T.ACCENT, outline: T.ACCENT)
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
}

/// Draws one cell of a view's list: the name column has the icon (indented for group members, bold for group heads),
/// the bar column a percentage pill, the others plain text.
final class ListCell: NSTableCellView {
    var item: ItemInfo?
    var index = 0
    weak var page: Page?
    override var isFlipped: Bool { true }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let it = item, let pg = page, index < pg.columns.count else { return }
        let strong = backgroundStyle == .emphasized
        let fore = strong ? T.BG : (it.color ?? (it.isSummary ? T.MUTED : T.FG))
        let text = index < it.cells.count ? it.cells[index] : ""
        let b = bounds
        if index == 0 {
            if it.treeRow && it.expandable {
                Theme.drawChevron(NSRect(x: ListCell.treeChevronX(it) + 1, y: ((b.height - 12) / 2).rounded(), width: 12, height: 12),
                                  strong ? T.BG : T.MUTED, down: it.expanded)
            }
            if it.chevron >= 0 {
                let cx = ListCell.chevronX + 7, cy = (b.height / 2).rounded()
                let tri = NSBezierPath()
                if it.chevron == 1 {
                    tri.move(to: NSPoint(x: cx - 4.5, y: cy - 2.5)); tri.line(to: NSPoint(x: cx + 4.5, y: cy - 2.5)); tri.line(to: NSPoint(x: cx, y: cy + 3))
                } else {
                    tri.move(to: NSPoint(x: cx - 2, y: cy - 4.5)); tri.line(to: NSPoint(x: cx + 3.5, y: cy)); tri.line(to: NSPoint(x: cx - 2, y: cy + 4.5))
                }
                tri.close()
                (strong ? T.BG : T.MUTED).setFill()
                tri.fill()
            }
            if it.check >= 0 {
                ListCell.drawCheck(NSRect(x: ListCell.checkX(it), y: ((b.height - ListCell.checkSize) / 2).rounded(), width: ListCell.checkSize, height: ListCell.checkSize), it.check, strong: strong)
            }
            if !it.isSummary && !it.isGroup {
                let ir = NSRect(x: ListCell.iconX(it), y: (b.height - 16) / 2, width: 16, height: 16)
                if let img = it.icon { img.draw(in: ir, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue]) }
                else if it.isDir || it.folderIcon { Theme.drawFolder(ir, strong ? T.BG : T.MUTED) } else { Theme.drawFile(ir, strong ? T.BG : T.MUTED) }
            }
            let x = ListCell.nameX(it)
            Theme.drawText(text, in: NSRect(x: x, y: 0, width: max(0, b.width - x - 4), height: b.height), font: ListCell.font(it, 0), color: fore)
        } else if index == pg.barColumn {
            let textW = ListCell.pctW
            let bh: CGFloat = 8
            let bar = NSRect(x: 6, y: (b.height - bh) / 2, width: max(0, b.width - textW - 12), height: bh)
            if bar.width > 8 && !it.isSummary && !it.hideBar {
                Theme.fillRound(bar, bh / 2, fill: strong ? T.BG : T.BORDER)
                let w = (bar.width * CGFloat(min(100, max(0, it.percent))) / 100).rounded()
                if w > 0 { Theme.fillRound(NSRect(x: bar.minX, y: bar.minY, width: max(w, bh), height: bh), bh / 2, fill: strong ? T.FG : T.ACCENT) }
            }
            Theme.drawText(text, in: NSRect(x: b.width - textW - 6, y: 0, width: textW, height: b.height), color: fore, align: .right)
        } else {
            Theme.drawText(text, in: b.insetBy(dx: 6, dy: 0), color: fore, align: pg.columns[index].right ? .right : .left)
        }
    }

    static let chevronX: CGFloat = 4
    static let pctW = Theme.textWidth("100.0 %", Theme.font)
    static let indentStep: CGFloat = 18

    /// Indentation of a tree-list row (one step per level).
    static func indent(_ it: ItemInfo) -> CGFloat { it.treeRow ? CGFloat(it.depth) * indentStep : 0 }

    /// x of a tree-list row's chevron: Contents at the left edge; a tree inside a group (suggestions) one step in, under
    /// its head's checkbox.
    static func treeChevronX(_ it: ItemInfo) -> CGFloat { indent(it) + chevronX + (it.groupOf != nil ? indentStep : 0) }

    /// Where a click opens or closes a tree-list row, in the name cell's coordinates (empty when it cannot expand).
    static func chevronHit(_ it: ItemInfo, height: CGFloat) -> NSRect {
        guard it.treeRow && it.expandable else { return .zero }
        return NSRect(x: treeChevronX(it) - 3, y: 0, width: 20, height: height)
    }

    /// x of the icon in the name column: after the checkbox or the chevron, members of a group indented, tree-list rows
    /// indented by their depth (with room for the chevron whether or not they can expand).
    static func iconX(_ it: ItemInfo) -> CGFloat {
        if it.treeRow && it.groupOf != nil { return ListCell.checkX(it) + (it.check >= 0 ? checkSize + 6 : 0) }
        if it.treeRow { return ListCell.checkX(it) + indent(it) }
        if it.check >= 0 { return ListCell.checkX(it) + checkSize + 6 }
        if it.chevron >= 0 { return ListCell.checkX(it) }                    // after the chevron
        if let g = it.groupOf, g.chevron >= 0 { return 42 }                  // under an opened head with a chevron
        return it.groupOf != nil ? 6 + 18 : 6
    }

    /// x of the text in the name column (after the icon; group heads and summaries have none).
    static func nameX(_ it: ItemInfo) -> CGFloat { iconX(it) + (!it.isSummary && !it.isGroup ? 22 : 0) }

    static func font(_ it: ItemInfo, _ column: Int) -> NSFont { column == 0 && it.isGroup ? Theme.fontBold : Theme.font }

    /// Width the text of column `column` gets in a cell `width` wide (the same room draw() gives it).
    static func textRoom(_ it: ItemInfo, column: Int, barColumn: Int, width: CGFloat) -> CGFloat {
        if column == 0 { return max(0, width - nameX(it) - 4) }
        if column == barColumn { return min(pctW, max(0, width - 6)) }
        return max(0, width - 12)
    }

    /// True when the text does not fit its room and is drawn cut off with an ellipsis.
    static func isCut(_ text: String, font: NSFont, room: CGFloat) -> Bool {
        !text.isEmpty && (text as NSString).size(withAttributes: [.font: font]).width > room + 0.01
    }
    /// x of the checkbox in the name column: a head next to its chevron, its members indented by 18 px (a tree inside a
    /// group also by its depth, after its chevron).
    static func checkX(_ it: ItemInfo) -> CGFloat { it.groupOf != nil ? 42 + (it.treeRow ? indent(it) : 0) : 24 }

    /// Side of a checkbox (as on Windows).
    static let checkSize: CGFloat = 16

    /// 16 px rounded checkbox: unchecked = muted outline, checked = accent with a check mark, mixed = accent with a dash.
    /// On a selected (accent) row it is drawn in bg / fg so it stays visible.
    static func drawCheck(_ r: NSRect, _ state: Int, strong: Bool) {
        if state == 0 {
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
            p.lineWidth = 1.5
            (strong ? T.BG : T.MUTED).setStroke()
            p.stroke()
            return
        }
        (strong ? T.BG : T.ACCENT).setFill()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        let m = NSBezierPath()
        if state == 1 {
            m.move(to: NSPoint(x: r.minX + 4, y: r.midY))
            m.line(to: NSPoint(x: r.minX + 7, y: r.maxY - 4))
            m.line(to: NSPoint(x: r.maxX - 3.5, y: r.minY + 4))
        } else {
            m.move(to: NSPoint(x: r.minX + 4, y: r.midY))
            m.line(to: NSPoint(x: r.maxX - 4, y: r.midY))
        }
        m.lineWidth = 2
        m.lineCapStyle = .round
        m.lineJoinStyle = .round
        (strong ? T.FG : T.BG).setStroke()
        m.stroke()
    }
}

/// A view shown in a tab above the list and the chart: a caption line, an optional bar of filters and actions, and a
/// list. The chart always shows the list of the open page.
final class Page: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let title: String
    let root = LayoutView()
    let headline = HeadlineView()
    let caption = CaptionView()
    let bar: ActionBar?
    let table = HoverTable()
    let scroll = NSScrollView()
    let columns: [Column]
    let barColumn: Int
    var items: [ItemInfo] = []
    var sortKey = "size", ascending = false, sortable = true
    /// Members of a group keep the order they were added in (duplicates: the newest copy, the one kept, first).
    var keepMemberOrder = false
    /// The user picked a sort column: refills keep that order instead of the fill's own (largest first).
    var userSorted = false
    var stale = true, followsFolder = false
    var fill: () -> Void = {}
    var chartTitle = "", chartSub = "", chartScope = "of the list"
    var chartTotal: Int64 = 0
    var empty = ""
    var onSorted: ((Page) -> Void)?
    var onSelection: ((Page) -> Void)?
    var pinFirst: ((ItemInfo) -> Bool)?    // heads listed before the others whatever the sort order
    /// A tree-list builds its rows level by level: a click on a column header calls this instead of sorting the rows.
    var onResort: (() -> Void)?
    /// Strips above the caption (top to bottom) and one between the bar and the list.
    private(set) var above: [PageStrip] = []
    private(set) var strip: PageStrip?
    /// A well-known folder or file: its explanation is added to the row's hover tip.
    var knownFor: ((ItemInfo) -> KnownItem?)?
    init(_ title: String, _ columns: [Column], barColumn: Int, bar: ActionBar?) {
        self.title = title; self.columns = columns; self.barColumn = barColumn; self.bar = bar
        super.init()
        root.fill = T.SURFACE
        if let b = bar {
            root.addSubview(b)
            b.onHeightChange = { [weak self] in self?.root.needsLayout = true }
        }
        for (i, c) in columns.enumerated() {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
            let h = DarkHeaderCell(textCell: c.title)
            h.right = c.right
            h.active = i == 1
            col.headerCell = h
            col.width = c.width
            col.minWidth = 40
            table.addTableColumn(col)
        }
        table.headerView = DarkHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
        table.cornerView = nil
        table.backgroundColor = T.SURFACE
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 0, height: 0)
        if #available(macOS 11.0, *) { table.style = .plain }
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.drawsBackground = true
        scroll.backgroundColor = T.SURFACE
        scroll.borderType = .noBorder
        root.addSubview(scroll)
        root.addSubview(caption)
        headline.isHidden = true
        root.addSubview(headline)
        table.tipFor = { [weak self] r in self?.hoverText(r) }
        root.onLayout = { [weak self] r in self?.layoutPage(r) }
        root.isHidden = true
    }

    /// Adds a strip above the caption (below the ones added before).
    func addAbove(_ v: PageStrip) {
        above.append(v)
        root.addSubview(v)
        root.needsLayout = true
    }

    /// Sets the strip between the bar and the list.
    func setStrip(_ v: PageStrip) {
        strip?.removeFromSuperview()
        strip = v
        root.addSubview(v)
        root.needsLayout = true
    }

    private func layoutPage(_ r: NSRect) {
        let w = r.width
        let lineH = CaptionView.lineH
        var top: CGFloat = 0
        for v in above where !v.isHidden {
            let h = v.stripHeight
            v.frame = NSRect(x: 0, y: top, width: w, height: h)
            top += h
        }
        headline.isHidden = headline.text.isEmpty
        if !headline.isHidden {
            let hh = headline.rowHeight
            headline.frame = NSRect(x: 4, y: top + 4, width: max(10, w - 8), height: hh)
            top += 4 + hh - 3
        }
        let lines = caption.lines(width: max(10, w - 8))
        let capH = lineH * lines + 10
        caption.frame = NSRect(x: 4, y: top + 5, width: max(10, w - 8), height: lineH * lines + 3)
        var y = top + capH
        if let b = bar {
            let h = b.arrange(width: w)
            b.frame = NSRect(x: 0, y: y, width: w, height: h)
            y += h
        }
        if let s = strip, !s.isHidden {
            let h = s.stripHeight
            s.frame = NSRect(x: 0, y: y + 2, width: w, height: h)
            y += h + 2
        }
        y += 4
        scroll.frame = NSRect(x: 0, y: y, width: w, height: max(0, r.height - y))
    }

    func setCaption(_ s: String) {
        if caption.text == s { return }
        caption.text = s
        root.needsLayout = true
    }

    func setHeadline(_ s: String, sub: String = "") {
        if headline.text == s && headline.sub == sub { return }
        headline.text = s
        headline.sub = sub
        root.needsLayout = true
    }

    /// Replaces the rows (sorted by the current column unless the page keeps its own order and the user has not picked
    /// a sort column; a tree-list sorts its rows level by level itself).
    func setRows(_ rows: [ItemInfo], _ emptyText: String, keepOrder: Bool = false) {
        var rows = rows
        if let f = rowFilter { rows = Page.without(rows, f) }
        let arrange = sortable && onResort == nil && (!keepOrder || userSorted)
        items = arrange ? sorted(rows) : rows
        table.resetHover()
        table.emptyText = rows.isEmpty ? emptyText : nil
        table.reloadData()
    }

    /// While a delete runs: rows it has deleted already, left out whenever the page is filled.
    var rowFilter: ((ItemInfo) -> Bool)?

    /// The rows without those for which gone() is true. A group head (a row others belong to) stays while any of its
    /// rows stays, and goes with the last of them.
    static func without(_ rows: [ItemInfo], _ gone: (ItemInfo) -> Bool) -> [ItemInfo] {
        var drop = Set<ObjectIdentifier>()
        for it in rows where gone(it) { drop.insert(ObjectIdentifier(it)) }
        if drop.isEmpty { return rows }
        let heads = Set(rows.compactMap { $0.groupOf.map { ObjectIdentifier($0) } })
        let keptHeads = Set(rows.filter { !drop.contains(ObjectIdentifier($0)) }.compactMap { $0.groupOf.map { ObjectIdentifier($0) } })
        for h in heads { if keptHeads.contains(h) { drop.remove(h) } else { drop.insert(h) } }
        return rows.filter { !drop.contains(ObjectIdentifier($0)) }
    }

    /// Takes rows out of the list in place (order, selection and scroll position stay); returns how many went.
    @discardableResult
    func removeRows(_ gone: (ItemInfo) -> Bool) -> Int {
        let kept = Page.without(items, gone)
        let n = items.count - kept.count
        if n == 0 { return 0 }
        let sel = Set(selectedItems.map { ObjectIdentifier($0) })
        items = kept
        table.resetHover()
        if items.isEmpty { table.emptyText = empty.isEmpty ? " " : empty }
        table.reloadData()
        var keep = IndexSet()
        for (i, it) in items.enumerated() where sel.contains(ObjectIdentifier(it)) { keep.insert(i) }
        if keep != table.selectedRowIndexes { table.selectRowIndexes(keep, byExtendingSelection: false) }
        return n
    }

    /// Rows in the current sort order (stable: ties keep the fill order). Members of a group (rows with groupOf) stay
    /// right under their head, sorted among themselves by the same column (or in their own order with
    /// keepMemberOrder); a member whose head is not in the list is sorted with the heads.
    func sorted(_ rows: [ItemInfo]) -> [ItemInfo] {
        let key = sortKey, asc = ascending
        let pin = pinFirst
        func ordered(_ list: [ItemInfo]) -> [ItemInfo] {
            let indexed = Array(list.enumerated())
            let out = indexed.sorted { x, y in
                let a = x.element, b = y.element
                if let p = pin { let pa = p(a), pb = p(b); if pa != pb { return pa } }
                if ItemInfo.compare(a, b, key, asc) { return true }
                if ItemInfo.compare(b, a, key, asc) { return false }
                return x.offset < y.offset
            }
            return out.map { $0.element }
        }
        if !rows.contains(where: { $0.groupOf != nil }) { return ordered(rows) }
        var heads: [ItemInfo] = []
        var members: [ObjectIdentifier: [ItemInfo]] = [:]
        for r in rows where r.groupOf == nil { members[ObjectIdentifier(r)] = [] }
        for r in rows {
            if let g = r.groupOf, members[ObjectIdentifier(g)] != nil { members[ObjectIdentifier(g)]?.append(r) } else { heads.append(r) }
        }
        let keepMembers = keepMemberOrder
        var result: [ItemInfo] = []
        result.reserveCapacity(rows.count)
        for h in ordered(heads) {
            result.append(h)
            let m = members[ObjectIdentifier(h)] ?? []
            result.append(contentsOf: keepMembers ? m : ordered(m))
        }
        return result
    }

    /// Text columns start A to Z, numbers largest first.
    static func startsAscending(_ key: String) -> Bool { key == "name" || key == "folder" || key == "cat" || key == "note" }

    /// The same row after a refill made new rows (the same folder, file, drive or object).
    static func sameRow(_ a: ItemInfo, _ b: ItemInfo) -> Bool {
        if a === b { return true }
        if let ra = a.scanRoot, let rb = b.scanRoot { return ra === rb }
        if let fa = a.file, let fb = b.file { return fa === fb }
        if a.file == nil && b.file == nil, a.isDir && b.isDir, let da = a.dir, let db = b.dir { return da === db }
        return false
    }

    /// The row shown at the top of the list.
    var topItem: ItemInfo? {
        let r = table.rows(in: table.visibleRect)
        return r.location >= 0 && r.location < items.count && r.length > 0 ? items[r.location] : nil
    }

    /// Scrolls so that row i is the top row (as far as the list can scroll).
    func scrollToTop(_ i: Int) {
        guard i >= 0, i < items.count else { return }
        let shown = max(1, table.rows(in: table.visibleRect).length)
        table.scrollRowToVisible(min(items.count - 1, i + shown - 1))
        table.scrollRowToVisible(i)
    }

    /// Sorts the list by column i, as a click on its header does: the same column again reverses the order. The
    /// order then stays for every refill; the top row and the selected rows stay.
    func sortBy(_ i: Int) {
        guard sortable, i >= 0, i < columns.count else { return }
        let key = columns[i].key
        if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = Page.startsAscending(key) }
        userSorted = true
        let top = topItem
        if let refill = onResort {
            refill()
        } else {
            let sel = Set(selectedItems.map { ObjectIdentifier($0) })
            items = sorted(items)
            table.resetHover()
            table.reloadData()
            var keep = IndexSet()
            for (n, it) in items.enumerated() where sel.contains(ObjectIdentifier(it)) { keep.insert(n) }
            if keep != table.selectedRowIndexes { table.selectRowIndexes(keep, byExtendingSelection: false) }
        }
        if let t = top, let n = items.firstIndex(where: { Page.sameRow($0, t) }) { scrollToTop(n) }
        let id = "c\(i)"
        for c in table.tableColumns {
            let on = c.identifier.rawValue == id
            (c.headerCell as? DarkHeaderCell)?.active = on
            let base = c.headerCell.stringValue.replacingOccurrences(of: "  ▲", with: "").replacingOccurrences(of: "  ▼", with: "")
            c.headerCell.stringValue = on ? base + (ascending ? "  ▲" : "  ▼") : base
        }
        table.headerView?.needsDisplay = true
        onSorted?(self)
    }

    var selectedItems: [ItemInfo] { table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0] : nil } }

    /// The cells of row r cut off with an ellipsis at the current column widths, in the order the columns are shown:
    /// (column title, full text).
    func cutCells(_ r: Int) -> [(title: String, text: String)] {
        guard r >= 0, r < items.count else { return [] }
        let it = items[r]
        var out: [(title: String, text: String)] = []
        for col in table.tableColumns {
            guard let i = Int(col.identifier.rawValue.dropFirst()), i < columns.count, i < it.cells.count else { continue }
            let room = ListCell.textRoom(it, column: i, barColumn: barColumn, width: col.width)
            if ListCell.isCut(it.cells[i], font: ListCell.font(it, i), room: room) { out.append((columns[i].title, it.cells[i])) }
        }
        return out
    }

    /// The hover tip of row r: the full name and where it is, then a blank line and "Column: full text" for every
    /// other cell cut off at the current column widths (unless the text is already shown in full above).
    func hoverText(_ r: Int) -> String? {
        guard r >= 0, r < items.count else { return nil }
        let head = items[r].toolTip
        var lines = head.isEmpty ? [] : head.components(separatedBy: "\n")
        // A well-known folder or file: what it is, whether it can go, and what manages it.
        var knownShort: String?
        if let k = knownFor?(items[r]) {
            lines.append("")
            lines.append(contentsOf: k.long.components(separatedBy: "\n"))
            knownShort = k.short
        }
        var extra: [String] = []
        for c in cutCells(r) where c.text != knownShort && !lines.contains(where: { $0.contains(c.text) }) {
            let line = c.title.isEmpty ? c.text : c.title + ": " + c.text
            if !extra.contains(line) { extra.append(line) }
        }
        let text = lines.joined(separator: "\n")
        if extra.isEmpty { return lines.isEmpty ? nil : text }
        return lines.isEmpty ? extra.joined(separator: "\n") : text + "\n\n" + extra.joined(separator: "\n")
    }

    func select(_ rows: IndexSet) { table.selectRowIndexes(rows, byExtendingSelection: false) }

    /// Renames column i (keeping its sort arrow), e.g. "% of parent" / "% used" in Contents.
    func setColumnTitle(_ i: Int, _ title: String) {
        guard let col = table.tableColumns.first(where: { $0.identifier.rawValue == "c\(i)" }) else { return }
        let cur = col.headerCell.stringValue
        let arrow = cur.hasSuffix("  ▲") ? "  ▲" : (cur.hasSuffix("  ▼") ? "  ▼" : "")
        if cur == title + arrow { return }
        col.headerCell.stringValue = title + arrow
        table.headerView?.needsDisplay = true
    }

    // MARK: data source

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = ListRowView()
        v.table = table
        v.index = row
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < items.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell-" + col.identifier.rawValue)
        let c = (tableView.makeView(withIdentifier: id, owner: nil) as? ListCell) ?? { let n = ListCell(); n.identifier = id; return n }()
        c.index = Int(col.identifier.rawValue.dropFirst()) ?? 0
        c.page = self
        c.item = items[row]
        c.needsDisplay = true
        return c
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let i = Int(tableColumn.identifier.rawValue.dropFirst()), i < columns.count else { return }
        sortBy(i)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { onSelection?(self) }
}

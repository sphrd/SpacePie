import AppKit

/// Folder sizes of an earlier scan (folders only, no file names), kept to show what changed since.
final class PrevNode {
    var name = ""
    var bytes: Int64 = 0, alloc: Int64 = 0, files: Int64 = 0
    var children: [String: PrevNode]?
    var size: Int64 { DirNode.onDisk ? alloc : bytes }
    func child(_ n: String) -> PrevNode? { children?[n] }
}

/// Saves a compact copy of every full scan (folder names and sizes, zlib-compressed binary) in
/// ~/Library/Application Support/SpacePie/history, one file per scanned drive or folder, and loads the previous
/// one for comparison. Nothing leaves the computer.
enum History {
    static let magic: UInt32 = 0x31415344   // "DSA1"

    static var folderOverride: String?          // self-test: its history stays next to its scratch folder

    static var folder: String {
        if let f = folderOverride { return f }
        return AppData.path("history")
    }

    static func file(for rootPath: String) -> String {
        var s = ""
        for ch in PathUtil.trim(rootPath).lowercased() { s.append(ch.isLetter || ch.isNumber ? ch : "_") }
        return folder + "/" + s + ".dsa"
    }

    /// Pre-order, children in list order: name, bytes, size on disk, files, number of children. Call on the main thread.
    /// With minFolder > 0 only folders of at least that size are kept (an archived copy for comparisons).
    static func serialize(_ rootPath: String, _ root: DirNode, minFolder: Int64 = 0) -> Data {
        var w = BinWriter()
        w.u32(magic)
        w.f64(Date().timeIntervalSince1970)
        w.str(rootPath)
        var stack: [DirNode] = [root]
        while let d = stack.popLast() {
            let kids = minFolder > 0 ? d.children.filter { max($0.bytes, $0.alloc) >= minFolder } : d.children
            w.str(d.name); w.i64(d.bytes); w.i64(d.alloc); w.i64(d.files); w.u32(UInt32(kids.count))
            var i = kids.count - 1
            while i >= 0 { stack.append(kids[i]); i -= 1 }
        }
        return w.data
    }

    static func save(_ rootPath: String, _ data: Data) throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let packed = try (data as NSData).compressed(using: .zlib) as Data
        try packed.write(to: URL(fileURLWithPath: file(for: rootPath)), options: .atomic)
        // Only the last scan of each drive or folder is kept, and only for the 10 most recently scanned ones.
        let dir = URL(fileURLWithPath: folder)
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let dated = files.filter { $0.pathExtension == "dsa" }.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for (u, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(10) { try? FileManager.default.removeItem(at: u) }
        }
    }

    static func load(_ rootPath: String) -> (PrevNode, Date)? { loadFile(file(for: rootPath)) }

    /// Reads a saved folder tree (the last full scan, or an archived one); nil if missing or unreadable.
    static func loadFile(_ path: String) -> (PrevNode, Date)? {
        guard let packed = FileManager.default.contents(atPath: path),
              let raw = try? (packed as NSData).decompressed(using: .zlib) as Data else { return nil }
        var r = BinReader([UInt8](raw))
        guard r.u32() == magic else { return nil }
        let when = Date(timeIntervalSince1970: r.f64())
        _ = r.str()
        // Iterative: very deep trees would overflow the stack.
        let root = PrevNode()
        var stack: [(PrevNode, Int)] = [(root, fill(&r, root))]
        while let top = stack.popLast() {
            if r.failed { return nil }
            if top.1 == 0 { continue }
            stack.append((top.0, top.1 - 1))
            let c = PrevNode()
            let cc = fill(&r, c)
            if top.0.children == nil { top.0.children = [:] }
            top.0.children![c.name] = c
            stack.append((c, cc))
        }
        return r.failed ? nil : (root, when)
    }

    private static func fill(_ r: inout BinReader, _ n: PrevNode) -> Int {
        n.name = r.str(); n.bytes = r.i64(); n.alloc = r.i64(); n.files = r.i64()
        return Int(r.u32())
    }

    // MARK: timeline and archived scans

    static let maxPoints = 1000
    /// Archived scans per drive or folder: at most one per day, the last 12 days with a scan.
    static let maxArchived = 12
    /// Archived scans keep only folders of at least this size (smaller ones never make the Changes list anyway).
    static let archiveMinFolder: Int64 = 4 << 20

    /// The file name part for a drive or folder (the same as its last-scan file).
    static func key(_ rootPath: String) -> String {
        var s = ""
        for ch in PathUtil.trim(rootPath).lowercased() { s.append(ch.isLetter || ch.isNumber ? ch : "_") }
        return s
    }

    static func timelineFile(_ rootPath: String) -> String { folder + "/" + key(rootPath) + ".timeline" }
    static func archiveFolder(_ rootPath: String) -> String { folder + "/" + key(rootPath) }

    /// Every recorded scan of the drive or folder, oldest first (56 bytes each: time, bytes, size on disk, files, folders,
    /// drive total, drive free).
    static func timeline(_ rootPath: String) -> [TimelinePoint] {
        guard let d = FileManager.default.contents(atPath: timelineFile(rootPath)) else { return [] }
        var r = BinReader([UInt8](d))
        var list: [TimelinePoint] = []
        while r.i + 56 <= r.b.count {
            let p = TimelinePoint()
            p.when = Date(timeIntervalSince1970: r.f64())
            p.bytes = r.i64(); p.alloc = r.i64(); p.files = r.i64(); p.dirs = r.i64(); p.total = r.i64(); p.free = r.i64()
            if r.failed { break }
            list.append(p)
        }
        return list
    }

    /// Adds a scan's totals to the drive's or folder's timeline (older points beyond 1,000 are dropped).
    static func appendTimeline(_ rootPath: String, _ point: TimelinePoint) throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var pts = timeline(rootPath)
        pts.append(point)
        if pts.count > maxPoints { pts.removeFirst(pts.count - maxPoints) }
        var w = BinWriter()
        for p in pts {
            w.f64(p.when.timeIntervalSince1970)
            w.i64(p.bytes); w.i64(p.alloc); w.i64(p.files); w.i64(p.dirs); w.i64(p.total); w.i64(p.free)
        }
        try w.data.write(to: URL(fileURLWithPath: timelineFile(rootPath)), options: .atomic)
    }

    private static func archiveFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }

    /// Keeps a small copy of a scan (folders of 4 MB or more, names and sizes; serialized with minFolder) for comparing
    /// any two scans later. One per day: a later scan the same day replaces it. Only the last 12 are kept, and only for
    /// the 10 most recently scanned drives/folders.
    static func archive(_ rootPath: String, _ data: Data, _ when: Date) throws {
        let fm = FileManager.default
        let dir = archiveFolder(rootPath)
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cal = Calendar.current
        for old in archived(rootPath) where cal.isDate(old.when, inSameDayAs: when) { try? fm.removeItem(atPath: old.file) }
        let packed = try (data as NSData).compressed(using: .zlib) as Data
        try packed.write(to: URL(fileURLWithPath: dir + "/" + archiveFormatter().string(from: when) + ".dsa"), options: .atomic)
        for old in archived(rootPath).dropFirst(maxArchived) { try? fm.removeItem(atPath: old.file) }
        // Drives or folders not scanned for a long time lose their archive and timeline (like the last-scan files).
        let base = URL(fileURLWithPath: folder)
        if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) {
            let dirs = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for (u, _) in dirs.sorted(by: { $0.1 > $1.1 }).dropFirst(10) {
                try? fm.removeItem(atPath: folder + "/" + u.lastPathComponent + ".timeline")
                try? fm.removeItem(at: u)
            }
        }
    }

    /// The archived scans of a drive or folder (time, file), newest first.
    static func archived(_ rootPath: String) -> [(when: Date, file: String)] {
        let dir = archiveFolder(rootPath)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        let f = archiveFormatter()
        var out: [(when: Date, file: String)] = []
        for n in names where n.hasSuffix(".dsa") {
            if let t = f.date(from: String(n.dropLast(4))) { out.append((when: t, file: dir + "/" + n)) }
        }
        return out.sorted { $0.when > $1.when }
    }
}

/// Totals of one scan, for the timeline.
final class TimelinePoint {
    var when = Date()
    var bytes: Int64 = 0, alloc: Int64 = 0, files: Int64 = 0, dirs: Int64 = 0, total: Int64 = 0, free: Int64 = 0
    var size: Int64 { DirNode.onDisk ? alloc : bytes }
}

struct BinWriter {
    var data = Data()
    mutating func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    mutating func i64(_ v: Int64) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    mutating func f64(_ v: Double) { i64(Int64(bitPattern: v.bitPattern)) }
    mutating func str(_ s: String) { let u = Array(s.utf8); u32(UInt32(u.count)); data.append(contentsOf: u) }
}

struct BinReader {
    let b: [UInt8]
    var i = 0
    var failed = false
    init(_ bytes: [UInt8]) { b = bytes }
    mutating func u32() -> UInt32 {
        guard i + 4 <= b.count else { failed = true; return 0 }
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(b[i + k]) << (8 * UInt32(k)) }
        i += 4
        return v
    }
    mutating func i64() -> Int64 {
        guard i + 8 <= b.count else { failed = true; return 0 }
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
        i += 8
        return Int64(bitPattern: v)
    }
    mutating func f64() -> Double { Double(bitPattern: UInt64(bitPattern: i64())) }
    mutating func str() -> String {
        let n = Int(u32())
        guard !failed, i + n <= b.count else { failed = true; return "" }
        let s = String(decoding: b[i..<(i + n)], as: UTF8.self)
        i += n
        return s
    }
}

/// A scan that can be compared: the one in memory now, the previous full scan, or an archived one.
final class ScanChoice {
    var label = ""
    var when = Date.distantPast
    var now = false, previous = false
    var file: String?          // archived scan
}

/// One side of a comparison: a folder of the scan in memory (dir) or of a saved scan (prev).
final class CmpSide {
    let dir: DirNode?
    let prev: PrevNode?
    init(dir: DirNode) { self.dir = dir; prev = nil }
    init(prev: PrevNode) { self.prev = prev; dir = nil }

    var name: String { dir?.name ?? prev?.name ?? "" }
    var size: Int64 { dir?.size ?? prev?.size ?? 0 }

    func kids() -> [CmpSide] {
        if let d = dir { return d.children.map { CmpSide(dir: $0) } }
        guard let kids = prev?.children else { return [] }
        return kids.values.map { CmpSide(prev: $0) }
    }

    func child(_ n: String) -> CmpSide? {
        if let d = dir { return d.child(n).map { CmpSide(dir: $0) } }
        return prev?.child(n).map { CmpSide(prev: $0) }
    }
}

extension MainWindowController {
    func buildChangesPage() -> Page {
        changeFrom.tip = "The earlier scan to compare: the previous scan in full, or one kept per day (folders of 4 MB or more)"
        changeTo.tip = "The later scan: this one, or a kept earlier one"
        changeFrom.onChange = { [unowned self] _ in self.fillChanges() }
        changeTo.onChange = { [unowned self] _ in self.fillChanges() }
        let p = Page("Changes", [Column("name", "Folder", 270), Column("change", "Change", 90, true), Column("size", "Now", 80, true),
                                 Column("files", "Before", 80, true)], barColumn: -1, bar: ActionBar([changeFrom, changeTo]))
        // Clicking a day on the timeline compares from that day's kept scan.
        historyStrip.onPick = { [unowned self] when in
            let cal = Calendar.current
            if let k = self.fromChoices.firstIndex(where: { !$0.now && cal.isDate($0.when, inSameDayAs: when) }) { self.changeFrom.selectedIndex = k }
        }
        historyStrip.isHidden = true
        p.setStrip(historyStrip)
        p.chartTitle = "Growth"
        p.chartScope = "of the growth"
        p.empty = "Nothing grew since the previous scan."
        p.fill = { [unowned self] in self.fillChanges() }
        return p
    }

    /// After a full scan: keep the previous scan for comparison and save this one (written in the background), add it to
    /// the timeline and keep a small copy of it for the day.
    func rememberScan(_ r: ScanRoot, _ result: DirNode, complete: Bool) {
        guard complete, !r.readOnly else { return }
        let path = r.path
        let data = History.serialize(path, result)
        let small = History.serialize(path, result, minFolder: History.archiveMinFolder)
        let point = TimelinePoint()
        point.when = Date()
        point.bytes = result.bytes; point.alloc = result.alloc; point.files = result.files; point.dirs = result.dirs
        point.total = r.total; point.free = r.free
        DispatchQueue.global(qos: .utility).async {
            let prev = History.load(path)
            try? History.save(path, data)
            // The timeline gets every scan (a few bytes); the archive one small copy per day.
            try? History.appendTimeline(path, point)
            try? History.archive(path, small, point.when)
            DispatchQueue.main.async {
                if r.previous == nil || prev != nil { r.previous = prev?.0; r.previousTime = prev?.1 ?? .distantPast }
                if let c = self.current, c.top === r.node, self.activePage === self.pContents { self.showContents(c) }
                self.setStale(self.pChanges)
            }
        }
    }

    /// The previous scan's node for a scanned folder (nil when unknown).
    func prevOf(_ d: DirNode) -> PrevNode? {
        guard let r = rootOf(d.top), let prev = r.previous else { return nil }
        var chain: [String] = []
        var n: DirNode? = d
        while let x = n, x.parent != nil { chain.append(x.name); n = x.parent }
        var p: PrevNode? = prev
        for name in chain.reversed() { p = p?.child(name); if p == nil { break } }
        return p
    }

    /// Change of each child folder of d since the previous scan, for the Change column.
    func setChanges(_ d: DirNode, _ items: [ItemInfo]) {
        guard let prev = prevOf(d) else { return }
        for it in items where it.isDir {
            guard let dn = it.dir else { continue }
            let pc = prev.child(dn.name)
            it.change = pc != nil ? dn.size - pc!.size : dn.size
            if pc == nil { it.note = "new" }
        }
    }

    func changeText(_ it: ItemInfo) -> String {
        if it.change == Int64.min { return "" }
        if it.note == "new" { return "new" }
        return Fmt.delta(it.change)
    }

    func changeCaption(_ d: DirNode) -> String {
        guard let r = rootOf(d.top), let prev = prevOf(d) else { return "" }
        let delta = d.size - prev.size
        if delta == 0 { return "  -  no change since the scan of \(Fmt.date(r.previousTime))" }
        return "  -  \(Fmt.delta(delta)) since the scan of \(Fmt.date(r.previousTime))"
    }

    // MARK: comparing any two scans

    /// Lists the scans of a drive or folder in the From / To boxes, keeping the choices when possible.
    func loadScanChoices(_ r: ScanRoot) {
        let oldFrom: ScanChoice? = changesRoot === r && changeFrom.selectedIndex < fromChoices.count ? fromChoices[changeFrom.selectedIndex] : nil
        let oldTo: ScanChoice? = changesRoot === r && changeTo.selectedIndex < toChoices.count ? toChoices[changeTo.selectedIndex] : nil
        changesRoot = r
        // The copy kept of the scan in memory is "Now", not an earlier scan.
        let archived = History.archived(r.path).filter { r.scanned == .distantPast || abs($0.when.timeIntervalSince(r.scanned)) > 120 }
        var from: [ScanChoice] = []
        if r.previous != nil {
            let c = ScanChoice()
            c.previous = true
            c.when = r.previousTime
            c.label = "Previous scan, " + Fmt.date(r.previousTime)
            from.append(c)
        }
        for a in archived where r.previous == nil || abs(a.when.timeIntervalSince(r.previousTime)) > 120 {
            let c = ScanChoice()
            c.file = a.file
            c.when = a.when
            c.label = Fmt.date(a.when)
            from.append(c)
        }
        from.sort { $0.when > $1.when }
        fromChoices = from
        let now = ScanChoice()
        now.now = true
        now.when = r.scanned
        now.label = "Now (this scan)"
        toChoices = [now] + from
        let fi = oldFrom.flatMap { o in fromChoices.firstIndex { $0.when == o.when } } ?? 0
        let ti = oldTo.flatMap { o in toChoices.firstIndex { $0.when == o.when && $0.now == o.now } } ?? 0
        changeFrom.setChoices(fromChoices.isEmpty ? ["No earlier scan yet"] : fromChoices.map { $0.label }, fi)
        changeTo.setChoices(toChoices.map { $0.label }, ti)
        changeFrom.isEnabled = fromChoices.count > 1
        changeTo.isEnabled = toChoices.count > 1
    }

    private func sideFor(_ c: ScanChoice, _ r: ScanRoot) -> CmpSide? {
        if c.now { return r.node.map { CmpSide(dir: $0) } }
        if c.previous { return r.previous.map { CmpSide(prev: $0) } }
        guard let f = c.file else { return nil }
        if let p = archiveCache[f] { return CmpSide(prev: p) }
        guard let loaded = History.loadFile(f) else { return nil }
        if archiveCache.count > 8 { archiveCache.removeAll() }
        archiveCache[f] = loaded.0
        return CmpSide(prev: loaded.0)
    }

    func fillChanges() {
        let p = pChanges!
        p.chartTitle = "Growth"
        if let r = active, r.node != nil, !r.readOnly {
            loadScanChoices(r)
            let points = History.timeline(r.path)
            historyStrip.setPoints(points, drive: r.isDrive)
            historyStrip.isHidden = points.isEmpty
        } else {
            historyStrip.isHidden = true
        }
        p.root.needsLayout = true
        guard let r = active, let rootNode = r.node, !r.readOnly, !fromChoices.isEmpty else {
            p.setCaption(active?.node == nil ? "Nothing scanned yet."
                : active!.readOnly ? "A saved scan opened from a file has no history here. Open the drive or folder itself to see what changed."
                : "No earlier scan of \(active!.path) to compare with yet. Every full scan is remembered; scan again later to see what changed.")
            p.chartSub = ""
            p.empty = "No earlier scan to compare with."
            p.setRows([], "No earlier scan of this drive or folder to compare with yet.\nScan it again later to see which folders grew or shrank.")
            if activePage === p { refreshChart() }
            return
        }
        let from = fromChoices[min(changeFrom.selectedIndex, fromChoices.count - 1)]
        let to = toChoices[min(changeTo.selectedIndex, toChoices.count - 1)]
        historyStrip.mark(from.when, to.now ? Date() : to.when)
        if !to.now && to.when <= from.when {
            p.setCaption("Pick a later scan in To than in From.")
            p.chartSub = ""
            p.setRows([], "The To scan must be later than the From scan.")
            if activePage === p { refreshChart() }
            return
        }
        guard let a = sideFor(from, r), let b = sideFor(to, r) else {
            p.setCaption("That scan could not be read.")
            p.chartSub = ""
            p.setRows([], "That scan could not be read.")
            if activePage === p { refreshChart() }
            return
        }
        // A folder is listed when its change is big enough and not mostly explained by one of its subfolders.
        let threshold = max(Int64(10 << 20), b.size / 1000)
        var found: [(CmpSide, CmpSide?, String)] = []
        var removed: [(String, CmpSide)] = []
        var stack: [(CmpSide, CmpSide?, String)] = [(b, a, rootNode.fullPath)]
        while let top = stack.popLast() {
            let (d, pn, path) = top
            let delta = d.size - (pn?.size ?? 0)
            if abs(delta) < threshold { continue }
            var explained = false
            for c in d.kids() {
                let pc = pn?.child(c.name)
                let cd = c.size - (pc?.size ?? 0)
                if abs(cd) >= threshold { stack.append((c, pc, PathUtil.join(path, c.name))) }
                if Double(abs(cd)) >= Double(abs(delta)) * 0.8 && cd.signum() == delta.signum() { explained = true }
            }
            if let before = pn {
                for pc in before.kids() where pc.size >= threshold && d.child(pc.name) == nil {
                    removed.append((PathUtil.join(path, pc.name), pc))
                    if Double(pc.size) >= Double(abs(delta)) * 0.8 && delta < 0 { explained = true }
                }
            }
            if !explained { found.append(top) }
        }
        var rows: [ItemInfo] = []
        var grew: Int64 = 0, shrank: Int64 = 0
        found.sort { abs($0.0.size - ($0.1?.size ?? 0)) > abs($1.0.size - ($1.1?.size ?? 0)) }
        for (d, pn, path) in found.prefix(500) {
            let before = pn?.size ?? 0, delta = d.size - before
            // Folders of the scan in memory can be opened; folders of a kept scan are only named.
            let it: ItemInfo
            if let dn = d.dir {
                it = ItemInfo.forDir(dn, 0)
            } else {
                it = ItemInfo()
                it.folderIcon = true
                it.path = path
                it.size = d.size
            }
            it.name = path
            it.change = delta
            it.files = before
            it.chartValue = max(0, delta)
            if pn == nil { it.note = "new" }
            if delta > 0 { grew += delta } else { shrank -= delta }
            it.cells = [it.name, changeText(it), Fmt.size(d.size), pn != nil ? Fmt.size(before) : "new"]
            if d.dir == nil { it.tip = ItemInfo.nameOf(path) + "\n" + path }
            rows.append(it)
        }
        removed.sort { $0.1.size > $1.1.size }
        for (path, pc) in removed.prefix(100) {
            let it = ItemInfo()
            it.name = path; it.change = -pc.size; it.files = pc.size; it.folderIcon = true; it.chartValue = 0
            shrank += pc.size
            it.cells = [it.name, changeText(it), to.now ? "removed" : "removed or small", Fmt.size(pc.size)]
            it.tip = ItemInfo.nameOf(path) + "\n" + path
            it.color = T.MUTED
            rows.append(it)
        }
        rows.sort { abs($0.change) > abs($1.change) }
        let total = b.size - a.size
        let span = to.now ? "Since the scan of \(Fmt.date(from.when))" : "From \(Fmt.date(from.when)) to \(Fmt.date(to.when))"
        p.setRows(rows, "No folder changed by more than \(Fmt.size(threshold)) " + (to.now ? "since that scan." : "between these scans."), keepOrder: true)
        p.setCaption("\(span): \(total >= 0 ? "+" : "-")\(Fmt.size(abs(total))) in total  -  folders that changed by \(Fmt.size(threshold)) or more (grew \(Fmt.size(grew)), shrank \(Fmt.size(shrank))).")
        p.chartSub = "+\(Fmt.size(grew)) " + (to.now ? "since \(Fmt.day(from.when))" : "from \(Fmt.day(from.when)) to \(Fmt.day(to.when))")
        p.chartTotal = 0
        p.empty = to.now ? "Nothing grew since that scan." : "Nothing grew between these scans."
        if activePage === p { refreshChart() }
    }
}

/// Timeline of a drive's (or folder's) scans: used space (drives) or scanned size (folders) over time, one dot per scan,
/// the two compared scans marked. Hover shows a scan's date and size; clicking a dot compares from that day.
final class HistoryStrip: NSView, PageStrip {
    private var points: [TimelinePoint] = []
    private var drive = false
    private var markA = Date.distantPast, markB = Date.distantPast
    private var hover = -1
    private var dots: [NSPoint] = []
    var onPick: ((Date) -> Void)?
    override var isFlipped: Bool { true }
    var stripHeight: CGFloat { 84 }

    func setPoints(_ pts: [TimelinePoint], drive isDrive: Bool) {
        points = pts
        drive = isDrive && pts.contains { $0.total > 0 }
        hover = -1
        needsDisplay = true
    }

    func mark(_ a: Date, _ b: Date) { markA = a; markB = b; needsDisplay = true }

    private func value(_ p: TimelinePoint) -> Int64 { drive && p.total > 0 ? p.total - p.free : p.size }

    private func nearest(_ t: Date) -> Int {
        var best = -1
        var bd = Double.greatestFiniteMagnitude
        for (i, p) in points.enumerated() {
            let d = abs(p.when.timeIntervalSince(t))
            if d < bd { bd = d; best = i }
        }
        return best
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func draw(_ dirtyRect: NSRect) {
        T.SURFACE.setFill(); bounds.fill()
        dots = []
        if points.isEmpty { return }
        let pad: CGFloat = 10, lh = Theme.lineHeight(Theme.font9)
        let top = lh + 8, bottom = bounds.height - lh - 2
        let plot = NSRect(x: pad, y: top, width: bounds.width - 2 * pad, height: max(10, bottom - top))
        Theme.fillRound(plot, 6, fill: T.BG)
        var minV = points.map { value($0) }.min() ?? 0, maxV = points.map { value($0) }.max() ?? 0
        if maxV == minV { maxV += 1 << 30; minV = max(0, minV - (1 << 30)) }
        let t0 = points[0].when, t1 = points[points.count - 1].when
        let span = max(1, t1.timeIntervalSince(t0))
        for p in points {
            let x = points.count == 1 ? plot.midX : plot.minX + 6 + CGFloat(p.when.timeIntervalSince(t0) / span) * (plot.width - 12)
            let y = plot.maxY - 5 - CGFloat(Double(value(p) - minV) / Double(maxV - minV)) * (plot.height - 10)
            dots.append(NSPoint(x: x, y: y))
        }
        if dots.count > 1 {
            let line = NSBezierPath()
            line.move(to: dots[0])
            for d in dots.dropFirst() { line.line(to: d) }
            line.lineWidth = 1.5
            line.lineJoinStyle = .round
            T.ACCENT.setStroke()
            line.stroke()
        }
        let ia = markA == .distantPast ? -1 : nearest(markA), ib = markB == .distantPast ? -1 : nearest(markB)
        for (i, d) in dots.enumerated() {
            let marked = i == ia || i == ib
            let rad: CGFloat = marked || i == hover ? 5 : 3
            (marked ? T.ACCENT_LIGHT : i == hover ? T.FG : T.ACCENT).setFill()
            NSBezierPath(ovalIn: NSRect(x: d.x - rad, y: d.y - rad, width: 2 * rad, height: 2 * rad)).fill()
        }
        let title = (drive ? "Used space" : "Size") + " over \(Fmt.count(points.count)) scan\(points.count == 1 ? "" : "s")"
        Theme.drawText(title, in: NSRect(x: pad, y: 2, width: bounds.width / 2, height: lh), font: Theme.font9, color: T.MUTED)
        let show = hover >= 0 ? hover : points.count - 1
        let p = points[show]
        let info = "\(Fmt.date(p.when))  -  \(Fmt.size(value(p)))" + (drive && p.total > 0 ? " used, \(Fmt.size(p.free)) free" : "")
        Theme.drawText(info, in: NSRect(x: pad, y: 2, width: bounds.width - 2 * pad, height: lh), font: Theme.font9,
                       color: hover >= 0 ? T.FG : T.MUTED, align: .right)
        Theme.drawText(Fmt.day(t0), in: NSRect(x: pad, y: bottom, width: 120, height: lh), font: Theme.font9, color: T.MUTED)
        if points.count > 1 {
            Theme.drawText(Fmt.day(t1), in: NSRect(x: bounds.width - pad - 120, y: bottom, width: 120, height: lh), font: Theme.font9,
                           color: T.MUTED, align: .right)
        }
    }

    private func hit(_ e: NSEvent) -> Int {
        let p = convert(e.locationInWindow, from: nil)
        var best = -1
        var bd: CGFloat = 12
        for (i, d) in dots.enumerated() {
            let dist = abs(d.x - p.x)
            if dist <= bd { bd = dist; best = i }
        }
        return best
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
        if h >= 0 && h < points.count { onPick?(points[h].when) }
    }
}
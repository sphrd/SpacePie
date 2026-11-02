import AppKit
import CoreServices
import CryptoKit

/// What a snapshot file says about the scan it holds.
struct SnapshotInfo {
    var rootPath = ""
    var taken = Date()              // when the scan started (the FSEvents id is from that moment)
    var eventId: UInt64 = 0         // FSEventsGetCurrentEventId() when the scan started
    var volumeUUID = ""             // FSEvents' id of the volume's event history
    var fullDiskAccess = false
    var scanSeconds: Double = 0     // how long the full scan took
}

/// Compact binary copy of a full scan (every folder with its own files, i.e. the tree and the file index the Files and
/// Duplicates views search) plus the FSEvents event id from when the scan started, in
/// ~/Library/Application Support/DiskSpaceAnalyzer/snapshots/<hash of the root>.bin. The next start shows it at once and
/// lets FSEvents replay what changed since (Replay). Only the 10 most recently written roots are kept; a file of another
/// version is deleted. Layout: magic, version (both u32, uncompressed), then LZFSE: header, then the folders in pre-order
/// (name, modified, flags, files, number of children); numbers are varints.
enum Snapshot {
    static let magic: UInt32 = 0x53415344      // "DSAS"
    static let version: UInt32 = 1
    static let keep = 10
    static var folderOverride: String?         // self-test

    static var folder: String {
        if let f = folderOverride { return f }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory() + "/Library/Application Support"
        return base + "/DiskSpaceAnalyzer/snapshots"
    }

    static func file(for rootPath: String) -> String {
        let digest = SHA256.hash(data: Data(PathUtil.trim(rootPath).utf8))
        return folder + "/" + digest.prefix(12).map { String(format: "%02x", $0) }.joined() + ".bin"
    }

    /// FSEvents' id of the event history of the volume holding path ("" when unknown); it changes when that history is
    /// reset, and then the saved event id means nothing.
    static func eventsUUID(_ path: String) -> String {
        var st = stat()
        guard stat(path, &st) == 0, let u = FSEventsCopyUUIDForDevice(st.st_dev) else { return "" }
        return CFUUIDCreateString(nil, u) as String
    }

    /// The header for a scan that starts now.
    static func infoNow(_ rootPath: String) -> SnapshotInfo {
        var i = SnapshotInfo()
        i.rootPath = PathUtil.trim(rootPath)
        i.taken = Date()
        i.eventId = UInt64(FSEventsGetCurrentEventId())
        i.volumeUUID = eventsUUID(rootPath)
        i.fullDiskAccess = FullDiskAccess.granted
        return i
    }

    /// Why a loaded snapshot cannot be brought up to date through FSEvents (nil = it can).
    static func unusable(_ info: SnapshotInfo, _ rootPath: String) -> String? {
        if info.eventId == 0 { return "no event id was saved" }
        if info.eventId > UInt64(FSEventsGetCurrentEventId()) { return "the event ids were reset" }
        let uuid = eventsUUID(rootPath)
        if uuid.isEmpty || uuid != info.volumeUUID { return "the volume's event history was reset" }
        if info.fullDiskAccess != FullDiskAccess.granted { return "Full Disk Access changed" }
        return nil
    }

    /// The tree as bytes (call while the trees are held still: on the main thread or inside readInBackground).
    static func serialize(_ root: DirNode, _ info: SnapshotInfo) -> Data {
        var w = PackWriter()
        w.str(info.rootPath)
        w.f64(info.taken.timeIntervalSince1970)
        w.u64(info.eventId)
        w.str(info.volumeUUID)
        w.byte(info.fullDiskAccess ? 1 : 0)
        w.f64(info.scanSeconds)
        for d in root.descendants() {
            w.str(d.name)
            w.sv(d.modified)
            var flags: UInt8 = d.denied ? 1 : 0
            switch d.skipped {
            case .no: break
            case .notDownloaded: flags |= 2
            case .needsAccess: flags |= 4
            }
            if d.fileList == nil { flags |= 8 }
            w.byte(flags)
            if let list = d.fileList {
                w.uv(UInt64(list.count))
                for f in list {
                    w.str(f.name)
                    w.uv(UInt64(max(0, f.bytes)))
                    w.uv(UInt64(max(0, f.alloc)))
                    w.sv(f.modified)
                    w.uv(UInt64(f.flags))
                }
            }
            w.uv(UInt64(d.children.count))
        }
        return Data(w.bytes)
    }

    /// Compresses and writes a serialized scan, then keeps only the 10 most recent roots.
    static func write(_ body: Data, _ rootPath: String) throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let packed = try (body as NSData).compressed(using: .lzfse) as Data
        var head = PackWriter()
        head.u32(magic)
        head.u32(version)
        var out = Data(head.bytes)
        out.append(packed)
        try out.write(to: URL(fileURLWithPath: file(for: rootPath)), options: .atomic)
        prune()
    }

    static func prune() {
        let dir = URL(fileURLWithPath: folder)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let dated = files.filter { $0.pathExtension == "bin" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (u, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) { try? FileManager.default.removeItem(at: u) }
    }

    /// The saved scan of rootPath with its header; nil when there is none (a file of another version or a damaged one is
    /// deleted). Totals are added up again from the files.
    static func load(_ rootPath: String) -> (DirNode, SnapshotInfo)? {
        let path = file(for: rootPath)
        guard let raw = FileManager.default.contents(atPath: path) else { return nil }
        func drop() -> (DirNode, SnapshotInfo)? { try? FileManager.default.removeItem(atPath: path); return nil }
        guard raw.count >= 8 else { return drop() }
        var hr = PackReader([UInt8](raw.prefix(8)))
        if hr.u32() != magic || hr.u32() != version { return drop() }
        guard let body = try? (raw.subdata(in: 8..<raw.count) as NSData).decompressed(using: .lzfse) as Data else { return drop() }
        var r = PackReader([UInt8](body))
        var info = SnapshotInfo()
        info.rootPath = r.str()
        info.taken = Date(timeIntervalSince1970: r.f64())
        info.eventId = r.u64()
        info.volumeUUID = r.str()
        info.fullDiskAccess = r.byte() != 0
        info.scanSeconds = r.f64()
        if r.failed { return drop() }
        if !PathUtil.same(info.rootPath, rootPath) { return nil }

        var all: [DirNode] = []
        func readNode(_ parent: DirNode?) -> (DirNode, Int) {
            let d = DirNode(name: r.str(), parent: parent)
            d.modified = r.sv()
            let flags = r.byte()
            d.denied = flags & 1 != 0
            d.skipped = flags & 2 != 0 ? .notDownloaded : (flags & 4 != 0 ? .needsAccess : .no)
            if flags & 8 == 0 {
                let n = Int(truncatingIfNeeded: r.uv())
                if n < 0 || n > r.remaining { r.failed = true; return (d, 0) }
                var list: [FileRec] = []
                list.reserveCapacity(n)
                var b: Int64 = 0, a: Int64 = 0
                for _ in 0..<n {
                    let f = FileRec(name: r.str(), bytes: Int64(truncatingIfNeeded: r.uv()), alloc: Int64(truncatingIfNeeded: r.uv()),
                                    modified: r.sv(), flags: UInt32(truncatingIfNeeded: r.uv()))
                    if r.failed { break }
                    b += f.bytes; a += f.alloc
                    list.append(f)
                }
                d.fileList = list
                d.localBytes = b; d.localAlloc = a; d.localFiles = Int64(list.count)
            }
            let kids = Int(truncatingIfNeeded: r.uv())
            if kids < 0 || kids > r.remaining { r.failed = true; return (d, 0) }
            return (d, kids)
        }
        // Iterative (very deep trees would overflow the stack), in the order serialize wrote them.
        let first = readNode(nil)
        let root = first.0
        all.append(root)
        var stack: [(DirNode, Int)] = [first]
        while let top = stack.popLast() {
            if r.failed { break }
            if top.1 == 0 { continue }
            stack.append((top.0, top.1 - 1))
            let c = readNode(top.0)
            top.0.children.append(c.0)
            all.append(c.0)
            stack.append(c)
        }
        if r.failed || !r.atEnd { return drop() }
        for d in all.reversed() { d.aggregate() }
        root.name = rootPath
        return (root, info)
    }
}

/// Little-endian binary writer with varints (unsigned LEB128; signed values zigzag-encoded).
struct PackWriter {
    var bytes: [UInt8] = []
    mutating func byte(_ v: UInt8) { bytes.append(v) }
    mutating func uv(_ v0: UInt64) {
        var v = v0
        while v >= 0x80 { bytes.append(UInt8(truncatingIfNeeded: v) | 0x80); v >>= 7 }
        bytes.append(UInt8(v))
    }
    mutating func sv(_ v: Int64) { uv(UInt64(bitPattern: (v << 1) ^ (v >> 63))) }
    mutating func u32(_ v: UInt32) { for k in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(k)))) } }
    mutating func u64(_ v: UInt64) { for k in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(k)))) } }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func str(_ s: String) { uv(UInt64(s.utf8.count)); bytes.append(contentsOf: s.utf8) }
    mutating func raw(_ d: [UInt8]) { bytes.append(contentsOf: d) }
}

struct PackReader {
    let b: [UInt8]
    var i = 0
    var failed = false
    init(_ bytes: [UInt8]) { b = bytes }
    var remaining: Int { b.count - i }
    var atEnd: Bool { i == b.count }
    mutating func byte() -> UInt8 {
        guard i < b.count else { failed = true; return 0 }
        let v = b[i]
        i += 1
        return v
    }
    mutating func uv() -> UInt64 {
        var v: UInt64 = 0, shift: UInt64 = 0
        while true {
            guard i < b.count, shift < 64 else { failed = true; return 0 }
            let x = b[i]
            i += 1
            v |= UInt64(x & 0x7f) << shift
            if x < 0x80 { return v }
            shift += 7
        }
    }
    mutating func sv() -> Int64 { let u = uv(); return Int64(bitPattern: (u >> 1) ^ (0 &- (u & 1))) }
    mutating func u32() -> UInt32 {
        guard i + 4 <= b.count else { failed = true; return 0 }
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(b[i + k]) << (8 * UInt32(k)) }
        i += 4
        return v
    }
    mutating func u64() -> UInt64 {
        guard i + 8 <= b.count else { failed = true; return 0 }
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
        i += 8
        return v
    }
    mutating func f64() -> Double { Double(bitPattern: u64()) }
    mutating func str() -> String {
        let n = Int(truncatingIfNeeded: uv())
        guard !failed, n >= 0, n <= remaining else { failed = true; return "" }
        let s = String(decoding: b[i..<(i + n)], as: UTF8.self)
        i += n
        return s
    }
    mutating func raw(_ n: Int) -> [UInt8] {
        guard !failed, n >= 0, n <= remaining else { failed = true; return [] }
        let v = Array(b[i..<(i + n)])
        i += n
        return v
    }
}

/// A snapshot shown at start-up while FSEvents replays what changed since it was taken.
final class Replay {
    let info: SnapshotInfo
    let loadSeconds: Double
    var historyDone = false
    var events = 0
    var timer: Timer?
    init(_ info: SnapshotInfo, _ loadSeconds: Double) { self.info = info; self.loadSeconds = loadSeconds }
}

/// Fast restart: at start-up the last full scan of the drive or folder is shown at once from its snapshot, and an
/// FSEvents stream started at the snapshot's event id replays every change since (applied like live updates: changed
/// folders are measured again). When the history is not available (macOS asks for a full rescan of the root, event ids
/// wrapped or were reset, the volume's event history changed, or the history does not end within 10 s) the drive or
/// folder is scanned again normally, showing the snapshot meanwhile.
extension MainWindowController {
    static func normalizePath(_ p0: String) -> String {
        var path = (p0 as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespaces)
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Start-up: shows the last scan of path when there is one, else scans it.
    func openLastScan(_ path0: String) {
        let path = MainWindowController.normalizePath(path0)
        if busy || scanning || !PathUtil.isDir(path) { scanPath(path); return }
        pathField.stringValue = path
        statusLabel.stringValue = "Loading the last scan of \(path)..."
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = Snapshot.load(path)
            let secs = Date().timeIntervalSince(started)
            DispatchQueue.main.async { self.showLastScan(path, loaded, secs) }
        }
    }

    private func showLastScan(_ path: String, _ loaded: (DirNode, SnapshotInfo)?, _ secs: Double) {
        if busy || scanning { return }
        guard let l = loaded else { scanPath(path); return }
        let node = l.0, info = l.1
        var r = findRoot(path)
        if r == nil {
            let n = ScanRoot(path: path)
            refreshCapacity(n)
            roots.append(n)
            sortRoots()
            r = n
        }
        let target = r!
        target.node = node
        refreshCapacity(target)
        // The chart shows the logo until the replay (or the rescan) has brought the saved scan up to date.
        let unusable = Snapshot.unusable(info, path)
        let rep = Replay(info, secs)
        if unusable == nil { target.replay = rep } else { holdChart = true }
        current = nil
        refreshTree(node, fallback: target)
        markSuggestionsDirty()
        viewsChanged()
        updateDriveLabel()
        // The Changes view compares with the last full scan (from the scan history).
        DispatchQueue.global(qos: .utility).async {
            let prev = History.load(path)
            DispatchQueue.main.async {
                if target.previous == nil, let p = prev { target.previous = p.0; target.previousTime = p.1; self.setStale(self.pChanges) }
            }
        }
        if let why = unusable {
            // Shown meanwhile; scanned again in the background.
            onReplayDone?(path, why)
            scanPath(path)
            holdChart = false
            refreshChart()
            statusLabel.stringValue = "Showing the scan of \(Fmt.date(info.taken)); the changes since are not available (\(why)), scanning again..."
            return
        }
        startWatching(target, since: info.eventId)
        statusLabel.stringValue = "Showing the scan of \(Fmt.date(info.taken)); updating..."
        rep.timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self, weak target] _ in
            guard let self = self, let t = target, let rp = t.replay, rp === rep, !rp.historyDone else { return }
            self.replayFailed(t, "the event history did not arrive within 10 s")
        }
        if target.isDrive && selfTestDir == nil {
            if apps == nil && !appsLoading { loadApps() }
            if systemGroups == nil && !systemLoading { loadSystem() }
        }
    }

    /// The snapshot's history could not be replayed: scan again (the snapshot stays visible meanwhile).
    func replayFailed(_ r: ScanRoot, _ why: String) {
        guard let rep = r.replay else { return }
        rep.timer?.invalidate()
        r.replay = nil
        stopWatching(r)
        fsDeep.removeAll { PathUtil.isWithin($0, r.path) }
        statusLabel.stringValue = "The changes since the scan of \(Fmt.date(rep.info.taken)) are not available (\(why)); scanning again..."
        onReplayDone?(r.path, why)
        rescanAfterReplay(r)
    }

    private func rescanAfterReplay(_ r: ScanRoot) {
        guard roots.contains(where: { $0 === r }) else { return }
        if busy || scanning { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.rescanAfterReplay(r) }; return }
        scanPath(r.path)
    }

    /// Called when no live changes are waiting: a replay whose history has ended is complete. The tree is up to date, so
    /// it is saved again (with the last event id seen) and the status says how long it took.
    func finishReplays() {
        for r in roots {
            guard let rep = r.replay, rep.historyDone, let node = r.node else { continue }
            rep.timer?.invalidate()
            if livePending { refreshAfterLive() }
            r.replay = nil
            let lastId = streams.first { $0.root === r }?.lastId ?? 0
            var info = Snapshot.infoNow(r.path)
            if lastId > 0 { info.eventId = lastId }
            info.scanSeconds = rep.info.scanSeconds
            saveSnapshot(r, node, info)
            let n = rep.events
            let full = rep.info.scanSeconds > 0 ? String(format: "; a full scan took %.1f s", rep.info.scanSeconds) : ""
            statusLabel.stringValue = "Up to date: the scan of \(Fmt.date(rep.info.taken)) plus \(Fmt.count(n)) change\(n == 1 ? "" : "s") since"
                + String(format: " (loaded in %.2f s", rep.loadSeconds) + full + ")."
            onReplayDone?(r.path, nil)
            // Up to date: the logo turns into the chart.
            if !chartOnHold { refreshChart() }
            checkLowSpace(r)
        }
    }

    /// Saves the scan of a drive or folder for the next start (serialized while the trees are held still, written in
    /// the background).
    func saveSnapshot(_ r: ScanRoot, _ node: DirNode, _ info: SnapshotInfo, _ done: ((Bool) -> Void)? = nil) {
        let path = r.path
        readInBackground({ Snapshot.serialize(node, info) }, { data in
            DispatchQueue.global(qos: .utility).async {
                let ok = (try? Snapshot.write(data, path)) != nil
                DispatchQueue.main.async { done?(ok) }
            }
        })
    }
}

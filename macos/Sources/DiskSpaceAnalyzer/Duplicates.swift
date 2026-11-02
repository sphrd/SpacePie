import AppKit
import CryptoKit
import Darwin

/// Finds files with identical content: same size (from the index), then the same hash of the first 64 KB, then the same
/// hash of the whole file. Several hard links to one file (same device and inode) are one file, not duplicates. Files
/// not downloaded from iCloud are skipped (reading them would download them). Hashes are remembered (HashCache): a file
/// whose path, size, modification time and inode did not change is not read again.
final class DuplicateFinder {
    private let lock = NSLock()
    private var _toRead: Int64 = 0, _read: Int64 = 0, _checked: Int64 = 0, _current = ""
    private var _cancelled = false
    private var _readFiles = Set<String>(), _cachedFiles = Set<String>()
    private var _cachedBytes: Int64 = 0
    var groups: [[FileEntry]] = []
    static var useCache = true

    var bytesToRead: Int64 { lock.lock(); defer { lock.unlock() }; return _toRead }
    var bytesRead: Int64 { lock.lock(); defer { lock.unlock() }; return _read }
    var filesChecked: Int64 { lock.lock(); defer { lock.unlock() }; return _checked }
    var current: String { lock.lock(); defer { lock.unlock() }; return _current }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    /// Files opened and read in this search.
    var filesRead: Int { lock.lock(); defer { lock.unlock() }; return _readFiles.count }
    /// Files whose hashes all came from the cache (not read at all).
    var filesFromCache: Int { lock.lock(); defer { lock.unlock() }; return _cachedFiles.subtracting(_readFiles).count }
    /// Bytes the cache saved from being read.
    var bytesFromCache: Int64 { lock.lock(); defer { lock.unlock() }; return _cachedBytes }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    static let headSize = 64 * 1024

    final class Candidate {
        let file: FileEntry
        let path: String
        var id: UInt64 = 0          // device and inode: equal for hard links
        var head: String?, full: String?
        init(_ f: FileEntry, _ p: String) { file = f; path = p }
    }

    /// Step 1, reading the index (the trees must not change meanwhile): files of the same size.
    func collect(_ scope: DirNode, _ minSize: Int64) -> [[Candidate]] {
        var bySize: [Int64: [Candidate]] = [:]
        for d in scope.descendants() {
            guard let list = d.fileList else { continue }
            var dirPath: String?
            for f in list where f.bytes >= max(1, minSize) && !f.dataless {
                if dirPath == nil { dirPath = d.fullPath }
                bySize[f.bytes, default: []].append(Candidate(FileEntry(d, f), PathUtil.join(dirPath!, f.name)))
            }
            if cancelled { return [] }
        }
        return bySize.values.filter { $0.count > 1 }
    }

    /// Steps 2 and 3, reading the files only.
    func run(_ sizeGroups: [[Candidate]]) {
        defer { if DuplicateFinder.useCache { HashCache.save() } }
        lock.lock(); _toRead = sizeGroups.reduce(Int64(0)) { $0 + Int64($1.count) * min(Int64(DuplicateFinder.headSize), $1[0].file.bytes) }; lock.unlock()
        var headGroups: [[Candidate]] = []
        for g in sizeGroups {
            if cancelled { return }
            hashAll(g, limit: Int64(DuplicateFinder.headSize), identify: true, full: false)
            var seen = Set<UInt64>()
            var distinct: [Candidate] = []
            for c in g where c.head != nil { if seen.insert(c.id).inserted { distinct.append(c) } }
            for hg in Dictionary(grouping: distinct, by: { $0.head! }).values where hg.count > 1 { headGroups.append(hg) }
        }
        lock.lock(); _toRead = _read + headGroups.reduce(Int64(0)) { $0 + ($1[0].file.bytes > Int64(DuplicateFinder.headSize) ? Int64($1.count) * $1[0].file.bytes : 0) }; lock.unlock()
        var result: [[FileEntry]] = []
        for g in headGroups {
            if cancelled { return }
            if g[0].file.bytes > Int64(DuplicateFinder.headSize) { hashAll(g, limit: Int64.max, identify: false, full: true) }
            else { for c in g { c.full = c.head } }
            for fg in Dictionary(grouping: g.filter { $0.full != nil }, by: { $0.full! }).values where fg.count > 1 {
                result.append(fg.map { $0.file }.sorted { $0.modified > $1.modified })
            }
        }
        result.sort { Int64($0.count - 1) * $0[0].bytes > Int64($1.count - 1) * $1[0].bytes }
        groups = result
    }

    /// Hashes the files of a group, three at a time.
    private func hashAll(_ g: [Candidate], limit: Int64, identify: Bool, full: Bool) {
        let n = g.count
        let chunk = max(1, (n + 2) / 3)
        DispatchQueue.concurrentPerform(iterations: min(3, n)) { k in
            var i = k * chunk
            while i < min(n, (k + 1) * chunk) {
                if cancelled { return }
                let h = hash(g[i], limit, identify, full: full)
                if full { g[i].full = h } else { g[i].head = h }
                i += 1
            }
        }
    }

    private func hash(_ c: Candidate, _ limit: Int64, _ identify: Bool, full: Bool) -> String? {
        lock.lock(); _current = c.path; lock.unlock()
        var st = stat()
        guard lstat(c.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int64(st.st_size)
        let mtime = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        let ino = UInt64(st.st_ino)
        if identify { c.id = (UInt64(UInt32(bitPattern: st.st_dev)) << 40) ^ ino }
        let cache = DuplicateFinder.useCache
        if cache {
            let known = HashCache.lookup(c.path, size, mtime, ino)
            if let h = full ? known.full : known.head {
                lock.lock()
                _cachedFiles.insert(c.path)
                _cachedBytes += min(limit, size)
                _toRead -= min(limit, size)
                _checked += 1
                lock.unlock()
                return h
            }
        }
        let fd = open(c.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { return nil }
        defer { close(fd) }
        lock.lock(); _readFiles.insert(c.path); lock.unlock()
        _ = fcntl(fd, F_NOCACHE, 1)
        var md5 = Insecure.MD5()
        let bufSize = 1 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }
        var left = limit
        while left > 0 {
            if cancelled { return nil }
            let n = read(fd, buf, Int(min(Int64(bufSize), left)))
            if n < 0 { return nil }
            if n == 0 { break }
            md5.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
            left -= Int64(n)
            lock.lock(); _read += Int64(n); lock.unlock()
        }
        lock.lock(); _checked += 1; lock.unlock()
        let h = Data(md5.finalize()).base64EncodedString()
        // Only a hash of the version measured above is remembered (the file did not change while it was read).
        var after = stat()
        if cache && fstat(fd, &after) == 0 && Int64(after.st_size) == size
            && Int64(after.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(after.st_mtimespec.tv_nsec) == mtime {
            HashCache.store(c.path, size, mtime, ino, head: full ? nil : h, full: full ? h : (size <= Int64(DuplicateFinder.headSize) ? h : nil))
        }
        return h
    }
}

extension MainWindowController {
    static let dupeSizes: [Int64] = [1 << 20, 10 << 20, 100 << 20, 1]

    func buildDuplicatesPage() -> Page {
        btnFindDupes.tip = "Compare the files in the selected folder by content"
        btnSelectExtra.tip = "Select every copy except the newest one of each group; then add them to the delete list or delete them"
        btnClone.tip = "Select duplicate groups (or press Select extra copies) to replace their extra copies with APFS clones"
        let p = Page("Duplicates", [Column("name", "Name", 260), Column("size", "Size", 84, true), Column("files", "Can free", 90, true),
                                    Column("folder", "Folder", 330), Column("mod", "Modified", 128)],
                     barColumn: -1, bar: ActionBar([btnFindDupes, dupeMin, btnSelectExtra, btnClone], right: [btnSelectExtra, btnClone]))
        p.sortable = false
        p.chartTitle = "Duplicates"
        p.chartScope = "of the duplicates"
        p.empty = "Press Find duplicates to compare the files in the selected folder."
        p.fill = { [unowned self] in self.fillDuplicates() }
        return p
    }

    func findDuplicates() {
        if let f = dupeFinder { f.cancel(); return }
        guard let sc = scope() else { pDupes.setCaption("Scan a drive or folder first."); return }
        let finder = DuplicateFinder()
        dupeFinder = finder
        dupeCacheNote = ""
        dupeScope = sc.fullPath
        let minSize = MainWindowController.dupeSizes[dupeMin.selectedIndex]
        btnFindDupes.title = "Stop"
        btnFindDupes.kind = .secondary
        dupeMin.isEnabled = false
        pDupes.bar?.relayout()
        pDupes.setCaption("Comparing files in \(Fmt.shorten(dupeScope, 50))...")
        dupeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, let f = self.dupeFinder else { return }
            let toRead = f.bytesToRead
            let pct = toRead > 0 ? 100 * Double(f.bytesRead) / Double(toRead) : 0
            let cached = f.filesFromCache
            self.pDupes.setCaption("Comparing files in \(Fmt.shorten(self.dupeScope, 50))...  \(Int(min(99, pct))) %  (\(Fmt.count(f.filesRead)) files read"
                + (cached > 0 ? ", \(Fmt.count(cached)) from the cache" : "") + ")  \(Fmt.shorten(f.current, 60))")
        }
        readInBackground({ finder.collect(sc, minSize) }, { [weak self] groups in
            DispatchQueue.global(qos: .userInitiated).async {
                finder.run(groups)
                DispatchQueue.main.async { self?.duplicatesDone(finder) }
            }
        })
    }

    private func duplicatesDone(_ finder: DuplicateFinder) {
        dupeTimer?.invalidate(); dupeTimer = nil
        dupeFinder = nil
        btnFindDupes.title = "Find duplicates"
        btnFindDupes.kind = .primary
        dupeMin.isEnabled = true
        pDupes.bar?.relayout()
        if finder.cancelled { pDupes.setCaption("Stopped."); onDupesFinished?(); return }
        dupeGroups = finder.groups
        let cached = finder.filesFromCache, read = finder.filesRead
        dupeCacheNote = cached + read == 0 ? "" : "  \(Fmt.count(cached)) file\(cached == 1 ? "" : "s") checked from the cache, \(Fmt.count(read)) read (\(Fmt.size(finder.bytesRead)))."
        fillDuplicates()
        statusLabel.stringValue = "Duplicates: \(Fmt.count(finder.groups.count)) group\(finder.groups.count == 1 ? "" : "s")." + dupeCacheNote
        onDupesFinished?()
    }

    /// True while the file is still in the scanned index (not deleted since).
    func stillIndexed(_ f: FileEntry) -> Bool {
        guard isAttached(f.dir), let list = f.dir.fileList else { return false }
        return list.contains { $0.name == f.name }
    }

    func fillDuplicates() {
        let p = pDupes!
        p.chartTitle = "Duplicates"
        guard var groups = dupeGroups else {
            if dupeFinder == nil {
                p.setCaption("Find files with the same content in the selected folder (" + (scope().map { Fmt.shorten($0.fullPath, 70) } ?? "nothing scanned yet") + ").")
            }
            p.setRows([], "Press Find duplicates to compare the files in the selected folder by content.\nHard links and files not downloaded from iCloud are not counted.")
            p.chartSub = ""
            if activePage === p { refreshChart() }
            return
        }
        // Files are matched by content; what they take follows the Size / Size on disk switch (sparse, compressed and
        // cloned copies can take far less on disk than their length). The newest copy (first) is the one kept.
        func extra(_ g: [FileEntry]) -> Int64 { g.dropFirst().reduce(0) { $0 + $1.size } }
        groups = groups.map { $0.filter { stillIndexed($0) } }.filter { $0.count > 1 }.sorted { extra($0) > extra($1) }
        dupeGroups = groups
        var rows: [ItemInfo] = []
        var free: Int64 = 0
        for g in groups {
            let each = g[0].size, wasted = extra(g)
            free += wasted
            let head = ItemInfo()
            head.isGroup = true
            head.name = "\(g.count) copies of \(g[0].name)"
            head.size = each; head.chartValue = wasted
            head.folder = Set(g.map { $0.dir.fullPath }).count == 1 ? "same folder" : ""
            head.cells = [head.name, Fmt.size(each), Fmt.size(wasted), head.folder, ""]
            let dirs = Set(g.map { $0.dir.fullPath })
            head.tip = "\(g[0].name)\n" + (dirs.count == 1 ? dirs.first! : "\(Fmt.count(dirs.count)) folders")
            rows.append(head)
            for f in g {
                let it = ItemInfo.forFile(f, 0)
                it.folder = f.dir.fullPath
                it.groupOf = head
                it.cells = [it.name, Fmt.size(f.size), "", it.folder, Fmt.date(f.modified)]
                rows.append(it)
            }
        }
        p.setRows(rows, "No duplicates found in \(dupeScope).")
        p.setCaption(groups.isEmpty ? "No duplicates found in \(Fmt.shorten(dupeScope, 80))." + dupeCacheNote
            : "\(Fmt.count(groups.count)) groups of identical files in \(Fmt.shorten(dupeScope, 60))  -  \(Fmt.size(free)) can be freed by keeping one copy of each. Newest copy first." + dupeCacheNote)
        p.chartSub = groups.isEmpty ? "" : Fmt.size(free) + " in extra copies"
        p.chartTotal = 0
        p.empty = "No duplicates found."
        if activePage === p { refreshChart() }
    }

    func selectExtraCopies() {
        let p = pDupes!
        var rows = IndexSet()
        var head: ItemInfo?
        var first = false
        for (i, it) in p.items.enumerated() {
            if it.isGroup { head = it; first = true; continue }
            guard let h = head, it.groupOf === h else { continue }
            if first { first = false; continue }          // keep the newest copy (listed first)
            rows.insert(i)
        }
        p.select(rows)
        window?.makeFirstResponder(p.table)
        lastView = p.table
        let size = rows.reduce(Int64(0)) { $0 + p.items[$1].size }
        statusLabel.stringValue = "Selected \(Fmt.count(rows.count)) extra copies (\(Fmt.size(size))). Add them to the delete list (⌘D) or delete them."
    }
}

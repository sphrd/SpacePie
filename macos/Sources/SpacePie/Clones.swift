import AppKit
import Darwin

/// APFS clones: an extra copy of a duplicate is replaced by a clone of the copy that is kept. Both paths stay separate,
/// independent files (changing one later does not change the other), but until then they share their data blocks, so
/// the extra copy's space is freed. Only on APFS and within one volume.
enum Cloner {
    /// File system type ("apfs", "hfs", ...) and mount point of the volume holding path.
    static func volume(_ path: String) -> (fsType: String, mount: String)? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let fs = withUnsafePointer(to: &s.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
        let mnt = withUnsafePointer(to: &s.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        return (fs, mnt)
    }

    /// Free bytes of the volume holding path (for the check that cloning did not cost space).
    static func freeBytes(_ path: String) -> Int64 {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return -1 }
        return Int64(s.f_bavail) * Int64(s.f_bsize)
    }

    /// Bytes of the file that no other file shares (APFS: ATTR_CMNEXT_PRIVATESIZE); nil when the volume can't tell.
    static func privateSize(_ path: String) -> Int64? {
        var req = attrlist()
        req.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        req.forkattr = 0x00000008                       // ATTR_CMNEXT_PRIVATESIZE
        var buf = [UInt8](repeating: 0, count: 64)
        let r = buf.withUnsafeMutableBytes { b -> Int32 in
            getattrlist(path, &req, b.baseAddress, b.count, UInt32(0x20 | 0x1))   // FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW
        }
        guard r == 0 else { return nil }
        let len = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        guard len >= 12 else { return nil }
        return buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
    }

    private static func readFull(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ n: Int) -> Int {
        var got = 0
        while got < n {
            let r = read(fd, buf + got, n - got)
            if r < 0 { if errno == EINTR { continue }; return -1 }
            if r == 0 { break }
            got += r
        }
        return got
    }

    /// Byte-for-byte comparison of two files.
    static func sameContent(_ a: String, _ b: String, cancelled: () -> Bool = { false }) -> Bool {
        let fa = open(a, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fa < 0 { return false }
        defer { close(fa) }
        let fb = open(b, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fb < 0 { return false }
        defer { close(fb) }
        _ = fcntl(fa, F_NOCACHE, 1)
        _ = fcntl(fb, F_NOCACHE, 1)
        let n = 1 << 20
        let ba = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 16)
        let bb = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 16)
        defer { ba.deallocate(); bb.deallocate() }
        while true {
            if cancelled() { return false }
            let ra = readFull(fa, ba, n), rb = readFull(fb, bb, n)
            if ra < 0 || rb < 0 || ra != rb { return false }
            if ra == 0 { return true }
            if memcmp(ba, bb, ra) != 0 { return false }
        }
    }

    static func xattrNames(_ path: String) -> [String] {
        let n = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard n > 0 else { return [] }
        var buf = [CChar](repeating: 0, count: n)
        let m = listxattr(path, &buf, n, XATTR_NOFOLLOW)
        guard m > 0 else { return [] }
        return buf[0..<m].split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    /// Why extra cannot be replaced by a clone of keep (nil = it can), without reading the files.
    static func blocker(keep: String, extra: String) -> String? {
        var sk = stat(), se = stat()
        guard lstat(keep, &sk) == 0 else { return "the copy to keep is gone" }
        guard lstat(extra, &se) == 0 else { return "it is gone" }
        guard (sk.st_mode & S_IFMT) == S_IFREG, (se.st_mode & S_IFMT) == S_IFREG else { return "not a regular file" }
        if sk.st_dev == se.st_dev && sk.st_ino == se.st_ino { return "the same file as the kept copy (a hard link)" }
        guard sk.st_dev == se.st_dev else { return "on another volume than the kept copy" }
        guard let v = volume(extra) else { return "its volume can't be read" }
        guard v.fsType == "apfs" else { return "\(v.mount) is \(v.fsType.uppercased()), not APFS" }
        guard sk.st_size == se.st_size else { return "its size changed" }
        if se.st_nlink > 1 { return "it has other hard links" }
        if se.st_uid != getuid() { return "it belongs to another user" }
        let locked = UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND) | UInt32(SF_IMMUTABLE) | UInt32(SF_APPEND)
        if se.st_flags & locked != 0 { return "it is locked" }
        if (se.st_flags | sk.st_flags) & UInt32(UF_COMPRESSED) != 0 { return "macOS compresses it" }
        if se.st_size > 0, let ps = privateSize(extra), ps == 0 { return "it already shares its space (a clone)" }
        return nil
    }

    /// Replaces extra by an APFS clone of keep: the contents are compared first, the clone is made under a temporary
    /// name in the same folder, gets extra's permissions, owner group, flags, extended attributes and dates, and is then
    /// renamed over extra (atomic). nil when done, else why not (nothing changed then).
    static func replace(keep: String, extra: String, cancelled: () -> Bool = { false }) -> String? {
        if let why = blocker(keep: keep, extra: extra) { return why }
        var se = stat()
        guard lstat(extra, &se) == 0 else { return "it is gone" }
        guard sameContent(keep, extra, cancelled: cancelled) else { return cancelled() ? "stopped" : "the contents differ" }
        var base = "." + PathUtil.name(extra)
        if base.utf8.count > 180 { base = String(base.prefix(60)) }
        let tmp = PathUtil.join(PathUtil.parent(extra), base + ".dsa-clone-" + String(UInt32.random(in: 0...UInt32.max), radix: 16))
        // COPYFILE_CLONE_FORCE: a clone or nothing (never a real copy).
        if copyfile(keep, tmp, nil, copyfile_flags_t(1 << 25)) != 0 {
            let e = errno
            unlink(tmp)
            return "the clone failed (" + String(cString: strerror(e)) + ")"
        }
        // The clone carries keep's metadata: replace it by extra's.
        for n in xattrNames(tmp) { _ = removexattr(tmp, n, XATTR_NOFOLLOW) }
        _ = copyfile(extra, tmp, nil, copyfile_flags_t((1 << 0) | (1 << 2)))      // COPYFILE_ACL | COPYFILE_XATTR
        _ = chown(tmp, uid_t.max, se.st_gid)
        _ = chmod(tmp, se.st_mode & 0o7777)
        _ = chflags(tmp, se.st_flags)
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = attrgroup_t(ATTR_CMN_CRTIME) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_ACCTIME)
        var times: [timespec] = [se.st_birthtimespec, se.st_mtimespec, se.st_atimespec]
        _ = times.withUnsafeMutableBytes { b -> Int32 in setattrlist(tmp, &al, b.baseAddress, b.count, UInt32(FSOPT_NOFOLLOW)) }
        // extra must not have changed meanwhile.
        var now = stat()
        guard lstat(extra, &now) == 0, now.st_ino == se.st_ino, now.st_size == se.st_size,
              now.st_mtimespec.tv_sec == se.st_mtimespec.tv_sec, now.st_mtimespec.tv_nsec == se.st_mtimespec.tv_nsec else {
            unlink(tmp)
            return "it changed while it was compared"
        }
        if rename(tmp, extra) != 0 {
            let e = errno
            unlink(tmp)
            return "it could not be replaced (" + String(cString: strerror(e)) + ")"
        }
        return nil
    }
}

/// One extra copy and the copy it becomes a clone of.
struct ClonePair {
    let keep: FileEntry
    let extra: FileEntry
}

/// Progress of a running "Replace with clones" (read by the progress strip's timer).
final class CloneJob {
    private let lock = NSLock()
    private var _stopped = false, _done = 0, _freed: Int64 = 0, _current = ""
    let total: Int
    init(_ total: Int) { self.total = total }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }
    var done: Int { lock.lock(); defer { lock.unlock() }; return _done }
    var freed: Int64 { lock.lock(); defer { lock.unlock() }; return _freed }
    var current: String { lock.lock(); defer { lock.unlock() }; return _current }
    func stop() { lock.lock(); _stopped = true; lock.unlock() }
    func begin(_ path: String) { lock.lock(); _current = path; lock.unlock() }
    func finished(_ freed: Int64) { lock.lock(); _done += 1; _freed += freed; lock.unlock() }
}

extension MainWindowController {
    /// The extra copies picked in Duplicates: a selected group means all copies but the newest; selected copies of a group
    /// become clones of the first copy of the group that is not selected (the newest when all are). Copies that can't be
    /// cloned are listed apart with the reason (skipped); reason explains why nothing can be done.
    func clonePlan() -> (pairs: [ClonePair], skipped: [String], reason: String?) {
        guard let p = pDupes else { return ([], [], nil) }
        var order: [ItemInfo] = []
        var whole = Set<ObjectIdentifier>()
        var picked: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]
        for it in p.selectedItems {
            guard let h = it.isGroup ? it : it.groupOf else { continue }
            let k = ObjectIdentifier(h)
            if !order.contains(where: { $0 === h }) { order.append(h) }
            if it.isGroup { whole.insert(k) } else { picked[k, default: []].insert(ObjectIdentifier(it)) }
        }
        if order.isEmpty { return ([], [], "Select duplicate groups, or press Select extra copies, to replace the extra copies with clones.") }
        var pairs: [ClonePair] = [], skipped: [String] = []
        var firstReason: String?
        for h in order {
            let members = p.items.filter { $0.groupOf === h && $0.file != nil }
            guard members.count > 1 else { continue }
            let sel = picked[ObjectIdentifier(h)] ?? []
            var keep = members[0]
            var extras = Array(members.dropFirst())
            if !whole.contains(ObjectIdentifier(h)) && !sel.isEmpty && sel.count < members.count,
               let k = members.first(where: { !sel.contains(ObjectIdentifier($0)) }) {
                keep = k
                extras = members.filter { sel.contains(ObjectIdentifier($0)) }
            }
            guard let kf = keep.file else { continue }
            for e in extras {
                guard let ef = e.file else { continue }
                if let why = Cloner.blocker(keep: kf.fullPath, extra: ef.fullPath) {
                    skipped.append(ef.fullPath + "  -  " + why)
                    if firstReason == nil { firstReason = why }
                } else {
                    pairs.append(ClonePair(keep: kf, extra: ef))
                }
            }
        }
        if pairs.isEmpty {
            let why = firstReason ?? "nothing to replace"
            return ([], skipped, "Replace with clones is not possible here: \(why). It works only on APFS volumes, for copies on the same volume as the kept copy.")
        }
        return (pairs, skipped, nil)
    }

    func updateCloneButton() {
        guard pDupes != nil else { return }
        if cloneJob != nil { btnClone.isEnabled = false; return }
        if activePage !== pDupes || busy || scanning || dupeFinder != nil {
            btnClone.isEnabled = false
            return
        }
        let plan = clonePlan()
        btnClone.isEnabled = !plan.pairs.isEmpty
        if let r = plan.reason { btnClone.tip = r }
        else {
            let total = plan.pairs.reduce(Int64(0)) { $0 + $1.extra.alloc }
            btnClone.tip = "Replace \(Fmt.count(plan.pairs.count)) extra cop\(plan.pairs.count == 1 ? "y" : "ies") with APFS clones of the kept copy: frees about \(Fmt.size(total)); every file stays a separate, independent file"
        }
    }

    /// The confirmation: not a danger prompt (nothing is lost); every extra copy on its own line with the copy it becomes a
    /// clone of.
    func cloneConfirmDialog(_ pairs: [ClonePair], _ skipped: [String]) -> PromptDialog {
        let n = pairs.count
        let total = pairs.reduce(Int64(0)) { $0 + $1.extra.alloc }
        let details = pairs.map { "\($0.extra.fullPath)   \(Fmt.size($0.extra.alloc))   (clone of \($0.keep.fullPath))" } + skipped.map { $0 + "   (left alone)" }
        let warning = skipped.isEmpty ? "" : "\(Fmt.count(skipped.count)) cop\(skipped.count == 1 ? "y is" : "ies are") left alone (reason on its line)."
        return PromptDialog(icon: .info, heading: "Replace \(Fmt.count(n)) extra cop\(n == 1 ? "y" : "ies") with clones?",
                            text: "Each extra copy becomes an APFS clone of the copy that is kept, which frees about \(Fmt.size(total)). Every path stays a separate, independent file: changing one later does not change the others. The contents are compared first; a copy that differs is left alone. No data is lost.",
                            warning: warning, details: details,
                            buttons: [("Replace with clones", .primary), ("Cancel", .secondary)], defaultIndex: 0, cancelIndex: 1)
    }

    /// Replace with clones: asks, then replaces the picked extra copies in the background behind the progress strip.
    /// done gets the replaced paths and the errors ("path  -  reason").
    func replaceSelectedWithClones(_ done: (([String], [String]) -> Void)? = nil) {
        if busy || scanning || cloneJob != nil { done?([], []); return }
        let plan = clonePlan()
        guard !plan.pairs.isEmpty else {
            if let r = plan.reason { alert("Nothing to replace with clones", r, details: plan.skipped) }
            done?([], [])
            return
        }
        if selfTestDir != nil || autoAccept { runClones(plan.pairs, done); return }
        cloneConfirmDialog(plan.pairs, plan.skipped).show(over: window) { i in
            if i == 0 { self.runClones(plan.pairs, done) } else { done?([], []) }
        }
    }

    func runClones(_ pairs: [ClonePair], _ done: (([String], [String]) -> Void)? = nil) {
        let job = CloneJob(pairs.count)
        cloneJob = job
        let freeBefore = Cloner.freeBytes(pairs[0].extra.fullPath)
        workBar.start("Replacing extra copies with clones...")
        workBar.cancelButton.onClick = { [weak self] in job.stop(); self?.workBar.cancelButton.isEnabled = false }
        layoutRoot()
        updateButtons()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let d = job.done
            self.workBar.set("Replacing with clones: \(Fmt.count(d)) of \(Fmt.count(job.total))  -  \(Fmt.size(job.freed)) freed"
                             + (job.stopped ? "  -  stopping..." : ""), Fmt.shorten(job.current, 160), Double(d) / Double(max(1, job.total)))
        }
        let work = pairs.map { ($0.keep.fullPath, $0.extra.fullPath, $0.extra.alloc) }
        DispatchQueue.global(qos: .userInitiated).async {
            var replaced: [String] = [], errors: [String] = []
            for (keep, extra, alloc) in work {
                if job.stopped { break }
                job.begin(extra)
                if let why = Cloner.replace(keep: keep, extra: extra, cancelled: { job.stopped }) {
                    errors.append(extra + "  -  " + why)
                    job.finished(0)
                } else {
                    replaced.append(extra)
                    job.finished(alloc)
                }
            }
            DispatchQueue.main.async {
                timer.invalidate()
                self.cloneJob = nil
                self.workBar.stop()
                self.layoutRoot()
                let freeAfter = Cloner.freeBytes(work[0].1)
                // The replaced copies leave the groups (they no longer take space of their own).
                let gone = Set(replaced)
                if var g = self.dupeGroups {
                    g = g.map { $0.filter { !gone.contains($0.fullPath) } }
                    self.dupeGroups = g
                }
                self.fillDuplicates()
                let n = replaced.count
                var status = "Replaced \(Fmt.count(n)) extra cop\(n == 1 ? "y" : "ies") with clones: \(Fmt.size(job.freed)) freed"
                if freeBefore >= 0 && freeAfter >= 0 { status += " (the volume has \(Fmt.delta(freeAfter - freeBefore)) free space now)" }
                status += errors.isEmpty ? "." : "; \(Fmt.count(errors.count)) left alone."
                if job.stopped { status += "  Stopped." }
                self.statusLabel.stringValue = status
                self.updateButtons()
                if !errors.isEmpty && self.selfTestDir == nil {
                    PromptDialog(icon: .warn, heading: "\(Fmt.count(errors.count)) cop\(errors.count == 1 ? "y was" : "ies were") left alone",
                                 text: "They were not replaced: nothing about them changed.", details: errors,
                                 buttons: [("OK", .primary)], defaultIndex: 0, cancelIndex: 0).show(over: self.window) { _ in }
                }
                done?(replaced, errors)
            }
        }
    }
}

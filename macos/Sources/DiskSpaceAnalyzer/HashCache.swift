import Foundation

/// Remembered content hashes for the duplicate finder, so a repeat search reads only new or changed files. A file is
/// known by its path, length, modification time (nanoseconds) and inode: any change makes it unknown. Each entry keeps
/// the hash of the first 64 KB and, once computed, of the whole file. Entries not seen for 90 days are dropped, at most
/// 2 million are kept (most recently seen first). Stored in ~/Library/Application Support/DiskSpaceAnalyzer/hashes.bin
/// (magic and version, then LZFSE: path, size, time, inode, which hashes, the 16-byte hashes, day last seen).
enum HashCache {
    struct Entry {
        var size: Int64
        var mtime: Int64
        var ino: UInt64
        var head: String?
        var full: String?
        var seen: UInt32
    }

    static let magic: UInt32 = 0x48415344      // "DSAH"
    static let version: UInt32 = 1
    static let maxEntries = 2_000_000
    static let keepDays: UInt32 = 90
    static var fileOverride: String?           // self-test

    private static let lock = NSLock()
    private static var map: [String: Entry]?
    private static var dirty = false

    static var path: String {
        if let f = fileOverride { return f }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory() + "/Library/Application Support"
        return base + "/DiskSpaceAnalyzer/hashes.bin"
    }

    static var today: UInt32 { UInt32(max(0, Date().timeIntervalSince1970 / 86400)) }

    static var count: Int { lock.lock(); defer { lock.unlock() }; ensureLoaded(); return map!.count }

    /// Forgets what is in memory (the file is read again on the next use).
    static func reset() { lock.lock(); map = nil; dirty = false; lock.unlock() }

    // Lock held.
    private static func ensureLoaded() {
        if map != nil { return }
        map = [:]
        guard let raw = FileManager.default.contents(atPath: path) else { return }
        var h = PackReader([UInt8](raw.prefix(8)))
        guard raw.count >= 8, h.u32() == magic, h.u32() == version,
              let body = try? (raw.subdata(in: 8..<raw.count) as NSData).decompressed(using: .lzfse) as Data else {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        var r = PackReader([UInt8](body))
        let n = Int(truncatingIfNeeded: r.uv())
        guard n >= 0, n <= r.remaining else { return }
        var m: [String: Entry] = [:]
        m.reserveCapacity(n)
        for _ in 0..<n {
            let p = r.str()
            let size = Int64(truncatingIfNeeded: r.uv())
            let mtime = r.sv()
            let ino = r.u64()
            let which = r.byte()
            let head = which & 1 != 0 ? Data(r.raw(16)).base64EncodedString() : nil
            let full = which & 2 != 0 ? Data(r.raw(16)).base64EncodedString() : nil
            let seen = UInt32(truncatingIfNeeded: r.uv())
            if r.failed { return }
            m[p] = Entry(size: size, mtime: mtime, ino: ino, head: head, full: full, seen: seen)
        }
        map = m
    }

    /// The known hashes of this exact version of a file (nil when unknown).
    static func lookup(_ path: String, _ size: Int64, _ mtime: Int64, _ ino: UInt64) -> (head: String?, full: String?) {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        guard var e = map![path], e.size == size, e.mtime == mtime, e.ino == ino else { return (nil, nil) }
        let t = today
        if e.seen != t { e.seen = t; map![path] = e; dirty = true }
        return (e.head, e.full)
    }

    static func store(_ path: String, _ size: Int64, _ mtime: Int64, _ ino: UInt64, head: String? = nil, full: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        var e = map![path] ?? Entry(size: size, mtime: mtime, ino: ino, head: nil, full: nil, seen: today)
        if e.size != size || e.mtime != mtime || e.ino != ino { e = Entry(size: size, mtime: mtime, ino: ino, head: nil, full: nil, seen: today) }
        if let h = head { e.head = h }
        if let f = full { e.full = f }
        e.seen = today
        map![path] = e
        dirty = true
    }

    /// Writes the cache when it changed: without entries older than 90 days, at most 2 million.
    static func save() {
        lock.lock()
        ensureLoaded()
        guard dirty, let m = map else { lock.unlock(); return }
        dirty = false
        lock.unlock()
        let oldest = today > keepDays ? today - keepDays : 0
        var kept = m.filter { $0.value.seen >= oldest }
        if kept.count > maxEntries {
            let newest = kept.sorted { $0.value.seen > $1.value.seen }.prefix(maxEntries)
            kept = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        var w = PackWriter()
        w.uv(UInt64(kept.count))
        for (p, e) in kept {
            let head = e.head.flatMap { Data(base64Encoded: $0) }.flatMap { $0.count == 16 ? [UInt8]($0) : nil }
            let full = e.full.flatMap { Data(base64Encoded: $0) }.flatMap { $0.count == 16 ? [UInt8]($0) : nil }
            w.str(p)
            w.uv(UInt64(max(0, e.size)))
            w.sv(e.mtime)
            w.u64(e.ino)
            let which: UInt8 = (head != nil ? 1 : 0) | (full != nil ? 2 : 0)
            w.byte(which)
            if let h = head { w.raw(h) }
            if let f = full { w.raw(f) }
            w.uv(UInt64(e.seen))
        }
        do {
            try FileManager.default.createDirectory(atPath: PathUtil.parent(path), withIntermediateDirectories: true)
            let packed = try (Data(w.bytes) as NSData).compressed(using: .lzfse) as Data
            var head = PackWriter()
            head.u32(magic)
            head.u32(version)
            var out = Data(head.bytes)
            out.append(packed)
            try out.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            lock.lock(); dirty = true; lock.unlock()
        }
    }
}

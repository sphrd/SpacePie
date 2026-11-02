import AppKit

/// One row of the System view.
final class SysItem {
    enum Kind { case snapshot, purgeable, backup, drive, note }
    let kind: Kind
    var name = "", meaning = ""
    var size: Int64 = -1             // -1 = unknown
    var percent: Double = -1         // of the drive (-1 = no bar)
    var date: Date?
    var path: String?                // a backup folder, a drive's mount point
    var snapshotDate = ""            // tmutil's date of a local snapshot (yyyy-MM-dd-HHmmss)
    var volume = ""                  // the drive a snapshot / purgeable space belongs to
    var level = 0                    // 0 fine, 1 amber (needs attention), 2 red (a problem)
    init(_ kind: Kind) { self.kind = kind }
    var canDelete: Bool { kind == .snapshot || (kind == .backup && path != nil) }
}

/// A group of the System view (an expandable head row).
final class SysGroup {
    let key: String, title: String, meaning: String
    var items: [SysItem] = []
    var expanded = true
    var size: Int64 = -1             // shown in the size column (-1 = none)
    var reclaim: Int64 = 0           // what deleting / macOS could free (the chart)
    init(_ key: String, _ title: String, _ meaning: String) { self.key = key; self.title = title; self.meaning = meaning }
}

/// System facts: Time Machine local snapshots (tmutil), purgeable space, iPhone/iPad backups, drives and their SMART
/// status (diskutil). The parsers are pure functions over the tools' text output, checked by the self-test with fixed
/// samples.
enum SystemInfo {
    static let lowBytes: Int64 = 10 * 1024 * 1024 * 1024
    static let lowShare = 0.10

    /// True when a volume has less than 10 % or less than 10 GB available (for important use).
    static func isLow(available: Int64, total: Int64) -> Bool {
        total > 0 && (available < lowBytes || Double(available) < lowShare * Double(total))
    }

    // MARK: tools

    /// Runs a tool and returns its exit status, standard output and standard error (status -1 when it could not run or
    /// timed out).
    static func run(_ tool: String, _ args: [String], timeout: Double = 30) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        let lock = NSLock()
        var o = Data(), e = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { let d = out.fileHandleForReading.readDataToEndOfFile(); lock.lock(); o = d; lock.unlock(); g.leave() }
        g.enter()
        DispatchQueue.global().async { let d = err.fileHandleForReading.readDataToEndOfFile(); lock.lock(); e = d; lock.unlock(); g.leave() }
        if g.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return (-1, "", "\(PathUtil.name(tool)) did not answer within \(Int(timeout)) s")
        }
        p.waitUntilExit()
        lock.lock(); defer { lock.unlock() }
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    // MARK: parsers

    struct LocalSnapshot: Equatable {
        var name: String
        var date: String          // yyyy-MM-dd-HHmmss, what tmutil deletelocalsnapshots takes
    }

    /// `tmutil listlocalsnapshots <mount>`: one snapshot name per line (com.apple.TimeMachine.<date>[.local]).
    static func parseLocalSnapshots(_ text: String) -> [LocalSnapshot] {
        var out: [LocalSnapshot] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("com.apple.TimeMachine."), let d = snapshotDate(line) else { continue }
            out.append(LocalSnapshot(name: line, date: d))
        }
        return out
    }

    /// The yyyy-MM-dd-HHmmss part of a snapshot name.
    static func snapshotDate(_ name: String) -> String? {
        guard let r = name.range(of: "[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}", options: .regularExpression) else { return nil }
        return String(name[r])
    }

    static func date(ofSnapshot d: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.date(from: d)
    }

    struct DiskInfo: Equatable {
        var device = "", volumeName = "", mountPoint = "", fileSystem = "", smart = "", solidState = "", protocolName = ""
    }

    /// `diskutil info <disk or mount point>`: "Key:   value" lines.
    static func parseDiskInfo(_ text: String) -> DiskInfo {
        var d = DiskInfo()
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = raw[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "device identifier": d.device = value
            case "volume name": d.volumeName = value
            case "mount point": d.mountPoint = value
            case "file system personality": d.fileSystem = value
            case "smart status": d.smart = value
            case "solid state": d.solidState = value
            case "protocol": d.protocolName = value
            default: break
            }
        }
        return d
    }

    struct ApfsSnapshot: Equatable {
        var name = "", xid = ""
        var purgeable: Bool?
        var limitsShrink = false
    }

    /// `diskutil apfs listSnapshots <volume>`: a block per snapshot ("Name:", "XID:", "Purgeable:", "NOTE: ... limits
    /// the minimum size ..."), drawn as a tree with |, +-- in front.
    static func parseApfsSnapshots(_ text: String) -> [ApfsSnapshot] {
        var out: [ApfsSnapshot] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw.drop(while: { "|+- \t".contains($0) }))
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "name": out.append(ApfsSnapshot(name: value))
            case "xid": if !out.isEmpty { out[out.count - 1].xid = value }
            case "purgeable": if !out.isEmpty { out[out.count - 1].purgeable = value.lowercased().hasPrefix("yes") }
            case "note": if !out.isEmpty && value.lowercased().contains("limits the minimum size") { out[out.count - 1].limitsShrink = true }
            default: break
            }
        }
        return out
    }

    /// Purgeable space of a volume: what macOS counts as available for important use beyond what is free right now.
    static func purgeable(_ path: String) -> Int64? {
        guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]),
              let important = v.volumeAvailableCapacityForImportantUsage, let free = v.volumeAvailableCapacity else { return nil }
        return max(0, important - Int64(free))
    }

    static let backupFolder = PathUtil.home + "/Library/Application Support/MobileSync/Backup"

    // MARK: gathering (background)

    /// Everything the System view lists, for the given drives (mount point, name).
    static func gather(_ drives: [(path: String, name: String)]) -> [SysGroup] {
        let apfs = drives.filter { Cloner.volume($0.path)?.fsType == "apfs" }

        // Time Machine local snapshots, per APFS volume (the same date on several volumes is one row per volume).
        let snaps = SysGroup("snapshots", "Time Machine local snapshots",
                             "Copies of the disk that Time Machine keeps on this Mac between backups. macOS deletes them by itself when space is needed; deleting them frees that space now.")
        var seenDates = Set<String>()
        for d in apfs {
            let r = run("/usr/bin/tmutil", ["listlocalsnapshots", d.path])
            let list = parseLocalSnapshots(r.out)
            if list.isEmpty { continue }
            let dataVolume = d.path == "/" && PathUtil.isDir("/System/Volumes/Data") ? "/System/Volumes/Data" : d.path
            let details = parseApfsSnapshots(run("/usr/sbin/diskutil", ["apfs", "listSnapshots", dataVolume]).out)
            for s in list where seenDates.insert(d.path + "\n" + s.date).inserted {
                let it = SysItem(.snapshot)
                it.snapshotDate = s.date
                it.volume = d.path
                it.date = date(ofSnapshot: s.date)
                it.name = "Snapshot " + (it.date.map { Fmt.date($0) } ?? s.date) + (apfs.count > 1 ? "  (\(d.name))" : "")
                var meaning = "Time Machine's copy of \(d.name) as it was then; its size is not reported by macOS."
                if let a = details.first(where: { $0.name == s.name }) {
                    if a.purgeable == true { meaning += " macOS can delete it by itself." }
                    if a.limitsShrink { meaning += " It keeps the disk's container from shrinking." }
                }
                it.meaning = meaning
                snaps.items.append(it)
            }
        }
        snaps.items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        if snaps.items.isEmpty {
            let n = SysItem(.note)
            n.name = "No local snapshots"
            n.meaning = "Time Machine keeps none on this Mac right now."
            snaps.items.append(n)
        }

        // Purgeable space.
        let purge = SysGroup("purgeable", "Purgeable space",
                             "Space macOS frees by itself when it is needed (caches, local snapshots, iCloud files that can be downloaded again). It already counts as available.")
        var purgeTotal: Int64 = 0
        for d in drives {
            guard let p = purgeable(d.path) else { continue }
            let (total, _) = MainWindowController.capacity(d.path)
            let it = SysItem(.purgeable)
            it.name = d.name
            it.volume = d.path
            it.path = d.path
            it.size = p
            it.percent = total > 0 ? 100 * Double(p) / Double(total) : -1
            it.meaning = p > 0 ? "macOS frees this by itself when space is needed; nothing to do." : "Nothing purgeable on this drive right now."
            purge.items.append(it)
            purgeTotal += p
        }
        purge.size = purgeTotal
        purge.reclaim = purgeTotal

        // iPhone and iPad backups (Finder / iTunes); the folder needs Full Disk Access.
        let backups = SysGroup("backups", "iPhone and iPad backups",
                               "Full backups of your devices made by Finder (or iTunes). Delete one only when you no longer need it, e.g. when the device backs up to iCloud.")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: backupFolder, isDirectory: &isDir) || !isDir.boolValue {
            let n = SysItem(.note)
            n.name = "No device backups"
            n.meaning = "There are no iPhone or iPad backups on this Mac."
            backups.items.append(n)
        } else if let names = try? fm.contentsOfDirectory(atPath: backupFolder) {
            var total: Int64 = 0
            let (volTotal, _) = MainWindowController.capacity(PathUtil.home)
            for nm in names.sorted() where !nm.hasPrefix(".") {
                let p = backupFolder + "/" + nm
                guard PathUtil.isDir(p) else { continue }
                let info = (NSDictionary(contentsOfFile: p + "/Info.plist") as? [String: Any]) ?? [:]
                let device = (info["Device Name"] as? String) ?? (info["Display Name"] as? String) ?? nm
                let product = (info["Product Name"] as? String) ?? (info["Product Type"] as? String) ?? ""
                let it = SysItem(.backup)
                it.path = p
                it.name = device + (product.isEmpty ? "" : "  (\(product))")
                it.date = info["Last Backup Date"] as? Date
                it.size = Scanner().run(p).size
                it.percent = volTotal > 0 ? 100 * Double(it.size) / Double(volTotal) : -1
                it.meaning = "Backup of \(device)" + (it.date.map { " from " + Fmt.day($0) } ?? "") + ". Delete moves it to the Trash."
                backups.items.append(it)
                total += it.size
            }
            backups.items.sort { $0.size > $1.size }
            backups.size = total
            backups.reclaim = total
            if backups.items.isEmpty {
                let n = SysItem(.note)
                n.name = "No device backups"
                n.meaning = "The backup folder is empty."
                backups.items.append(n)
            }
        } else {
            let n = SysItem(.note)
            n.name = "Backups not readable"
            n.level = 1
            n.meaning = "macOS protects the backup folder. Give Disk Space Analyzer Full Disk Access (button in the toolbar), then refresh."
            n.path = backupFolder
            backups.items.append(n)
        }

        // Drives: free space, file system and SMART status.
        let disks = SysGroup("drives", "Drives", "Every local drive: free space, file system and the disk's own health check (SMART).")
        for d in drives {
            let (total, free) = MainWindowController.capacity(d.path)
            let info = parseDiskInfo(run("/usr/sbin/diskutil", ["info", d.path]).out)
            let it = SysItem(.drive)
            it.name = d.name
            it.path = d.path
            it.volume = d.path
            it.size = max(0, total - free)
            it.percent = total > 0 ? 100 * Double(total - free) / Double(total) : -1
            let fs = !info.fileSystem.isEmpty ? info.fileSystem : (Cloner.volume(d.path)?.fsType.uppercased() ?? "")
            let smart = info.smart.isEmpty ? "unknown" : info.smart
            var meaning = "\(Fmt.size(free)) free of \(Fmt.size(total))" + (total > 0 ? " (\(Int((100 * Double(free) / Double(total)).rounded())) %)" : "")
                + (fs.isEmpty ? "" : "  -  \(fs)") + "  -  SMART: \(smart)"
            let s = smart.lowercased()
            if s.contains("fail") {
                it.level = 2
                meaning += ". The disk reports a problem: back up its data now."
            } else if !(s.contains("verified") || s.contains("not supported") || s == "unknown") {
                it.level = 1
            }
            if isLow(available: free, total: total) {
                it.level = max(it.level, 1)
                meaning += ". Low on space."
            }
            it.meaning = meaning
            disks.items.append(it)
        }
        return [snaps, purge, backups, disks]
    }
}

extension MainWindowController {
    func buildSystemPage() -> Page {
        btnSysRefresh.tip = "Look again"
        btnSysSuggest.tip = "Open Suggestions: what can be deleted to free space"
        btnSysDelete.tip = "Delete the selected local snapshots, or move the selected device backups to the Trash"
        btnSysDeleteAll.tip = "Delete every Time Machine local snapshot on this Mac"
        for b in [btnSysRefresh, btnSysSuggest, btnSysDelete, btnSysDeleteAll] { b.compact = true }
        btnSysSuggest.isHidden = true
        let bar = ActionBar([btnSysRefresh, btnSysSuggest, btnSysDelete, btnSysDeleteAll], right: [btnSysDelete, btnSysDeleteAll])
        bar.minRowHeight = 0
        // "What it means" right after Size, so it shows without scrolling in a narrow list.
        let p = Page("System", [Column("name", "Name", 230), Column("size", "Size", 84, true), Column("note", "What it means", 440),
                                Column("size", "% of drive", 110, true), Column("mod", "Date", 128)],
                     barColumn: 3, bar: bar)
        p.sortable = false
        p.chartTitle = "System"
        p.chartScope = "of what can be freed"
        p.empty = "Nothing found."
        p.headline.color = T.WARN_FG
        // Opened: shown at once, looked at again in the background when the last look is older than a minute.
        p.fill = { [unowned self] in
            if self.systemGroups == nil || Date().timeIntervalSince(self.systemLoadedAt) > 60 { self.loadSystem() } else { self.showSystem() }
        }
        p.table.onClickAt = { [unowned self] r, pt in self.systemClick(r, pt) }
        return p
    }

    /// Looks at snapshots, purgeable space, backups and drives in the background, then shows them.
    func loadSystem(_ done: (() -> Void)? = nil) {
        if let d = done { systemWaiters.append(d) }
        if systemLoading { return }
        systemLoading = true
        let p = pSystem!
        if systemGroups == nil {
            p.setCaption("Looking at local snapshots, purgeable space, device backups and drives...")
            p.setRows([], "Looking...")
            if activePage === p { rowSlice = [:]; chart.showLogo(p.chartTitle, "", "Looking...") }
        } else {
            p.setCaption("Looking again...")
        }
        updateButtons()
        let drives = roots.filter { $0.isDrive }.map { (path: $0.path, name: $0.displayName) }
        DispatchQueue.global(qos: .userInitiated).async {
            let groups = SystemInfo.gather(drives)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                for g in groups { if let o = self.systemGroups?.first(where: { $0.key == g.key }) { g.expanded = o.expanded } }
                self.systemGroups = groups
                self.systemLoading = false
                self.systemLoadedAt = Date()
                self.showSystem()
                let w = self.systemWaiters
                self.systemWaiters = []
                for f in w { f() }
            }
        }
    }

    /// The drive (mount point, name, available, total) that is low on space, if any: the startup disk first.
    func lowSpaceDrive() -> (path: String, name: String, free: Int64, total: Int64)? {
        for r in roots where r.isDrive {
            let (total, free) = MainWindowController.capacity(r.path)
            if SystemInfo.isLow(available: free, total: total) { return (r.path, r.displayName, free, total) }
        }
        return nil
    }

    static func lowSpaceText(_ name: String, _ free: Int64, _ total: Int64) -> String {
        "Low space on \(name): \(Fmt.size(free)) available of \(Fmt.size(total)) (\(Int((100 * Double(free) / Double(max(1, total))).rounded())) %)."
    }

    func showSystem() {
        let p = pSystem!
        guard let groups = systemGroups else { return }
        let keep = Set(p.selectedItems.compactMap { systemKey($0) })
        var rows: [ItemInfo] = []
        var reclaim: Int64 = 0
        for g in groups {
            let h = ItemInfo()
            h.isGroup = true
            h.sysGroup = g
            h.name = g.title
            h.size = max(0, g.size)
            h.chartValue = max(0, g.reclaim)
            h.hideBar = true
            h.chevron = g.expanded ? 1 : 0
            let count = g.items.filter { $0.kind != .note }.count
            let title = g.key == "purgeable" || count == 0 ? g.title : "\(g.title)  (\(Fmt.count(count)))"
            h.cells = [title, g.size >= 0 ? Fmt.size(g.size) : "", g.meaning, "", ""]
            h.tip = g.title + "\n" + g.meaning
            if g.items.contains(where: { $0.level == 2 }) { h.color = T.DANGER } else if g.items.contains(where: { $0.level == 1 }) { h.color = T.WARN_FG }
            reclaim += max(0, g.reclaim)
            rows.append(h)
            if !g.expanded { continue }
            for s in g.items {
                let it = ItemInfo()
                it.sys = s
                it.sysGroup = g
                it.groupOf = h
                it.name = s.name
                it.size = max(0, s.size)
                it.percent = max(0, s.percent)
                it.hideBar = s.percent < 0
                it.isSummary = s.kind == .note
                it.folderIcon = s.kind == .backup || s.kind == .drive || s.kind == .purgeable
                it.path = s.path
                it.modified = Int64(s.date?.timeIntervalSince1970 ?? 0)
                if s.kind == .backup, let path = s.path {
                    it.targets = [DeleteTarget(path: path, label: s.name, isDir: true, size: max(0, s.size))]
                }
                it.cells = [s.name, s.size >= 0 ? Fmt.size(s.size) : "—", s.meaning, s.percent >= 0 ? Fmt.pct(s.percent) : "", Fmt.date(it.modified)]
                it.tip = s.name + "\n" + (s.path ?? s.meaning)
                if s.level == 2 { it.color = T.DANGER } else if s.level == 1 { it.color = T.WARN_FG }
                rows.append(it)
            }
        }
        p.setRows(rows, "Nothing found.", keepOrder: true)
        if !keep.isEmpty {
            var sel = IndexSet()
            for (i, it) in p.items.enumerated() { if let k = systemKey(it), keep.contains(k) { sel.insert(i) } }
            p.select(sel)
        }
        let low = lowSpaceDrive()
        p.setHeadline(low.map { MainWindowController.lowSpaceText($0.name, $0.free, $0.total) + "  See Suggestions for what can be deleted." } ?? "")
        let snaps = groups.first { $0.key == "snapshots" }?.items.filter { $0.kind == .snapshot }.count ?? 0
        let backups = groups.first { $0.key == "backups" }?.items.filter { $0.kind == .backup } ?? []
        let purge = groups.first { $0.key == "purgeable" }?.size ?? 0
        let drives = groups.first { $0.key == "drives" }?.items.count ?? 0
        p.setCaption("\(Fmt.count(snaps)) local snapshot\(snaps == 1 ? "" : "s")  -  \(Fmt.size(max(0, purge))) purgeable  -  \(Fmt.count(backups.count)) device backup\(backups.count == 1 ? "" : "s")"
                     + (backups.isEmpty ? "" : " (\(Fmt.size(backups.reduce(Int64(0)) { $0 + max(0, $1.size) })))") + "  -  \(Fmt.count(drives)) drive\(drives == 1 ? "" : "s").  Expand a group to see its items.")
        p.chartSub = Fmt.size(reclaim) + " can be freed (purgeable and backups)"
        p.chartTotal = 0
        p.empty = "Nothing found."
        updateButtons()
        if activePage === p { refreshChart() }
    }

    private func systemKey(_ it: ItemInfo) -> String? {
        if let s = it.sys { return "i\n" + (it.sysGroup?.key ?? "") + "\n" + s.name + "\n" + (s.path ?? s.snapshotDate) }
        if let g = it.sysGroup { return "g\n" + g.key }
        return nil
    }

    /// The selected snapshots and backups.
    var selectedSystemItems: [SysItem] {
        guard pSystem != nil else { return [] }
        return pSystem.selectedItems.compactMap { $0.sys }.filter { $0.canDelete }
    }

    var allLocalSnapshots: [SysItem] { systemGroups?.first { $0.key == "snapshots" }?.items.filter { $0.kind == .snapshot } ?? [] }

    func updateSystemButtons() {
        let idle = !busy && !scanning && !systemLoading
        btnSysRefresh.isEnabled = !systemLoading
        btnSysDelete.isEnabled = idle && !selectedSystemItems.isEmpty
        btnSysDeleteAll.isEnabled = idle && !allLocalSnapshots.isEmpty
        let low = lowSpaceDrive() != nil
        if btnSysSuggest.isHidden == low {
            btnSysSuggest.isHidden = !low
            pSystem.bar?.relayout()
        }
    }

    func systemClick(_ row: Int, _ pt: NSPoint) -> Bool {
        let p = pSystem!
        guard row < p.items.count, let g = p.items[row].sysGroup, p.items[row].groupOf == nil,
              let ci = p.table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "c0" }) else { return false }
        let x = pt.x - p.table.rect(ofColumn: ci).minX
        if x >= ListCell.chevronX - 3 && x < ListCell.chevronX + 17 { g.expanded.toggle(); showSystem(); return true }
        return false
    }

    func expandSystem(_ rows: [ItemInfo], _ open: Bool?) {
        var changed = false
        for it in rows where it.groupOf == nil {
            guard let g = it.sysGroup else { continue }
            let to = open ?? !g.expanded
            if g.expanded != to { g.expanded = to; changed = true }
        }
        if changed { showSystem() }
    }

    func systemKeyDown(_ e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) || e.modifierFlags.contains(.control) { return false }
        let sel = pSystem.selectedItems
        if sel.isEmpty { return false }
        switch e.keyCode {
        case 123: expandSystem(sel, false); return true
        case 124: expandSystem(sel, true); return true
        default: return false
        }
    }

    func showSuggestionsTab() {
        if let i = pages.firstIndex(where: { $0 === pSuggest }) { viewTabs.selectedIndex = i }
    }

    // MARK: deleting snapshots and backups

    /// The confirmation (danger): snapshots are deleted for good, backups go to the Trash.
    func systemDeleteDialog(_ items: [SysItem]) -> PromptDialog {
        let snaps = items.filter { $0.kind == .snapshot }, backs = items.filter { $0.kind == .backup }
        var text: [String] = []
        if !snaps.isEmpty { text.append("Local snapshots are deleted for good; Time Machine's backups on the backup disk stay.") }
        if !backs.isEmpty {
            let size = backs.reduce(Int64(0)) { $0 + max(0, $1.size) }
            text.append("Device backups (\(Fmt.size(size))) are moved to the Trash; the space is freed when the Trash is emptied.")
        }
        let n = items.count
        let heading = !backs.isEmpty && snaps.isEmpty ? "Move \(Fmt.count(n)) device backup\(n == 1 ? "" : "s") to the Trash?"
            : !snaps.isEmpty && backs.isEmpty ? "Delete \(Fmt.count(n)) local snapshot\(n == 1 ? "" : "s")?" : "Delete \(Fmt.count(n)) items?"
        let details = items.map { s -> String in
            s.kind == .snapshot ? "Local snapshot \(s.snapshotDate) on \(s.volume)" : (s.path ?? s.name) + "   " + Fmt.size(max(0, s.size)) + "   " + s.name
        }
        let label = snaps.isEmpty ? "Move to Trash" : "Delete"
        return PromptDialog(icon: .danger, heading: heading, text: text.joined(separator: " "), details: details,
                            buttons: [(label, .danger), ("Cancel", .secondary)],
                            defaultIndex: 1, cancelIndex: 1)
    }

    func deleteSelectedSystemItems() { deleteSystemItems(selectedSystemItems) }
    func deleteAllLocalSnapshots() { deleteSystemItems(allLocalSnapshots) }

    func deleteSystemItems(_ items: [SysItem], _ done: (([String]) -> Void)? = nil) {
        if items.isEmpty || busy || scanning { done?([]); return }
        let go = { [unowned self] in
            self.deleteSnapshots(items.filter { $0.kind == .snapshot }) { errors in
                let backs = items.filter { $0.kind == .backup && $0.path != nil }
                let finish = { [unowned self] (more: [String]) in
                    let all = errors + more
                    self.loadSystem()
                    self.updateDriveLabel()
                    if !errors.isEmpty && self.selfTestDir == nil {
                        self.alert("\(Fmt.count(errors.count)) local snapshot\(errors.count == 1 ? "" : "s") could not be deleted",
                                   "tmutil refused (deleting local snapshots can need an administrator). Open Terminal and run: sudo tmutil deletelocalsnapshots / "
                                   + "- or leave them: macOS deletes them by itself when space is needed.", details: errors)
                    }
                    done?(all)
                }
                if backs.isEmpty { finish([]); return }
                let targets = backs.map { DeleteTarget(path: $0.path!, label: $0.name, isDir: true, size: max(0, $0.size)) }
                self.runDelete(targets, trash: true) { job in finish(job?.errors ?? []) }
            }
        }
        if selfTestDir != nil || autoAccept { go(); return }
        systemDeleteDialog(items).show(over: window) { i in if i == 0 { go() } else { done?([]) } }
    }

    /// tmutil deletelocalsnapshots <date> for each snapshot, behind the red delete strip (Stop ends after the current one).
    private func deleteSnapshots(_ snaps: [SysItem], _ then: @escaping ([String]) -> Void) {
        let dates = Array(Set(snaps.map { $0.snapshotDate })).sorted()
        if dates.isEmpty { then([]); return }
        let stop = StopFlag()
        sysStop = stop
        setBusy(true)
        deleteBar.set("Deleting local snapshots: 0 of \(Fmt.count(dates.count))", "", 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var errors: [String] = []
            var deleted = 0
            for (i, d) in dates.enumerated() {
                if stop.stopped { break }
                DispatchQueue.main.async {
                    self.deleteBar.set("Deleting local snapshots: \(Fmt.count(i)) of \(Fmt.count(dates.count))" + (stop.stopped ? "  -  stopping..." : ""),
                                       "tmutil deletelocalsnapshots \(d)", Double(i) / Double(dates.count))
                }
                let r = SystemInfo.run("/usr/bin/tmutil", ["deletelocalsnapshots", d], timeout: 300)
                if r.status == 0 { deleted += 1 }
                else {
                    let msg = (r.err.isEmpty ? r.out : r.err).split(whereSeparator: { $0 == "\n" }).first.map { String($0) } ?? "exit code \(r.status)"
                    errors.append("Local snapshot \(d)  -  \(msg)")
                }
            }
            DispatchQueue.main.async {
                self.sysStop = nil
                self.setBusy(false)
                self.statusLabel.stringValue = "Deleted \(Fmt.count(deleted)) local snapshot\(deleted == 1 ? "" : "s")"
                    + (errors.isEmpty ? "." : "; \(Fmt.count(errors.count)) could not be deleted.") + (stop.stopped ? "  Stopped." : "")
                then(errors)
            }
        }
    }

    // MARK: low space

    /// After a scan of a drive (once per session per volume): an amber status line with Show suggestions when the
    /// startup disk or the scanned drive has less than 10 % or 10 GB available.
    func checkLowSpace(_ r: ScanRoot?) {
        if selfTestDir != nil { return }
        var candidates = roots.filter { $0.isSystem }
        if let r = r, r.isDrive, !candidates.contains(where: { $0 === r }) { candidates.append(r) }
        for c in candidates {
            let (total, free) = MainWindowController.capacity(c.path)
            guard SystemInfo.isLow(available: free, total: total), lowWarned.insert(PathUtil.trim(c.path)).inserted else { continue }
            showLowSpaceStatus(MainWindowController.lowSpaceText(c.displayName, free, total))
            return
        }
    }

    func showLowSpaceStatus(_ text: String) {
        lowSpaceText = text
        statusLabel.stringValue = text
        statusLabel.textColor = T.WARN_FG
        lowSpaceLink.isHidden = false
        layoutStatus()
        updateButtons()
    }

    /// The amber status line goes back to normal once another message replaces it.
    func checkLowSpaceStatus() {
        guard !lowSpaceLink.isHidden, statusLabel.stringValue != lowSpaceText else { return }
        statusLabel.textColor = T.MUTED
        lowSpaceLink.isHidden = true
        layoutStatus()
    }
}

/// A stop request shared with a background loop.
final class StopFlag {
    private let lock = NSLock()
    private var value = false
    var stopped: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

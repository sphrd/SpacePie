import AppKit
import Darwin

/// Fixed outputs of tmutil and diskutil for the parser checks.
enum SelfTestSamples {
    static let tmutil = """
    Snapshots for disk /:
    com.apple.TimeMachine.2026-10-30-093012.local
    com.apple.TimeMachine.2026-11-01-180455.local
    """

    static let tmutilOld = """
    com.apple.TimeMachine.2019-11-02-101530
    """

    static let diskutilInfo = """
       Device Identifier:         disk3s1s1
       Device Node:               /dev/disk3s1s1
       Whole:                     No
       Part of Whole:             disk3

       Volume Name:               Macintosh HD
       Mounted:                   Yes
       Mount Point:               /

       Partition Type:            41504653-0000-11AA-AA11-00306543ECAC
       File System Personality:   APFS
       Type (Bundle):             apfs
       Name (User Visible):       APFS
       Owners:                    Enabled

       OS Can Be Installed:       No
       Booter Disk:               disk3s2
       Recovery Disk:             disk3s3
       Media Type:                Generic
       Protocol:                  Apple Fabric
       SMART Status:              Verified
       Volume UUID:               5D2E9C2A-1B3C-4D5E-8F90-0A1B2C3D4E5F

       Disk Size:                 494.4 GB (494384795648 Bytes) (exactly 965595304 512-Byte-Units)
       Container Free Space:      201.3 GB (201327890432 Bytes) (exactly 393218536 512-Byte-Units)

       Device Location:           Internal
       Removable Media:           Fixed

       Solid State:               Yes
    """

    static let diskutilFailing = """
       Device Identifier:         disk5s1
       Volume Name:               Backup
       Mount Point:               /Volumes/Backup
       File System Personality:   ExFAT
       Protocol:                  USB
       SMART Status:              Failing
       Solid State:               No
    """

    static let apfsSnapshots = """
    Snapshots for disk3s5 (2 found)
    |
    +-- 9D8E5C0A-1B2C-4D3E-8F90-1A2B3C4D5E6F
    |   Name:        com.apple.TimeMachine.2026-10-30-093012.local
    |   XID:         1234567
    |   Purgeable:   Yes
    |
    +-- 0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0
        Name:        com.apple.TimeMachine.2026-11-01-180455.local
        XID:         1234999
        Purgeable:   No
        NOTE:        This snapshot limits the minimum size of APFS Container disk3
    """
}

/// Self-test of the System view, the duplicate hash cache, Replace with clones and the fast restart from a snapshot.
extension SelfTestRun {
    /// Differences between two trees (sizes, counts, folder and file names); empty when they are equal.
    static func treeDiffs(_ a: DirNode, _ b: DirNode, _ path: String = "") -> [String] {
        var out: [String] = []
        if a.bytes != b.bytes || a.alloc != b.alloc || a.files != b.files || a.dirs != b.dirs {
            out.append("\(path.isEmpty ? "/" : path): \(a.bytes) B, \(a.alloc) on disk, \(a.files) files, \(a.dirs) folders vs \(b.bytes), \(b.alloc), \(b.files), \(b.dirs)")
        }
        let fa = (a.fileList ?? []).map { "\($0.name) \($0.bytes)" }.sorted(), fb = (b.fileList ?? []).map { "\($0.name) \($0.bytes)" }.sorted()
        if fa != fb { out.append("\(path.isEmpty ? "/" : path): files [\(fa.joined(separator: ", "))] vs [\(fb.joined(separator: ", "))]") }
        let ka = Set(a.children.map { $0.name }), kb = Set(b.children.map { $0.name })
        if ka != kb { out.append("\(path.isEmpty ? "/" : path): folders \(ka.sorted()) vs \(kb.sorted())") }
        for c in a.children { if let d = b.child(c.name) { out += treeDiffs(c, d, path + "/" + c.name) } }
        return out
    }

    func addFeatureChecks() {
        let w = self.w
        let fm = FileManager.default

        // MARK: System view
        steps.then {
            let want = ["Contents", "Suggestions", "Apps", "System", "Files", "File types", "Duplicates", "Changes"]
                + (MainWindowController.deleteListInRail ? ["Delete list"] : [])
            let i = w.pages.firstIndex { $0 === w.pSystem } ?? -1
            self.check(i == 3 && w.pages[2] === w.pApps && w.viewTabs.titles.map { NavRail.split($0).label } == w.railPages.map { $0.title }
                       && w.viewTabs.titles.map { NavRail.split($0).label } == want
                       && w.railPages.contains { $0 === w.pBasket } == MainWindowController.deleteListInRail,
                       "system: the System view comes right after Apps in the rail; the Delete list is last only while it is in the rail (\(w.viewTabs.titles.joined(separator: ", ")))")
            let snaps = SystemInfo.parseLocalSnapshots(SelfTestSamples.tmutil)
            self.check(snaps.map { $0.date } == ["2026-10-30-093012", "2026-11-01-180455"] && snaps.first?.name == "com.apple.TimeMachine.2026-10-30-093012.local"
                       && SystemInfo.parseLocalSnapshots(SelfTestSamples.tmutilOld).map { $0.date } == ["2019-11-02-101530"]
                       && SystemInfo.parseLocalSnapshots("Snapshots for disk /:\n").isEmpty
                       && SystemInfo.date(ofSnapshot: "2026-10-30-093012") != nil,
                       "system: tmutil listlocalsnapshots sample parsed (\(snaps.map { $0.date }.joined(separator: ", ")))")
            let di = SystemInfo.parseDiskInfo(SelfTestSamples.diskutilInfo)
            self.check(di.smart == "Verified" && di.fileSystem == "APFS" && di.device == "disk3s1s1" && di.mountPoint == "/" && di.volumeName == "Macintosh HD"
                       && di.solidState == "Yes" && di.protocolName == "Apple Fabric",
                       "system: diskutil info sample parsed (SMART \(di.smart), \(di.fileSystem), \(di.device) at \(di.mountPoint), \(di.protocolName))")
            let bad = SystemInfo.parseDiskInfo(SelfTestSamples.diskutilFailing)
            self.check(bad.smart == "Failing" && bad.fileSystem == "ExFAT" && bad.mountPoint == "/Volumes/Backup",
                       "system: a failing disk's sample parsed (SMART \(bad.smart), \(bad.fileSystem))")
            let aps = SystemInfo.parseApfsSnapshots(SelfTestSamples.apfsSnapshots)
            self.check(aps.count == 2 && aps[0].name == "com.apple.TimeMachine.2026-10-30-093012.local" && aps[0].xid == "1234567" && aps[0].purgeable == true
                       && !aps[0].limitsShrink && aps[1].xid == "1234999" && aps[1].purgeable == false && aps[1].limitsShrink,
                       "system: diskutil apfs listSnapshots sample parsed (\(aps.count) snapshots, purgeable \(aps.map { $0.purgeable == true ? "yes" : "no" }.joined(separator: "/")))")
            let gb: Int64 = 1 << 30
            self.check(SystemInfo.isLow(available: 9 * gb, total: 1000 * gb) && SystemInfo.isLow(available: 40 * gb, total: 500 * gb)
                       && !SystemInfo.isLow(available: 60 * gb, total: 500 * gb) && !SystemInfo.isLow(available: 0, total: 0),
                       "system: low space = under 10 GB or under 10 % available")
            if i >= 0 { w.pageIndex = i }
        }
        steps.waitUntil(120) { w.systemGroups != nil && !w.systemLoading }
        steps.then {
            let groups = w.systemGroups ?? []
            let drives = groups.first { $0.key == "drives" }?.items ?? []
            let purge = groups.first { $0.key == "purgeable" }?.items ?? []
            let snaps = groups.first { $0.key == "snapshots" }?.items ?? []
            let backups = groups.first { $0.key == "backups" }?.items ?? []
            let rootDrive = drives.first { $0.path == "/" }
            self.check(groups.map { $0.key } == ["snapshots", "purgeable", "backups", "drives"] && rootDrive != nil && rootDrive!.size > 0,
                       "system: \(groups.map { $0.title }.joined(separator: ", ")); drive row for / (\(rootDrive?.meaning ?? "missing"))")
            let rootPurge = purge.first { $0.volume == "/" }
            self.check(rootPurge != nil && rootPurge!.size >= 0 && purge.allSatisfy { $0.size >= 0 },
                       "system: purgeable space of / is \(rootPurge.map { Fmt.size($0.size) } ?? "missing") (>= 0)")
            self.check(!snaps.isEmpty && !backups.isEmpty,
                       "system: local snapshots: \(snaps.map { $0.name }.joined(separator: ", ")); device backups: \(backups.map { $0.name }.joined(separator: ", "))")
            let rows = w.pSystem.items
            self.check(rows.filter { $0.groupOf == nil }.count == 4 && rows.contains { $0.sys?.kind == .drive } && !w.pSystem.caption.text.isEmpty,
                       "system: \(rows.count) rows; caption \"\(w.pSystem.caption.text)\"")
            let fake = SysItem(.snapshot)
            fake.snapshotDate = "2026-10-30-093012"
            fake.volume = "/"
            let d = w.systemDeleteDialog([fake])
            self.check(d.icon == .danger && d.buttonKinds.first == .danger && d.buttonTitles[d.defaultIndex] == "Cancel" && d.heading == "Delete 1 local snapshot?"
                       && d.detailLines == ["Local snapshot 2026-10-30-093012 on /"],
                       "system: delete confirmation \"\(d.heading)\" (danger button, Cancel the default)")
        }

        // MARK: Duplicate hash cache
        steps.then {
            let hd = self.dir + "-hash"
            try? fm.removeItem(atPath: hd)
            try? fm.createDirectory(atPath: hd, withIntermediateDirectories: true)
            var g = SystemRandomNumberGenerator()
            func random(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }) }
            let same = random(200_000)
            for n in ["h1", "h2", "h3"] { fm.createFile(atPath: hd + "/\(n).bin", contents: same) }
            fm.createFile(atPath: hd + "/h4.bin", contents: random(200_000))
            HashCache.reset()
            func search() -> (DuplicateFinder, [[String]]) {
                let scope = Scanner().run(hd)
                return withExtendedLifetime(scope) { () -> (DuplicateFinder, [[String]]) in
                    let f = DuplicateFinder()
                    f.run(f.collect(scope, 1))
                    let groups = f.groups.map { $0.map { $0.name }.sorted() }.sorted { ($0.first ?? "") < ($1.first ?? "") }
                    return (f, groups)
                }
            }
            let (f1, g1) = search()
            self.check(g1 == [["h1.bin", "h2.bin", "h3.bin"]] && f1.filesRead == 4 && f1.bytesRead == 4 * 65536 + 3 * 200_000 && f1.filesFromCache == 0,
                       "hash cache: first search read \(f1.filesRead) files (\(f1.bytesRead) bytes), groups \(g1)")
            HashCache.reset()          // read back from hashes.bin, as after a restart
            let (f2, g2) = search()
            self.check(g2 == g1 && f2.bytesRead == 0 && f2.filesRead == 0 && f2.filesFromCache == 4 && PathUtil.exists(HashCache.path),
                       "hash cache: second search read \(f2.bytesRead) bytes, \(f2.filesFromCache) files from the cache (\(HashCache.count) entries in \(PathUtil.name(HashCache.path))), same groups")
            var changed = same
            changed[0] ^= 0xff
            fm.createFile(atPath: hd + "/h2.bin", contents: changed)
            let (f3, g3) = search()
            self.check(g3 == [["h1.bin", "h3.bin"]] && f3.filesRead == 1 && f3.bytesRead == 65536 && f3.filesFromCache == 3,
                       "hash cache: after h2.bin changed only it was read (\(f3.filesRead) file, \(f3.bytesRead) bytes; \(f3.filesFromCache) from the cache), groups \(g3)")
            try? fm.removeItem(atPath: hd)
        }

        // MARK: Replace with clones (APFS)
        steps.then {
            let cd = self.dir + "-clone"
            try? fm.removeItem(atPath: cd)
            try? fm.createDirectory(atPath: cd, withIntermediateDirectories: true)
            var g = SystemRandomNumberGenerator()
            let big = Data((0..<(4 << 20)).map { _ in UInt8.random(in: 0...255, using: &g) })
            let keep = cd + "/keep.bin", extra = cd + "/extra.bin"
            fm.createFile(atPath: keep, contents: big)
            fm.createFile(atPath: extra, contents: big)
            chmod(keep, 0o644)
            chmod(extra, 0o600)
            let tag: [UInt8] = Array("kept".utf8)
            _ = setxattr(extra, "com.example.dsa", tag, tag.count, 0, 0)
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: extra)
            sync()
            let fs = Cloner.volume(cd)?.fsType ?? "?"
            let privBefore = Cloner.privateSize(extra)
            var before = stat()
            lstat(extra, &before)
            let freeBefore = Cloner.freeBytes(cd)
            let why = Cloner.replace(keep: keep, extra: extra)
            sync()
            let freeAfter = Cloner.freeBytes(cd)
            let privAfter = Cloner.privateSize(extra)
            var after = stat()
            lstat(extra, &after)
            let attrs = Cloner.xattrNames(extra)
            let shared = privAfter.map { $0 == 0 } ?? (freeAfter + (1 << 20) >= freeBefore)
            self.check(fs == "apfs" && why == nil && PathUtil.exists(keep) && PathUtil.exists(extra) && Cloner.sameContent(keep, extra) && shared,
                       "clones: extra.bin replaced by a clone of keep.bin on \(fs) (\(why ?? "ok")); both exist with the same content; private size of extra.bin \(privBefore.map { Fmt.size($0) } ?? "?") -> \(privAfter.map { Fmt.size($0) } ?? "?"); volume free space \(Fmt.delta(freeAfter - freeBefore))")
            self.check(after.st_mode & 0o7777 == 0o600 && after.st_mtimespec.tv_sec == 1_600_000_000 && attrs.contains("com.example.dsa") && after.st_ino != before.st_ino,
                       "clones: the replaced copy kept its permissions (\(String(after.st_mode & 0o7777, radix: 8))), date (\(after.st_mtimespec.tv_sec)) and extended attributes (\(attrs.joined(separator: ", ")))")
            // Independent files: changing one leaves the other as it was.
            if let h = FileHandle(forWritingAtPath: keep) { h.write(Data([1, 2, 3])); h.closeFile() }
            let other = fm.contents(atPath: extra)
            self.check(other == big && !Cloner.sameContent(keep, extra) && Cloner.blocker(keep: keep, extra: keep) != nil,
                       "clones: still two independent files (changing keep.bin did not change extra.bin)")
            try? fm.removeItem(atPath: cd)
        }
        // Through the Duplicates view: the group of dup1.bin / dup2.bin selected, the button enabled, the prompt, the result.
        steps.then {
            if let r = self.root { w.selectDir(r) }
            w.dupeMin.selectedIndex = 3
            w.pageIndex = w.pages.firstIndex { $0 === w.pDupes } ?? 6
            w.findDuplicates()
        }
        steps.waitUntil(60) { w.dupeFinder == nil }
        steps.add { next in
            let p = w.pDupes!
            self.check(p.caption.text.contains("checked from the cache"), "hash cache: Duplicates caption \"\(p.caption.text)\"")
            p.select(IndexSet())
            w.updateButtons()
            let none = !w.btnClone.isEnabled && (w.btnClone.tip ?? "").hasPrefix("Select duplicate groups")
            guard let hi = p.items.firstIndex(where: { $0.isGroup }) else {
                self.check(false, "clones: no duplicate group in the Duplicates view"); next(); return
            }
            p.select(IndexSet(integer: hi))
            w.updateButtons()
            let plan = w.clonePlan()
            self.check(none && w.btnClone.isEnabled && plan.pairs.count == 1 && plan.reason == nil,
                       "clones: Replace with clones disabled without a selection, enabled for the selected group (\(w.btnClone.tip ?? ""))")
            guard let pair = plan.pairs.first else { next(); return }
            let d = w.cloneConfirmDialog(plan.pairs, [])
            self.check(d.icon == .info && d.buttonKinds.first == .primary && d.buttonTitles.first == "Replace with clones" && d.heading == "Replace 1 extra copy with clones?"
                       && d.detailLines.count == 1 && d.detailLines[0].hasPrefix(pair.extra.fullPath) && d.window?.backgroundColor == T.BG,
                       "clones: themed confirmation \"\(d.heading)\", not a danger prompt (\(d.detailLines.first ?? ""))")
            let keep = pair.keep.fullPath, extra = pair.extra.fullPath
            w.replaceSelectedWithClones { replaced, errors in
                self.check(replaced == [extra] && errors.isEmpty && PathUtil.exists(keep) && PathUtil.exists(extra) && Cloner.sameContent(keep, extra)
                           && (Cloner.privateSize(extra) ?? 0) == 0 && w.statusLabel.stringValue.hasPrefix("Replaced 1 extra copy with clones"),
                           "clones: Duplicates view replaced \(PathUtil.name(extra)) by a clone of \(PathUtil.name(keep)); status \"\(w.statusLabel.stringValue)\"")
                let again = Cloner.blocker(keep: keep, extra: extra)
                self.check(again == "it already shares its space (a clone)", "clones: a clone is not replaced again (\(again ?? "nil"))")
                next()
            }
        }

        // MARK: Fast restart from a snapshot
        // Timing on a bigger tree: a full scan vs saving and loading its snapshot.
        steps.add { next in
            let big = "/Applications"
            DispatchQueue.global(qos: .userInitiated).async {
                let t0 = Date()
                let tree = Scanner().run(big)
                let scanS = Date().timeIntervalSince(t0)
                var info = Snapshot.infoNow(big)
                info.scanSeconds = scanS
                let t1 = Date()
                let ok = (try? Snapshot.write(Snapshot.serialize(tree, info), big)) != nil
                let saveS = Date().timeIntervalSince(t1)
                let bytes = (try? fm.attributesOfItem(atPath: Snapshot.file(for: big))[.size] as? Int64) ?? -1
                let t2 = Date()
                let loaded = Snapshot.load(big)
                let loadS = Date().timeIntervalSince(t2)
                DispatchQueue.main.async {
                    let l = loaded?.0
                    let same = l != nil && l!.files == tree.files && l!.dirs == tree.dirs && l!.bytes == tree.bytes && l!.alloc == tree.alloc
                    self.check(ok && same && loaded?.1.eventId == info.eventId,
                               String(format: "snapshot timing: %@ full scan %.2f s (%@ files, %@ folders); snapshot %@ saved in %.2f s, loaded in %.2f s (%.0fx faster than the scan)",
                                      big, scanS, Fmt.count(tree.files), Fmt.count(tree.dirs), Fmt.size(bytes), saveS, loadS, scanS / max(0.001, loadS)))
                    try? fm.removeItem(atPath: Snapshot.file(for: big))
                    next()
                }
            }
        }
        // Restart: scan a folder (saved), "quit" (forget it), change files, start again from the snapshot + FSEvents replay.
        let sd = dir + "-snap"
        var replayWhy: String? = "not finished"
        var replayDone = false
        var restartAt = Date()
        steps.then {
            try? fm.removeItem(atPath: sd)
            func write(_ rel: String, _ n: Int) {
                let p = sd + "/" + rel
                try? fm.createDirectory(atPath: PathUtil.parent(p), withIntermediateDirectories: true)
                fm.createFile(atPath: p, contents: Data(count: n))
            }
            write("k1/a.bin", 3000); write("k1/b.bin", 4000); write("k2/sub/c.bin", 5000); write("k3/d.bin", 6000)
            write("k3/deep/e.bin", 1500); write("top.bin", 1000)
            try? fm.removeItem(atPath: Snapshot.file(for: sd))
            w.scanPath(sd)
        }
        steps.waitUntil(30) { !w.scanning && w.findRoot(sd)?.node != nil && PathUtil.exists(Snapshot.file(for: sd)) }
        steps.then {
            self.check(PathUtil.exists(Snapshot.file(for: sd)) && PathUtil.parent(Snapshot.file(for: sd)) == self.dir + "-snapshots",
                       "snapshot: saved after the full scan (\(PathUtil.name(Snapshot.file(for: sd))))")
            // "Quit": the folder is forgotten.
            if let r = w.findRoot(sd) { w.stopWatching(r); w.roots.removeAll { $0 === r } }
            w.current = nil
            w.refreshTree(nil)
            // Changes while the app is not running: added, removed, modified, renamed files; a new and a removed folder.
            fm.createFile(atPath: sd + "/k1/new.bin", contents: Data(count: 7000))
            try? fm.removeItem(atPath: sd + "/k1/b.bin")
            if let h = FileHandle(forWritingAtPath: sd + "/k2/sub/c.bin") { h.seekToEndOfFile(); h.write(Data(count: 4000)); h.closeFile() }
            try? fm.moveItem(atPath: sd + "/top.bin", toPath: sd + "/top2.bin")
            try? fm.createDirectory(atPath: sd + "/k4/e", withIntermediateDirectories: true)
            fm.createFile(atPath: sd + "/k4/e/f.bin", contents: Data(count: 2000))
            try? fm.removeItem(atPath: sd + "/k3")
        }
        steps.wait(2)
        var logoAtReplayDone = false
        steps.then {
            restartAt = Date()
            if let i = w.pages.firstIndex(where: { $0 === w.pContents }) { w.pageIndex = i }
            w.onReplayDone = { path, why in
                guard PathUtil.same(path, sd) else { return }
                replayWhy = why
                replayDone = true
                logoAtReplayDone = w.chart.showingLogo
            }
            w.openLastScan(sd)
        }
        steps.waitUntil(30) { replayDone && !w.scanning }
        steps.wait(0.5)
        steps.then {
            w.onReplayDone = nil
            self.check(logoAtReplayDone && !w.chart.showingLogo && w.activePage === w.pContents,
                       "snapshot restart: the chart shows the logo until the replay is done, then the chart")
            let r = w.findRoot(sd)
            let fresh = Scanner().run(sd)
            let diffs = r?.node.map { SelfTestRun.treeDiffs($0, fresh) } ?? ["not shown"]
            let took = Date().timeIntervalSince(restartAt)
            self.check(replayDone && replayWhy == nil, "snapshot restart: shown from the snapshot and brought up to date through FSEvents (\(replayWhy ?? "no fallback"))")
            self.check(diffs.isEmpty && r?.node?.files == fresh.files && r?.node?.bytes == fresh.bytes,
                       "snapshot restart: the tree equals a fresh scan (\(fresh.files) files, \(fresh.dirs) folders, \(fresh.bytes) bytes)" + (diffs.isEmpty ? "" : ": " + diffs.prefix(5).joined(separator: "; ")))
            self.check(w.statusLabel.stringValue.hasPrefix("Up to date: the scan of "),
                       String(format: "snapshot restart: ready in %.2f s; status \"%@\"", took, w.statusLabel.stringValue))
            // Not replayable (the volume's event history "changed"): the snapshot shows, then a normal scan runs.
            if let r = r { w.stopWatching(r); w.roots.removeAll { $0 === r } }
            w.current = nil
            w.refreshTree(nil)
            var info = Snapshot.infoNow(sd)
            info.volumeUUID = "00000000-0000-0000-0000-000000000000"
            try? Snapshot.write(Snapshot.serialize(fresh, info), sd)
            replayDone = false
            replayWhy = nil
            w.onReplayDone = { path, why in
                guard PathUtil.same(path, sd) else { return }
                replayWhy = why
                replayDone = true
            }
            w.openLastScan(sd)
        }
        steps.waitUntil(30) { replayDone && !w.scanning && w.findRoot(sd)?.node != nil }
        steps.waitUntil(10) { Snapshot.load(sd).map { $0.1.volumeUUID != "00000000-0000-0000-0000-000000000000" } ?? false }
        steps.then {
            w.onReplayDone = nil
            let loaded = Snapshot.load(sd)
            self.check(replayWhy == "the volume's event history was reset" && w.findRoot(sd)?.node != nil && loaded != nil && loaded!.1.volumeUUID == Snapshot.eventsUUID(sd),
                       "snapshot fallback: \(replayWhy ?? "no fallback") -> scanned again and saved")
            if let r = w.findRoot(sd) { w.stopWatching(r); w.roots.removeAll { $0 === r } }
            w.current = nil
            w.refreshTree(nil)
            // A snapshot of another version is deleted; only the 10 most recent roots are kept.
            let vf = Snapshot.file(for: "/dsa-selftest/other-version")
            var h = PackWriter()
            h.u32(Snapshot.magic)
            h.u32(Snapshot.version + 1)
            fm.createFile(atPath: vf, contents: Data(h.bytes + [1, 2, 3]))
            let gone = Snapshot.load("/dsa-selftest/other-version") == nil && !PathUtil.exists(vf)
            for i in 0..<12 {
                let f = Snapshot.folder + "/dummy\(i).bin"
                fm.createFile(atPath: f, contents: Data([0]))
                try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(Double(-86400 * (i + 1)))], ofItemAtPath: f)
            }
            Snapshot.prune()
            let left = ((try? fm.contentsOfDirectory(atPath: Snapshot.folder)) ?? []).filter { $0.hasSuffix(".bin") }
            self.check(gone && left.count == Snapshot.keep && PathUtil.exists(Snapshot.file(for: sd)),
                       "snapshot: a file of another version is deleted (\(gone)); \(left.count) snapshots kept, the newest ones")
            try? fm.removeItem(atPath: sd)
            try? fm.removeItem(atPath: self.dir + "-snapshots")
            try? fm.removeItem(atPath: HashCache.path)
        }
    }
}

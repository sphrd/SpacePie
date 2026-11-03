import AppKit

/// Self-test of the v2.0 features (run inside --cli selftest on the scratch folder's scan): last opened, search in
/// everything scanned, treemap, Back / Forward and the path bar, well-known folders, the unreadable-folders banner, synced
/// folders in the delete confirmation, app leftover confidence, scan files and the scan history (timeline, daily copies).
extension SelfTestRun {
    func addV2Checks() {
        let w = self.w
        let fm = FileManager.default

        // Last opened: the scan records each file's last-access time (never before its last change).
        steps.then {
            guard let top = self.root else { self.check(false, "last opened: nothing scanned"); return }
            var files: [FileRec] = []
            for d in top.descendants() { files.append(contentsOf: d.fileList ?? []) }
            self.check(!files.isEmpty && files.allSatisfy { $0.accessed > 0 && $0.lastUse >= $0.modified },
                       "last opened: every file has a last-access time (\(files.count) files)")
            let flt = FileFilter()
            flt.usedBefore = Int64(Date().addingTimeInterval(-365 * 86400).timeIntervalSince1970)
            let n = FileIndex.largest(top, 100, flt).count
            self.check(n == 0, "last opened: \"not opened for 1 year\" finds nothing among files just made (\(n))")
        }

        // Search in everything scanned: folders by name and files by pattern, across every scanned root.
        steps.then {
            let scanned = w.roots.compactMap { $0.node }
            let byName = FileFilter()
            byName.patterns = ["node_modules"]
            let dirs = FileIndex.folders(scanned, 100, byName)
            let bins = FileFilter()
            bins.patterns = ["*.bin"]
            let files = FileIndex.largest(scanned, 100, bins)
            self.check(dirs.count >= 1 && dirs.dirs.allSatisfy { $0.name.lowercased() == "node_modules" } && files.count >= 1
                       && files.files.allSatisfy { $0.name.hasSuffix(".bin") },
                       "search: folders by name (\(dirs.count) node_modules) and files by pattern (\(files.count) *.bin) in everything scanned")
        }

        // Treemap: rectangles fill the area in true proportion; the folder contents are drawn as rectangles.
        steps.then {
            let sizes: [Double] = [50, 25, 12.5, 6.25, 6.25]
            let rects = PieChart.squarify(sizes, NSRect(x: 0, y: 0, width: 400, height: 300))
            var area = 0.0
            for r in rects { area += Double(r.width * r.height) }
            var prop = true
            for i in sizes.indices where abs(Double(rects[i].width * rects[i].height) / 120000 - sizes[i] / 100) >= 0.01 { prop = false }
            let inside = rects.allSatisfy { $0.minX >= -0.5 && $0.minY >= -0.5 && $0.maxX <= 400.5 && $0.maxY <= 300.5 }
            self.check(abs(area - 120000) < 1 && prop && inside, "treemap: rectangles fill the area, each in proportion to its size")
            if let i = w.pages.firstIndex(where: { $0 === w.pContents }) { w.viewTabs.selectedIndex = i }
            guard let top = self.root else { self.check(false, "treemap: nothing scanned"); return }
            w.selectDir(top)
            let was = w.chart.treemap
            w.chart.treemap = true
            w.updateChart(top)
            w.chart.display()
            if w.chart.tileCount == 0 { w.chart.layoutTreemapNow() }
            let n = w.chart.tileCount
            self.check(n > 0, "treemap: the folder contents are drawn as \(n) rectangles")
            w.chart.treemap = was
            w.updateChart(top)
        }

        // Back / Forward and the path bar.
        steps.then {
            guard let top = self.root, let a = self.find("A") ?? top.children.first else { self.check(false, "navigation: nothing scanned"); return }
            w.selectDir(top)
            w.selectDir(a)
            let crumbOk = w.crumbs.count == 2 && !w.crumbs.isHidden
            w.goBack()
            let back = w.current === top
            w.goForward()
            let fwd = w.current === a
            w.selectDir(top)
            self.check(crumbOk && back && fwd, "navigation: path bar shows 2 parts, Back returns to the folder before (\(back)), Forward goes again (\(fwd))")
        }

        // Well-known folders are named, with what to do about them.
        steps.then {
            let k1 = Known.lookup("/System", "System")
            let k2 = Known.lookup("/Users/someone/work/app/node_modules", "node_modules")
            let k3 = Known.lookup(self.P("A"), "A")
            let k4 = Known.lookup(PathUtil.home + "/Library/Caches", "Caches")
            let k5 = Known.lookup("/private/var/vm/swapfile3", nil)
            self.check(k1?.verdict == Known.keep && k2?.verdict.hasPrefix("Safe") == true && k3 == nil && k4?.verdict == Known.safe && k5?.verdict == Known.macOS,
                       "known folders: /System = keep, node_modules = safe to delete, ~/Library/Caches = safe to delete, swap = managed by macOS, an ordinary folder has no label")
            let row = w.pContents.items.first { $0.isDir && $0.dir?.name == "P" }
            self.check(w.pContents.columns.last?.title == "What it is" && (row?.cells.count ?? 0) == w.pContents.columns.count,
                       "known folders: Contents has a \"What it is\" column")
        }

        // Folders that could not be read are counted for the banner.
        steps.then {
            guard let top = self.root else { self.check(false, "unreadable: nothing scanned"); return }
            let fake = DirNode(name: "locked", parent: top)
            fake.denied = true
            top.children.append(fake)
            w.deniedCache.removeAll()
            w.updateUnreadBanner(top)
            let msg = w.unreadBanner.message
            let shown = !w.unreadBanner.isHidden && msg.hasPrefix("1 folder in this scan could not be read")
            top.children.removeAll { $0 === fake }
            fake.parent = nil
            w.deniedCache.removeAll()
            w.updateUnreadBanner(top)
            self.check(shown && w.unreadBanner.isHidden, "unreadable: the banner counts folders that could not be read (\"\(msg)\"), and hides when there are none")
        }

        // Synced folders are recognized before deleting, and the confirmation says so.
        steps.then {
            let base = self.dir + "-sync"
            try? fm.removeItem(atPath: base)
            for p in ["Library/Mobile Documents/com~apple~CloudDocs/Documents", "Documents", "Desktop", "Library/CloudStorage/OneDrive-Personal",
                      "Library/CloudStorage/GoogleDrive-me@example.com", "Dropbox"] {
                try? fm.createDirectory(atPath: base + "/" + p, withIntermediateDirectories: true)
            }
            SyncFolders.homeOverride = base
            SyncFolders.reset()
            let found = [SyncFolders.service(for: base + "/Documents/report.txt"),
                         SyncFolders.service(for: base + "/Library/CloudStorage/OneDrive-Personal/a.txt"),
                         SyncFolders.service(for: base + "/Library/CloudStorage/GoogleDrive-me@example.com/b"),
                         SyncFolders.service(for: base + "/Dropbox/c"),
                         SyncFolders.service(for: base + "/Desktop/d"),
                         SyncFolders.service(for: self.dir)]
            let t1 = DeleteTarget(path: base + "/Library/CloudStorage/OneDrive-Personal/a.txt", label: "a.txt", size: 100)
            let t2 = DeleteTarget(path: self.P("A/a1.txt"), label: "a1.txt", size: 100)
            let d = w.deleteConfirmDialog([t1, t2], trash: false, synced: w.syncedTargets([t1, t2]))
            let noted = d.warning.contains("1 of them is in folders synced with OneDrive") && (d.detailLines.first?.hasSuffix("  -  synced with OneDrive") ?? false)
                && !(d.detailLines.last?.contains("synced") ?? true)
            SyncFolders.homeOverride = nil
            SyncFolders.reset()
            try? fm.removeItem(atPath: base)
            let want: [String?] = ["iCloud Drive", "OneDrive", "Google Drive", "Dropbox", nil, nil]
            self.check(found == want && noted,
                       "synced folders: iCloud Drive (Documents), OneDrive, Google Drive and Dropbox recognized, others not (\(found.map { $0 ?? "-" }.joined(separator: ", "))); the confirmation names them (\(noted))")
        }

        // App leftovers: how sure each item belongs to the app.
        steps.then {
            let home = self.dir + "-tiers"
            try? fm.removeItem(atPath: home)
            let made = [home + "/Library/Caches/com.dsatiervendor.dsatierpro", home + "/Library/Application Support/Dsatiervendor/DSA Tier Pro",
                        home + "/Library/Logs/dsa tier"]
            for p in made { try? fm.createDirectory(atPath: p, withIntermediateDirectories: true) }
            let items = InstalledApp.findLeftovers(bundleId: "com.dsatiervendor.dsatierpro", name: "DSA Tier Pro", home: home, fullDiskAccess: false)
            func tier(_ suffix: String) -> String { items.first { $0.path.hasSuffix(suffix) }?.match ?? "missing" }
            let cache = tier("/Caches/com.dsatiervendor.dsatierpro"), dev = tier("/Application Support/Dsatiervendor"), name = tier("/Logs/dsa tier")
            let unchecked = items.first { $0.path.hasSuffix("/Logs/dsa tier") }.map { !$0.checked && !$0.sure } ?? false
            try? fm.removeItem(atPath: home)
            self.check(cache == AppLeftover.exact && dev == AppLeftover.sameDeveloper && name == AppLeftover.nameOnly && unchecked,
                       "apps: leftovers by confidence: bundle id = \(cache), developer folder = \(dev), shortened name = \(name) (unchecked: \(unchecked))")
        }

        // Scan files: saved, opened read-only next to the live scan, never confused with it, then closed.
        var savedFile = ""
        var same = false
        steps.add { next in
            guard let top = self.root, let r = w.rootOf(top) else { self.check(false, "scan file: nothing scanned"); next(); return }
            savedFile = self.dir + "." + Snapshot.scanFileExtension
            try? fm.removeItem(atPath: savedFile)
            try? w.saveScanFile(top, savedFile)
            if let back = Snapshot.loadScanFile(savedFile) {
                same = back.0.files == top.files && back.0.dirs == top.dirs && back.0.bytes == top.bytes && PathUtil.same(back.1.rootPath, r.path)
            }
            w.openScanFile(savedFile)
            next()
        }
        steps.waitUntil(10) { w.roots.contains { $0.readOnly } }
        steps.then {
            let ro = w.roots.first { $0.readOnly }
            let top = self.root
            let live = top.flatMap { w.rootOf($0) }
            let separate = ro != nil && ro!.node !== top && w.findScanned(self.dir, exact: true) === top && live != nil && w.findRoot(live!.path) === live
            var guarded = false
            if let n = ro?.node, let c = n.children.first { guarded = w.fromReadOnly(ItemInfo.forDir(c, 0)) }
            let label = ro?.displayName ?? ""
            w.closeSavedScan(ro)
            let closed = !w.roots.contains { $0.readOnly }
            try? fm.removeItem(atPath: savedFile)
            if let t = self.root { w.selectDir(t) }
            self.check(same && separate && guarded && closed && label.contains("(saved scan, "),
                       "scan file: saved and read back identical (\(same)), opened read-only beside the live scan (\(separate)), its items can't be deleted (\(guarded)), closed (\(closed))")
        }

        // History: every scan adds a timeline point; one small copy is kept per day for comparisons.
        steps.waitUntil(10) { !History.timeline(self.dir).isEmpty && !History.archived(self.dir).isEmpty }
        steps.then {
            let tl = History.timeline(self.dir)
            let ar = History.archived(self.dir)
            let days = Set(ar.map { Fmt.day($0.when) })
            let kept = ar.first.flatMap { History.loadFile($0.file) }
            self.check(tl.count >= 1 && !ar.isEmpty && days.count == ar.count && kept != nil && (tl.last?.files ?? 0) > 0,
                       "history: \(tl.count) timeline point(s), \(ar.count) kept cop\(ar.count == 1 ? "y" : "ies") (one per day), read back (\(kept != nil))")
            // The Changes view offers the scans to compare (From / To) and shows the timeline.
            if let i = w.pages.firstIndex(where: { $0 === w.pChanges }) { w.viewTabs.selectedIndex = i }
            w.fillChanges()
            self.check(w.changeTo.count >= 1 && w.historyStrip.isHidden == tl.isEmpty,
                       "changes: From (\(w.changeFrom.count) choice(s)) / To (\(w.changeTo.count)) and the timeline strip")
            if let i = w.pages.firstIndex(where: { $0 === w.pContents }) { w.viewTabs.selectedIndex = i }
        }
    }
}

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

        // Removing as administrator: the script run as root (here as the user, on scratch files) moves items with odd
        // names to the Trash under a free name and deletes others; the AppleScript string keeps quotes and backslashes.
        steps.then {
            let base = self.P("admin-test")
            let name = "DSA admin test it's \"q\" " + UUID().uuidString
            try? fm.createDirectory(atPath: base + "/" + name, withIntermediateDirectories: true)
            fm.createFile(atPath: base + "/" + name + "/f.bin", contents: Data(count: 10))
            fm.createFile(atPath: base + "/gone $x.bin", contents: Data(count: 10))
            let sh1 = SystemInfo.run("/bin/sh", ["-c", AdminRemove.script([base + "/" + name], trash: true)])
            let sh2 = SystemInfo.run("/bin/sh", ["-c", AdminRemove.script([base + "/gone $x.bin"], trash: false)])
            let inTrash = PathUtil.home + "/.Trash/" + name
            let ok = sh1.status == 0 && sh2.status == 0 && PathUtil.isDir(inTrash) && !PathUtil.exists(base + "/" + name)
                && !PathUtil.exists(base + "/gone $x.bin")
            try? fm.removeItem(atPath: inTrash)
            let q = AdminRemove.appleScriptString("a \"b\" \\c")
            self.check(ok && q == "\"a \\\"b\\\" \\\\c\"", "admin remove: the root script moves to the Trash and deletes (names with quotes, $), AppleScript quoting")
            try? fm.removeItem(atPath: base)
        }

        // Zoom (⌘+ / ⌘- / ⌘0): the window's content is drawn at the zoom; the toolbar's buttons never overlap.
        steps.then {
            let before = w.zoom
            let saved = UserDefaults.standard.object(forKey: MainWindowController.zoomKey)
            var ok = true, detail = ""
            for z: CGFloat in [1.5, 2, 0.75] {
                w.setZoom(z)
                let r = w.root
                let scaled = abs(r.bounds.width - (r.frame.width / z).rounded()) <= 1
                let bar: [NSView] = [w.btnBack, w.btnForward, w.btnUp, w.btnRescan, w.btnFinder, w.btnAddList, w.btnBasket, w.btnDelete,
                                     w.btnOpenScan, w.btnExport, w.measure]
                var overlap = false
                for i in bar.indices { for j in bar.indices where j > i && bar[i].frame.intersects(bar[j].frame) { overlap = true } }
                if bar.contains(where: { $0.frame.maxX > r.bounds.width + 1 }) { overlap = true }   // or out of the window
                if !scaled || overlap { ok = false; detail += " \(z): scaled \(scaled), overlap \(overlap)" }
            }
            w.setZoom(before)
            if let v = saved { UserDefaults.standard.set(v, forKey: MainWindowController.zoomKey) } else { UserDefaults.standard.removeObject(forKey: MainWindowController.zoomKey) }
            self.check(ok && w.zoom == before, "zoom: 150 %, 200 % and 75 % scale the window's content, toolbar buttons never overlap or leave the window" + detail)
        }

        // Drive progress: size on disk against the used space (a 1 GB sparse file adds 1 GB of length, nearly nothing on
        // disk); past 99 % it says it is finishing instead of "X of Y" with X larger than Y.
        steps.then {
            let base = self.P("progress-test")
            try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)
            fm.createFile(atPath: base + "/sparse.img", contents: nil)
            if let h = FileHandle(forWritingAtPath: base + "/sparse.img") { h.truncateFile(atOffset: 1 << 30); h.closeFile() }
            let s = Scanner()
            _ = s.run(base)
            let over = MainWindowController.driveProgress("/", found: 120 << 30, used: 100 << 30)
            let mid = MainWindowController.driveProgress("/", found: 50 << 30, used: 100 << 30)
            self.check(s.bytesSeen >= 1 << 30 && s.allocSeen < 1 << 20 && over.fraction == 0.99 && !over.text.contains(" of ")
                       && over.text.contains("finishing") && abs(mid.fraction - 0.5) < 0.001 && mid.text.contains("50 %"),
                       "scan progress: size on disk (sparse 1 GB: \(Fmt.size(s.allocSeen)) on disk), never \"X of Y\" past the total")
            try? fm.removeItem(atPath: base)
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
            if let i = w.pages.firstIndex(where: { $0 === w.pContents }) { w.pageIndex = i }
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
            let crumbOk = w.crumbs.count == 3 && !w.crumbs.isHidden && w.crumbs.texts.first == MainWindowController.thisPcName
            w.goBack()
            let back = w.current === top
            w.goForward()
            let fwd = w.current === a
            w.selectDir(top)
            self.check(crumbOk && back && fwd, "navigation: path bar shows \(MainWindowController.thisPcName) and 2 folders (\(w.crumbs.texts.joined(separator: " > "))), Back returns to the folder before (\(back)), Forward goes again (\(fwd))")

            // Contents is a tree-list: a folder opens in place, its rows one level deeper right below it.
            let ex = top.children.first { MainWindowController.hasContent($0) }
            let before = w.pContents.items.count
            var below = false, grown = 0
            if let e = ex {
                w.setExpanded(e, true)
                w.refillContents()
                if let at = w.pContents.items.firstIndex(where: { $0.dir === e && $0.depth == 0 }) {
                    below = at + 1 < w.pContents.items.count && w.pContents.items[at + 1].depth == 1 && w.pContents.items[at].expanded
                }
                grown = w.pContents.items.count - before
                w.setExpanded(e, false)
                w.refillContents()
            }
            self.check(ex != nil && below && grown > 0 && w.pContents.items.count == before,
                       "tree-list: opening \(ex?.name ?? "?") shows its \(grown) rows below it at depth 1, closing hides them")

            // Up from the top of a scan leads to This PC (every drive and scanned folder, that one selected), then disabled.
            w.goUp()
            let sel = w.pContents.selectedItems
            let pc = w.thisPc && w.current == nil && w.pContents.items.filter { $0.depth == 0 }.count == w.roots.count && !w.btnUp.isEnabled
                && sel.count == 1 && sel[0].scanRoot === w.rootOf(top) && w.crumbs.count == 1
                && w.pContents.columns.count > 2 && (w.contents.tableColumns.first { $0.identifier.rawValue == "c2" }?.headerCell.stringValue.hasPrefix("% used") ?? false)
            w.crumbs.pick(0)
            // Only real drives count in This Mac: the chart total is the drives' used space; the scanned scratch folder
            // shows its own size, is a "Scanned folder" and has no slice.
            w.updateChartThisPc()
            let drivesUsed = w.thisPcDrives.reduce(Int64(0)) { $0 + $1.used }
            let folderRow = w.pContents.items.first { $0.depth == 0 && $0.scanRoot === w.rootOf(top) }
            let chartOk = w.chart.showingLogo || (w.chart.total == drivesUsed
                && !w.chart.slices.contains { s in s.rows.contains { $0 < w.pContents.items.count && w.pContents.items[$0].noSlice } })
            let folderOk = folderRow != nil && folderRow!.size == top.size && folderRow!.category == "Scanned folder" && folderRow!.noSlice
            self.check(chartOk && folderOk,
                       "this mac: the chart total (\(Fmt.size(w.chart.total))) is the drives' used space (\(Fmt.size(drivesUsed))); a scanned folder shows its own size and has no slice")
            w.selectDir(top)
            self.check(pc && !w.thisPc && w.current === top,
                       "this pc: Up from the scanned folder lists the \(w.roots.count) drives and folders with it selected; Up is then disabled")
        }

        // Sorting by any column: grouped lists move whole groups and sort members inside them; the order survives refills.
        steps.then {
            let p = Page("Sort", [Column("name", "Name", 100), Column("size", "Size", 60, true)], barColumn: -1, bar: nil)
            func build() -> [ItemInfo] {
                var rows: [ItemInfo] = []
                for g in ["Beta", "Alpha", "Gamma"] {
                    let head = ItemInfo()
                    head.name = g; head.size = Int64(g.count * 100)
                    head.cells = [g, ""]
                    rows.append(head)
                    for m in ["z", "a", "m"] {
                        let it = ItemInfo()
                        it.name = g + "-" + m; it.size = Int64(m.unicodeScalars.first?.value ?? 0); it.groupOf = head
                        it.cells = [it.name, ""]
                        rows.append(it)
                    }
                }
                return rows
            }
            p.setRows(build(), "", keepOrder: true)
            p.sortBy(0)
            func order() -> String { p.items.map { $0.name }.joined(separator: ",") }
            let want = "Alpha,Alpha-a,Alpha-m,Alpha-z,Beta,Beta-a,Beta-m,Beta-z,Gamma,Gamma-a,Gamma-m,Gamma-z"
            let sorted = order() == want
            p.setRows(build(), "", keepOrder: true)
            let kept = order() == want
            self.check(sorted && kept, "sorting: by name moves whole groups and sorts inside them (\(sorted)), and a refill keeps the order (\(kept))")
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
            let shown = !w.unreadBanner.isHidden && (msg.hasPrefix("1 folder in this scan could not be read") || msg.hasPrefix("1 folder in this scan is closed by macOS"))
            // Closed with x: it stays hidden for this scan.
            w.current = top
            w.unreadBanner.close()
            w.updateUnreadBanner(top)
            let staysClosed = w.unreadBanner.isHidden
            w.unreadClosed.removeAll()
            top.children.removeAll { $0 === fake }
            fake.parent = nil
            w.deniedCache.removeAll()
            w.updateUnreadBanner(top)
            self.check(shown && staysClosed && w.unreadBanner.isHidden,
                       "unreadable: the banner counts folders that could not be read (\"\(msg)\"), stays closed after x (\(staysClosed)), and hides when there are none")
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

        // CleanMyMac-style checks: ignore list, leftovers of removed apps, broken launch items, rotated logs, unused apps,
        // and which deletions need the administrator.
        steps.then {
            let base = self.dir + "-more"
            try? fm.removeItem(atPath: base)
            try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)
            IgnoreList.fileOverride = base + "/ignored.txt"
            IgnoreList.clear()
            let s1 = Suggestion("DSA test one", safe: true, note: ""), s2 = Suggestion("DSA test two", safe: true, note: "")
            s1.targets = [DeleteTarget(path: base + "/a", label: "a", size: 10)]; s1.size = 10
            s2.targets = [DeleteTarget(path: base + "/b", label: "b", size: 10), DeleteTarget(path: base + "/c", label: "c", size: 5)]; s2.size = 15
            IgnoreList.add(name: "DSA test one")
            IgnoreList.add(path: base + "/b")
            let kept = IgnoreList.apply([s1, s2])
            let ignoreOk = kept.count == 1 && kept[0].name == "DSA test two" && kept[0].targets.count == 1 && kept[0].size == 5 && IgnoreList.count == 2
            IgnoreList.clear()
            IgnoreList.fileOverride = nil

            let home = base + "/home"
            for d in ["Library/Preferences", "Library/Application Support/com.dsaorphanvendor.dsaorphan", "Library/Application Support/com.apple.dsatest", "Library/LaunchAgents"] {
                try? fm.createDirectory(atPath: home + "/" + d, withIntermediateDirectories: true)
            }
            fm.createFile(atPath: home + "/Library/Preferences/com.dsaorphanvendor.dsaorphan.plist", contents: Data(count: 100))
            fm.createFile(atPath: home + "/Library/Preferences/com.dsarecentvendor.dsarecent.plist", contents: Data(count: 100))
            fm.createFile(atPath: home + "/Library/Preferences/org.cups.dsatest.plist", contents: Data(count: 100))
            let longAgo = Date().addingTimeInterval(-90 * 86400)
            for p in ["Preferences/com.dsaorphanvendor.dsaorphan.plist", "Application Support/com.dsaorphanvendor.dsaorphan", "Application Support/com.apple.dsatest", "Preferences/org.cups.dsatest.plist"] {
                try? fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: home + "/Library/" + p)
            }
            let orphans = w.orphanLeftovers(home: home).map { PathUtil.name($0.path) }
            let orphanOk = orphans.contains("com.dsaorphanvendor.dsaorphan.plist") && orphans.contains("com.dsaorphanvendor.dsaorphan") && !orphans.contains("com.apple.dsatest")
                && !orphans.contains("com.dsarecentvendor.dsarecent.plist") && !orphans.contains("org.cups.dsatest.plist")

            let agents = home + "/Library/LaunchAgents/"
            (["Label": "com.example.dsabroken", "Program": base + "/no such program"] as NSDictionary).write(toFile: agents + "com.example.dsabroken.plist", atomically: true)
            (["Label": "com.example.dsafine", "ProgramArguments": ["/bin/ls"]] as NSDictionary).write(toFile: agents + "com.example.dsafine.plist", atomically: true)
            let brokenOk = MainWindowController.isBrokenLaunchItem(agents + "com.example.dsabroken.plist") && !MainWindowController.isBrokenLaunchItem(agents + "com.example.dsafine.plist")

            let logsOk = MainWindowController.isRotatedLog("system.log.0.gz") && MainWindowController.isRotatedLog("install.log.3")
                && !MainWindowController.isRotatedLog("system.log") && !MainWindowController.isRotatedLog("wifi.log")

            let old = Date().addingTimeInterval(-400 * 86400), recent = Date().addingTimeInterval(-86400)
            let a1 = InstalledApp(); a1.installed = old; a1.lastUsed = old
            let a2 = InstalledApp(); a2.installed = old; a2.lastUsed = recent
            let a3 = InstalledApp(); a3.installed = old
            let a4 = InstalledApp(); a4.installed = recent
            let unusedOk = a1.isUnused() && !a2.isUnused() && a3.isUnused() && !a4.isUnused()

            let rootOk = MainWindowController.needsRoot(DeleteTarget(path: "/private/var/log/system.log", label: "x", size: 1))
                && !MainWindowController.needsRoot(DeleteTarget(path: base + "/a", label: "a", size: 1))
            try? fm.removeItem(atPath: base)
            self.check(ignoreOk && orphanOk && brokenOk && logsOk && unusedOk && rootOk,
                       "more checks: ignore list (\(ignoreOk)), leftovers of removed apps (\(orphanOk): \(orphans.joined(separator: ", "))), broken launch items (\(brokenOk)), rotated logs (\(logsOk)), unused apps (\(unusedOk)), admin-only deletes (\(rootOk))")
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
            if let i = w.pages.firstIndex(where: { $0 === w.pChanges }) { w.pageIndex = i }
            w.fillChanges()
            self.check(w.changeTo.count >= 1 && w.historyStrip.isHidden == tl.isEmpty,
                       "changes: From (\(w.changeFrom.count) choice(s)) / To (\(w.changeTo.count)) and the timeline strip")
            if let i = w.pages.firstIndex(where: { $0 === w.pContents }) { w.pageIndex = i }
        }
    }
}

import AppKit

/// The views shown in tabs above the list and the chart. Every view is a list; the chart always shows the list that is
/// open, slice for row in the same order, and hover is linked both ways.
extension MainWindowController {
    static let minSizes: [Int64] = [0, 1 << 20, 10 << 20, 100 << 20, 1 << 30]
    // Date filter: not changed for (months), then not opened for (months, negative).
    static let ageMonths = [0, 3, 6, 12, 24, 60, -3, -6, -12, -24]
    static let maxOwnSlices = 50          // every row of at least 2 % of the total (7.2 degrees) gets a slice of its own
    static let minOwnShare = 0.02         // (2 % allows at most 50); all smaller rows together form one "smaller items" slice

    var activePage: Page { pages[min(max(0, pageIndex), pages.count - 1)] }

    /// The views listed in the rail, in rail order (the delete list only while deleteListInRail is on; otherwise it opens
    /// from its toolbar button).
    var railPages: [Page] { MainWindowController.deleteListInRail ? pages : pages.filter { $0 !== pBasket } }

    /// Shows view p (from the rail, the Delete list button or the app).
    func showView(_ p: Page) { if let i = pages.firstIndex(where: { $0 === p }) { pageIndex = i } }

    /// The rail follows the view shown (no row is selected while the delete list is shown).
    func syncRail() {
        let p = activePage
        viewTabs.selectedIndex = railPages.firstIndex { $0 === p } ?? -1
        // The Delete list button is the delete list's tab (merged into the pane below it while it is open), unless the
        // rail has a row for it.
        btnBasket.selected = p === pBasket && !MainWindowController.deleteListInRail
        layoutRoot()
    }

    func buildViews() {

        pContents = Page("Contents", [Column("name", "Name", 210),         Column("size", "Size", 80, true), Column("size", "% of parent", 125, true),
                                      Column("change", "Change", 80, true), Column("files", "Files", 74, true), Column("dirs", "Folders", 66, true),
                                      Column("mod", "Modified", 128), Column("cat", "What it is", 240)], barColumn: 2, bar: nil)
        pContents.followsFolder = true
        pContents.fill = { [unowned self] in
            if self.thisPc { self.showThisPc() } else if let c = self.current, self.isAttached(c) { self.showContents(c) }
        }
        // Contents is a tree-list: sorting rebuilds it level by level; the chevron of a folder opens it in place.
        pContents.onResort = { [unowned self] in self.refillContents() }
        pContents.table.onClickAt = { [unowned self] r, p in self.contentsClick(r, p) }
        pages.append(pContents)

        // Suggestions comes right after Contents (the app opens on Contents).
        pSuggest = buildSuggestionsPage(); pages.append(pSuggest)
        // Apps (installed apps, uninstaller) right after Suggestions.
        pApps = buildAppsPage(); pages.append(pApps)
        // System (snapshots, purgeable space, device backups, drives) right after Apps.
        pSystem = buildSystemPage(); pages.append(pSystem)

        // Files: the whole index under the selected folder (or everything scanned), filtered; largest first.
        fileSearch.onChange = { [unowned self] in self.fillFiles() }
        fileSearch.toolTip = "Part of a name, or a pattern with * and ? (*. = no extension). Several patterns: separate them with ; (⌘F). Folders whose name contains the text are listed too; patterns find files only."
        fileScope.tip = "Search the folder open in Contents, or every scanned drive and folder at once"
        fileAge.tip = "Files not changed (modified), or not opened (nor changed), for at least this long. \"Opened\" uses the last-access time macOS records"
        for c in [fileScope, fileType, fileMinSize, fileAge] { c.onChange = { [unowned self] _ in self.fillFiles() } }
        pFiles = Page("Files", [Column("name", "Name", 210), Column("size", "Size", 80, true), Column("size", "% of folder", 125, true),
                                Column("folder", "Folder", 330), Column("cat", "Type", 110), Column("mod", "Modified", 128),
                                Column("used", "Last opened", 128)],
                      barColumn: 2, bar: ActionBar([fileSearch, fileScope, fileType, fileMinSize, fileAge]))
        pFiles.followsFolder = true
        pFiles.chartScope = "of folder"
        pFiles.fill = { [unowned self] in self.fillFiles() }
        pages.append(pFiles)

        // File types: space by extension or category under the selected folder.
        typeGroup.onChange = { [unowned self] _ in self.fillTypes() }
        pTypes = Page("File types", [Column("name", "Type", 180), Column("size", "Size", 84, true), Column("size", "% of folder", 160, true),
                                     Column("files", "Files", 84, true), Column("cat", "Category", 170)],
                      barColumn: 2, bar: ActionBar([typeGroup]))
        pTypes.followsFolder = true
        pTypes.chartScope = "of folder"
        pTypes.fill = { [unowned self] in self.fillTypes() }
        pages.append(pTypes)

        pDupes = buildDuplicatesPage(); pages.append(pDupes)
        pChanges = buildChangesPage(); pages.append(pChanges)
        pBasket = buildBasketPage(); pages.append(pBasket)
    }

    func showPage() {
        let p = activePage
        HoverTip.shared.reset()
        for q in pages { q.root.isHidden = q !== p }
        listPanel.needsLayout = true
        if p.stale { p.stale = false; p.fill() } else {
            if deleteJob != nil { pruneDeletedRows(p) }
            refreshChart()
        }
        lastView = p.table
        updateButtons()
    }

    /// The chart follows the open view.
    func refreshChart() {
        if chartOnHold { showScanLogo(); return }
        let p = activePage
        if p === pContents {
            if thisPc { updateChartThisPc() }
            else if let c = current, isAttached(c) { updateChart(c) }
            else if let a = active, a.node == nil { updateChartUnscanned(a) }
            return
        }
        if p.items.isEmpty {
            rowSlice = [:]
            chart.showLogo(p.chartTitle, p.chartSub, p.empty)
            return
        }
        var total = p.chartTotal
        if total <= 0 { for it in p.items where it.groupOf == nil { total += max(0, it.chartSize) } }
        if total <= 0 && p === pSystem {
            rowSlice = [:]
            chart.showLogo(p.chartTitle, p.chartSub, "Nothing here that can be freed.")
            return
        }
        chart.setData(p.chartTitle, p.chartSub, buildSlices(p, total, p.chartScope))
    }

    /// The scanned tree changed (scan, rescan, delete, measure): views refill when they are shown next.
    func viewsChanged() {
        if pages.isEmpty { return }
        deniedCache.removeAll()
        for p in pages where p !== pContents { p.stale = true }
        updateBasketTitle()
        let a = activePage
        if a !== pContents && a.stale { a.stale = false; a.fill() }
    }

    /// Another folder was opened: folder-based views follow it.
    func contentsChanged() {
        for p in pages where p.followsFolder && p !== pContents { p.stale = true }
        let a = activePage
        if a === pContents { if thisPc { updateChartThisPc() } else if let c = current { updateChart(c) } }
        else if a.stale { a.stale = false; a.fill() }
    }

    func scope() -> DirNode? {
        if let c = current, isAttached(c) { return c }
        return active?.node ?? roots.first { $0.node != nil }?.node
    }

    /// Chart hover for a list row: the slice of a top-level row; for a row inside an expanded folder (Contents), the
    /// folder's section in the outer rings or treemap (a file: the section of the folder it is in).
    func hoverChart(_ p: Page, _ r: Int) {
        if r < 0 || r >= p.items.count { chart.setHover(-1); return }
        if let s = rowSlice[r] { chart.setHover(s); return }
        let info = p.items[r]
        // A row inside a group (a suggestion's folders and files) lights its head's slice.
        if p !== pContents, let g = info.groupOf, let hr = p.items.firstIndex(where: { $0 === g }), let s = rowSlice[hr] { chart.setHover(s); return }
        guard p === pContents, let dir = info.dir ?? info.file?.dir else { chart.setHover(-1); return }
        // The top-level folder row the row lies under gives the slice.
        for (row, slice) in rowSlice {
            guard let top = p.items[row].dir else { continue }
            var d: DirNode? = dir
            while let x = d { if x === top { chart.setHoverDir(slice, dir); return }; d = x.parent }
        }
        chart.setHover(-1)
    }

    /// List rows for the hovered chart part: a slice's rows; a subfolder section (outer ring or inner treemap tile) in
    /// Contents: the folder's row, or the row of its nearest parent shown when it is not expanded.
    func rowsForChartHover(_ slice: Int, _ dir: DirNode?) -> [Int] {
        if slice < 0 || slice >= chart.slices.count { return [] }
        guard let dir = dir, activePage === pContents else { return chart.slices[slice].rows }
        let items = pContents.items
        var d: DirNode? = dir
        while let x = d {
            if let r = items.firstIndex(where: { $0.dir === x }) { return [r] }
            d = x.parent
        }
        return chart.slices[slice].rows
    }

    /// Slices for a list exactly as displayed, in row order: every row of at least 2 % of the total has a slice of its own
    /// (true proportions); all smaller rows together form one "smaller items" slice, placed where the first of them is.
    /// Rows of a group (duplicates) join their group's slice. Fills rowSlice so hover links rows and slices both ways.
    func buildSlices(_ p: Page, _ total0: Int64, _ scopeText: String) -> [ChartSlice] {
        rowSlice = [:]
        let rows = p.items
        let total = max(Int64(1), total0)
        let big = rows.indices.filter { rows[$0].depth == 0 && !rows[$0].noSlice && rows[$0].groupOf == nil && rows[$0].chartSize > 0 &&
            Double(rows[$0].chartSize) >= MainWindowController.minOwnShare * Double(total) }
        let own = Set(big.sorted { rows[$0].chartSize > rows[$1].chartSize }.prefix(MainWindowController.maxOwnSlices))
        var slices: [ChartSlice] = []
        var headSlice: [ObjectIdentifier: Int] = [:]
        var rest: ChartSlice?
        var restIndex = -1
        var colour = 0
        for (i, info) in rows.enumerated() {
            // Only the top level of a tree-list (Contents): expanded rows are inside their folder's slice.
            if info.depth > 0 || info.noSlice { continue }
            if let g = info.groupOf, let head = headSlice[ObjectIdentifier(g)] {
                slices[head].rows.append(i)
                rowSlice[i] = head
                continue
            }
            let size = info.chartSize
            let at: Int
            if own.contains(i) {
                let s = ChartSlice(info.name, size, T.CHART[colour % T.CHART.count])
                colour += 1
                s.detail = Fmt.pct(100 * Double(size) / Double(total)) + " " + scopeText
                if info.isDir, let d = info.dir, isAttached(d) { s.dir = d }
                s.rows = [i]
                slices.append(s)
                at = slices.count - 1
            } else {
                if rest == nil { let n = ChartSlice("", 0, T.CHART_OTHER); slices.append(n); rest = n; restIndex = slices.count - 1 }
                rest!.rows.append(i)
                rest!.size += max(0, size)
                at = restIndex
            }
            rowSlice[i] = at
            headSlice[ObjectIdentifier(info)] = at
        }
        if let s = rest {
            let n = s.rows.filter { rows[$0].groupOf == nil }.count
            s.label = n == 1 ? rows[s.rows[0]].name : "\(Fmt.count(n)) smaller items"
            s.detail = Fmt.pct(100 * Double(s.size) / Double(total)) + " " + scopeText
        }
        return slices
    }

    /// Folder contents chart with two outer rings; a drive root also gets "System / not readable" and "Free space".
    func updateChart(_ d: DirNode) {
        if chartOnHold { showScanLogo(); return }
        let r = rootOf(d.top)
        if let r = r { refreshCapacity(r) }
        var slices = buildSlices(pContents, d.size, "of folder")
        var title = d.name, sub = d.fullPath
        if d.parent == nil, let r = r {
            title = r.displayName
            if r.showsCapacity {
                if r.used - d.size > 0 {
                    let s = ChartSlice("System / not readable", r.used - d.size, T.PILL)
                    s.detail = Fmt.pct(100 * Double(r.used - d.size) / Double(r.total)) + " of drive"
                    slices.append(s)
                }
                let f = ChartSlice("Free space", r.free, T.CHART_FREE)
                f.empty = true
                f.detail = Fmt.pct(100 * Double(r.free) / Double(r.total)) + " of drive"
                slices.append(f)
                sub = "\(Fmt.size(r.used)) used of \(Fmt.size(r.total))  -  \(Fmt.size(r.free)) free"
            }
        }
        chart.setData(title, sub, slices, rings: 2)
        let centre = d.parent == nil ? (r.map { $0.isDrive ? $0.displayName : (($0.path as NSString).lastPathComponent) } ?? d.name) : d.name
        chart.setCenter(centre, canGoUp: d.parent != nil, free: d.parent == nil && (r?.showsCapacity ?? false) ? r!.free : -1)
    }

    /// While a scan runs (or a saved scan is brought up to date at start-up) the numbers are still changing: the chart
    /// pane shows the logo whatever view is open; when it is done the next refresh turns the logo into the chart.
    var chartOnHold: Bool { scanning || holdChart || roots.contains { $0.replay != nil } }

    func showScanLogo() {
        rowSlice = [:]
        let r = scanRoot ?? active
        let sub = r.map { $0.total > 0 ? "\(Fmt.size($0.used)) used of \(Fmt.size($0.total))  -  \(Fmt.size($0.free)) free" : $0.path } ?? ""
        // The logo's working loop says enough: no text under it.
        chart.showLogo(r?.displayName ?? "", sub, "", working: true)
    }

    /// Nothing scanned yet: the chart pane shows the app logo; it morphs into the chart once the scan is done.
    func updateChartUnscanned(_ r: ScanRoot) {
        rowSlice = [:]
        let sub = r.total > 0 ? "\(Fmt.size(r.used)) used of \(Fmt.size(r.total))  -  \(Fmt.size(r.free)) free" : r.path
        chart.showLogo(r.displayName, sub, r.scanning ? "" : "Not scanned yet. Press Scan, or double-click the drive.",
                       working: r.scanning || scanning)
    }

    func onListDoubleClick(_ p: Page) {
        let sel = p.selectedItems
        guard sel.count == 1 else { return }
        let info = sel[0]
        if p === pTypes {
            // Open the Files view with this type.
            if let e = info.ext { fileType.selectedIndex = 0; fileSearch.text = e.isEmpty ? "" : "*." + e }
            else { fileSearch.text = ""; fileType.selectedIndex = (FileTypes.categories.firstIndex(of: info.category) ?? -1) + 1 }
            pageIndex = pages.firstIndex { $0 === pFiles } ?? 1
            fillFiles()
            return
        }
        if info.isGroup || info.isSummary {
            if p === pSystem && info.groupOf == nil { expandSystem([info], nil) }
            return
        }
        // A suggestion, or a folder in it, opens and closes; files show in Finder.
        if p === pSuggest && info.suggestion != nil && (info.groupOf == nil ? info.chevron >= 0 : info.expandable) { expandSuggestions([info], nil); return }
        // An app opens and closes (showing all its files).
        if p === pApps, info.app != nil, info.groupOf == nil { expandApps([info], nil); return }
        openSelected()
    }

    func showFilesSearch() {
        pageIndex = pages.firstIndex { $0 === pFiles } ?? 1
        fileSearch.focus()
    }

    func setStale(_ p: Page) { p.stale = true; if activePage === p { p.stale = false; p.fill() } }

    // MARK: Files view

    func currentFileFilter() -> FileFilter {
        let f = FileFilter()
        f.patterns = fileSearch.text.split(whereSeparator: { $0 == ";" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        if fileType.selectedIndex > 0 { f.category = FileTypes.categories[fileType.selectedIndex - 1] }
        f.minSize = MainWindowController.minSizes[fileMinSize.selectedIndex]
        let months = MainWindowController.ageMonths[fileAge.selectedIndex]
        if months > 0, let d = Calendar.current.date(byAdding: .month, value: -months, to: Date()) { f.modifiedBefore = Int64(d.timeIntervalSince1970) }
        if months < 0, let d = Calendar.current.date(byAdding: .month, value: months, to: Date()) { f.usedBefore = Int64(d.timeIntervalSince1970) }
        return f
    }

    /// Whether macOS records when files are opened on the volume holding path: not on volumes mounted "noatime" (then
    /// the last-access time only moves when a file changes).
    static func lastAccessRecorded(_ path: String) -> Bool {
        var st = statfs()
        if statfs(path, &st) != 0 { return true }
        return st.f_flags & UInt32(MNT_NOATIME) == 0
    }

    func fillFiles() {
        let p = pFiles!
        p.chartTitle = "Files"
        let everywhere = fileScope.selectedIndex == 1
        let sc = scope()
        let scopes: [DirNode] = everywhere ? roots.compactMap { $0.node } : (sc.map { [$0] } ?? [])
        if scopes.isEmpty {
            p.setCaption("Nothing scanned yet.")
            p.chartSub = ""
            p.empty = "Scan a drive or folder first."
            p.setRows([], "Scan a drive or folder to search its files.")
            if activePage === p { refreshChart() }
            return
        }
        let scopePath = everywhere ? (scopes.count == 1 ? scopes[0].fullPath : "\(Fmt.count(scopes.count)) scanned drives and folders") : scopes[0].fullPath
        let filter = currentFileFilter()
        // Folders have no type or dates of their own here, so only a name search (and the size) finds them.
        let withFolders = !filter.patterns.isEmpty && filter.category == nil && filter.modifiedBefore <= 0 && filter.usedBefore <= 0
        let noAtime = filter.usedBefore > 0 && !scopes.allSatisfy { MainWindowController.lastAccessRecorded($0.fullPath) }
        filesGen += 1
        let gen = filesGen
        p.setCaption("Searching " + scopePath + "...")
        readInBackground({ () -> ([ItemInfo], Int64, Int64, Int, Int64) in
            let found = FileIndex.largest(scopes, MainWindowController.topCount, filter)
            let dirs = withFolders ? FileIndex.folders(scopes, MainWindowController.topCount, filter) : (dirs: [DirNode](), count: Int64(0))
            let folder = max(Int64(1), scopes.reduce(Int64(0)) { $0 + $1.size })
            var rows: [ItemInfo] = []
            var shown: Int64 = 0
            for d in dirs.dirs {
                let it = ItemInfo.forDir(d, folder)
                it.folder = d.parent?.fullPath ?? ""
                it.category = "Folder"
                it.chartValue = 0       // a folder's size also holds matching files: the chart shows the files only
                it.cells = [it.name, Fmt.size(it.size), Fmt.pct(it.percent), it.folder, it.category, Fmt.date(it.modified), ""]
                rows.append(it)
            }
            for fe in found.files {
                let it = ItemInfo.forFile(fe, folder)
                it.folder = fe.dir.fullPath
                it.category = FileTypes.category(FileIndex.ext(fe.name))
                shown += fe.size
                it.cells = [it.name, Fmt.size(it.size), Fmt.pct(it.percent), it.folder, it.category, Fmt.date(it.modified), Fmt.date(it.used)]
                rows.append(it)
            }
            if found.count > Int64(found.files.count) {
                let rest = ItemInfo()
                rest.isSummary = true
                rest.name = "[\(Fmt.count(found.count - Int64(found.files.count))) smaller matching files not listed]"
                rest.size = found.size - shown; rest.files = found.count - Int64(found.files.count)
                rest.percent = 100 * Double(found.size - shown) / Double(folder)
                rest.cells = [rest.name, Fmt.size(rest.size), Fmt.pct(rest.percent), "", "", "", ""]
                rest.tip = rest.name + "\n" + scopePath
                rows.append(rest)
            }
            return (rows, found.count, found.size, found.files.count, dirs.count)
        }, { [weak self] res in
            guard let self = self, gen == self.filesGen else { return }
            let (rows, count, size, shownCount, dirCount) = res
            let filtered = !filter.isEmpty
            p.setRows(rows, filtered ? "Nothing matches the filters in \(scopePath)." : "No files in \(scopePath).")
            let folders = dirCount > 0 ? " and \(Fmt.count(dirCount)) folder\(dirCount == 1 ? "" : "s")" : ""
            p.setCaption("\(Fmt.count(count)) \(filtered ? "matching " : "")files\(folders) in \(Fmt.shorten(scopePath, 70)), \(Fmt.size(size))"
                         + (count > Int64(shownCount) ? "  -  showing the largest \(Fmt.count(shownCount))" : "")
                         + (noAtime ? "  -  this volume doesn't record when files are opened, so \"not opened\" uses the last change" : ""))
            p.chartTitle = filtered ? "Matching files" : "Largest files"
            p.chartSub = scopePath
            p.chartTotal = 0
            p.chartScope = "of the matches"
            p.empty = filtered ? "No files match." : "No files."
            if self.activePage === p { self.refreshChart() }
        })
    }

    // MARK: File types view

    func fillTypes() {
        let p = pTypes!
        p.chartTitle = "File types"
        guard let sc = scope() else {
            p.setCaption("Nothing scanned yet.")
            p.chartSub = ""
            p.empty = "Scan a drive or folder first."
            p.setRows([], "Scan a drive or folder to see its file types.")
            if activePage === p { refreshChart() }
            return
        }
        let byCategory = typeGroup.selectedIndex == 1
        typesGen += 1
        let gen = typesGen
        let scopePath = sc.fullPath
        p.setCaption("Counting file types in " + scopePath + "...")
        readInBackground({ () -> ([ItemInfo], Int64) in
            var sizes: [String: (Int64, Int64)] = [:]
            for d in sc.descendants() {
                guard let list = d.fileList else { continue }
                for f in list {
                    let e = FileIndex.ext(f.name)
                    let key = byCategory ? FileTypes.category(e) : e
                    let v = sizes[key] ?? (0, 0)
                    sizes[key] = (v.0 + FileIndex.measure(f), v.1 + 1)
                }
            }
            let total = max(Int64(1), sc.size)
            var rows: [ItemInfo] = []
            for (k, v) in sizes {
                let it = ItemInfo()
                it.size = v.0; it.files = v.1; it.percent = 100 * Double(v.0) / Double(total)
                if byCategory { it.name = k; it.category = k }
                else { it.ext = k; it.name = k.isEmpty ? "(no extension)" : "." + k; it.category = FileTypes.category(k) }
                it.cells = [it.name, Fmt.size(it.size), Fmt.pct(it.percent), Fmt.count(it.files), byCategory ? "" : it.category]
                it.tip = MainWindowController.typeTip(it.name, it.files, scopePath)
                rows.append(it)
            }
            return (rows, sc.size)
        }, { [weak self] res in
            guard let self = self, gen == self.typesGen else { return }
            p.setRows(res.0, "No files in \(scopePath).")
            p.setCaption("\(Fmt.count(res.0.count)) \(byCategory ? "categories" : "file types") in \(Fmt.shorten(scopePath, 80))  -  double-click one to list its files")
            p.chartSub = scopePath
            p.chartTotal = res.1
            p.empty = "No files."
            if self.activePage === p { self.refreshChart() }
        })
    }

    /// Tooltip of a file type row: the type, then how many files of it the folder holds.
    static func typeTip(_ type: String, _ files: Int64, _ scopePath: String) -> String {
        "\(type)\n\(Fmt.count(files)) file\(files == 1 ? "" : "s") in \(scopePath)"
    }
}

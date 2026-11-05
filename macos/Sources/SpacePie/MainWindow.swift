import AppKit
import Quartz

/// A top-level entry of This PC: a drive (scanned or not) or a folder the user scanned.
final class ScanRoot {
    var path: String
    var isDrive = false, isSystem = false
    var label = ""
    var total: Int64 = 0, free: Int64 = 0
    var node: DirNode?
    var scanning = false
    var previous: PrevNode?            // the scan before this one (folder sizes only), for the Changes view
    var previousTime = Date.distantPast
    var replay: Replay?                // shown from its snapshot while FSEvents replays the changes since
    /// A scan opened from a file (Open scan): browsed only; nothing is rescanned, watched or deleted.
    var readOnly = false
    var sourceFile = ""
    var scanned = Date.distantPast     // when the scan shown was made (distantPast = unknown)
    init(path: String) { self.path = path }
    var displayName: String {
        if readOnly { return path + "  (saved scan, " + Fmt.date(scanned) + ")" }
        return isDrive && !label.isEmpty ? label : path
    }
    var used: Int64 { max(0, total - free) }
    /// The chart shows the drive's free space and the part not scanned: a drive, or a saved scan of a whole volume.
    var showsCapacity: Bool {
        if isDrive { return total > 0 }
        return readOnly && total > 0 && (path == "/" || PathUtil.parent(path) == "/Volumes")
    }
}

// MARK: - Header views

final class DarkHeaderCell: NSTableHeaderCell {
    var active = false
    var right = false
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        T.SURFACE.setFill(); cellFrame.fill()
        T.BORDER.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 6, width: 1, height: cellFrame.height - 12).fill()
        Theme.drawText(stringValue, in: cellFrame.insetBy(dx: 7, dy: 0), font: Theme.font, color: active ? T.ACCENT : T.MUTED, align: right ? .right : .left)
    }
}

final class DarkHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        T.SURFACE.setFill(); bounds.fill()
        T.BORDER.setFill(); NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        super.draw(dirtyRect)
    }
}

/// Rounded panel that lays out its content in the inner rectangle.
final class ContainerPanel: PanelView {
    var onLayout: ((NSRect) -> Void)?
    override func layout() { super.layout(); onLayout?(bounds.insetBy(dx: 8, dy: 8)) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
}

// MARK: - Main window

final class MainWindowController: NSWindowController, NSMenuDelegate,
    NSSplitViewDelegate, NSTextFieldDelegate, NSWindowDelegate {

    static let topCount = 1000
    static let maxFilesShown = 2000
    static let chromeHeight: CGFloat = 12 + 32 + 8 + 32 + 10 + 28     // toolbar rows above the main area, status line below
    static let listMinWidth: CGFloat = 360
    /// The level above every drive (Contents, the path bar and the chart).
    static let thisPcName = "This Mac"

    // Model
    var roots: [ScanRoot] = []
    var active: ScanRoot?
    var current: DirNode?
    var rowSlice: [Int: Int] = [:]
    var scanner: Scanner?
    var scanRoot: ScanRoot?
    var scanUsed: Int64 = 0                // the scanned drive's used space (progress), read once per scan
    var deleteJob: DeleteJob?
    var deleteFinished = Set<String>()     // targets of the running delete that are done
    var deleteTargetPaths: [String] = []   // the running delete's targets
    var deleteRowsRemoved = 0              // rows that left the lists while it ran
    var scanning = false
    var holdChart = false                  // a saved scan is shown and a rescan is about to start: the chart waits
    var busy = false
    var drivesChanged = false
    weak var lastView: NSView?
    var progressTimer: Timer?
    var onScanFinished: (() -> Void)?
    var readers = 0                       // background tasks reading the scanned trees (the trees must not change meanwhile)
    var liveWorking = false               // a batch of live changes is being worked out in the background
    /// Contents lists the drives and scanned folders (This PC, the level above every drive).
    var thisPc = false
    /// Folders opened in place in the Contents tree-list.
    var expandedDirs: [ObjectIdentifier: DirNode] = [:]
    /// The view shown (index in pages); the rail follows it.
    var pageIndex = 0 { didSet { if oldValue != pageIndex { syncRail(); showPage() } } }

    // Toolbar and panes
    let root = DropView()
    let pathLabel = NSTextField(labelWithString: "Location:")
    let pathPanel = ContainerPanel()
    let pathField = NSTextField()
    let drivesButton = ChevronButton()
    lazy var btnBrowse = RoundButton("Choose...", .secondary) { [unowned self] in self.browse() }
    lazy var btnScan = RoundButton("Scan", .primary) { [unowned self] in self.startScan() }
    lazy var btnAccess = RoundButton("Full Disk Access...", .secondary) { [unowned self] in self.openFullDiskAccess() }
    lazy var btnBack = RoundButton(icon: { (r: NSRect, c: NSColor) in Theme.drawArrow(r, c, left: true) }, { [unowned self] in self.goBack() })
    lazy var btnForward = RoundButton(icon: { (r: NSRect, c: NSColor) in Theme.drawArrow(r, c, left: false) }, { [unowned self] in self.goForward() })
    lazy var btnUp = RoundButton("Up", .secondary) { [unowned self] in self.goUp() }
    lazy var btnRescan = RoundButton(refresh: { [unowned self] in self.rescanSelected() })
    lazy var btnFinder = RoundButton("Show in Finder", .secondary) { [unowned self] in self.showInFinder() }
    lazy var btnAddList = RoundButton("Add to delete list", .secondary) { [unowned self] in self.addSelectionToBasket() }
    lazy var btnDelete = RoundButton("Delete permanently", .danger) { [unowned self] in self.deleteSelected() }
    /// Opens the delete list (not in the rail); its title counts the items: "Delete list (4)".
    lazy var btnBasket = RoundButton("Delete list", .warn) { [unowned self] in self.showView(self.pBasket) }
    lazy var btnExport = RoundButton("Export...", .secondary) { [unowned self] in self.exportScan() }
    lazy var btnOpenScan = RoundButton("Open scan...", .secondary) { [unowned self] in self.openScanDialog() }
    let measure = Segmented(["Size", "Size on disk"])
    let scanBar = ScanBar()
    let split2 = NSSplitView()
    /// The main area under the toolbar: the rail of views on the left, then the list | chart split.
    let rightPane = LayoutView()
    let listPanel = ContainerPanel()
    // Keep in the order of buildViews() (Pages.swift), without the delete list (railPages).
    let viewTabs = NavRail(["Contents", "Suggestions", "Apps", "System", "Files", "File types", "Duplicates", "Changes"])
    let chartPanel = ContainerPanel()
    let chart = PieChart()
    /// Pie or treemap, top right of the chart pane; the choice is remembered (UserDefaults).
    let chartMode = Segmented(["Pie", "Treemap"])
    static let treemapKey = "ChartTreemap"
    let statusLabel = CutLabel(labelWithString: "Choose a drive or folder and press Scan.")
    let liveLabel = CutLabel(labelWithString: "")
    let driveLabel = CutLabel(labelWithString: "")
    lazy var versionLink = LinkLabel("v" + Updater.currentString) { [unowned self] in self.updates.check(manual: true) }
    let deleteBar = ScanBar()
    let workBar = ScanBar()               // long actions that delete nothing (replace with clones)
    lazy var lowSpaceLink = LinkLabel("Show suggestions") { [unowned self] in self.showSuggestionsTab() }
    var lowSpaceText = ""
    var lowWarned = Set<String>()         // volumes warned about low space this session
    let contextMenu = NSMenu()
    lazy var updates = UpdateController(parent: window)
    var split2Positioned = false
    /// Zoom of everything in the window (⌘+ / ⌘- / ⌘0); remembered between starts.
    var zoom: CGFloat = MainWindowController.savedZoom

    // Views (tabs)
    var pages: [Page] = []
    var pContents: Page!, pFiles: Page!, pTypes: Page!, pDupes: Page!, pSuggest: Page!, pApps: Page!, pSystem: Page!, pChanges: Page!, pBasket: Page!
    var contents: HoverTable { pContents.table }

    // Files view
    let fileSearch = SearchBox("Search names  (e.g. *.iso, invoice, node_modules)")
    let fileScope = ChoiceBox("", ["In the selected folder", "In everything scanned"])
    let fileType = ChoiceBox("", ["Any type"] + FileTypes.categories)
    let fileMinSize = ChoiceBox("", ["Any size", "1 MB or more", "10 MB or more", "100 MB or more", "1 GB or more"])
    let fileAge = ChoiceBox("", ["Any date", "Not changed for 3 months", "Not changed for 6 months", "Not changed for 1 year",
                                 "Not changed for 2 years", "Not changed for 5 years", "Not opened for 3 months", "Not opened for 6 months",
                                 "Not opened for 1 year", "Not opened for 2 years"])
    var filesGen = 0
    // File types view
    let typeGroup = ChoiceBox("Group by: ", ["Extension", "Category"])
    let appFilter = ChoiceBox("", ["All apps", "Not opened for 6 months"])
    var typesGen = 0
    // Duplicates view
    lazy var btnFindDupes = RoundButton("Find duplicates", .primary) { [unowned self] in self.findDuplicates() }
    let dupeMin = ChoiceBox("", ["Files of 1 MB or more", "Files of 10 MB or more", "Files of 100 MB or more", "All files"])
    lazy var btnSelectExtra = RoundButton("Select extra copies", .secondary) { [unowned self] in self.selectExtraCopies() }
    lazy var btnClone = RoundButton("Replace with clones", .secondary) { [unowned self] in self.replaceSelectedWithClones() }
    var cloneJob: CloneJob?
    var dupeCacheNote = ""
    var dupeFinder: DuplicateFinder?
    var dupeGroups: [[FileEntry]]?
    var dupeScope = ""
    var dupeTimer: Timer?
    var onDupesFinished: (() -> Void)?
    // Suggestions view
    lazy var btnLookAgain = RoundButton(refresh: { [unowned self] in self.suggestDirty = true; self.fillSuggestions(clear: true) })
    lazy var btnSugAll = RoundButton("Select all", .secondary) { [unowned self] in self.checkAllSuggestions(true) }
    lazy var btnSugNone = RoundButton("Deselect all", .secondary) { [unowned self] in self.checkAllSuggestions(false) }
    lazy var btnSugDelete = RoundButton("Delete permanently", .danger) { [unowned self] in self.deleteCheckedSuggestions(trash: false) }
    lazy var btnSugIgnored = RoundButton("Ignored", .secondary) { [unowned self] in self.showIgnoredSuggestions() }
    var suggestGen = 0
    var suggestions: [Suggestion]?
    var suggestDirty = false          // the scanned data changed since the suggestions were found: find them again
    var suggestFinding = false
    var lastSuggestFind = Date.distantPast   // live changes look again at most every 20 s
    // Apps view (uninstaller)
    lazy var btnAppsRefresh = RoundButton(refresh: { [unowned self] in self.loadApps() })
    let appSearch = SearchBox("Search apps")
    lazy var btnUninstall = RoundButton("Uninstall...", .warn) { [unowned self] in self.uninstallSelectedApp() }
    lazy var btnRemoveLeftovers = RoundButton("Remove leftovers", .warn) { [unowned self] in self.removeCheckedLeftovers() }
    var apps: [InstalledApp]?
    var appRoots: [String]?               // where to look for apps (nil = /Applications, its Utilities, ~/Applications)
    var appsGen = 0
    var appsLoading = false
    var appsFromCache = false             // apps is the list saved last time (not read yet in this session)
    var appsPrefetch: AppsRead?           // the reading started at launch, while the disk is scanned
    var appsReadMs = 0, appsAfterScanMs = 0   // the last reading: bundles and icons; sizes after the scan
    var appsWorking = false               // looking for an app's files before uninstalling it
    var autoAccept = false                // screenshot run: no confirmations
    var shotMode = false                  // --cli screenshot: never asks for an administrator password
    // System view
    lazy var btnSysRefresh = RoundButton(refresh: { [unowned self] in self.loadSystem() })
    lazy var btnSysSuggest = RoundButton("Show suggestions", .secondary) { [unowned self] in self.showSuggestionsTab() }
    lazy var btnSysDelete = RoundButton("Delete...", .warn) { [unowned self] in self.deleteSelectedSystemItems() }
    lazy var btnSysDeleteAll = RoundButton("Delete all local snapshots...", .warn) { [unowned self] in self.deleteAllLocalSnapshots() }
    var systemGroups: [SysGroup]?
    var systemLoading = false
    var systemLoadedAt = Date.distantPast
    var systemWaiters: [() -> Void] = []
    var sysStop: StopFlag?                // Stop on the delete strip while local snapshots are deleted
    // Fast restart (Snapshot.swift)
    var fastStart = false                 // start-up shows the last scan and replays the changes since
    var fsDeep: [String] = []             // folders to scan again as a whole (FSEvents could not list their changes)
    var onReplayDone: ((String, String?) -> Void)?   // root path, why it fell back to a scan (nil = replayed)
    // Delete list
    var basket: [DeleteTarget] = []
    lazy var btnBasketRemove = RoundButton("Remove from list", .secondary) { [unowned self] in self.removeFromBasket() }
    lazy var btnBasketClear = RoundButton("Clear list", .secondary) { [unowned self] in self.basket.removeAll(); self.basketChanged() }
    lazy var btnBasketTrash = RoundButton("Move to Trash", .secondary) { [unowned self] in self.deleteBasket(trash: true) }
    lazy var btnBasketDelete = RoundButton("Delete permanently", .danger) { [unowned self] in self.deleteBasket(trash: false) }
    // Live updates
    var streams: [LiveStream] = []
    var fsPending: [String] = []
    var missed: [ScanRoot] = []
    var liveTimer: Timer?
    var ownPaths: [String] = []           // targets of our own (last) delete
    var ownDeleting = false
    var ownUntil = Date.distantPast
    var lastLiveRefresh = Date.distantPast
    var livePending = false
    // Self-test (--cli selftest)
    var selfTestDir: String?
    var selfTestFailed = false
    // Back / Forward, path bar, unreadable folders (Navigation.swift)
    var navBack: [NavEntry] = []
    var navForward: [NavEntry] = []
    var navigating = false
    let crumbs = Breadcrumb()
    let unreadBanner = Banner()
    var unreadAccess: RoundButton?
    /// Scanned trees whose unreadable-folders banner was closed (shown again after the next scan: a new tree).
    var unreadClosed: [DirNode] = []
    var unreadCanGrant: Bool?             // self-test: whether giving access would open the folders (nil = ask the system)
    var deniedCache: [ObjectIdentifier: (top: DirNode, list: [DirNode])] = [:]
    var mouseMonitor: Any?
    // Changes: compare any two scans (History.swift)
    let changeFrom = ChoiceBox("From: ", ["Previous scan"])
    let changeTo = ChoiceBox("To: ", ["Now"])
    let historyStrip = HistoryStrip()
    var fromChoices: [ScanChoice] = []
    var toChoices: [ScanChoice] = []
    var archiveCache: [String: PrevNode] = [:]
    weak var changesRoot: ScanRoot?
    // Quick Look (Preview.swift)
    var quickLookURLs: [URL] = []
    let quickLookSource = QuickLookSource()

    convenience init() {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Wide enough for the rail of views, a list of about 400 px and a chart pane 4/5 as wide as the main area is high.
        let height = min(760, vf.height * 0.85)
        let wanted = 2 * 15 + NavRail.width + 10 + 400 + 2 + (height - MainWindowController.chromeHeight) * 0.8
        let size = NSSize(width: min(max(1280, wanted), vf.width * 0.92), height: height)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "SpacePie"
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = T.BG
        w.minSize = NSSize(width: min(900, vf.width), height: min(520, vf.height))
        w.setFrameOrigin(NSPoint(x: vf.midX - w.frame.width / 2, y: vf.midY - w.frame.height / 2))
        self.init(window: w)
        w.delegate = self
        build()
    }

    // MARK: Build

    private func build() {
        guard let w = window else { return }
        root.fill = T.BG
        w.contentView = root

        pathLabel.font = Theme.font; pathLabel.textColor = T.FG
        pathField.isBordered = false; pathField.drawsBackground = true; pathField.backgroundColor = T.SURFACE
        pathField.textColor = T.FG; pathField.font = Theme.font; pathField.focusRingType = .none
        pathField.delegate = self
        pathField.placeholderString = "Drive or folder"
        pathField.cell?.isScrollable = true
        pathPanel.radius = 8
        pathPanel.addSubview(pathField); pathPanel.addSubview(drivesButton)
        pathPanel.onLayout = { [unowned self] _ in
            let b = self.pathPanel.bounds
            self.drivesButton.frame = NSRect(x: b.width - 30, y: 1, width: 26, height: b.height - 2)
            let fh: CGFloat = 18
            self.pathField.frame = NSRect(x: 10, y: (b.height - fh) / 2, width: b.width - 44, height: fh)
        }
        drivesButton.onPress = { [unowned self] in self.showDrivesMenu() }
        btnBrowse.tip = "Choose a folder to analyze (⌘O)"
        btnScan.tip = "Analyze the drive or folder (Return)"
        btnFinder.tip = "Show the selected item in Finder (⇧⌘R)"
        btnAccess.tip = "Let the app read every folder (System Settings > Privacy & Security > Full Disk Access)"
        btnUp.tip = "Go to the parent folder (⌘↑)"
        btnBack.tip = "Back to the folder shown before (⌘[)"
        btnForward.tip = "Forward again (⌘])"
        btnRescan.tip = "Rescan the selected folder (⌘R)"
        btnAddList.tip = "Collect the selected items in the delete list; review them there, then delete them together (⌘D)"
        btnDelete.tip = "Permanently delete the selected items, bypassing the Trash (⇧⌘D or ⌘⌫)"
        btnBasket.tip = "Show the delete list: the items collected with Add to delete list, to review and delete together"
        btnExport.tip = "Save the scan as an HTML report, a CSV file, or a scan file to open again later (⇧⌘E)"
        btnOpenScan.tip = "Open a scan saved with Export (.\(Snapshot.scanFileExtension)): browse it read-only, next to the drives (⇧⌘O)"
        measure.tip = "Size: file lengths, as Finder shows them. Size on disk: the space really used (blocks, files not downloaded from iCloud)"
        measure.selectedIndex = DirNode.onDisk ? 1 : 0
        measure.onChange = { [unowned self] i in self.setMeasure(i == 1) }
        for v: NSView in [pathLabel, pathPanel, btnBrowse, btnScan, btnAccess, btnBack, btnForward, btnUp, btnRescan, btnFinder, btnAddList, btnDelete,
                          btnBasket, btnOpenScan, btnExport, measure, scanBar, statusLabel, liveLabel, driveLabel, versionLink] {
            root.addSubview(v)
        }
        // The main area lies below the toolbar in z-order too, so nothing it draws can cover the toolbar.
        root.addSubview(rightPane, positioned: .below, relativeTo: nil)
        for l in [statusLabel, driveLabel, liveLabel] { l.font = Theme.font9; l.textColor = T.MUTED; l.lineBreakMode = .byTruncatingTail }
        driveLabel.alignment = .right
        liveLabel.alignment = .right

        scanBar.cancelButton.onClick = { [unowned self] in self.scanner?.cancel(); self.scanBar.cancelButton.isEnabled = false }
        updates.canRestart = { [unowned self] in !self.busy }

        // Views above the list and the chart
        buildViews()
        for p in pages {
            listPanel.addSubview(p.root)
            p.table.menu = contextMenu
            p.table.target = self
            p.table.doubleAction = #selector(listDoubleClick(_:))
            let t = p.table
            p.table.onKey = { [unowned self] e in self.handleKey(e, in: t) }
            p.table.onHot = { [unowned self, unowned p] r in
                if self.activePage === p { self.chart.setHover(self.rowSlice[r] ?? -1) }
            }
            p.onSorted = { [unowned self] pg in if self.activePage === pg { self.refreshChart() } }
            p.onSelection = { [unowned self] pg in self.lastView = pg.table; self.updateButtons() }
            p.knownFor = { it in it.scanRoot != nil ? nil : MainWindowController.knownFor(it) }
        }
        activePage.root.isHidden = false
        if let si = railPages.firstIndex(where: { $0 === pSuggest }) { viewTabs.setColor(si, T.SUGGEST) }
        listPanel.onLayout = { [unowned self] r in for p in self.pages { p.root.frame = r } }
        viewTabs.background = T.BG
        viewTabs.onChange = { [unowned self] i in
            let rp = self.railPages
            if i >= 0 && i < rp.count { self.showView(rp[i]) }
        }
        syncRail()

        // Chart
        chartPanel.addSubview(chart)
        // Pie or treemap, top right of the chart pane (the title leaves room for it); the choice is remembered.
        chartMode.font = Theme.font9
        chartMode.backFill = T.SURFACE
        chartMode.tip = "Show the open list as a pie chart or as a treemap (rectangles sized by space)"
        chart.treemap = UserDefaults.standard.bool(forKey: MainWindowController.treemapKey)
        chartMode.selectedIndex = chart.treemap ? 1 : 0
        chartMode.onChange = { [unowned self] i in
            self.chart.treemap = i == 1
            UserDefaults.standard.set(i == 1, forKey: MainWindowController.treemapKey)
        }
        chartPanel.addSubview(chartMode)
        chartPanel.onLayout = { [unowned self] r in
            self.chart.frame = r
            let cs = self.chartMode.preferredSize
            self.chartMode.frame = NSRect(x: r.maxX - cs.width - 10, y: r.minY + 10, width: cs.width, height: cs.height)
            self.chart.titleRightMargin = cs.width + 10
        }
        chart.onHover = { [unowned self] i in
            self.activePage.table.setHighlight(i >= 0 && i < self.chart.slices.count ? self.chart.slices[i].rows : [])
        }
        chart.onClick = { [unowned self] s in if let d = s.dir, self.isAttached(d) { self.selectDir(d) } }
        chart.onCenterClick = { [unowned self] in if self.activePage === self.pContents { self.goUp() } }

        split2.isVertical = true
        split2.dividerStyle = .thin
        split2.delegate = self
        split2.addArrangedSubview(listPanel); split2.addArrangedSubview(chartPanel)
        split2.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 0)
        split2.setHoldingPriority(NSLayoutConstraint.Priority(270), forSubviewAt: 1)
        rightPane.fill = T.BG
        rightPane.addSubview(viewTabs); rightPane.addSubview(split2)
        rightPane.onLayout = { [unowned self] r in
            self.viewTabs.frame = NSRect(x: 0, y: 0, width: NavRail.width, height: r.height)
            let x = NavRail.width + 10
            self.split2.frame = NSRect(x: x, y: 0, width: max(50, r.width - x), height: r.height)
            // Once the main area has its width: the chart pane 4/5 as wide as it is high, the list gets the rest.
            if !self.split2Positioned && r.width - x > 400 {
                self.split2Positioned = true
                let w = r.width - x, div = self.split2.dividerThickness
                // The height without the scan bar (the first scan may have started already).
                let h = self.root.bounds.height - MainWindowController.chromeHeight
                let chartW = max(180, min(h * 0.8, w - MainWindowController.listMinWidth - div))
                self.split2.setPosition(w - chartW - div, ofDividerAt: 0)
            }
        }

        // Context menu
        contextMenu.delegate = self
        contextMenu.appearance = NSAppearance(named: .darkAqua)

        // Deleting: the strip stays in the toolbar area (danger colours); the window stays browsable meanwhile.
        deleteBar.danger = true
        deleteBar.cancelButton.tip = "Stop deleting after the current file; whatever was not deleted yet stays"
        deleteBar.cancelButton.onClick = { [unowned self] in
            if let s = self.sysStop { s.stopped = true; self.deleteBar.cancelButton.isEnabled = false; return }
            guard let j = self.deleteJob, !j.stopped else { return }
            j.stop()
            self.deleteBar.cancelButton.isEnabled = false
        }
        root.addSubview(deleteBar)
        workBar.cancelButton.tip = "Stop after the current file; whatever was not done yet stays as it is"
        root.addSubview(workBar)
        lowSpaceLink.isHidden = true
        root.addSubview(lowSpaceLink)

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)

        buildNavigation()
        // A scan file (.spacepie) dropped on the window opens read-only; a folder dropped on it is scanned.
        root.canDrop = { [unowned self] u in
            !self.busy && (MainWindowController.isScanFile(u.path) || (!self.scanning && PathUtil.isDir(u.path)))
        }
        root.onDrop = { [unowned self] u in
            if MainWindowController.isScanFile(u.path) { self.openScanFile(u.path) } else { self.scanPath(u.path) }
        }
        root.registerForDraggedTypes([.fileURL])

        root.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(layoutRoot), name: NSView.frameDidChangeNotification, object: root)
        // Full Disk Access can be granted while the app runs: check again whenever the app comes to the front.
        NotificationCenter.default.addObserver(self, selector: #selector(updateAccessButton), name: NSApplication.didBecomeActiveNotification, object: nil)
        btnAccess.isHidden = FullDiskAccess.granted
        layoutRoot()
        updateButtons()
        updateLiveLabel()
    }

    /// The path field without a selected text and without the focus (the lists have it): a field keeps showing its
    /// last selection after editing ends.
    func clearPathSelection() {
        if window?.firstResponder !== pathField.currentEditor() { window?.makeFirstResponder(pathField) }
        pathField.currentEditor()?.selectedRange = NSRange(location: 0, length: 0)
        window?.makeFirstResponder(contents)
    }

    /// The Full Disk Access button is only shown while access is missing (scans check it themselves each time).
    @objc func updateAccessButton() {
        let granted = FullDiskAccess.granted
        if btnAccess.isHidden == granted { return }
        btnAccess.isHidden = granted
        layoutRoot()
    }

    @objc func layoutRoot() {
        // Zoom: the content view's coordinates are scaled, so every view and its text is drawn larger or smaller (sharp,
        // not a bitmap scale); the layout below works in those zoomed points.
        let want = NSSize(width: (root.frame.width / zoom).rounded(), height: (root.frame.height / zoom).rounded())
        if root.bounds.size != want { root.setBoundsSize(want); root.setBoundsOrigin(.zero); root.needsDisplay = true }
        let b = root.bounds
        let m: CGFloat = 15, gap: CGFloat = 6
        var y: CGFloat = 12
        let h: CGFloat = 32
        let ap = btnAccess.preferredSize, sp = btnScan.preferredSize, bp = btnBrowse.preferredSize
        btnAccess.frame = NSRect(x: b.width - m - ap.width, y: y, width: ap.width, height: h)
        btnScan.frame = NSRect(x: (btnAccess.isHidden ? b.width - m + 16 : btnAccess.frame.minX) - 16 - sp.width, y: y, width: sp.width, height: h)
        btnBrowse.frame = NSRect(x: btnScan.frame.minX - gap - bp.width, y: y, width: bp.width, height: h)
        pathLabel.sizeToFit()
        pathLabel.frame.origin = NSPoint(x: m, y: y + (h - pathLabel.frame.height) / 2)
        let px = pathLabel.frame.maxX + gap
        pathPanel.frame = NSRect(x: px, y: y, width: max(120, btnBrowse.frame.minX - gap - px), height: h)
        pathPanel.needsLayout = true
        y += h + 8
        var x = m
        for btn in [btnBack, btnForward, btnUp, btnRescan, btnFinder, btnAddList, btnBasket, btnDelete] {
            if btn === btnBasket { x += 10 }
            let p = btn.preferredSize
            let bw = btn.isIcon ? h : p.width
            // A narrow window (or a large zoom): the buttons flow onto another row instead of leaving the window.
            if x > m && x + bw > b.width - m { x = m; y += h + 8 }
            btn.frame = NSRect(x: x, y: y, width: bw, height: h)
            x += bw + gap
        }
        let ms = measure.preferredSize, es = btnExport.preferredSize, os = btnOpenScan.preferredSize
        // The right-hand group (Open scan, Export, the measure switch) moves to a row of its own when the window (or a
        // larger zoom) leaves too little room beside the action row; nothing overlaps.
        let rightW = os.width + gap + es.width + 16 + ms.width
        if x - gap + 16 > b.width - m - rightW { y += h + 8 }
        measure.frame = NSRect(x: b.width - m - ms.width, y: y, width: ms.width, height: h)
        btnExport.frame = NSRect(x: measure.frame.minX - 16 - es.width, y: y, width: es.width, height: h)
        btnOpenScan.frame = NSRect(x: btnExport.frame.minX - gap - os.width, y: y, width: os.width, height: h)
        y += h + 10
        if !scanBar.isHidden { scanBar.frame = NSRect(x: m, y: y, width: b.width - 2 * m, height: ScanBar.height); y += ScanBar.height }
        if !deleteBar.isHidden { deleteBar.frame = NSRect(x: m, y: y, width: b.width - 2 * m, height: ScanBar.height); y += ScanBar.height }
        if !workBar.isHidden { workBar.frame = NSRect(x: m, y: y, width: b.width - 2 * m, height: ScanBar.height); y += ScanBar.height }
        let statusH: CGFloat = 28
        rightPane.frame = NSRect(x: m, y: y, width: b.width - 2 * m, height: max(100, b.height - y - statusH))
        layoutStatus()
    }

    func layoutStatus() {
        let b = root.bounds, m: CGFloat = 15
        let sy = b.height - 28 + 6
        let vw = Theme.textWidth(versionLink.textValue, Theme.font9) + 4
        versionLink.frame = NSRect(x: b.width - m - vw, y: sy, width: vw, height: 16)
        let dw = min(b.width / 3, Theme.textWidth(driveLabel.stringValue, Theme.font9) + 6)
        driveLabel.frame = NSRect(x: versionLink.frame.minX - 20 - dw, y: sy, width: dw, height: 16)
        let lw = liveLabel.stringValue.isEmpty ? 0 : Theme.textWidth(liveLabel.stringValue, Theme.font9) + 6
        liveLabel.frame = NSRect(x: driveLabel.frame.minX - (lw > 0 ? 18 : 0) - lw, y: sy, width: lw, height: 16)
        var sw = max(50, liveLabel.frame.minX - 16 - m)
        if !lowSpaceLink.isHidden {
            let kw = Theme.textWidth(lowSpaceLink.textValue, Theme.font9) + 4
            sw = max(50, min(Theme.textWidth(statusLabel.stringValue, Theme.font9) + 6, sw - kw - 12))
            lowSpaceLink.frame = NSRect(x: m + sw + 10, y: sy, width: kw, height: 16)
        }
        statusLabel.frame = NSRect(x: m, y: sy, width: sw, height: 16)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        MainWindowController.listMinWidth
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.bounds.width - 180
    }
    func windowDidResize(_ notification: Notification) { layoutRoot() }

    // MARK: Zoom (View menu: Actual Size ⌘0, Zoom In ⌘+, Zoom Out ⌘-)

    static let zoomKey = "WindowZoom"
    static let zoomSteps: [CGFloat] = [0.75, 0.85, 1, 1.1, 1.25, 1.5, 1.75, 2]
    static var savedZoom: CGFloat {
        let v = CGFloat(UserDefaults.standard.double(forKey: zoomKey))
        return zoomSteps.contains(v) ? v : 1
    }

    func setZoom(_ z: CGFloat) {
        let v = min(MainWindowController.zoomSteps.last!, max(MainWindowController.zoomSteps.first!, z))
        if v == zoom { return }
        zoom = v
        UserDefaults.standard.set(Double(v), forKey: MainWindowController.zoomKey)
        HoverTip.shared.reset()
        layoutRoot()
        root.needsDisplay = true
        statusLabel.stringValue = "Zoom \(Int((v * 100).rounded())) %  (⌘+ larger, ⌘- smaller, ⌘0 actual size)"
    }

    @objc func menuBarZoomIn(_ sender: Any?) { setZoom(MainWindowController.zoomSteps.first { $0 > zoom + 0.001 } ?? zoom) }
    @objc func menuBarZoomOut(_ sender: Any?) { setZoom(MainWindowController.zoomSteps.last { $0 < zoom - 0.001 } ?? zoom) }
    @objc func menuBarActualSize(_ sender: Any?) { setZoom(1) }

    // MARK: Start-up

    func start(initialPath: String?) {
        loadDrives()
        refreshTree(nil)
        // A scan file passed on the command line opens read-only next to the startup disk, which is analyzed as usual.
        let scanFile = initialPath.flatMap { MainWindowController.isScanFile($0) ? $0 : nil }
        let path = scanFile != nil ? "/" : (initialPath ?? "/")
        if fastStart { openLastScan(path) } else { scanPath(path) }
        if let f = scanFile { openScanFile(f) }
        // The installed apps (bundles, icons) are read while the disk is scanned; their sizes follow from the scan.
        if selfTestDir == nil { prefetchApps() }
        if selfTestDir == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.updates.check(manual: false) }
        }
    }

    // MARK: Drives

    static func same(_ a: String, _ b: String) -> Bool { PathUtil.same(a, b) }

    func findRoot(_ path: String) -> ScanRoot? { roots.first { !$0.readOnly && PathUtil.same($0.path, path) } }
    func rootOf(_ top: DirNode?) -> ScanRoot? { guard let t = top else { return nil }; return roots.first { $0.node === t } }
    func isAttached(_ d: DirNode?) -> Bool { guard let d = d else { return false }; return rootOf(d.top) != nil }

    func sortRoots() {
        roots.sort { a, b in
            if a.readOnly != b.readOnly { return b.readOnly }
            if a.isSystem != b.isSystem { return a.isSystem }
            if a.isDrive != b.isDrive { return a.isDrive }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
    }

    static func capacity(_ path: String) -> (Int64, Int64) {
        if Demo.on { return Demo.capacity(path) }
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return (0, 0) }
        let total = Int64(v.volumeTotalCapacity ?? 0)
        let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        return (total, free)
    }

    func refreshCapacity(_ r: ScanRoot) {
        if r.readOnly { return }   // a saved scan keeps the capacity it was saved with
        let c = MainWindowController.capacity(r.path); r.total = c.0; r.free = c.1
    }

    private func loadDrives() {
        if Demo.on {   // pictures: made-up drives, never this Mac's
            for v in Demo.volumes {
                let r = findRoot(v.path) ?? { let n = ScanRoot(path: v.path); roots.append(n); return n }()
                r.isDrive = true; r.isSystem = v.system; r.label = v.label
                refreshCapacity(r)
            }
            sortRoots()
            return
        }
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var ready: [(String, URLResourceValues)] = []
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.volumeIsLocal == false || v.volumeIsBrowsable == false { continue }   // network shares are not listed
            ready.append((u.path, v))
        }
        roots.removeAll { r in r.isDrive && !r.readOnly && !ready.contains { PathUtil.same($0.0, r.path) } && !r.scanning }
        for (path, v) in ready {
            let r = findRoot(path) ?? { let n = ScanRoot(path: path); roots.append(n); return n }()
            r.isDrive = true
            r.isSystem = path == "/"
            let name = v.volumeName ?? path
            let external = v.volumeIsInternal == false || v.volumeIsRemovable == true || v.volumeIsEjectable == true
            r.label = name + (external ? " - external" : "")
            refreshCapacity(r)
        }
        if let a = active, !roots.contains(where: { $0 === a }) { active = nil; current = nil }
        sortRoots()
    }

    @objc private func volumesChanged() {
        if busy || scanning { drivesChanged = true; return }
        drivesChanged = false
        loadDrives()
        refreshTree(current)
    }

    private func showDrivesMenu() {
        let m = NSMenu()
        m.appearance = NSAppearance(named: .darkAqua)
        for r in roots where r.isDrive {
            let item = NSMenuItem(title: r.displayName + "   " + r.path, action: #selector(chooseDrive(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = r.path
            m.addItem(item)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: pathPanel.bounds.height + 4), in: pathPanel)
    }

    @objc private func chooseDrive(_ sender: NSMenuItem) { if let p = sender.representedObject as? String { scanPath(p) } }

    private func openFullDiskAccess() { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }

    // MARK: Scanning

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === pathField else { return }
        if (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue { startScan() }
    }

    func scanPath(_ path: String) {
        if busy || scanning { return }
        pathField.stringValue = path
        startScan()
    }

    func startScan() {
        if busy || scanning { return }
        var path = (pathField.stringValue as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespaces)
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            alert("Folder not found", path); return
        }
        pathField.stringValue = path
        clearPathSelection()
        var r = findRoot(path)
        if r == nil { let n = ScanRoot(path: path); refreshCapacity(n); roots.append(n); sortRoots(); r = n }
        let target = r!
        if let rep = target.replay { rep.timer?.invalidate(); target.replay = nil }
        let s = Scanner()
        scanner = s; scanRoot = target; scanUsed = 0
        target.scanning = true
        let oldNode = target.node
        setScanning(true, "Scanning " + target.path + "...")
        refreshTree(current)
        if current == nil && oldNode == nil { selectRoot(target) }
        let started = Date()
        var snapInfo = Snapshot.infoNow(path)        // the event id from before the scan: changes during it are replayed too
        DispatchQueue.global(qos: .userInitiated).async {
            let result = s.run(path)
            DispatchQueue.main.async {
                self.whenNoReaders {
                    target.scanning = false
                    self.scanner = nil; self.scanRoot = nil
                    self.setScanning(false, nil)
                    target.node = result
                    target.scanned = Date()
                    self.refreshCapacity(target)
                    self.rememberScan(target, result, complete: !s.cancelled)
                    if !s.cancelled {
                        snapInfo.scanSeconds = Date().timeIntervalSince(started)
                        self.saveSnapshot(target, result, snapInfo)
                    }
                    self.startWatching(target)
                    var goTo: DirNode?
                    if let c = self.current, let old = oldNode, c.top === old { goTo = MainWindowController.findByPath(result, c.fullPath) ?? result }
                    else if let a = self.active, a !== target { goTo = self.current }
                    else { goTo = result }
                    if self.active === target { self.current = nil }
                    self.refreshTree(goTo, fallback: target)
                    self.markSuggestionsDirty()
                    self.viewsChanged()
                    self.updateDriveLabel()
                    self.statusLabel.stringValue = "\(result.name): \(Fmt.size(result.size)) in \(Fmt.count(result.files)) files and \(Fmt.count(result.dirs)) folders - scanned in \(String(format: "%.2f", Date().timeIntervalSince(started))) s" + (s.cancelled ? "  (stopped - partial results)" : "")
                    // A drive is scanned: list the installed apps right away (sizes come from this scan), so the Apps tab
                    // is ready when it is opened; the tab waiting for the scan is filled now too.
                    if self.selfTestDir == nil && !self.appsLoading && (self.apps == nil || self.appsFromCache)
                        && ((target.isDrive && !s.cancelled) || self.activePage === self.pApps) { self.loadApps() }
                    // The System view too (snapshots, backups, drives).
                    if target.isDrive && !s.cancelled && self.selfTestDir == nil && !self.systemLoading { self.loadSystem() }
                    if !s.cancelled { self.checkLowSpace(target) }
                    self.onScanFinished?()
                }
            }
        }
    }

    /// Runs f once no background task reads the scanned trees (they are only changed on the main thread).
    func whenNoReaders(_ f: @escaping () -> Void) {
        if readers == 0 { f(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.whenNoReaders(f) }
    }

    /// Runs work on a background thread while the trees are held still, then done on the main thread.
    func readInBackground<R>(_ work: @escaping () -> R, _ done: @escaping (R) -> Void) {
        readers += 1
        DispatchQueue.global(qos: .userInitiated).async {
            let r = work()
            DispatchQueue.main.async { self.readers -= 1; done(r) }
        }
    }

    static func findByPath(_ root: DirNode, _ full: String) -> DirNode? {
        let rp = root.fullPath
        guard PathUtil.isWithin(full, rp) else { return nil }
        var node = root
        for part in full.dropFirst(rp.count).split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == part }) else { break }
            node = next
        }
        return node
    }

    /// The deepest scanned folder holding path; with exact, only a folder whose path is exactly path. A folder another
    /// scan did enter is preferred to one that was skipped (e.g. Desktop scanned on its own, skipped in the disk's scan).
    func findScanned(_ path: String, exact: Bool) -> DirNode? {
        MainWindowController.findScanned(in: roots.filter { !$0.readOnly }.compactMap { $0.node }, path, exact: exact)
    }

    /// findScanned over given trees (a background task takes them on the main thread first).
    static func findScanned(in scanned: [DirNode], _ path: String, exact: Bool) -> DirNode? {
        var skipped: DirNode?
        for n in scanned {
            guard PathUtil.isWithin(path, n.fullPath) else { continue }
            if let d = MainWindowController.findByPath(n, path), !exact || PathUtil.same(d.fullPath, path) {
                if !d.insideSkipped { return d }
                if skipped == nil { skipped = d }
            }
        }
        return skipped
    }

    func setScanning(_ on: Bool, _ text: String?) {
        scanning = on
        if on { scanBar.start(text ?? "Starting..."); startProgressTimer() }
        else { scanBar.stop(); if !busy { stopProgressTimer() } }
        layoutRoot()
        updateButtons()
        // The chart switches to the logo at once; when the scan ends the refresh turns it into the chart.
        if on && !pages.isEmpty { refreshChart() }
        if !on && drivesChanged { DispatchQueue.main.async { self.volumesChanged() } }
    }

    func setBusy(_ on: Bool) {
        busy = on
        if on {
            deleteBar.start(deleteJob?.trash == true ? "Moving to the Trash..." : "Deleting permanently...")
            deleteBar.cancelButton.isEnabled = true
            startProgressTimer()
            for p in pages { p.rowFilter = { [unowned self] it in self.rowDeleted(it) || self.rowGoneFromDisk(it) } }
        } else {
            deleteBar.stop()
            if !scanning { stopProgressTimer() }
            for p in pages { p.rowFilter = nil }
        }
        layoutRoot()
        updateButtons()
        if !on && drivesChanged { DispatchQueue.main.async { self.volumesChanged() } }
    }

    private func startProgressTimer() {
        if progressTimer != nil { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.updateProgress() }
    }
    private func stopProgressTimer() { progressTimer?.invalidate(); progressTimer = nil }

    /// The progress of a whole-drive scan: size on disk found so far against the drive's used space (both count
    /// allocated blocks; file lengths would run ahead: cloud files not downloaded, sparse and compressed files). Past
    /// 99 % (clones, snapshots and other volumes make the two differ a little) it says it is finishing, never "X of Y"
    /// with X larger than Y.
    static func driveProgress(_ root: String, found: Int64, used: Int64) -> (text: String, fraction: Double) {
        let f = Double(found) / Double(max(1, used))
        if f >= 0.99 { return ("Scanning \(root): \(Fmt.size(found)) found, finishing the last folders...", 0.99) }
        return ("Scanning \(root): \(Fmt.size(found)) of \(Fmt.size(used)) done (\(Int(f * 100)) %)", f)
    }

    /// Space in use on the volume holding path, purgeable space included (it is still on the disk and scanned).
    static func usedOnDisk(_ path: String) -> Int64 {
        guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacity else { return 0 }
        return Int64(max(0, total - free))
    }

    func updateProgress() {
        if let s = scanner {
            let detail = "\(Fmt.count(s.filesSeen)) files, \(Fmt.count(s.dirsSeen)) folders  --  \(Fmt.shorten(s.current, 90))"
            if s.cancelled { scanBar.set("Cancelling... (finishing current folder)", detail, -1) }
            else if let r = scanRoot, r.isDrive, r.total > 0, PathUtil.same(r.path, s.rootPath) {
                if scanUsed <= 0 { scanUsed = MainWindowController.usedOnDisk(r.path) }
                let p = MainWindowController.driveProgress(r.path, found: s.allocSeen, used: scanUsed > 0 ? scanUsed : r.used)
                scanBar.set(p.text, detail, p.fraction)
            } else { scanBar.set("Scanning \(Fmt.shorten(s.rootPath, 60)): \(Fmt.size(DirNode.onDisk ? s.allocSeen : s.bytesSeen)) so far", detail, -1) }
        }
        if let j = deleteJob {
            let done = j.bytesDone, total = j.totalBytes
            var status = j.trash ? "Moving to the Trash: \(Fmt.count(j.recycled)) item\(j.recycled == 1 ? "" : "s")"
                                 : "Deleting permanently: \(Fmt.count(j.filesDeleted)) file\(j.filesDeleted == 1 ? "" : "s") removed, \(Fmt.size(done)) freed"
            if j.stopped { status += "  -  stopping after the current file..." }
            let frac = total > 0 ? min(1, Double(done) / Double(total)) : -1
            deleteBar.set(status, Fmt.shorten(j.current, 160), frac)
            let d = j.drain()
            applyDeleted(d.gone, d.finished)
        }
    }

    func updateButtons() {
        let idle = !busy && !scanning
        let any = roots.contains { $0.node != nil }
        btnScan.isEnabled = idle
        btnBrowse.isEnabled = idle
        pathField.isEnabled = !busy
        btnUp.isEnabled = !thisPc && (current != nil || active != nil)
        btnRescan.isEnabled = idle && current != nil
        btnFinder.isEnabled = current != nil || active != nil
        btnDelete.isEnabled = idle && any
        btnAddList.isEnabled = !busy && any
        btnExport.isEnabled = !busy && any
        btnOpenScan.isEnabled = !busy
        // A saved scan opened from a file is only browsed.
        if let a = active, a.readOnly { btnRescan.isEnabled = false; btnDelete.isEnabled = false; btnAddList.isEnabled = false }
        updateNavButtons()
        measure.isEnabled = !busy
        if pBasket != nil {
            btnBasketRemove.isEnabled = !busy && !basket.isEmpty
            btnBasketClear.isEnabled = !busy && !basket.isEmpty
            btnBasketTrash.isEnabled = idle && !basket.isEmpty
            btnBasketDelete.isEnabled = idle && !basket.isEmpty
        }
        if pSuggest != nil {
            let shown = shownSuggestions
            let anyChecked = shown.contains { $0.checkState != 0 }
            btnSugAll.isEnabled = !shown.isEmpty
            btnSugNone.isEnabled = !shown.isEmpty
            btnSugDelete.isEnabled = idle && anyChecked
            let ignored = IgnoreList.count
            let title = "Ignored (\(Fmt.count(ignored)))..."
            if btnSugIgnored.isHidden != (ignored == 0) || btnSugIgnored.title != title {
                btnSugIgnored.isHidden = ignored == 0
                btnSugIgnored.title = title
                pSuggest.bar?.relayout()
            }
        }
        if pApps != nil { updateAppButtons() }
        if pSystem != nil { updateSystemButtons() }
        if pDupes != nil {
            btnFindDupes.isEnabled = cloneJob == nil
            updateCloneButton()
        }
    }

    func updateDriveLabel() {
        defer { layoutStatus() }
        if let r = active, r.readOnly {
            driveLabel.stringValue = r.total > 0 ? "Saved scan of \(Fmt.date(r.scanned)): \(Fmt.size(r.free)) free of \(Fmt.size(r.total)) then"
                : "Saved scan of \(Fmt.date(r.scanned))"
            return
        }
        guard let r = active, r.total > 0 else { driveLabel.stringValue = ""; return }
        refreshCapacity(r)
        driveLabel.stringValue = "\(r.displayName)  \(Fmt.size(r.free)) free of \(Fmt.size(r.total)) (\(Int((100 * Double(r.free) / Double(max(1, r.total))).rounded()))% free)"
    }

    private func browse() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.message = "Choose a folder to analyze"
        p.beginSheetModal(for: window!) { resp in
            if resp == .OK, let u = p.url { self.scanPath(u.path) }
        }
    }

    // MARK: Contents: tree-list and This PC

    /// Shows target again after the scanned trees changed (or the drive it was on, or This PC).
    func refreshTree(_ target: DirNode?, fallback: ScanRoot? = nil) {
        pruneExpanded()
        HoverTip.shared.reset(owner: contents)
        if let t = target, isAttached(t) { selectDir(t) }
        else if let f = fallback, roots.contains(where: { $0 === f }) { selectRoot(f) }
        else if thisPc { showThisPc() }
        else if let a = active, roots.contains(where: { $0 === a }) { selectRoot(a) }
        else if let first = roots.first { selectRoot(first) }
        else { showThisPc() }
    }

    /// After live changes: folders that left the scans are forgotten and This PC is refilled in place (the folder shown
    /// is refreshed by refreshAfterLive).
    func refreshTreeQuietly() {
        pruneExpanded()
        guard thisPc else { return }
        if activePage === pContents { if NSEvent.pressedMouseButtons == 0 { refillContents() } } else { pContents.stale = true }
    }

    func selectRoot(_ r: ScanRoot) {
        if let n = r.node { selectDir(n) } else { showUnscanned(r) }
    }

    func selectDir(_ d: DirNode) {
        guard isAttached(d) else { return }
        showContents(d)
    }

    func isExpanded(_ d: DirNode) -> Bool { expandedDirs[ObjectIdentifier(d)] === d }

    func setExpanded(_ d: DirNode, _ on: Bool) {
        if on { expandedDirs[ObjectIdentifier(d)] = d } else { expandedDirs.removeValue(forKey: ObjectIdentifier(d)) }
    }

    private func pruneExpanded() {
        expandedDirs = expandedDirs.filter { isAttached($0.value) }
        unreadClosed.removeAll { !isAttached($0) }
    }

    /// A folder that has rows to show when it is opened in place.
    static func hasContent(_ d: DirNode?) -> Bool {
        guard let d = d else { return false }
        return !d.denied && d.skipped == .no && (!d.children.isEmpty || d.files > 0)
    }

    /// Rows of folder d at depth, sorted like the list, each opened folder followed by its own rows.
    func addContentRows(_ d: DirNode, _ depth: Int, _ into: inout [ItemInfo]) {
        var level: [ItemInfo] = d.children.map { ItemInfo.forDir($0, d.size) }
        var files = Scanner.listFiles(d)
        files.sort { $0.size > $1.size }
        let maxShown = MainWindowController.maxFilesShown
        for f in files.prefix(maxShown) { level.append(ItemInfo.forFile(f, d.size)) }
        if files.count > maxShown {
            let rest = files.dropFirst(maxShown).reduce(Int64(0)) { $0 + $1.size }
            let s = ItemInfo()
            s.isSummary = true
            s.name = "[\(Fmt.count(files.count - maxShown)) smaller files not listed]"
            s.size = rest; s.files = Int64(files.count - maxShown)
            s.percent = d.size > 0 ? 100 * Double(rest) / Double(d.size) : 0
            s.tip = s.name + "\n" + d.fullPath
            level.append(s)
        }
        setChanges(d, level)
        for it in level {
            let known = MainWindowController.knownFor(it)
            it.category = known?.short ?? ""
            it.cells = [it.name, Fmt.size(it.size), Fmt.pct(it.percent), changeText(it), Fmt.count(it.files), it.isDir ? Fmt.count(it.dirs) : "",
                        Fmt.date(it.modified), it.category]
            if it.isDir, let dn = it.dir, dn.denied || dn.skipped != .no { it.color = T.MUTED }
        }
        for it in pContents.sorted(level) {
            it.treeRow = true
            it.depth = depth
            if it.isDir, let dn = it.dir {
                it.expandable = MainWindowController.hasContent(dn)
                it.expanded = it.expandable && isExpanded(dn)
            }
            into.append(it)
            if it.expanded, let dn = it.dir { addContentRows(dn, depth + 1, &into) }
        }
    }

    /// Identity of a row across refills (the same folder, file or drive).
    private func rowKey(_ it: ItemInfo) -> String {
        if let r = it.scanRoot { return "r\(ObjectIdentifier(r).hashValue)" }
        if it.isDir, let d = it.dir { return "d\(ObjectIdentifier(d).hashValue)" }
        if let p = it.file?.fullPath { return "f" + p }
        return "n" + it.name
    }

    /// Replaces the Contents rows; with keepView the scroll position and the selected rows (by folder or file) stay.
    func fillContentsRows(_ items: [ItemInfo], keepView: Bool, empty: String) {
        let t = contents
        let clip = t.enclosingScrollView?.contentView
        let origin = clip?.bounds.origin ?? .zero
        var keep = Set<String>()
        if keepView { for it in pContents.selectedItems { keep.insert(rowKey(it)) } }
        pContents.setColumnTitle(2, thisPc ? "% used" : "% of parent")
        pContents.setRows(items, empty, keepOrder: true)
        var sel = IndexSet()
        if !keep.isEmpty { for (i, it) in pContents.items.enumerated() where keep.contains(rowKey(it)) { sel.insert(i) } }
        if sel != t.selectedRowIndexes { t.selectRowIndexes(sel, byExtendingSelection: false) }
        if keepView, let c = clip {
            let r = c.constrainBoundsRect(NSRect(origin: origin, size: c.bounds.size))
            c.scroll(to: r.origin)
            t.enclosingScrollView?.reflectScrolledClipView(c)
        } else if t.numberOfRows > 0 { t.scrollRowToVisible(0) }
    }

    /// Text shown in Contents when folder d has no rows.
    func contentsEmptyText(_ d: DirNode) -> String {
        switch d.skipped {
        case .notDownloaded:
            return "This folder is in iCloud and not downloaded: it takes no space on this Mac.\nIt is not opened, so nothing gets downloaded."
        case .needsAccess:
            return "macOS protects this folder. Press Rescan folder (⌘R) to scan it (macOS asks once),\nor give the app Full Disk Access (button in the toolbar) and reopen it."
        case .no: return ""
        }
    }

    /// Rebuilds the Contents rows after a folder was opened or closed in place, or the sort order changed.
    func refillContents() {
        if thisPc { fillContentsRows(thisPcRows(), keepView: true, empty: roots.isEmpty ? "No drives found." : "") }
        else if let c = current, isAttached(c) {
            var items: [ItemInfo] = []
            addContentRows(c, 0, &items)
            fillContentsRows(items, keepView: true, empty: contentsEmptyText(c))
        } else { return }
        if activePage === pContents { refreshChart() }
    }

    /// A click on the chevron of a folder in Contents opens or closes it in place (true = handled).
    func contentsClick(_ row: Int, _ p: NSPoint) -> Bool {
        guard row >= 0, row < pContents.items.count else { return false }
        let it = pContents.items[row]
        guard it.treeRow, it.expandable, let d = it.dir else { return false }
        let col = contents.column(at: p)
        guard col >= 0, col < contents.tableColumns.count, contents.tableColumns[col].identifier.rawValue == "c0" else { return false }
        let cell = contents.frameOfCell(atColumn: col, row: row)
        let local = NSPoint(x: p.x - cell.minX, y: p.y - cell.minY)
        guard ListCell.chevronHit(it, height: cell.height).contains(local) else { return false }
        setExpanded(d, !it.expanded)
        refillContents()
        return true
    }

    /// Right opens the selected folder in place (or moves into it), Left closes it (or selects its parent row).
    func expandSelected(_ expand: Bool) -> Bool {
        let rows = contents.selectedRowIndexes
        guard rows.count == 1, let r = rows.first, r < pContents.items.count else { return false }
        let it = pContents.items[r]
        guard it.treeRow else { return false }
        if expand {
            guard it.expandable, let d = it.dir else { return true }
            if !it.expanded { setExpanded(d, true); refillContents(); return true }
            if r + 1 < pContents.items.count { selectContentsRow(r + 1) }
            return true
        }
        if it.expanded, let d = it.dir { setExpanded(d, false); refillContents(); return true }
        var i = r - 1
        while i >= 0 {
            if pContents.items[i].depth < it.depth { selectContentsRow(i); break }
            i -= 1
        }
        return true
    }

    func selectContentsRow(_ i: Int) {
        guard i >= 0 && i < pContents.items.count else { return }
        contents.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        contents.scrollRowToVisible(i)
    }

    /// A real drive of This Mac (not a scanned folder, not a saved scan): only these count in its totals and chart.
    static func countsAsDrive(_ r: ScanRoot) -> Bool { r.isDrive && !r.readOnly }

    /// The drives that count in This Mac's totals and chart.
    var thisPcDrives: [ScanRoot] { roots.filter { MainWindowController.countsAsDrive($0) } }

    /// One row per drive, saved scan and scanned folder; scanned ones open into their folders. A drive shows its used
    /// space (of its capacity) and has a chart slice; a scanned folder or saved scan shows its own size (of its volume)
    /// and has none.
    func thisPcRows() -> [ItemInfo] {
        var items: [ItemInfo] = []
        for r in roots {
            let n = r.node
            let drive = MainWindowController.countsAsDrive(r)
            let size: Int64 = drive ? (r.total > 0 ? r.used : (n?.size ?? 0)) : (n?.size ?? 0)
            let it = ItemInfo()
            it.treeRow = true
            it.scanRoot = r
            it.folderIcon = true
            it.isDir = n != nil
            it.dir = n
            it.path = r.path
            it.noSlice = !drive
            it.name = r.displayName + (n == nil ? (r.scanning ? "  (scanning...)" : "  (not scanned)") : (r.scanning ? "  (rescanning...)" : ""))
            it.size = size
            it.files = n?.files ?? 0
            it.dirs = n?.dirs ?? 0
            it.percent = r.total > 0 ? 100 * Double(size) / Double(r.total) : 0
            if drive { it.category = r.total > 0 ? "\(Fmt.size(r.free)) free of \(Fmt.size(r.total))" : "" }
            else { it.category = r.readOnly ? "Saved scan" : "Scanned folder" }
            it.tip = r.displayName + "\n" + (n?.fullPath ?? r.path)
            it.cells = [it.name, Fmt.size(it.size), Fmt.pct(it.percent), "", n != nil ? Fmt.count(it.files) : "", n != nil ? Fmt.count(it.dirs) : "",
                        "", it.category]
            if n == nil { it.color = T.MUTED }
            it.expandable = MainWindowController.hasContent(n)
            if let dn = n { it.expanded = it.expandable && isExpanded(dn) }
            items.append(it)
            if it.expanded, let dn = n { addContentRows(dn, 1, &items) }
        }
        return items
    }

    /// Contents shows This PC: every drive with its used space; Up from a drive leads here.
    func showThisPc() {
        thisPc = true
        current = nil
        unreadBanner.message = ""
        updateCrumbs(nil)
        for r in roots { refreshCapacity(r) }
        fillContentsRows(thisPcRows(), keepView: false, empty: roots.isEmpty ? "No drives found." : "")
        let drives = thisPcDrives
        let used = drives.reduce(Int64(0)) { $0 + $1.used }, total = drives.reduce(Int64(0)) { $0 + $1.total }
        pContents.setCaption("\(Fmt.count(drives.count)) drive\(drives.count == 1 ? "" : "s")"
                             + (total > 0 ? ": \(Fmt.size(used)) used of \(Fmt.size(total))" : ""))
        for p in pages where p.followsFolder && p !== pContents { p.stale = true }
        if activePage === pContents { refreshChart() }
        updateButtons()
    }

    /// This PC chart: the used space of every drive (scanned folders and saved scans have no slice).
    func updateChartThisPc() {
        if chartOnHold { showScanLogo(); return }
        let drives = thisPcDrives
        let total = drives.reduce(Int64(0)) { $0 + $1.total }
        let used = drives.reduce(Int64(0)) { $0 + $1.used }
        let slices = buildSlices(pContents, max(1, used), "of the used space")
        chart.setData(MainWindowController.thisPcName, total > 0 ? "\(Fmt.size(total)) in \(drives.count) drive\(drives.count == 1 ? "" : "s")" : "", slices)
    }
    func showUnscanned(_ r: ScanRoot) {
        thisPc = false
        current = nil
        active = r
        refreshCapacity(r)
        if !busy && !scanning { pathField.stringValue = r.path }
        updateCrumbs(nil, unscanned: r)
        unreadBanner.message = ""
        pContents.setColumnTitle(2, "% of parent")
        pContents.setRows([], r.scanning
            ? "Scanning \(r.displayName)...\nThe results appear here when the scan finishes. You can browse other drives meanwhile."
            : "\(r.displayName) has not been scanned yet.\nPress Scan, or double-click the drive in \(MainWindowController.thisPcName), to analyze it.")
        viewsChanged()
        pContents.setCaption(r.displayName + (r.scanning ? "  -  scanning..." : "  -  not scanned"))
        if activePage === pContents { updateChartUnscanned(r) }
        updateDriveLabel()
        updateButtons()
    }

    func showContents(_ d: DirNode) {
        recordNavigation(current, d)
        let same = d === current && !thisPc
        thisPc = false
        current = d
        if let r = rootOf(d.top), r !== active {
            active = r
            updateDriveLabel()
            if !busy && !scanning { pathField.stringValue = r.path }
        }
        updateCrumbs(d)
        updateUnreadBanner(d)
        var items: [ItemInfo] = []
        addContentRows(d, 0, &items)
        fillContentsRows(items, keepView: same, empty: contentsEmptyText(d))
        // The path is in the path bar above; the caption gives the totals.
        pContents.setCaption("\(Fmt.size(d.size)) in \(Fmt.count(d.files)) files and \(Fmt.count(d.dirs)) folders" + changeCaption(d))
        contentsChanged()
        updateButtons()
    }

    // MARK: Selection and actions

    /// The selected items of the list that had the focus last (Contents when none had it yet).
    func selection() -> [ItemInfo] {
        let view: NSView = lastView ?? contents
        if let p = pages.first(where: { $0.table === view }) {
            return p.selectedItems.filter { !$0.isSummary && !$0.isGroup && ($0.canDelete || $0.fullPath != nil) }
        }
        return []
    }

    @objc private func listDoubleClick(_ sender: Any?) {
        guard let t = sender as? HoverTable, let p = pages.first(where: { $0.table === t }) else { return }
        lastView = t
        onListDoubleClick(p)
    }

    func openSelected() {
        let sel = selection()
        guard sel.count == 1 else { return }
        let it = sel[0]
        // A drive (or scanned folder) in This PC that is not scanned yet: scan it.
        if let r = it.scanRoot, r.node == nil { scanPath(r.path); return }
        if it.isDir, let d = it.dir { if isAttached(d) { selectDir(d) }; return }
        guard let f = it.file else { showInFinder(); return }
        if lastView !== contents && isAttached(f.dir) {
            selectDir(f.dir)
            showView(pContents)
            if let i = pContents.items.firstIndex(where: { $0.depth == 0 && $0.file != nil && $0.file!.name == f.name }) {
                contents.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
                contents.scrollRowToVisible(i)
                window?.makeFirstResponder(contents)
                lastView = contents
            }
            return
        }
        showInFinder()
    }

    /// The parent folder; from the top of a scan (or a drive not scanned yet) This PC, with that drive selected.
    func goUp() {
        if thisPc { return }
        if let p = current?.parent { selectDir(p); return }
        let from = current.flatMap { rootOf($0.top) } ?? active
        showThisPc()
        if let f = from, let i = pContents.items.firstIndex(where: { $0.scanRoot === f }) { selectContentsRow(i) }
    }

    func showInFinder() {
        let sel = selection()
        let paths = sel.isEmpty ? [current?.fullPath ?? active?.path].compactMap { $0 } : sel.compactMap { $0.fullPath }
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    func copyPath() {
        let paths = selection().compactMap { $0.fullPath }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func handleKey(_ e: NSEvent, in view: NSView) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        if pSuggest != nil && view === pSuggest.table && suggestKeyDown(e) { return true }
        if pApps != nil && view === pApps.table && appsKeyDown(e) { return true }
        if pSystem != nil && view === pSystem.table && systemKeyDown(e) { return true }
        switch e.keyCode {
        case 36, 76:                                                     // Return / Enter
            lastView = view; openSelected(); return true
        case 123 where !cmd && view === contents:                       // Left: close a folder in place (or go to its parent row)
            if expandSelected(false) { return true }
        case 124 where !cmd && view === contents:                       // Right: open a folder in place (or go into it)
            if expandSelected(true) { return true }
        case 51 where cmd: lastView = view; deleteSelected(); return true      // Cmd+Delete
        case 2 where cmd:                                                // Cmd+D add to the delete list, Shift+Cmd+D delete permanently
            lastView = view
            if e.modifierFlags.contains(.shift) { deleteSelected() } else { addSelectionToBasket() }
            return true
        case 126 where cmd: goUp(); return true                         // Cmd+Up
        case 114: lastView = view; addSelectionToBasket(); return true  // Help / Insert key of full-size keyboards
        case 49 where !cmd && !e.modifierFlags.contains(.option) && !e.modifierFlags.contains(.control) && spacePreviews(view):
            lastView = view; quickLookSelected(); return true           // Space: Quick Look (not where Space ticks checkboxes)
        default: break
        }
        return false
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        if let v = window?.firstResponder as? NSView, pages.contains(where: { $0.table === v }) { lastView = v }
        let sel = selection()
        let any = !sel.isEmpty
        let deletable = any && !busy && sel.allSatisfy { $0.canDelete && !fromReadOnly($0) }
        func add(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags, _ enabled: Bool, _ action: Selector, warn: Bool = false) {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            if !key.isEmpty { it.keyEquivalentModifierMask = mods }
            it.target = self; it.isEnabled = enabled
            if warn && enabled { it.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: T.WARN_FG, .font: NSFont.menuFont(ofSize: 0)]) }
            m.addItem(it)
        }
        m.autoenablesItems = false
        if lastView === pSuggest.table {
            let rows = pSuggest.selectedItems.filter { $0.suggestion != nil }
            add("Never suggest this", "", [], !rows.isEmpty, #selector(menuIgnoreSuggestion))
            m.addItem(.separator())
        }
        if lastView === pApps.table {
            let app = selectedApp
            let idle = !busy && !scanning && !appsWorking
            add("Uninstall...", "", [], idle && app != nil && !app!.uninstalled, #selector(menuUninstall), warn: true)
            m.addItem(.separator())
        }
        add("Open", "", [], any && sel.count == 1, #selector(menuOpen))
        add("Quick Look", " ", [], any && sel.count == 1 && (sel[0].isDir || sel[0].file != nil || sel[0].fullPath != nil), #selector(menuQuickLook))
        add("Show in Finder", "", [], any, #selector(menuFinder))
        add("Get Info", "i", .command, any && sel.count == 1 && sel[0].fullPath != nil, #selector(menuGetInfo))
        add("Copy path", "", [], any, #selector(menuCopy))
        add("Rescan folder", "r", .command, any && !busy && !scanning && sel.count == 1 && sel[0].isDir && !fromReadOnly(sel[0]), #selector(menuRescan))
        m.addItem(.separator())
        if lastView !== pBasket.table { add("Add to delete list", "d", .command, deletable, #selector(menuAddList)) }
        add("Move to Trash...", "", [], deletable && !scanning, #selector(menuTrash))
        add("Delete permanently...", "d", [.command, .shift], deletable && !scanning, #selector(menuDelete), warn: true)
        if selectedSavedScan() != nil {
            m.addItem(.separator())
            add("Close saved scan", "", [], !busy, #selector(menuCloseSavedScan))
        }
    }

    @objc private func menuUninstall() { uninstallSelectedApp() }
    @objc private func menuIgnoreSuggestion() { ignoreSelectedSuggestions() }
    @objc private func menuOpen() { openSelected() }
    @objc private func menuQuickLook() { quickLookSelected() }
    @objc private func menuGetInfo() { getInfoSelected() }
    @objc private func menuCloseSavedScan() { closeSavedScan(selectedSavedScan()) }
    @objc private func menuFinder() { showInFinder() }
    @objc private func menuCopy() { copyPath() }
    @objc private func menuRescan() { rescanSelected() }
    @objc private func menuAddList() { addSelectionToBasket() }
    @objc private func menuTrash() { trashSelected() }
    @objc private func menuDelete() { deleteSelected() }

    // MARK: Model updates

    func removeNode(_ dn: DirNode) {
        guard let p = dn.parent else { return }
        p.children.removeAll { $0 === dn }
        p.addUp(-dn.bytes, -dn.alloc, -dn.files, -(dn.dirs + 1))
        dn.parent = nil
    }

    func replaceNode(_ old: DirNode, _ fresh: DirNode) {
        guard let p = old.parent else { if let r = rootOf(old) { r.node = fresh }; return }
        fresh.name = old.name
        fresh.modified = old.modified
        fresh.parent = p
        if let i = p.children.firstIndex(where: { $0 === old }) { p.children[i] = fresh }
        p.addUp(fresh.bytes - old.bytes, fresh.alloc - old.alloc, fresh.files - old.files, fresh.dirs - old.dirs)
        old.parent = nil
    }

    /// Switches every view between file size and size on disk.
    func setMeasure(_ onDisk: Bool) {
        if DirNode.onDisk == onDisk { return }
        if measure.selectedIndex != (onDisk ? 1 : 0) { measure.selectedIndex = onDisk ? 1 : 0; return }
        whenNoReaders {
            DirNode.onDisk = onDisk
            for r in self.roots { r.node?.resortAll() }
            let keep = self.current
            self.current = nil
            if let k = keep, self.isAttached(k) { self.refreshTree(k) } else if self.active != nil { self.refreshTree(nil) }
            self.markSuggestionsDirty()
            self.viewsChanged()
            self.statusLabel.stringValue = onDisk
                ? "Showing size on disk: the space files really take (whole blocks; files not downloaded from iCloud take nothing; hard links count once)."
                : "Showing file size: the length of each file, as Finder's Size column shows it."
        }
    }

    func rescanSelected() {
        if busy || scanning { return }
        let sel = selection()
        guard let dir = sel.count == 1 && sel[0].isDir ? sel[0].dir : current else { return }
        if let ro = rootOf(dir.top), ro.readOnly {
            statusLabel.stringValue = "This is a saved scan opened from a file: it can be browsed, not rescanned."
            return
        }
        if dir.parent == nil { scanPath(rootOf(dir)?.path ?? dir.fullPath); return }
        let path = dir.fullPath
        let s = Scanner()
        scanner = s; scanRoot = rootOf(dir.top)
        setScanning(true, "Rescanning " + Fmt.shorten(path, 80) + "...")
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = s.run(path)
            DispatchQueue.main.async {
                self.whenNoReaders {
                    self.scanner = nil; self.scanRoot = nil
                    self.setScanning(false, nil)
                    let inside = self.current.map { $0.isUnder(dir) } ?? false
                    let here = inside ? self.current!.fullPath : nil
                    var target = self.current
                    if !FileManager.default.fileExists(atPath: path) { if inside { target = dir.parent }; self.removeNode(dir) }
                    else { self.replaceNode(dir, fresh); if inside { target = MainWindowController.findByPath(fresh, here!) ?? fresh } }
                    if target == nil || self.rootOf(target!.top) == nil { target = dir.parent }
                    self.current = nil
                    self.refreshTree(target)
                    self.markSuggestionsDirty()
                    self.viewsChanged()
                    self.updateDriveLabel()
                    self.statusLabel.stringValue = "Rescanned \(path): \(Fmt.size(fresh.size)) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s"
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) { scanner?.cancel(); stopAllWatching(); NSApp.terminate(nil) }

    // MARK: Menu bar actions (validated)

    @objc func menuBarRescan(_ sender: Any?) { rescanSelected() }
    @objc func menuBarDelete(_ sender: Any?) { deleteSelected() }
    @objc func menuBarTrash(_ sender: Any?) { trashSelected() }
    @objc func menuBarAddList(_ sender: Any?) { addSelectionToBasket() }
    @objc func menuBarUp(_ sender: Any?) { goUp() }
    @objc func menuBarFinder(_ sender: Any?) { showInFinder() }
    @objc func menuBarScan(_ sender: Any?) { startScan() }
    @objc func menuBarFind(_ sender: Any?) { showFilesSearch() }
    @objc func menuBarExport(_ sender: Any?) { exportScan() }
    @objc func menuBarOpenScan(_ sender: Any?) { openScanDialog() }
    @objc func menuBarBack(_ sender: Any?) { goBack() }
    @objc func menuBarForward(_ sender: Any?) { goForward() }
    @objc func menuBarGetInfo(_ sender: Any?) { getInfoSelected() }
    @objc func menuBarQuickLook(_ sender: Any?) { quickLookSelected() }

    // MARK: Quick Look panel control (the panel looks for its controller in the responder chain)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLookSource.urls = quickLookURLs
        panel.dataSource = quickLookSource
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }
}

/// Chevron that opens the drive list next to the path field.
final class ChevronButton: NSView {
    var onPress: (() -> Void)?
    private var hover = false
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func draw(_ dirtyRect: NSRect) {
        T.SURFACE.setFill(); bounds.fill()
        Theme.drawChevron(NSRect(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2, width: 14, height: 14), hover ? T.ACCENT : T.MUTED, down: true)
    }
}

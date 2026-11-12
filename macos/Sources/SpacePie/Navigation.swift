import AppKit

/// A folder opened before (Back / Forward): the folder itself while it is in a scan, else found again by its path.
final class NavEntry {
    weak var node: DirNode?
    let path: String
    init(_ node: DirNode) { self.node = node; path = node.fullPath }
}

/// The window's content view: also takes a dropped scan file (or folder).
final class DropView: FlatView {
    var canDrop: ((URL) -> Bool)?
    var onDrop: ((URL) -> Void)?

    private func url(_ info: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls?.first
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let u = url(sender), canDrop?(u) == true { return .copy }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let u = url(sender), canDrop?(u) == true { return .copy }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let u = url(sender), canDrop?(u) == true else { return false }
        DispatchQueue.main.async { [weak self] in self?.onDrop?(u) }
        return true
    }
}

/// The row above the folder contents: Back, Forward, Up and Rescan as small icon buttons, then the path bar. A narrow
/// list pane (or a large zoom): the buttons flow onto more lines, the path bar onto a line of its own.
final class NavRow: NSView, PageStrip {
    private let buttons: [RoundButton]
    private let crumbs: Breadcrumb
    override var isFlipped: Bool { true }
    var stripHeight: CGFloat { arrange(superview?.bounds.width ?? bounds.width, apply: false) }

    init(_ buttons: [RoundButton], _ crumbs: Breadcrumb) {
        self.buttons = buttons; self.crumbs = crumbs
        super.init(frame: .zero)
        for b in buttons { addSubview(b) }
        addSubview(crumbs)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }

    override func layout() {
        super.layout()
        _ = arrange(bounds.width, apply: true)
    }

    /// Lays the row out for the width (when apply) and returns its height.
    private func arrange(_ rowW: CGFloat, apply: Bool) -> CGFloat {
        let gap: CGFloat = 6, ch = crumbs.stripHeight
        let h = max(ch, buttons.first?.preferredSize.height ?? 0)
        var x: CGFloat = 0, y: CGFloat = 0
        for b in buttons {
            let p = b.preferredSize
            if x > 0 && x + p.width > rowW { x = 0; y += h + 4 }
            if apply { b.frame = NSRect(x: x, y: y + ((h - p.height) / 2).rounded(), width: p.width, height: p.height) }
            x += p.width + gap
        }
        x += 4
        if rowW - x < 120 { x = 0; y += h + 4 }
        if apply { crumbs.frame = NSRect(x: x, y: y + ((h - ch) / 2).rounded(), width: max(20, rowW - x), height: ch) }
        return y + h + 4
    }

    override func draw(_ dirtyRect: NSRect) { T.SURFACE.setFill(); bounds.fill() }
}

/// Getting around and knowing what you look at: Back / Forward through the folders opened, the path bar above the
/// folder contents, and the banner naming folders that could not be read.
extension MainWindowController {
    static let maxHistory = 100

    func buildNavigation() {
        crumbs.onPick = { [unowned self] t in
            if self.busy { return }
            switch t {
            case .thisPc: self.showThisPc()
            case .root(let r): if self.roots.contains(where: { $0 === r }) { self.selectRoot(r) }
            case .dir(let d): if self.isAttached(d) { self.selectDir(d) }
            }
        }
        unreadBanner.addButton("Show them", tip: "List the folders that could not be read") { [unowned self] in self.showUnreadable() }
        unreadAccess = unreadBanner.addButton("Full Disk Access...", tip: "Let the app read every folder (System Settings > Privacy & Security > Full Disk Access)") {
            _ = NSWorkspace.shared.open(FullDiskAccess.settingsURL)
        }
        unreadAccess?.isHidden = FullDiskAccess.granted
        // Closed with x: hidden for this scan (a new scan is a new tree and shows it again).
        unreadBanner.onClose = { [unowned self] in
            if let c = self.current, self.isAttached(c), !self.unreadClosed.contains(where: { $0 === c.top }) { self.unreadClosed.append(c.top) }
        }
        // Top to bottom: banner, navigation row (Back, Forward, Up, Rescan, then the path bar), caption, list.
        let navButtons = [btnBack, btnForward, btnUp, btnRescan]
        for b in navButtons { b.compact = true }
        pContents.addAbove(unreadBanner)
        pContents.addAbove(NavRow(navButtons, crumbs))
        // The mouse's back and forward buttons (buttons 4 and 5).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] e in
            guard let self = self, e.window === self.window else { return e }
            if e.buttonNumber == 3 { self.goBack(); return nil }
            if e.buttonNumber == 4 { self.goForward(); return nil }
            return e
        }
        // A click anywhere but a list, a button, a field or a view of the views bar (blank panes, captions, the headline,
        // the chart, the views bar's empty part) clears the selection of the list worked in last. Buttons keep it so
        // they can act on it; switching views keeps it too.
        clickAwayMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            guard let self = self, e.window === self.window, let cv = self.window?.contentView,
                  let hit = cv.hitTest(cv.convert(e.locationInWindow, from: nil)) else { return e }
            var v: NSView? = hit
            while let x = v {
                if x is NSTableView || x is NSTableHeaderView || x is NSScroller || x is RoundButton || x is Segmented || x is NSControl ||
                    x is NSText || x is ChevronButton { return e }
                if let rail = x as? NavRail, rail.hit(e) >= 0 { return e }
                v = x.superview
            }
            if let t = self.lastView as? NSTableView, !t.selectedRowIndexes.isEmpty { t.deselectAll(nil) }
            return e
        }
    }

    // MARK: Back / Forward

    /// Called whenever a folder is opened: remembers the one shown before, for Back.
    func recordNavigation(_ from: DirNode?, _ to: DirNode) {
        guard !navigating, let f = from, f !== to, isAttached(f) else { return }
        navBack.append(NavEntry(f))
        if navBack.count > MainWindowController.maxHistory { navBack.removeFirst(navBack.count - MainWindowController.maxHistory) }
        navForward.removeAll()
    }

    func goBack() { step(back: true) }

    func goForward() { step(back: false) }

    /// Opens the most recent folder of the list that still exists in a scan; the folder shown now goes to the other list.
    private func step(back: Bool) {
        if busy { return }
        while let entry = back ? navBack.popLast() : navForward.popLast() {
            // The same folder object while it is still in a scan (also in a saved scan); otherwise by its path.
            var d: DirNode? = nil
            if let n = entry.node, isAttached(n) { d = n } else { d = findScanned(entry.path, exact: true) }
            guard let target = d else { continue }
            if let c = current, isAttached(c) {
                if back { navForward.append(NavEntry(c)) } else { navBack.append(NavEntry(c)) }
            }
            navigating = true
            selectDir(target)
            if !activePage.followsFolder, let i = pages.firstIndex(where: { $0 === pContents }) { pageIndex = i }
            navigating = false
            break
        }
        updateNavButtons()
    }

    func updateNavButtons() {
        btnBack.isEnabled = !busy && !navBack.isEmpty
        btnForward.isEnabled = !busy && !navForward.isEmpty
    }

    /// The item belongs to a saved scan opened from a file (browsed only, never changed).
    func fromReadOnly(_ it: ItemInfo) -> Bool {
        let d: DirNode? = it.isDir ? it.dir : it.file?.dir
        guard let n = d, let r = rootOf(n.top) else { return false }
        return r.readOnly
    }

    /// The saved scan selected in Contents (its row in This PC), or the one whose top folder is shown with nothing
    /// selected (nil otherwise).
    func selectedSavedScan() -> ScanRoot? {
        guard lastView == nil || lastView === contents else { return nil }
        let sel = pContents.selectedItems
        if sel.count == 1, let r = sel[0].scanRoot, r.readOnly { return r }
        if sel.isEmpty, !thisPc, let c = current, c.parent == nil, let r = rootOf(c), r.readOnly { return r }
        return nil
    }

    // MARK: Path bar

    /// This PC, then the drive (not scanned) or every folder from the scanned top down to d.
    func updateCrumbs(_ d: DirNode?, unscanned: ScanRoot? = nil) {
        var parts: [(text: String, target: CrumbTarget)] = [(text: MainWindowController.thisPcName, target: .thisPc)]
        if let u = unscanned { parts.append((text: u.displayName, target: .root(u))) }
        if let d = d {
            var chain: [DirNode] = []
            var n: DirNode? = d
            while let c = n { chain.insert(c, at: 0); n = c.parent }
            let r = rootOf(chain.first)
            for c in chain {
                let text = c.parent == nil ? (r.map { $0.isDrive ? $0.displayName : $0.path } ?? c.name) : c.name
                parts.append((text: text, target: .dir(c)))
            }
        }
        crumbs.setParts(parts)
    }

    // MARK: Folders that could not be read

    /// Folders under top that could not be read (access denied, or protected and not entered without Full Disk Access);
    /// cached per scanned tree until it changes.
    func deniedUnder(_ top: DirNode) -> [DirNode] {
        let key = ObjectIdentifier(top)
        if let c = deniedCache[key], c.top === top { return c.list }
        let list = top.descendants().filter { $0.denied || $0.skipped == .needsAccess }
        deniedCache[key] = (top: top, list: list)
        return list
    }

    /// Shows or hides the banner for the tree that holds d: how many folders could not be read and what to do.
    func updateUnreadBanner(_ d: DirNode?) {
        guard let d = d, isAttached(d), let r = rootOf(d.top), !r.readOnly else { unreadBanner.message = ""; return }
        if unreadClosed.contains(where: { $0 === d.top }) { unreadBanner.message = ""; return }
        let here = deniedUnder(d.top).filter { $0.isUnder(d) }
        if here.isEmpty { unreadBanner.message = ""; return }
        // With Full Disk Access the folders still closed are closed to every app (System Integrity Protection, other
        // accounts): nothing the user can do, so nothing is shown (owner: "there should be no dialog even in that case").
        if !unreadFixable(here) { unreadBanner.message = ""; return }
        let one = here.count == 1
        unreadAccess?.isHidden = false
        unreadBanner.needsLayout = true
        unreadBanner.message = "\(Fmt.count(here.count)) folder\(one ? "" : "s") \(d.parent == nil ? "in this scan" : "in here") could not be read (access denied); "
            + "\(one ? "its" : "their") size\(one ? "" : "s") \(one ? "is" : "are") not in these totals. Give the app Full Disk Access to read them."
    }

    /// Giving the app Full Disk Access would open (most of) these folders.
    func unreadFixable(_ here: [DirNode]) -> Bool {
        if let f = unreadCanGrant { return f }
        return !FullDiskAccess.granted || here.contains { !$0.denied }
    }

    static let sipReason = "protected by macOS"

    func showUnreadable() {
        guard let d = current, isAttached(d) else { return }
        let here = deniedUnder(d.top).filter { $0.isUnder(d) }
        if here.isEmpty || !unreadFixable(here) { return }
        // Why each one stays closed, grouped by that reason: protected by macOS (System Integrity Protection: even
        // looking at the folder is refused, or it is yours and still closed, e.g. app containers), belonging to another
        // account (root, a service, another user), or needing Full Disk Access.
        let uid = getuid()
        var owners: [uid_t: String] = [:]
        func reason(_ n: DirNode) -> String {
            if !n.denied { return "needs Full Disk Access" }
            var st = stat()
            if lstat(n.fullPath, &st) != 0 { return errno == EPERM ? MainWindowController.sipReason : "access denied" }
            if st.st_uid == uid { return MainWindowController.sipReason }
            if owners[st.st_uid] == nil { owners[st.st_uid] = getpwuid(st.st_uid).map { String(cString: $0.pointee.pw_name) } ?? "uid \(st.st_uid)" }
            return "belongs to " + owners[st.st_uid]!
        }
        var listed: [(why: String, path: String)] = []
        for n in here.prefix(2000) { listed.append((why: reason(n), path: n.fullPath)) }
        listed.sort { a, b in
            if a.why != b.why { return a.why < b.why }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
        var lines: [String] = listed.map { $0.path + "   " + $0.why }
        if here.count > lines.count { lines.append("... and \(Fmt.count(here.count - lines.count)) more") }
        let d2 = PromptDialog(icon: .warn, heading: "\(Fmt.count(here.count)) folder\(here.count == 1 ? "" : "s") could not be read",
                              text: "macOS refused access, so what is inside them is not counted. Some belong to macOS or to other users.",
                              warning: "Give the app Full Disk Access (button in the toolbar, or here) to read most of them, then scan again. "
                                  + "Folders protected by macOS stay closed to every app.",
                              details: lines, buttons: [("OK", .primary)], defaultIndex: 0, cancelIndex: 0)
        d2.show(over: window) { _ in }
    }
}

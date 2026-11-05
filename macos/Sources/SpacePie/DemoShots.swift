import AppKit

/// Demo mode for README / website pictures (`--cli demo-shots <out> /Volumes/Data`, after tools/make_demo_mac.py):
/// the demo volume of sparse files plus made-up drives, suggestions and apps, so no picture ever shows this Mac.
enum Demo {
    static var on = false
    static let home = "/Users/alex"
    private static let GB: Int64 = 1 << 30, MB: Int64 = 1 << 20, KB: Int64 = 1 << 10

    /// The drives shown in This Mac (path, label, system, total, free); the demo volume is the scanned one.
    static let volumes: [(path: String, label: String, system: Bool, total: Int64, free: Int64)] = [
        ("/", "Macintosh HD", true, 994 * GB, 412 * GB),
        ("/Volumes/Data", "Data", false, 931 * GB, 234 * GB),
        ("/Volumes/Backup", "Backup - external", false, 2000 * GB, 1290 * GB),
    ]

    static func capacity(_ path: String) -> (Int64, Int64) {
        let v = volumes.filter { $0.path != "/" && PathUtil.isWithin(path, $0.path) }.first ?? volumes.first { $0.path == path }
        return v.map { ($0.total, $0.free) } ?? (0, 0)
    }

    // MARK: made-up suggestions

    static func suggestions() -> [Suggestion] {
        let lib = home + "/Library"
        var list: [Suggestion] = []
        func add(_ name: String, _ safe: Bool, _ note: String, _ items: [(String, Int64)], contents: Bool = true, trash: Bool = false) {
            let s = Suggestion(name, safe: safe, note: note)
            for (p, size) in items {
                let leaf = PathUtil.name(p)
                let label = items.count == 1 ? name : leaf == "node_modules" ? PathUtil.name(PathUtil.parent(p)) + "/node_modules" : leaf
                let t = DeleteTarget(path: p, label: label, isDir: true, size: size)
                t.contentsOnly = contents && !trash
                t.emptyTrash = trash
                if trash { t.label = "Trash" }
                s.targets.append(t)
            }
            s.size = s.targets.reduce(Int64(0)) { $0 + $1.size }
            s.location = trash ? "Trash" : items.count == 1 ? items[0].0 : "\(items.count) locations"
            list.append(s)
        }
        add("Xcode DerivedData", true, "Build products and indexes of Xcode projects. Rebuilt on the next build.",
            [(lib + "/Developer/Xcode/DerivedData", 18_400 * MB)])
        add("Device support files", true, "Debug symbols Xcode copied from iPhones and iPads. Copied again when a device is connected.",
            [(lib + "/Developer/Xcode/iOS DeviceSupport/iPhone16,1 18.2", 4_700 * MB), (lib + "/Developer/Xcode/iOS DeviceSupport/iPhone16,1 18.4", 4_400 * MB)], contents: false)
        add("Unavailable simulators", true, "Simulators of iOS versions no longer installed: they can't be started any more.",
            [(lib + "/Developer/CoreSimulator/Devices/4D89F20D", 3_900 * MB), (lib + "/Developer/CoreSimulator/Devices/690D0B44", 1_700 * MB),
             (lib + "/Developer/CoreSimulator/Devices/A8B0EFA3", 1_100 * MB)], contents: false)
        add("Disk images", false, "Disk images (.dmg, .iso, .img...) not opened for 30 days and not mounted: usually installers already used. Keep the ones you still need.",
            [(home + "/Downloads/ubuntu-24.04-desktop-arm64.iso", 6 * GB), (home + "/Desktop/Xcode_16.1.xip", 3_300 * MB)], contents: false)
        add("Trash", true, "Deleted items waiting in the Trash. Emptying it frees the space for good.", [(home + "/.Trash", 4_200 * MB)], trash: true)
        add("Old installers in Downloads", false, "Installer packages and archives older than 30 days. Keep the ones you still need.",
            [(home + "/Downloads/Office-Installer.pkg", 2_100 * MB), (home + "/Downloads/driver-pack-2.zip", 1_200 * MB), (home + "/Downloads/Blender-4.2.zip", 480 * MB)], contents: false)
        add("User caches", true, "Files apps keep to start and work faster. Rebuilt when needed; quit apps first. Files in use are skipped.",
            [(lib + "/Caches", 3_200 * MB)])
        var modules: [(String, Int64)] = []
        let projects = ["web-shop", "portfolio", "chat-app", "dashboard"]
        for (i, name) in projects.enumerated() {
            let size: Int64 = Int64(900 - 180 * i) * MB
            modules.append((home + "/Projects/" + name + "/node_modules", size))
        }
        add("node_modules folders", true, "JavaScript packages of projects. Restored with npm install (or yarn / pnpm).", modules, contents: false)
        add("Homebrew cache", true, "Downloaded packages Homebrew keeps after installing them. Downloaded again when needed.", [(lib + "/Caches/Homebrew", 1_400 * MB)])
        add("Leftovers of removed apps", false, "Settings, caches and data of apps that are no longer on this Mac (matched by their app id). Check them before deleting.",
            [(lib + "/Application Support/com.example.photostudio", 410 * MB), (lib + "/Containers/com.example.notes", 160 * MB),
             (lib + "/Preferences/com.example.photostudio.plist", 2 * MB)], contents: false)
        add("System logs", true, "Logs of installers, apps and services for all users, and old (rotated) macOS logs. Only needed to investigate a problem.",
            [("/Library/Logs", 410 * MB)])
        for s in list { s.checkAll(s.safe) }
        return list
    }

    // MARK: made-up apps

    static func apps() -> [InstalledApp] {
        let day: TimeInterval = 86400
        let now = Date()
        let rows: [(String, String, String, Int64, Double, Double?)] = [
            ("Adobe Photoshop 2026", "com.adobe.Photoshop", "27.1", 5_960 * MB, 120, 1),
            ("Adobe Premiere Pro 2025", "com.adobe.PremierePro.25", "25.6", 4_840 * MB, 300, 240),
            ("PyCharm", "com.jetbrains.pycharm", "2024.3", 3_410 * MB, 200, 3),
            ("Microsoft Word", "com.microsoft.Word", "16.90", 2_230 * MB, 400, 6),
            ("Microsoft Outlook", "com.microsoft.Outlook", "16.90", 2_070 * MB, 400, 0.2),
            ("Microsoft Excel", "com.microsoft.Excel", "16.90", 1_940 * MB, 400, 12),
            ("Microsoft PowerPoint", "com.microsoft.Powerpoint", "16.90", 1_680 * MB, 400, 210),
            ("Google Chrome", "com.google.Chrome", "131.0", 1_420 * MB, 600, 0.1),
            ("CrossOver", "com.codeweavers.CrossOver", "24.0", 1_140 * MB, 250, 380),
            ("Visual Studio Code", "com.microsoft.VSCode", "1.95", 620 * MB, 500, 0.5),
            ("Firefox", "org.mozilla.firefox", "133.0", 480 * MB, 700, 30),
            ("Microsoft Teams", "com.microsoft.teams2", "24295", 1_090 * MB, 650, 9),
            ("Spotify", "com.spotify.client", "1.2.50", 360 * MB, 800, 2),
            ("UTM", "com.utmapp.UTM", "4.6", 330 * MB, 150, 20),
        ]
        var list: [InstalledApp] = []
        for (name, id, version, size, installedDays, usedDays) in rows {
            let a = InstalledApp()
            a.name = name; a.bundleId = id; a.version = version; a.size = size
            let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path
            a.path = found ?? "/Applications/" + name + ".app"
            a.installed = now.addingTimeInterval(-installedDays * day)
            a.lastUsed = usedDays.map { now.addingTimeInterval(-$0 * day) }
            a.icon = icon(found)
            a.iconRequested = true
            list.append(a)
        }
        // The largest app opened in the picture: the bundle and everything that belongs to it.
        if let ps = list.first {
            let lib = home + "/Library"
            let items: [(String, String, Int64, Bool)] = [
                (ps.path, "App", ps.size, true),
                (lib + "/Caches/com.adobe.Photoshop", "Cache", 1_240 * MB, true),
                (lib + "/Application Support/Adobe/Adobe Photoshop 2026", "Support files", 312 * MB, true),
                (lib + "/Logs/Adobe/Photoshop", "Logs", 3 * MB, true),
                (lib + "/Saved Application State/com.adobe.Photoshop.savedState", "Saved state", 48 * KB, true),
                (lib + "/Preferences/com.adobe.Photoshop.plist", "Settings", 12 * KB, false),
            ]
            ps.leftovers = items.map { p, kind, size, dir in
                let l = AppLeftover(p, kind)
                l.size = size; l.isDir = dir
                return l
            }
        }
        return InstalledApp.sorted(list)
    }

    /// The app's own icon when it is installed here, else the generic app icon (row size).
    private static func icon(_ path: String?) -> NSImage {
        if let p = path { return InstalledApp.loadIcon(p) }
        let generic = NSWorkspace.shared.icon(for: .applicationBundle)
        generic.size = InstalledApp.iconSize
        return generic
    }
}

/// The README / website pictures, from the real window on the demo volume (names = the files in assets/).
final class DemoShotRun {
    let app: AppDelegate
    let dir: String
    let steps = Steps()
    private let shots: ShotRun
    init(_ app: AppDelegate, _ dir: String) { self.app = app; self.dir = dir; shots = ShotRun(app, dir) }

    func start() {
        let w = app.main!
        func page(_ p: Page) { if let i = w.pages.firstIndex(where: { $0 === p }) { w.pageIndex = i } }
        steps.then {
            w.window?.setContentSize(NSSize(width: 1280, height: 694))
            w.window?.center()
            w.clearPathSelection()
            w.measure.selectedIndex = 0   // the demo files are sparse: they only look big by file size
        }
        steps.waitUntil(20) { w.readers == 0 }
        steps.wait(1.5)
        // Contents as a tree-list (the hero picture): the two largest folders opened in place.
        var openDir: DirNode?
        steps.then {
            page(w.pContents)
            openDir = w.current
            for it in w.pContents.items.filter({ $0.isDir && $0.expandable }).prefix(2) { if let d = it.dir { w.setExpanded(d, true) } }
            w.refillContents()
        }
        steps.wait(1.5)
        steps.then { self.shots.shot("screenshot"); w.expandedDirs.removeAll(); w.refillContents() }
        // Treemap.
        steps.then { w.chartMode.selectedIndex = 1 }
        steps.wait(1.5)
        steps.then { self.shots.shot("screenshot-treemap"); w.chartMode.selectedIndex = 0 }
        // This Mac.
        steps.then { w.showThisPc() }
        steps.wait(1.5)
        steps.then { self.shots.shot("screenshot-this-pc"); if let d = openDir, w.isAttached(d) { w.selectDir(d) } }
        steps.wait(1)
        // Duplicates.
        steps.then { w.dupeMin.selectedIndex = 0; page(w.pDupes); w.findDuplicates() }
        steps.waitUntil(240) { w.dupeFinder == nil }
        steps.wait(1.5)
        steps.then { self.shots.shot("screenshot-duplicates") }
        var scanStatus = ""
        steps.then { scanStatus = self.scanLine(w) }
        // Suggestions: the largest of those with the most items opened, one item unchecked (a mixed check).
        steps.then { page(w.pSuggest) }
        steps.waitUntil(30) { w.suggestions != nil && !w.suggestFinding }
        steps.then {
            let shown = w.shownSuggestions.sorted { $0.size > $1.size }
            let most = shown.map { $0.targets.count }.max() ?? 0
            if let s = shown.first(where: { $0.targets.count == most && $0.safe }) ?? shown.first(where: { $0.targets.count == most }) {
                s.expanded = true
                if s.targets.count > 1 { s.setChecked(s.targets.count - 1, false) }
            }
            w.showSuggestions()
        }
        steps.wait(1.5)
        steps.then { w.statusLabel.stringValue = scanStatus; self.shots.shot("screenshot-suggestions") }
        // Apps: the largest app opened with all its files.
        steps.then { page(w.pApps) }
        steps.waitUntil(30) { w.apps != nil && !w.appsLoading }
        steps.then { if let h = w.pApps.items.first(where: { $0.app != nil && $0.groupOf == nil }) { w.expandApps([h], true) } }
        steps.wait(1.5)
        steps.then { w.statusLabel.stringValue = scanStatus; self.shots.shot("screenshot-apps") }
        // Delete list: the four largest files.
        steps.then { page(w.pFiles) }
        steps.waitUntil(20) { w.readers == 0 && !w.pFiles.items.isEmpty }
        steps.then {
            for it in w.pFiles.items.filter({ $0.canDelete && $0.file != nil }).prefix(4) { for t in DeleteTarget.from(it) { w.addTarget(t) } }
            w.basketChanged()
            page(w.pBasket)
        }
        steps.wait(1.5)
        steps.then { w.statusLabel.stringValue = scanStatus; self.shots.shot("screenshot-delete-list") }
        // Deleting the projects' node_modules folders: the confirmation, then the red strip mid-delete.
        steps.then {
            w.basket.removeAll()
            for i in 1...12 {
                let p = "/Volumes/Data/Projects/web-app-\(i)/node_modules"
                if let n = w.findScanned(p, exact: true) {
                    let t = DeleteTarget(path: p, label: "web-app-\(i)/node_modules", isDir: true, size: n.size)
                    t.dir = n
                    w.addTarget(t)
                }
            }
            w.basketChanged()
            page(w.pContents)
            w.statusLabel.stringValue = scanStatus
            DeleteJob.throttle = 120_000
            w.deleteBasket(trash: false)
        }
        steps.wait(1)
        steps.then {
            if let d = PromptDialog.open.last, let v = d.window?.contentView { self.shots.save(v, "screenshot-delete-confirm"); d.finish(0) }
            else { print("delete-confirm: no prompt shown") }
        }
        steps.waitUntil(20) { w.deleteJob == nil || w.deleteBar.fraction > 0.3 }
        steps.then { self.shots.shot("screenshot-deleting") }
        steps.waitUntil(120) { w.deleteJob == nil && !w.busy }
        steps.then { DeleteJob.throttle = 0 }
        steps.run { exit(0) }
    }

    /// The status line a scan leaves ("Data: 694 GB in 1,940 files and 165 folders").
    func scanLine(_ w: MainWindowController) -> String {
        guard let r = w.findRoot("/Volumes/Data"), let n = r.node else { return "" }
        return "\(r.displayName): \(Fmt.size(n.size)) in \(Fmt.count(n.files)) files and \(Fmt.count(n.dirs)) folders"
    }
}

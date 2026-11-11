import AppKit

// SpacePie for macOS.
//   SpacePie                      opens the window and scans the startup disk
//   SpacePie <folder>             opens the window and scans <folder>
//   SpacePie <scan.spacepie>      opens the window, scans the startup disk and opens the saved scan read-only
//   SpacePie --cli scan <folder>  headless scan, prints totals (same format as the Windows exe)
//   SpacePie --cli screenshot <out-folder> <folder>
//                                          opens the window, scans, saves a PNG of every view, About, the update window
//                                          and the Full Disk Access dialog
//   SpacePie --cli selftest <scratch-folder>
//                                          end-to-end self-test of the real window; writes <scratch-folder>.log, exit code 0 = passed
//   SpacePie --splash             shows the start-up screen until it is clicked or Esc is pressed

func headlessScan(_ path: String) -> Int32 {
    let full = (path as NSString).expandingTildeInPath
    let started = Date()
    let s = Scanner()
    let root = s.run(full)
    let secs = Date().timeIntervalSince(started)
    print("")
    print("\(root.name)\t\(root.bytes) bytes\t\(root.alloc) on disk\t\(root.files) files\t\(root.dirs) dirs\t\(String(format: "%.3f", secs)) s")
    for c in root.children {
        print("  " + c.name.padding(toLength: max(40, c.name.count), withPad: " ", startingAt: 0)
              + " \(Fmt.count(c.bytes).leftPad(15)) bytes \(Fmt.count(c.alloc).leftPad(15)) on disk \(Fmt.count(c.files).leftPad(10)) files")
    }
    return 0
}

/// Scans the folder and prints what the Suggestions view would list (checks and CI).
func headlessSuggest(_ path: String) -> Int32 {
    let full = (path as NSString).expandingTildeInPath
    let root = Scanner().run(full)
    let started = Date()
    let w = MainWindowController()
    let list = w.findSuggestions([root], volumes: [])
    print("\(list.count) suggestions in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
    for s in list {
        print("\(s.safe ? "safe  " : "review") \(Fmt.size(s.size).leftPad(10))  \(s.name)  (\(s.location))")
        for t in s.targets.prefix(ProcessInfo.processInfo.environment["ALL"] != nil ? 999 : 5) { print("                      \(Fmt.size(t.size).leftPad(10))  \(t.emptyTrash ? "Empty the " + t.label : t.path)") }
        if s.targets.count > 5 { print("                      ... and \(s.targets.count - 5) more") }
    }
    return 0
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var main: MainWindowController!
    var about: AboutWindow?
    var fullDiskAccess: FullDiskAccessWindow?
    var splash: SplashWindow?
    let initialPath: String?
    let screenshotDir: String?
    let selfTestDir: String?
    private var shots: ShotRun?
    private var test: SelfTestRun?

    init(initialPath: String?, screenshotDir: String?, selfTestDir: String? = nil) {
        self.initialPath = initialPath; self.screenshotDir = screenshotDir; self.selfTestDir = selfTestDir
    }

    // Normal start only: the splash is on screen from the first moment until the main window shows.
    func applicationWillFinishLaunching(_ notification: Notification) {
        if screenshotDir != nil || selfTestDir != nil { return }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let s = SplashWindow()
        splash = s
        s.present()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Updater.cleanUp()
        NSApp.appearance = NSAppearance(named: .darkAqua)
        splash?.step("Building the menu")
        buildMenu()
        splash?.step("Building the main window")
        main = MainWindowController()
        main.selfTestDir = selfTestDir
        main.shotMode = screenshotDir != nil
        // Normal start: the last scan shows at once and is brought up to date (not in the --cli modes).
        main.fastStart = screenshotDir == nil && selfTestDir == nil
        splash?.step("Opening the window")
        main.showWindow(nil)
        main.window?.makeKeyAndOrderFront(nil)
        if let s = splash {
            s.orderOut(nil)
            s.close()
            splash = nil
            main.window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let dir = screenshotDir { startScreenshots(dir) }
        if let dir = selfTestDir {
            main.onScanFinished = { [weak self] in
                guard let self = self, self.test == nil else { return }
                self.main.onScanFinished = nil
                let t = SelfTestRun(self.main, dir)
                self.test = t
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { t.start() }
            }
        }
        // Ask for Full Disk Access before the first scan (never in the --cli modes); the scan starts when the dialog closes.
        if screenshotDir == nil && selfTestDir == nil && FullDiskAccess.shouldPrompt {
            FullDiskAccess.notePrompted()
            let path = initialPath
            let d = FullDiskAccessWindow { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.async { self.fullDiskAccess = nil }
                self.main.window?.makeKeyAndOrderFront(nil)
                self.main.start(initialPath: path)
            }
            fullDiskAccess = d
            DispatchQueue.main.async { d.present(over: self.main.window) }
            return
        }
        main.start(initialPath: initialPath)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func showAbout(_ sender: Any?) {
        if about == nil { about = AboutWindow(checkForUpdates: { [weak self] in self?.main.updates.check(manual: true) }) }
        about?.present(over: main.window)
    }

    @objc func checkForUpdates(_ sender: Any?) { main.updates.check(manual: true) }
    @objc func openRepo(_ sender: Any?) { NSWorkspace.shared.open(AboutWindow.repoURL) }
    @objc func chooseFolder(_ sender: Any?) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = "Choose a folder to analyze"
        if p.runModal() == .OK, let u = p.url { main.scanPath(u.path) }
    }

    private func buildMenu() {
        let bar = NSMenu()
        func item(_ m: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = target
            m.addItem(it)
        }
        func sub(_ title: String) -> NSMenu {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            top.submenu = m
            bar.addItem(top)
            return m
        }

        // App menu: About and Check for Updates are the app-level actions (design language: menu bar).
        let app = sub("SpacePie")
        item(app, "About SpacePie", #selector(showAbout(_:)), target: self)
        item(app, "Check for Updates...", #selector(checkForUpdates(_:)), target: self)
        app.addItem(.separator())
        item(app, "Hide SpacePie", #selector(NSApplication.hide(_:)), "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        item(app, "Quit SpacePie", #selector(NSApplication.terminate(_:)), "q")

        let file = sub("File")
        item(file, "Choose Folder...", #selector(chooseFolder(_:)), "o", target: self)
        item(file, "Import Scan...", #selector(MainWindowController.menuBarOpenScan(_:)), "o", [.command, .shift])
        item(file, "Export...", #selector(MainWindowController.menuBarExport(_:)), "e", [.command, .shift])
        file.addItem(.separator())
        item(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")

        let edit = sub("Edit")
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        item(edit, "Find Files...", #selector(MainWindowController.menuBarFind(_:)), "f")

        let view = sub("View")
        item(view, "Actual Size", #selector(MainWindowController.menuBarActualSize(_:)), "0")
        item(view, "Zoom In", #selector(MainWindowController.menuBarZoomIn(_:)), "+")
        item(view, "Zoom Out", #selector(MainWindowController.menuBarZoomOut(_:)), "-")
        // ⌘= also zooms in (the + key without Shift on most keyboards), as in other apps.
        let zoomEq = NSMenuItem(title: "Zoom In", action: #selector(MainWindowController.menuBarZoomIn(_:)), keyEquivalent: "=")
        zoomEq.keyEquivalentModifierMask = .command
        zoomEq.isHidden = true
        zoomEq.allowsKeyEquivalentWhenHidden = true
        view.addItem(zoomEq)

        let folder = sub("Folder")
        item(folder, "Back", #selector(MainWindowController.menuBarBack(_:)), "[")
        item(folder, "Forward", #selector(MainWindowController.menuBarForward(_:)), "]")
        item(folder, "Up", #selector(MainWindowController.menuBarUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!))
        item(folder, "Rescan Folder", #selector(MainWindowController.menuBarRescan(_:)), "r")
        item(folder, "Show in Finder", #selector(MainWindowController.menuBarFinder(_:)), "r", [.command, .shift])
        item(folder, "Quick Look", #selector(MainWindowController.menuBarQuickLook(_:)), "y")
        item(folder, "Get Info", #selector(MainWindowController.menuBarGetInfo(_:)), "i")
        folder.addItem(.separator())
        item(folder, "Add to Delete List", #selector(MainWindowController.menuBarAddList(_:)), "d")
        item(folder, "Move to Trash...", #selector(MainWindowController.menuBarTrash(_:)))
        item(folder, "Delete Permanently...", #selector(MainWindowController.menuBarDelete(_:)), "d", [.command, .shift])

        let window = sub("Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = window

        let help = sub("Help")
        item(help, "SpacePie on GitHub", #selector(openRepo(_:)), target: self)
        NSApp.helpMenu = help

        NSApp.mainMenu = bar
    }

    // MARK: CI screenshots

    private var demoShots: DemoShotRun?

    private func startScreenshots(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if Demo.on {
            let run = DemoShotRun(self, dir)
            demoShots = run
            main.onScanFinished = { [weak self] in
                guard let self = self else { return }
                self.main.onScanFinished = nil
                run.start()
            }
            return
        }
        let run = ShotRun(self, dir)
        shots = run
        // The splash is not shown in this mode: rendered from its view.
        if let rep = SplashView.render() {
            let path = dir + "/0-splash.png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("saved \(path)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { run.shot("0-scanning") }
        main.onScanFinished = { [weak self] in
            guard let self = self else { return }
            self.main.onScanFinished = nil
            run.start()
        }
    }
}

Dataless.disableMaterialization()      // before anything reads the disk: never download iCloud items (see Access.swift)

/// `SpacePie --splash`: shows the splash until it is clicked or Esc is pressed (to look at it for as long as you
/// like); the main window is not opened.
final class SplashPreviewDelegate: NSObject, NSApplicationDelegate {
    private var window: SplashWindow?
    private var monitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let s = SplashWindow()
        window = s
        s.present()
        s.step("Preview - click or press Esc to close")
        NSApp.activate(ignoringOtherApps: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { e in
            if e.type == .leftMouseDown || e.keyCode == 53 { NSApp.terminate(nil) }   // 53 = Esc
            return e
        }
    }
}

let args = CommandLine.arguments
if args.count == 2 && args[1] == "--splash" {
    let app = NSApplication.shared
    let d = SplashPreviewDelegate()
    app.delegate = d
    app.setActivationPolicy(.regular)
    app.run()
    exit(0)
}
if args.count >= 2 && args[1] == "--cli" {
    if args.count == 4 && args[2] == "scan" { exit(headlessScan(args[3])) }
    if args.count == 4 && args[2] == "suggest" { exit(headlessSuggest(args[3])) }
    if args.count == 4 && args[2] == "update-install" {
        // Installs the app from a downloaded SpacePie-macOS.dmg where Update now would (checks and CI).
        guard let target = Updater.installTarget() else { print("failed: no writable place to install to"); exit(1) }
        do { try Updater.install(args[3], to: target); print("installed to \(target)"); exit(0) } catch { print("failed: \(error.localizedDescription)"); exit(1) }
    }
    if args.count == 5 && args[2] == "screenshot" {
        let app = NSApplication.shared
        let d = AppDelegate(initialPath: args[4], screenshotDir: args[3])
        app.delegate = d
        app.setActivationPolicy(.regular)
        app.run()
        exit(0)
    }
    if args.count == 5 && args[2] == "demo-shots" {
        // README / website pictures from the demo volume (tools/make_demo_mac.py): nothing of this Mac is shown, and
        // nothing is written to the app's own data.
        Demo.on = true
        Fmt.setLocale(Locale(identifier: "en_US"))
        let state = NSTemporaryDirectory() + "spacepie-demo-state"
        try? FileManager.default.removeItem(atPath: state)
        Snapshot.folderOverride = state + "/snapshots"
        HashCache.fileOverride = state + "/hashes.bin"
        History.folderOverride = state + "/history"
        IgnoreList.fileOverride = state + "/ignored.txt"
        AppsCache.fileOverride = state + "/apps.plist"
        let app = NSApplication.shared
        let d = AppDelegate(initialPath: args[4], screenshotDir: args[3])
        app.delegate = d
        app.setActivationPolicy(.regular)
        app.run()
        exit(0)
    }
    if args.count == 4 && args[2] == "selftest" {
        let dir = SelfTest.prepare(args[3])
        // The self-test keeps its snapshots and hash cache next to its scratch folder.
        Snapshot.folderOverride = dir + "-snapshots"
        HashCache.fileOverride = dir + "-hashes.bin"
        History.folderOverride = dir + "-history"
        let app = NSApplication.shared
        let d = AppDelegate(initialPath: dir, screenshotDir: nil, selfTestDir: dir)
        app.delegate = d
        app.setActivationPolicy(.regular)
        app.run()
        exit(0)
    }
    print("Usage: SpacePie --cli scan <folder>")
    print("       SpacePie --cli suggest <folder>")
    print("       SpacePie --cli screenshot <out-folder> <folder>")
    print("       SpacePie --cli selftest <scratch-folder>")
    print("       SpacePie --cli demo-shots <out-folder> /Volumes/Data   (after python3 tools/make_demo_mac.py)")
    print("       SpacePie --cli update-install <SpacePie-macOS.dmg>")
    exit(2)
}

let initial = args.dropFirst().first { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
let app = NSApplication.shared
let delegate = AppDelegate(initialPath: initial, screenshotDir: nil)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

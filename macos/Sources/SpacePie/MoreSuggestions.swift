import AppKit
import CoreServices

/// Suggestions the user never wants to see again: a whole suggestion (by name) or one location (by path), kept in
/// ~/Library/Application Support/SpacePie/ignored-suggestions.txt ("s<TAB>name" / "t<TAB>path" lines).
enum IgnoreList {
    static var fileOverride: String?          // self-test
    static var path: String { fileOverride ?? AppData.path("ignored-suggestions.txt") }
    private static let lock = NSLock()
    private static var cache: (names: Set<String>, paths: Set<String>)?

    static func load() -> (names: Set<String>, paths: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        var names = Set<String>(), paths = Set<String>()
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1).map { String($0) }
                guard parts.count == 2 else { continue }
                if parts[0] == "s" { names.insert(parts[1]) } else if parts[0] == "t" { paths.insert(PathUtil.trim(parts[1])) }
            }
        }
        cache = (names, paths)
        return (names, paths)
    }

    static var count: Int { let l = load(); return l.names.count + l.paths.count }

    /// One line per ignored item, for the list the user can review.
    static var lines: [String] {
        let l = load()
        return l.names.sorted().map { "All of \"\($0)\"" } + l.paths.sorted()
    }

    static func add(name: String? = nil, path: String? = nil) {
        var l = load()
        if let n = name { l.names.insert(n) }
        if let p = path { l.paths.insert(PathUtil.trim(p)) }
        save(l)
    }

    static func clear() { save((names: [], paths: [])) }

    private static func save(_ l: (names: Set<String>, paths: Set<String>)) {
        lock.lock(); cache = l; lock.unlock()
        let text = (l.names.sorted().map { "s\t" + $0 } + l.paths.sorted().map { "t\t" + $0 }).joined(separator: "\n")
        try? FileManager.default.createDirectory(atPath: PathUtil.parent(path), withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The suggestions without what is ignored (whole suggestions by name, locations by path).
    static func apply(_ list: [Suggestion]) -> [Suggestion] {
        let l = load()
        if l.names.isEmpty && l.paths.isEmpty { return list }
        var out: [Suggestion] = []
        for s in list where !l.names.contains(s.name) {
            s.targets.removeAll { l.paths.contains(PathUtil.trim($0.path)) }
            s.size = s.targets.reduce(Int64(0)) { $0 + $1.size }
            if s.targets.isEmpty || s.size <= 0 { continue }
            if s.targets.count > 1 && !s.location.hasSuffix("drives") { s.location = "\(Fmt.count(s.targets.count)) locations" }
            else if s.targets.count == 1 && !s.targets[0].emptyTrash { s.location = s.targets[0].path }
            out.append(s)
        }
        return out
    }
}

extension MainWindowController {
    /// More places other Mac cleaners look (CleanMyMac's System Junk, Trash Bins, Mail Attachments and Uninstaller
    /// leftovers), with the same rules as the rest: one line on what deleting means, items to review start unchecked,
    /// never anything inside an app. Runs on a background thread while the trees are held still.
    func findMoreSuggestions(_ scanned: [DirNode], into list: inout [Suggestion]) {
        let home = PathUtil.home, lib = home + "/Library"
        let admin = "macOS asks for your administrator password."

        // System caches and logs (all users): not macOS's own caches.
        let sysCaches = Suggestion("System caches", safe: true, note: "Caches of apps and services for all users (not macOS's own). Rebuilt when needed. " + admin)
        let appleCaches = Set(DeleteJob.children("/Library/Caches").map { PathUtil.name($0) }.filter { $0.hasPrefix("com.apple.") })
        addContents(sysCaches, "/Library/Caches", exclude: appleCaches)
        finish(&list, sysCaches)
        let sysLogs = Suggestion("System logs", safe: true, note: "Logs of installers, apps and services for all users, and old (rotated) macOS logs. Only needed to investigate a problem. " + admin)
        addContents(sysLogs, "/Library/Logs")
        for f in DeleteJob.children("/private/var/log") where MainWindowController.isRotatedLog(PathUtil.name(f)) {
            var st = stat()
            guard lstat(f, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let size = DirNode.onDisk ? Int64(st.st_blocks) * 512 : Int64(st.st_size)
            if size > 0 { sysLogs.targets.append(DeleteTarget(path: f, label: PathUtil.name(f), size: size, note: "old log")); sysLogs.size += size }
        }
        finish(&list, sysLogs)

        // Mail: attachments Mail saved when they were opened (downloaded again from the message), and the local trash.
        let mailDl = Suggestion("Mail attachments", safe: true, note: "Attachments Mail saved when you opened them. Mail gets them again from the message when needed.")
        addContents(mailDl, lib + "/Containers/com.apple.mail/Data/Library/Mail Downloads")
        addContents(mailDl, lib + "/Mail Downloads")
        finish(&list, mailDl)
        if FullDiskAccess.granted {
            let mailTrash = Suggestion("Mail trash", safe: false, note: "Messages in Mail's Trash and Deleted Messages mailboxes on this Mac. Quit Mail first. Messages kept on the mail server stay there.")
            for v in DeleteJob.children(lib + "/Mail") where PathUtil.name(v).hasPrefix("V") && PathUtil.isDir(v) {
                for account in DeleteJob.children(v) where PathUtil.isDir(account) {
                    for box in ["Deleted Messages.mbox", "Trash.mbox"] {
                        for m in MainWindowController.messageFolders(PathUtil.join(account, box)) { addContents(mailTrash, m) }
                    }
                }
            }
            for t in mailTrash.targets { t.label = "Mail trash: " + PathUtil.name(PathUtil.parent(MainWindowController.mboxOf(t.path))) }
            finish(&list, mailTrash)
        }

        // More Xcode data (DerivedData, archives, device support and simulator caches are listed above).
        let dev = lib + "/Developer"
        cacheRow(&list, "Xcode device logs", dev + "/Xcode/iOS Device Logs", true, "Logs Xcode copied from connected devices. Copied again when needed.")
        cacheRow(&list, "Xcode previews", dev + "/Xcode/UserData/Previews", true, "SwiftUI preview builds. Rebuilt when a preview is shown.")
        cacheRow(&list, "Xcode documentation", dev + "/Shared/Documentation/DocSets", true, "Downloaded documentation sets. Downloaded again when needed.")
        let sims = Suggestion("Unavailable simulators", safe: true, note: "Simulators of iOS versions no longer installed: they can't be started any more.")
        for udid in MainWindowController.unavailableSimulators() {
            let d = dev + "/CoreSimulator/Devices/" + udid
            guard PathUtil.isDir(d) else { continue }
            let size = measureFolder(d)
            if size > 0 { sims.targets.append(DeleteTarget(path: d, label: "Simulator " + udid.prefix(8), isDir: true, size: size, note: "unavailable")); sims.size += size }
        }
        finish(&list, sims)

        // Leftovers of apps that are no longer installed (named after their bundle id; review first).
        let orphans = Suggestion("Leftovers of removed apps", safe: false, note: "Settings, caches and data of apps that are no longer on this Mac (matched by their app id). Check them before deleting.")
        for t in orphanLeftovers() { orphans.targets.append(t); orphans.size += t.size }
        orphans.location = "\(Fmt.count(orphans.targets.count)) items"
        if !orphans.targets.isEmpty { list.append(orphans) }

        // Broken background items: launch agents and daemons whose program is gone.
        let broken = Suggestion("Broken background items", safe: true, note: "Launch agents and daemons whose program is gone (left by removed apps). They only fail at every start. Items in /Library: " + admin)
        for dir in [lib + "/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            for p in DeleteJob.children(dir) where MainWindowController.isBrokenLaunchItem(p) {
                var st = stat()
                let size: Int64 = lstat(p, &st) == 0 ? max(Int64(st.st_blocks) * 512, 1) : 1
                broken.targets.append(DeleteTarget(path: p, label: PathUtil.name(p), size: size, note: "program missing"))
                broken.size += size
            }
        }
        broken.location = "\(Fmt.count(broken.targets.count)) items"
        if !broken.targets.isEmpty { list.append(broken) }

        // Deleted users: kept disk images of removed accounts, and home folders without an account.
        let users = Suggestion("Deleted users", safe: false, note: "Folders of user accounts that no longer exist. Check that nothing in them is still needed. " + admin)
        addContents(users, "/Users/Deleted Users")
        let homes = MainWindowController.accountHomes(), uids = MainWindowController.accountIds()
        if !homes.isEmpty && !uids.isEmpty {
            for p in DeleteJob.children("/Users") where PathUtil.isDir(p) {
                let n = PathUtil.name(p)
                if n.hasPrefix(".") || ["Shared", "Deleted Users", "Guest"].contains(n) || homes.contains(PathUtil.trim(p)) { continue }
                // Owned by an account that exists (e.g. a folder an installer made for root): not a deleted user's.
                var st = stat()
                if lstat(p, &st) != 0 || uids.contains(st.st_uid) { continue }
                let size = measureFolder(p)
                if size > 0 { users.targets.append(DeleteTarget(path: p, label: n, isDir: true, size: size, note: "no such user")); users.size += size }
            }
        }
        finish(&list, users)

        // From the scanned index: disk images not opened for 30 days, unfinished downloads, old update packages.
        let found = indexFindings(scanned)
        for (name, safe, note, targets) in [
            ("Disk images", false, "Disk images (.dmg, .iso, .img...) not opened for 30 days and not mounted: usually installers already used. Keep the ones you still need.", found.images),
            ("Unfinished downloads", true, "Downloads in Downloads or on the Desktop that never finished (older than a day). They can't be opened; download again if needed.", found.partial),
            ("Old update packages", true, "Update packages apps downloaded and kept after installing them (older than 7 days).", found.updates)] {
            if targets.isEmpty { continue }
            let s = Suggestion(name, safe: safe, note: note)
            s.targets = targets
            s.size = targets.reduce(Int64(0)) { $0 + $1.size }
            s.location = targets.count == 1 ? targets[0].path : "\(Fmt.count(targets.count)) locations"
            list.append(s)
        }
    }

    /// "system.log.0.gz", "install.log.3", "wifi.log.bz2": logs macOS has rotated (the live log is never one of them).
    static func isRotatedLog(_ name: String) -> Bool {
        name.range(of: "\\.(gz|bz2|xz|[0-9]+)$", options: .regularExpression) != nil
    }

    /// Folders named "Messages" inside a mailbox (a few levels down), where Mail keeps the message files.
    static func messageFolders(_ mbox: String) -> [String] {
        guard PathUtil.isDir(mbox) else { return [] }
        var out: [String] = []
        var stack: [(String, Int)] = [(mbox, 0)]
        while let (d, depth) = stack.popLast() {
            for c in DeleteJob.children(d) where PathUtil.isDir(c) {
                if PathUtil.name(c) == "Messages" { out.append(c) } else if depth < 6 { stack.append((c, depth + 1)) }
            }
        }
        return out
    }

    /// The .mbox folder holding path.
    static func mboxOf(_ path: String) -> String {
        var p = path
        while p != "/" && !p.hasSuffix(".mbox") { p = PathUtil.parent(p) }
        return p
    }

    /// Ids of simulators whose runtime is gone (xcrun simctl; nothing when Xcode is not installed).
    static func unavailableSimulators() -> [String] {
        guard FileManager.default.fileExists(atPath: "/Applications/Xcode.app") || FileManager.default.fileExists(atPath: "/Library/Developer/CoreSimulator")
        else { return [] }
        let r = SystemInfo.run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"], timeout: 20)
        guard r.status == 0, let data = r.out.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let devices = o["devices"] as? [String: Any] else { return [] }
        var out: [String] = []
        for case let list as [[String: Any]] in devices.values {
            for d in list where (d["isAvailable"] as? Bool) == false { if let u = d["udid"] as? String { out.append(u) } }
        }
        return out
    }

    /// A launch agent or daemon (not Apple's) whose program path no longer exists.
    static func isBrokenLaunchItem(_ plist: String) -> Bool {
        let n = PathUtil.name(plist)
        guard n.hasSuffix(".plist"), !n.hasPrefix("com.apple."), let d = NSDictionary(contentsOfFile: plist) as? [String: Any] else { return false }
        if d["BundleProgram"] != nil { return false }      // relative to an app bundle: checked by macOS itself
        guard let prog = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first, prog.hasPrefix("/") else { return false }
        var st = stat()
        // Only "no such file" counts: a folder we may not look into (EACCES) is not proof that it is gone.
        return lstat(prog, &st) != 0 && errno == ENOENT
    }

    /// User ids of the accounts on this Mac (dscl); empty when they can't be read.
    static func accountIds() -> Set<UInt32> {
        let r = SystemInfo.run("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"], timeout: 10)
        guard r.status == 0 else { return [] }
        var out = Set<UInt32>()
        for line in r.out.split(separator: "\n") {
            if let last = line.split(separator: " ", omittingEmptySubsequences: true).last, let id = Int64(last) { out.insert(UInt32(truncatingIfNeeded: id)) }
        }
        return out
    }

    /// Home folders of the accounts on this Mac (dscl); empty when it can't be read.
    static func accountHomes() -> Set<String> {
        let r = SystemInfo.run("/usr/bin/dscl", [".", "-list", "/Users", "NFSHomeDirectory"], timeout: 10)
        guard r.status == 0 else { return [] }
        var out = Set<String>()
        for line in r.out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2 { out.insert(PathUtil.trim(parts.dropFirst().joined(separator: " "))) }
        }
        return out
    }

    /// Ids that are not apps' own: macOS components, developer tools, and libraries many apps share (their names
    /// say nothing about which app is gone).
    static let notAppIds = ["org.cups.", "org.swift.", "net.java.", "org.openjdk.", "org.python.", "org.ruby-lang.", "com.oracle.java",
                            "com.electron.", "com.github.electron", "org.sparkle-project.", "com.sindresorhus.launchatloginhelper",
                            "com.amplitude.", "com.segment.", "com.revenuecat.", "com.google.keystone", "com.microsoft.autoupdate",
                            "com.crashlytics", "io.sentry", "com.firebase", "com.google.firebase"]

    /// Bundle ids of what is installed outside the app folders: audio plug-ins, System Settings panes, frameworks,
    /// extensions, screen savers, input methods and services, and the labels of launch agents and daemons whose
    /// program exists (an app's helper keeps its developer's files).
    static func installedComponentIds(home: String = PathUtil.home) -> [String] {
        var out: [String] = []
        var dirs: [String] = []
        for base in ["/Library", home + "/Library"] {
            for d in ["Audio/Plug-Ins/Components", "Audio/Plug-Ins/VST", "Audio/Plug-Ins/VST3", "Audio/Plug-Ins/HAL", "Audio/Plug-Ins/MAS",
                      "PreferencePanes", "Frameworks", "Extensions", "Screen Savers", "Input Methods", "Services", "Internet Plug-Ins",
                      "QuickLook", "Spotlight", "Application Support/Avid/Audio/Plug-Ins"] { dirs.append(base + "/" + d) }
        }
        for d in dirs {
            for b in DeleteJob.children(d) {
                let info = NSDictionary(contentsOfFile: b + "/Contents/Info.plist") ?? NSDictionary(contentsOfFile: b + "/Resources/Info.plist")
                if let id = info?["CFBundleIdentifier"] as? String { out.append(id.lowercased()) }
            }
        }
        for d in ["/Library/LaunchAgents", "/Library/LaunchDaemons", home + "/Library/LaunchAgents"] {
            for p in DeleteJob.children(d) where p.hasSuffix(".plist") && !isBrokenLaunchItem(p) {
                if let label = (NSDictionary(contentsOfFile: p))?["Label"] as? String { out.append(label.lowercased()) }
            }
        }
        return out
    }

    /// "com.vendor.app": an app id (reverse domain, at least three parts).
    static func isAppId(_ s: String) -> Bool {
        s.range(of: "^[a-z]{2,6}\\.[a-z0-9_-]+(\\.[a-z0-9_-]+)+$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Items in ~/Library named after an app id whose app is no longer installed, nor any other app of the same developer
    /// (an app's id, or its helper's "com.vendor.app.helper"). Never Apple's, never shared group containers.
    func orphanLeftovers(home: String = PathUtil.home) -> [DeleteTarget] {
        let lib = home + "/Library"
        let installed = (apps?.filter { !$0.uninstalled } ?? InstalledApp.readAll(InstalledApp.defaultRoots)).map { $0.bundleId.lowercased() }
            + MainWindowController.installedComponentIds(home: home)
        let now = Date()
        func developer(_ id: String) -> String? {
            let p = id.split(separator: ".")
            return p.count >= 3 ? p[0] + "." + p[1] : nil
        }
        let developers = Set(installed.compactMap { developer($0) })
        var known: [String: Bool] = [:]
        func appExists(_ id: String) -> Bool {
            if let k = known[id] { return k }
            let v = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
            known[id] = v
            return v
        }
        func owned(_ id: String) -> Bool {
            let l = id.lowercased()
            if l.hasPrefix("com.apple.") || l.hasPrefix("group.") || l.hasPrefix("systemgroup.") { return true }
            if MainWindowController.notAppIds.contains(where: { l.hasPrefix($0) }) { return true }
            if let d = developer(l), developers.contains(d) { return true }
            var parts = l.split(separator: ".").map { String($0) }
            while parts.count >= 2 {
                if installed.contains(parts.joined(separator: ".")) || appExists(parts.joined(separator: ".")) { return true }
                parts.removeLast()
            }
            return false
        }
        var out: [DeleteTarget] = []
        // Not ~/Library/Caches and ~/Library/Logs: the User caches and Logs rows empty them already.
        for (folder, kind) in [("Application Support", "Support files"), ("Containers", "Container"), ("Preferences", "Settings"),
                               ("Saved Application State", "Saved state"), ("HTTPStorages", "Web data"), ("WebKit", "Web data"),
                               ("Cookies", "Cookies")] {
            for p in DeleteJob.children(lib + "/" + folder) {
                var id = PathUtil.name(p)
                for suffix in [".plist", ".savedstate", ".binarycookies"] where id.hasSuffix(suffix) { id = String(id.dropLast(suffix.count)) }
                guard MainWindowController.isAppId(id), !owned(id) else { continue }
                if Dataless.isDataless(p) { continue }
                // Changed in the last 30 days: something still uses it (a command-line tool, a plug-in, a helper).
                if let m = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date,
                   now.timeIntervalSince(m) < 30 * 86400 { continue }
                let size = max(1, InstalledApp.measureItem(p))
                out.append(DeleteTarget(path: p, label: kind + ": " + id, isDir: PathUtil.isDir(p), size: size, note: "app not installed"))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Disk images not opened for 30 days (and not mounted), unfinished downloads and old update packages, from the index.
    func indexFindings(_ scanned: [DirNode]) -> (images: [DeleteTarget], partial: [DeleteTarget], updates: [DeleteTarget]) {
        let home = PathUtil.trim(PathUtil.home)
        let now = Int64(Date().timeIntervalSince1970)
        let mounted = MainWindowController.mountedImages()
        let imageExt: Set<String> = ["dmg", "iso", "img", "sparseimage", "cdr", "toast"]
        let partialExt = [".crdownload", ".part", ".partial", ".opdownload", ".filepart", ".download"]
        let updateDirs: Set<String> = ["update", "updates", "updater", "sparkle", "installer", "installers", "squirrel"]
        let updateExt: Set<String> = ["pkg", "dmg", "zip", "delta", "xip"]
        var images: [DeleteTarget] = [], partial: [DeleteTarget] = [], updates: [DeleteTarget] = []
        for root in scanned {
            for d in root.descendants() {
                if d.insideSkipped { continue }
                let path = d.fullPath
                // Never inside apps, virtual machines, photo libraries or the system.
                if MainWindowController.systemRoots.contains(where: { PathUtil.isWithin(path, $0) && $0 != "/Library" }) { continue }
                let lower = path.lowercased()
                if lower.contains(".app/") || lower.hasSuffix(".app") || lower.contains(".utm") || lower.contains(".pvm") || lower.contains(".vmwarevm")
                    || lower.contains(".photoslibrary") || lower.contains("/library/caches") { continue }
                let inLibrary = PathUtil.isWithin(path, home + "/Library") || PathUtil.isWithin(path, "/Library")
                let inUpdates = inLibrary && path.split(separator: "/").contains { updateDirs.contains($0.lowercased()) }
                let inDownloads = PathUtil.isWithin(path, home + "/Downloads") || PathUtil.isWithin(path, home + "/Desktop")
                // Safari's unfinished downloads are folders.
                if d.name.hasSuffix(".download"), d.modified > 0, now - d.modified > 86400, inDownloads, d.size > 0 {
                    partial.append(DeleteTarget(path: path, label: d.name, isDir: true, size: d.size, note: "unfinished download"))
                }
                if d.name.hasSuffix(".sparsebundle"), !inLibrary, !mounted.contains(path), d.size >= 10 << 20, d.modified > 0, now - d.modified > 30 * 86400 {
                    images.append(DeleteTarget(path: path, label: d.name, isDir: true, size: d.size, note: "disk image"))
                }
                guard let files = d.fileList else { continue }
                for f in files where !f.dataless {
                    let ext = FileIndex.ext(f.name), size = FileIndex.measure(f)
                    let fp = PathUtil.join(path, f.name)
                    if !inLibrary && imageExt.contains(ext) && size >= 10 << 20 && f.lastUse > 0 && now - f.lastUse > 30 * 86400 && !mounted.contains(fp) {
                        images.append(DeleteTarget(path: fp, label: f.name, size: size, note: "disk image"))
                    } else if inDownloads && partialExt.contains(where: { f.name.hasSuffix($0) }) && f.modified > 0 && now - f.modified > 86400 && size > 0 {
                        partial.append(DeleteTarget(path: fp, label: f.name, size: size, note: "unfinished download"))
                    } else if inUpdates && updateExt.contains(ext) && size >= 1 << 20 && f.modified > 0 && now - f.modified > 7 * 86400 {
                        updates.append(DeleteTarget(path: fp, label: f.name, size: size, note: "old update"))
                    }
                }
            }
        }
        return (images.sorted { $0.size > $1.size }, partial.sorted { $0.size > $1.size }, updates.sorted { $0.size > $1.size })
    }

    /// Paths of the disk images mounted now (hdiutil info).
    static func mountedImages() -> Set<String> {
        let r = SystemInfo.run("/usr/bin/hdiutil", ["info", "-plist"], timeout: 10)
        guard r.status == 0, let data = r.out.data(using: .utf8),
              let o = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = o["images"] as? [[String: Any]] else { return [] }
        return Set(images.compactMap { $0["image-path"] as? String }.map { PathUtil.trim($0) })
    }

    // MARK: ignore list in the Suggestions view

    /// Never suggest the selected rows again (a suggestion by name, a location by path); they leave the list at once.
    func ignoreSelectedSuggestions() {
        let sel = pSuggest.selectedItems.filter { $0.suggestion != nil }
        if sel.isEmpty { return }
        for it in sel {
            guard let s = it.suggestion else { continue }
            if it.groupOf == nil { IgnoreList.add(name: s.name) }
            else if let t = it.targets?.first { IgnoreList.add(path: t.path) }
        }
        suggestions = IgnoreList.apply(suggestions ?? [])
        showSuggestions()
        statusLabel.stringValue = "Not suggested again: \(Fmt.count(sel.count)) item\(sel.count == 1 ? "" : "s"). Ignored (\(IgnoreList.count))... in the Suggestions bar lists them."
    }

    /// The ignored items, with Stop ignoring all.
    func showIgnoredSuggestions() {
        let lines = IgnoreList.lines
        if lines.isEmpty { return }
        let d = PromptDialog(icon: .info, heading: "\(Fmt.count(lines.count)) item\(lines.count == 1 ? " is" : "s are") never suggested",
                             text: "You chose not to see these in Suggestions again.", details: lines,
                             buttons: [("Close", .primary), ("Stop ignoring all", .secondary)], defaultIndex: 0, cancelIndex: 0)
        d.show(over: window) { [weak self] i in
            guard let self = self, i == 1 else { return }
            IgnoreList.clear()
            self.suggestDirty = true
            self.fillSuggestions(quiet: true)
            self.updateButtons()
        }
    }
}

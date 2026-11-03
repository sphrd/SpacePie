import AppKit

/// Something an app left behind in ~/Library or /Library (settings, caches, support files...).
final class AppLeftover {
    static let exact = "Exact match", sameDeveloper = "Same developer", nameOnly = "Name only - check before removing"
    var path: String, kind: String
    var size: Int64 = 0                   // -1 = not measured (needs Full Disk Access)
    var note = ""
    var needsAdmin = false
    var isDir = false
    var checked = true
    /// How sure it belongs to the app (exact, sameDeveloper, nameOnly). Name-only matches are never pre-checked and never
    /// moved by the one-step uninstall.
    var match = AppLeftover.exact
    var sure: Bool { match != AppLeftover.nameOnly }
    init(_ path: String, _ kind: String) { self.path = path; self.kind = kind }
}

/// An app bundle in /Applications, /Applications/Utilities or ~/Applications.
final class InstalledApp {
    var name = "", bundleId = "", version = "", path = ""
    var size: Int64 = 0
    var installed: Date?
    var uninstalled = false
    var leftovers: [AppLeftover]?        // installed: the bundle and all its files; partly removed: what is left; nil = not looked for yet
    var expanded = false
    var loadingItems = false
    var itemWaiters: [() -> Void] = []
    var icon: NSImage?                   // the app's own icon at row size; nil = not loaded yet
    var iconRequested = false

    static let iconSize = NSSize(width: 16, height: 16)

    /// The bundle's icon (Finder's icon for it) drawn once at row size, so rows only blit a small bitmap.
    static func loadIcon(_ path: String) -> NSImage {
        let src = NSWorkspace.shared.icon(forFile: path)
        let s = iconSize
        let px = Int(s.width * 2), py = Int(s.height * 2)      // 2x for Retina
        var r = NSRect(x: 0, y: 0, width: px, height: py)
        guard let cg = src.cgImage(forProposedRect: &r, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: px, height: py, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { let c = src.copy() as! NSImage; c.size = s; return c }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: py))
        guard let out = ctx.makeImage() else { let c = src.copy() as! NSImage; c.size = s; return c }
        return NSImage(cgImage: out, size: s)
    }

    var publisher: String {
        let parts = bundleId.split(separator: ".")
        guard parts.count >= 2, let first = parts[1].first else { return "—" }
        return String(first).uppercased() + parts[1].dropFirst()
    }

    var leftoverSize: Int64 { (leftovers ?? []).reduce(Int64(0)) { $0 + max(0, $1.size) } }
    var shownSize: Int64 { uninstalled ? leftoverSize : size }
    var displayName: String { uninstalled ? name + "  (partly removed)" : name }
    var hasLeftovers: Bool { !(leftovers ?? []).isEmpty }
    var checkedLeftovers: [AppLeftover] { (leftovers ?? []).filter { $0.checked } }

    /// 0 = nothing checked, 1 = every leftover checked, 2 = some (mixed).
    var checkState: Int {
        let all = leftovers ?? []
        let n = all.filter { $0.checked }.count
        return n == 0 ? 0 : n == all.count ? 1 : 2
    }
    func checkAll(_ on: Bool) { for l in leftovers ?? [] { l.checked = on } }

    static var defaultRoots: [String] { ["/Applications", "/Applications/Utilities", PathUtil.home + "/Applications"] }

    /// Reads a bundle's Info.plist; nil when it is not a folder.
    static func read(_ path: String) -> InstalledApp? {
        guard PathUtil.isDir(path) else { return nil }
        let info = (NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any]) ?? [:]
        let a = InstalledApp()
        a.path = PathUtil.trim(path)
        let file = (PathUtil.name(path) as NSString).deletingPathExtension
        func str(_ k: String) -> String? { (info[k] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } }
        a.name = str("CFBundleDisplayName") ?? str("CFBundleName") ?? file
        a.bundleId = str("CFBundleIdentifier") ?? ""
        a.version = str("CFBundleShortVersionString") ?? ""
        if let at = try? FileManager.default.attributesOfItem(atPath: path) {
            a.installed = (at[.creationDate] as? Date) ?? (at[.modificationDate] as? Date)
        }
        return a
    }

    /// Every .app directly in the roots and one subfolder level below them (e.g. /Applications/Adobe X/Adobe X.app),
    /// without Apple's own apps and anything under /System; largest first.
    static func find(_ roots: [String], _ measure: @escaping (String) -> Int64) -> [InstalledApp] {
        let list = readAll(roots)
        for a in list { a.size = measure(a.path) }
        return sorted(list)
    }

    static func sorted(_ list: [InstalledApp]) -> [InstalledApp] {
        list.sorted { $0.size != $1.size ? $0.size > $1.size : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The bundles in the roots with their Info.plist (and, with icons, their icons at row size); sizes are left at 0.
    static func readAll(_ roots: [String], icons: Bool = false) -> [InstalledApp] {
        var seen = Set<String>()
        var out: [InstalledApp] = []
        func isApp(_ p: String) -> Bool { p.lowercased().hasSuffix(".app") && PathUtil.isDir(p) }
        func consider(_ p: String) {
            let std = PathUtil.trim((p as NSString).standardizingPath)
            let real = (std as NSString).resolvingSymlinksInPath
            if std == "/System" || std.hasPrefix("/System/") || real.hasPrefix("/System/") { return }
            if !seen.insert(std.lowercased()).inserted { return }
            guard let a = read(std), !a.bundleId.lowercased().hasPrefix("com.apple.") else { return }
            out.append(a)
        }
        for r in roots {
            for c in DeleteJob.children(r) {
                if isApp(c) { consider(c) }
                else if PathUtil.isDir(c) { for cc in DeleteJob.children(c) where isApp(cc) { consider(cc) } }
            }
        }
        if icons {
            for a in out { a.icon = loadIcon(a.path); a.iconRequested = true }
        }
        return out
    }

    /// Items named after the bundle id B or the app name N in ~/Library and /Library (case-insensitive; names shorter
    /// than 4 characters and com.apple.* never match), each with how sure it belongs to the app (exact match, same
    /// developer, name only). otherBundleIds: the other installed apps (a developer folder shared with one is left out).
    static func findLeftovers(bundleId: String, name: String, home: String = PathUtil.home, fullDiskAccess: Bool = FullDiskAccess.granted,
                              otherBundleIds: [String] = []) -> [AppLeftover] {
        let b = bundleId.lowercased(), n = name.lowercased()
        if b.hasPrefix("com.apple.") { return [] }
        let useB = b.count >= 4, useN = n.count >= 4 && !n.hasPrefix("com.apple.")
        if !useB && !useN { return [] }
        var out: [AppLeftover] = []
        var seen = Set<String>()
        let fm = FileManager.default
        func add(_ p: String, _ kind: String, _ admin: Bool, _ measure: Bool, _ tier: String = AppLeftover.exact) {
            if !seen.insert(p.lowercased()).inserted { return }
            let l = AppLeftover(p, kind)
            l.match = tier
            l.isDir = PathUtil.isDir(p)
            l.needsAdmin = admin || access(PathUtil.parent(p), W_OK) != 0
            if l.needsAdmin { l.note = "needs administrator"; l.checked = false }
            // Name-only matches start unchecked: an uninstaller that ticks them is how the wrong folder gets deleted.
            if !l.sure { l.checked = false }
            if !measure {
                l.size = -1
                l.note = "needs Full Disk Access to measure"
            } else if Dataless.isDataless(p) {
                l.size = 0
                l.note = "in iCloud, not downloaded"
            } else {
                l.size = measureItem(p)
            }
            out.append(l)
        }
        func scan(_ dir: String, _ kind: String, admin: Bool = false, measure: Bool = true, tier: String = AppLeftover.exact,
                  _ match: (String) -> Bool) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for nm in names.sorted() where match(nm.lowercased()) { add(PathUtil.join(dir, nm), kind, admin, measure, tier) }
        }
        func isB(_ x: String) -> Bool { useB && x == b }
        func isN(_ x: String) -> Bool { useN && x == n }
        /// tok as a whole dot-separated part of a name: "TEAMID.com.foo.app" or "com.foo.app".
        func hasToken(_ x: String, _ tok: String) -> Bool {
            if tok.isEmpty { return false }
            var from = x.startIndex
            while let r = x.range(of: tok, range: from..<x.endIndex) {
                let before = r.lowerBound == x.startIndex || x[x.index(before: r.lowerBound)] == "."
                let after = r.upperBound == x.endIndex || x[r.upperBound] == "."
                if before && after { return true }
                from = x.index(after: r.lowerBound)
            }
            return false
        }
        for lib in [home + "/Library", "/Library"] {
            scan(lib + "/Application Support", "Support files") { isN($0) || isB($0) }
            scan(lib + "/Caches", "Cache") { isB($0) || isN($0) }
            scan(lib + "/Logs", "Logs") { isN($0) || isB($0) }
            if !useB { continue }
            scan(lib + "/Preferences", "Settings") { $0 == b + ".plist" || ($0.hasPrefix(b + ".") && $0.hasSuffix(".plist")) }
            scan(lib + "/Preferences/ByHost", "Settings") { $0.hasPrefix(b + ".") && $0.hasSuffix(".plist") }
            scan(lib + "/Containers", "Container", measure: fullDiskAccess) { $0 == b }
            scan(lib + "/Group Containers", "Container", measure: fullDiskAccess) { hasToken($0, b) }
            scan(lib + "/Saved Application State", "Saved state") { $0 == b + ".savedstate" }
            scan(lib + "/HTTPStorages", "Web data") { $0 == b || $0 == b + ".binarycookies" }
            scan(lib + "/WebKit", "Web data") { $0 == b }
            scan(lib + "/Cookies", "Cookies") { $0 == b + ".binarycookies" }
            scan(lib + "/LaunchAgents", "Launch agent") { $0.hasPrefix(b) && $0.hasSuffix(".plist") }
            scan(lib + "/Application Scripts", "Scripts") { $0 == b }
        }
        if useB {
            scan("/Library/LaunchDaemons", "Launch daemon", admin: true) { $0.hasPrefix(b) && $0.hasSuffix(".plist") }
            scan("/Library/PrivilegedHelperTools", "Helper tool", admin: true) { $0.hasPrefix(b) }
        }
        // Same developer: the developer part of the bundle id ("com.foo" of "com.foo.app"), when no other installed app has
        // it: group containers shared under it, and the app's folder inside a developer folder (Application Support/Foo/App;
        // the developer folder itself when it holds nothing else).
        let parts = b.split(separator: ".").map { String($0) }
        let others = otherBundleIds.map { $0.lowercased() }.filter { $0 != b }
        if parts.count >= 3 && !b.hasPrefix("com.apple.") {
            let devPrefix = parts[0] + "." + parts[1], developer = parts[1]
            let shared = others.contains { $0 == devPrefix || $0.hasPrefix(devPrefix + ".") }
            if !shared && devPrefix.count >= 6 && !InstalledApp.genericNames.contains(developer) {
                for lib in [home + "/Library", "/Library"] {
                    scan(lib + "/Group Containers", "Container", measure: fullDiskAccess, tier: AppLeftover.sameDeveloper) { hasToken($0, devPrefix) }
                    if developer.count < 4 { continue }
                    let support = lib + "/Application Support"
                    for d in DeleteJob.children(support) where PathUtil.isDir(d) && PathUtil.name(d).lowercased() == developer {
                        let inside = DeleteJob.children(d).filter { PathUtil.name($0) != ".DS_Store" }
                        let mine = inside.filter { let x = PathUtil.name($0).lowercased(); return isN(x) || isB(x) }
                        if mine.isEmpty { continue }
                        if mine.count == inside.count { add(d, "Support files", false, true, AppLeftover.sameDeveloper) }
                        else { for p in mine { add(p, "Support files", false, true, AppLeftover.sameDeveloper) } }
                    }
                }
            }
        }
        // Name only (check before removing): a shortened name of the app (without version, edition or the developer's name),
        // or a folder with the app's name in Documents (the user's own files may be there).
        let short = InstalledApp.shortNames(name: n, bundleId: b).filter { $0 != n && $0 != b }
        if !short.isEmpty {
            for lib in [home + "/Library", "/Library"] {
                scan(lib + "/Application Support", "Support files", tier: AppLeftover.nameOnly) { short.contains($0) }
                scan(lib + "/Caches", "Cache", tier: AppLeftover.nameOnly) { short.contains($0) }
                scan(lib + "/Logs", "Logs", tier: AppLeftover.nameOnly) { short.contains($0) }
            }
        }
        // ~/Documents is protected: only looked at with Full Disk Access (no permission prompt).
        if useN && fullDiskAccess {
            let docs = home + "/Documents"
            for nm in [name] + Array(short) {
                let p = PathUtil.join(docs, nm)
                if PathUtil.isDir(p) { add(p, "Documents folder", false, true, AppLeftover.nameOnly) }
            }
        }
        return out
    }

    /// Words that never identify an app on their own.
    static let genericNames: Set<String> = ["app", "apps", "mac", "macos", "data", "cache", "caches", "logs", "log", "support", "helper",
                                             "update", "updater", "common", "shared", "plugins", "plugin", "default", "desktop", "settings",
                                             "preferences", "documents", "files", "tools", "tool", "google", "microsoft", "adobe", "apple",
                                             "mozilla", "user", "users", "temp", "tmp", "library", "application", "applications", "com",
                                             "org", "net", "io", "pro", "lite", "free", "beta", "studio", "player", "editor", "viewer"]

    /// Shortened forms of an app's name (lower case, at least 4 characters, never a generic word): without a trailing
    /// version or edition ("Foo Pro 3" -> "foo"), without spaces, and the last part of the bundle id.
    static func shortNames(name: String, bundleId: String) -> Set<String> {
        var out = Set<String>()
        func add(_ s0: String) {
            let s = s0.trimmingCharacters(in: .whitespaces)
            if s.count >= 4 && !genericNames.contains(s) && !s.hasPrefix("com.apple.") { out.insert(s) }
        }
        let editions: Set<String> = ["pro", "lite", "free", "beta", "plus", "hd", "x", "desktop", "app", "for", "mac", "macos", "studio", "edition"]
        var words = name.lowercased().split(separator: " ").map { String($0) }
        while let last = words.last, words.count > 1,
              editions.contains(last) || last.allSatisfy({ $0.isNumber || $0 == "." }) { words.removeLast() }
        add(words.joined(separator: " "))
        add(name.lowercased().replacingOccurrences(of: " ", with: ""))
        if let last = bundleId.lowercased().split(separator: ".").last, bundleId.split(separator: ".").count >= 3 { add(String(last)) }
        return out
    }

    /// Size of a file or folder as the views count it (file size or size on disk).
    static func measureItem(_ p: String) -> Int64 {
        if PathUtil.isDir(p) { return Scanner().run(p).size }
        var st = stat()
        guard lstat(p, &st) == 0 else { return 0 }
        return DirNode.onDisk ? Int64(st.st_blocks) * 512 : Int64(st.st_size)
    }
}

extension MainWindowController {
    func buildAppsPage() -> Page {
        btnAppsRefresh.tip = "List the installed apps again"
        appSearch.toolTip = "Part of an app's name, publisher or bundle id"
        appSearch.onChange = { [unowned self] in self.showApps() }
        btnUninstall.tip = "Move the selected app and all its files to the Trash"
        btnRemoveLeftovers.tip = "Move the checked items that are left to the Trash"
        for b in [btnAppsRefresh, btnUninstall, btnRemoveLeftovers] { b.compact = true }
        let bar = ActionBar([btnAppsRefresh, appSearch, btnUninstall, btnRemoveLeftovers], right: [btnUninstall, btnRemoveLeftovers])
        bar.minRowHeight = 0
        let p = Page("Apps", [Column("name", "Name", 230), Column("size", "Size", 80, true), Column("size", "% of apps", 125, true),
                              Column("cat", "Publisher", 110), Column("note", "Version", 90), Column("mod", "Installed", 128),
                              Column("folder", "Location", 330)],
                     barColumn: 2, bar: bar)
        p.chartTitle = "Installed apps"
        p.chartScope = "of apps"
        p.empty = "No apps found."
        // Partly removed apps (items left that could not be moved) come first, then the rest in the sort order.
        p.pinFirst = { $0.app?.uninstalled ?? false }
        p.fill = { [unowned self] in self.fillApps() }
        p.table.onClickAt = { [unowned self] r, pt in self.appClick(r, pt) }
        return p
    }

    var appSearchRoots: [String] { appRoots ?? InstalledApp.defaultRoots }
    var appsAuto: Bool { selfTestDir != nil || autoAccept }
    /// Moves to the Trash; the self-test and screenshot runs only use the Trash on CI (deleted for good elsewhere).
    var appsTrash: Bool { appsAuto ? ProcessInfo.processInfo.environment["CI"] != nil : true }

    /// Starts reading the installed apps' bundles and icons in the background (called at launch, while the disk is scanned).
    func prefetchApps() {
        if appsPrefetch != nil || appsLoading || (apps != nil && !appsFromCache) { return }
        appsPrefetch = AppsRead(appSearchRoots)
    }

    /// Apps tab: the list read in this session, else the list saved last time (shown at once), then read again in the
    /// background and replaced in place. Within a session only Refresh reads it again; during a scan it waits for the scan.
    func fillApps() {
        let p = pApps!
        if apps == nil && selfTestDir == nil && appRoots == nil, let saved = AppsCache.load() {
            apps = saved
            appsFromCache = true
        }
        if apps != nil { showApps() }
        if appsLoading || (apps != nil && !appsFromCache) { return }
        if scanning && selfTestDir == nil {
            if apps == nil {
                let t = "The installed apps are read when the scan is done."
                p.setCaption(t)
                p.setRows([], t)
                if activePage === p { rowSlice = [:]; chart.showLogo(p.chartTitle, "", t) }
            }
            return
        }
        loadApps()
    }

    /// Lists the installed apps: bundles and icons in the background (or from the reading started at launch), then the
    /// sizes in one pass over the scan on the main thread; bundles that were not scanned are measured in the background.
    /// The new list replaces the shown one in place and is saved for the next start.
    func loadApps(_ done: (() -> Void)? = nil) {
        let p = pApps!
        appsGen += 1
        let gen = appsGen
        appsLoading = true
        if apps == nil {
            p.setCaption("Looking for installed apps...")
            p.setRows([], "Looking for installed apps...")
            if activePage === p { rowSlice = [:]; chart.showLogo(p.chartTitle, "", "Looking for installed apps...") }
        } else {
            showApps()
        }
        updateButtons()
        let roots = appSearchRoots
        let read: AppsRead
        if let pre = appsPrefetch, pre.roots == roots { read = pre } else { read = AppsRead(roots) }
        appsPrefetch = nil
        read.whenDone { [weak self] found in
            guard let self = self, gen == self.appsGen else { return }
            let t = Date()
            var unknown: [InstalledApp] = []
            for a in found {
                if let n = self.findScanned(a.path, exact: true), !n.insideSkipped { a.size = n.size } else { unknown.append(a) }
            }
            let finish = {
                guard gen == self.appsGen else { return }
                self.appsReadMs = read.ms
                self.appsAfterScanMs = Int(Date().timeIntervalSince(t) * 1000)
                self.appsLoaded(InstalledApp.sorted(found))
                done?()
            }
            if unknown.isEmpty { finish(); return }
            let paths = unknown.map { $0.path }
            DispatchQueue.global(qos: .userInitiated).async {
                let sizes = paths.map { Scanner().run($0).size }
                DispatchQueue.main.async {
                    for (a, s) in zip(unknown, sizes) { a.size = s }
                    finish()
                }
            }
        }
    }

    /// The fresh list replaces the shown one: the same app (same bundle path) keeps its state and the items found for
    /// it (open or closed); partly removed apps stay.
    private func appsLoaded(_ found: [InstalledApp]) {
        appsLoading = false
        let old = apps ?? []
        for a in found {
            guard let o = old.first(where: { PathUtil.same($0.path, a.path) && !$0.uninstalled }) else { continue }
            a.expanded = o.expanded
            if a.icon == nil, let img = o.icon { a.icon = img; a.iconRequested = true }
            if let items = o.leftovers, let b = items.first, b.kind == "App" { b.size = a.size; a.leftovers = items }
            else if o.loadingItems {
                // Still being looked for: they go to the new entry when found.
                o.itemWaiters.append { [weak self] in
                    guard a.leftovers == nil, !a.uninstalled, let items = o.leftovers else { return }
                    if let b = items.first, b.kind == "App" { b.size = a.size }
                    a.leftovers = items
                    self?.showApps()
                }
            }
            else if o.expanded { a.expanded = false }
        }
        let kept = old.filter { o in o.uninstalled && o.hasLeftovers && !found.contains(where: { PathUtil.same($0.path, o.path) }) }
        apps = kept + found
        appsFromCache = false
        if selfTestDir == nil && appRoots == nil { AppsCache.save(found) }
        showApps()
    }

    /// The apps shown: matching the search box.
    var shownApps: [InstalledApp] {
        let q = appSearch.text.trimmingCharacters(in: .whitespaces).lowercased()
        let all = apps ?? []
        if q.isEmpty { return all }
        return all.filter { $0.name.lowercased().contains(q) || $0.publisher.lowercased().contains(q) || $0.bundleId.lowercased().contains(q) }
    }

    func showApps() {
        let p = pApps!
        guard let all = apps else { return }
        let list = shownApps
        let total = list.reduce(Int64(0)) { $0 + max(0, $1.shownSize) }
        let keep = Set(p.selectedItems.compactMap { appKey($0) })
        var rows: [ItemInfo] = []
        for a in list {
            let it = ItemInfo()
            it.app = a
            it.name = a.displayName
            it.size = a.shownSize
            it.folderIcon = true
            if !a.uninstalled { it.icon = a.icon }
            it.path = a.uninstalled ? nil : a.path
            it.category = a.uninstalled ? "" : a.publisher
            it.note = a.uninstalled ? "" : a.version
            it.modified = a.uninstalled ? 0 : Int64(a.installed?.timeIntervalSince1970 ?? 0)
            it.folder = a.path
            it.percent = total > 0 ? 100 * Double(max(0, it.size)) / Double(total) : 0
            it.hideBar = a.uninstalled
            it.cells = [it.name, Fmt.size(it.size), a.uninstalled ? "" : Fmt.pct(it.percent), it.category, it.note, Fmt.date(it.modified), it.folder]
            var tip = a.name + "\n" + a.path + (a.bundleId.isEmpty ? "" : "\n" + a.bundleId)
            if !a.uninstalled, a.leftovers != nil { tip += "\nAll its files: " + Fmt.size(a.leftoverSize) }
            it.tip = tip
            if a.uninstalled { it.color = T.WARN_FG }
            it.chevron = a.expanded ? 1 : 0
            if a.uninstalled && a.hasLeftovers { it.check = a.checkState }
            rows.append(it)
            if !a.expanded { continue }
            guard let items = a.leftovers else {
                let w = ItemInfo()
                w.app = a
                w.groupOf = it
                w.isSummary = true
                w.hideBar = true
                w.name = "Looking for its files..."
                w.cells = [w.name, "", "", "", "", "", ""]
                rows.append(w)
                continue
            }
            for l in items {
                let c = ItemInfo()
                c.app = a
                c.leftover = l
                c.groupOf = it
                c.name = l.kind + ": " + PathUtil.name(l.path)
                c.size = max(0, l.size)
                c.folderIcon = l.isDir
                if !a.uninstalled && l.kind == "App" && PathUtil.same(l.path, a.path) { c.icon = a.icon }
                c.path = l.path
                c.category = l.kind
                c.note = l.match + (l.note.isEmpty ? "" : "; " + l.note)
                c.folder = l.path
                c.hideBar = true
                c.cells = [c.name, l.size < 0 ? "—" : Fmt.size(l.size), "", l.kind, c.note, "", l.path]
                c.tip = c.name + "\n" + l.path + "\n" + c.note
                c.check = a.uninstalled ? (l.checked ? 1 : 0) : -1
                if !l.sure { c.color = T.WARN_FG }
                rows.append(c)
            }
        }
        let filtered = !appSearch.text.trimmingCharacters(in: .whitespaces).isEmpty
        p.setRows(rows, filtered ? "No apps match the search." : "No apps found in " + appSearchRoots.joined(separator: ", ") + ".")
        loadAppIcons(list)
        if !keep.isEmpty {
            var sel = IndexSet()
            for (i, it) in p.items.enumerated() { if let k = appKey(it), keep.contains(k) { sel.insert(i) } }
            p.select(sel)
        }
        let installed = list.filter { !$0.uninstalled }
        let size = installed.reduce(Int64(0)) { $0 + $1.size }
        let n = installed.count
        if all.isEmpty && appsLoading { p.setCaption("Looking for installed apps...") }
        else {
            p.setCaption("\(Fmt.count(n)) app\(n == 1 ? "" : "s"), \(Fmt.size(size)).  Expand an app to see all its files. Uninstall moves the app and all its files to the Trash."
                         + (appsLoading ? "  Checking for changes..." : appsFromCache ? "  (List saved last time; checked again when the scan is done.)" : ""))
        }
        p.chartSub = Fmt.size(total)
        p.chartTotal = 0
        p.empty = filtered ? "No apps match." : "No apps found."
        updateButtons()
        if activePage === p { refreshChart() }
    }

    /// Loads the icons of the listed apps that have none yet, off the main thread, then shows them in the rows.
    func loadAppIcons(_ list: [InstalledApp]) {
        let need = list.filter { !$0.uninstalled && $0.icon == nil && !$0.iconRequested }
        if need.isEmpty { return }
        for a in need { a.iconRequested = true }
        let paths = need.map { $0.path }
        DispatchQueue.global(qos: .userInitiated).async {
            let icons = paths.map { InstalledApp.loadIcon($0) }
            DispatchQueue.main.async { [weak self] in
                for (a, img) in zip(need, icons) { a.icon = img }
                guard let self = self, let p = self.pApps else { return }
                var rows = IndexSet()
                for (i, it) in p.items.enumerated() {
                    guard let a = it.app, !a.uninstalled, it.icon == nil, let img = a.icon else { continue }
                    if it.groupOf == nil || (it.leftover?.kind == "App" && PathUtil.same(it.leftover!.path, a.path)) {
                        it.icon = img
                        rows.insert(i)
                    }
                }
                if !rows.isEmpty { p.table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<p.table.numberOfColumns)) }
            }
        }
    }

    private func appKey(_ it: ItemInfo) -> String? {
        guard let a = it.app else { return nil }
        if let l = it.leftover { return "l\n" + l.path }
        if it.groupOf != nil { return nil }
        return "a\n" + a.path + (a.uninstalled ? "\nu" : "")
    }

    /// The one app selected (a head row), if exactly one row is selected.
    var selectedApp: InstalledApp? {
        guard pApps != nil else { return nil }
        let sel = pApps.selectedItems
        guard sel.count == 1, sel[0].groupOf == nil, let a = sel[0].app else { return nil }
        return a
    }

    func selectApp(_ a: InstalledApp) {
        guard let i = pApps.items.firstIndex(where: { $0.app === a && $0.groupOf == nil }) else { return }
        pApps.select(IndexSet(integer: i))
        let last = pApps.items.lastIndex { $0.app === a } ?? i
        pApps.table.scrollRowToVisible(last)
        pApps.table.scrollRowToVisible(i)
    }

    func updateAppButtons() {
        let idle = !busy && !scanning && !appsWorking
        btnAppsRefresh.isEnabled = idle && !appsLoading
        btnUninstall.isEnabled = idle && (selectedApp.map { !$0.uninstalled } ?? false)
        btnRemoveLeftovers.isEnabled = idle && (apps ?? []).contains { $0.uninstalled && !$0.checkedLeftovers.isEmpty }
    }

    // MARK: checks and expanding (as in Suggestions)

    func appChecksChanged() {
        for it in pApps.items where it.check >= 0 {
            if let l = it.leftover { it.check = l.checked ? 1 : 0 }
            else if let a = it.app { it.check = a.checkState }
        }
        pApps.table.redrawCells()
        updateButtons()
    }

    func toggleAppChecks(_ rows: [ItemInfo]) {
        let rows = rows.filter { $0.check >= 0 }
        if rows.isEmpty { return }
        let on = rows.contains { $0.check != 1 }
        for it in rows {
            if let l = it.leftover { l.checked = on } else { it.app?.checkAll(on) }
        }
        appChecksChanged()
    }

    /// Opens or closes apps (nil = toggle); the first time an app opens its files are looked for in the background.
    func expandApps(_ rows: [ItemInfo], _ open: Bool?) {
        var changed = false
        for it in rows where it.groupOf == nil {
            guard let a = it.app else { continue }
            let to = open ?? !a.expanded
            if a.expanded != to { a.expanded = to; changed = true }
            if to && a.leftovers == nil { loadAppItems(a) }
        }
        if changed { showApps() }
    }

    /// Everything that belongs to an app: the bundle first, then what the leftover search finds.
    func loadAppItems(_ a: InstalledApp, _ done: (() -> Void)? = nil) {
        if a.loadingItems { if let d = done { a.itemWaiters.append(d) }; return }
        a.loadingItems = true
        let id = a.bundleId, name = a.name, path = a.path, size = a.size
        let others = (apps ?? []).filter { $0 !== a && !$0.uninstalled }.map { $0.bundleId }
        DispatchQueue.global(qos: .userInitiated).async {
            let bundle = AppLeftover(path, "App")
            bundle.isDir = true
            bundle.size = size
            let items = (PathUtil.exists(path) ? [bundle] : []) + InstalledApp.findLeftovers(bundleId: id, name: name, otherBundleIds: others)
            DispatchQueue.main.async {
                a.loadingItems = false
                if !a.uninstalled { a.leftovers = items }
                self.showApps()
                let waiters = a.itemWaiters
                a.itemWaiters = []
                done?()
                for w in waiters { w() }
            }
        }
    }

    func appClick(_ row: Int, _ pt: NSPoint) -> Bool {
        let p = pApps!
        guard row < p.items.count, p.items[row].app != nil,
              let ci = p.table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "c0" }) else { return false }
        let it = p.items[row]
        let x = pt.x - p.table.rect(ofColumn: ci).minX
        if it.chevron >= 0 && x >= ListCell.chevronX - 3 && x < ListCell.chevronX + 17 { expandApps([it], nil); return true }
        let cx = ListCell.checkX(it)
        if it.check >= 0 && x >= cx - 4 && x < cx + 18 { toggleAppChecks([it]); return true }
        return false
    }

    func appsKeyDown(_ e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) || e.modifierFlags.contains(.control) { return false }
        let sel = pApps.selectedItems
        if sel.isEmpty { return false }
        switch e.keyCode {
        case 49: toggleAppChecks(sel); return true
        case 123: expandApps(sel, false); return true
        case 124: expandApps(sel, true); return true
        default: return false
        }
    }

    // MARK: uninstall

    /// Uninstall... : one confirmation, then the app (quit first when it runs) and all its files go to the Trash
    /// together. What could not be moved stays under "<App>  (partly removed)". done(true) when everything went.
    func uninstallSelectedApp(_ done: ((Bool) -> Void)? = nil) {
        guard let a = selectedApp, !a.uninstalled, !busy, !scanning, !appsWorking else { done?(false); return }
        uninstallApp(a, done)
    }

    func uninstallApp(_ a: InstalledApp, _ done: ((Bool) -> Void)? = nil) {
        if PathUtil.same(a.path, Bundle.main.bundlePath) {
            alert("SpacePie can't uninstall itself", "Quit it, then move it to the Trash in Finder.")
            done?(false); return
        }
        guard let items = a.leftovers else {
            // Its files are looked for first (as when the row is opened).
            appsWorking = true
            updateButtons()
            statusLabel.stringValue = "Looking for the files of \(a.name)..."
            loadAppItems(a) { [unowned self] in
                self.appsWorking = false
                self.updateButtons()
                if a.leftovers == nil { done?(false) } else { self.uninstallApp(a, done) }
            }
            return
        }
        // Name-only matches are listed but not moved: they may belong to something else.
        let sure = items.filter { $0.sure }
        let review = items.filter { !$0.sure }
        let total = sure.reduce(Int64(0)) { $0 + max(0, $1.size) }
        let go = { [unowned self] in
            self.quitIfRunning(a) { ok in
                if ok { self.trashAll(a, sure, review, total, done) } else { done?(false) }
            }
        }
        if appsAuto { go(); return }
        uninstallDialog(a, items, total).show(over: window) { i in if i == 0 { go() } else { done?(false) } }
    }

    /// Uninstall confirmation: every item of the app on its own line with its size and how sure it belongs to the app;
    /// items matched only by name are listed separately ("listed, but not moved"). The red Uninstall button, Cancel the
    /// default.
    func uninstallDialog(_ a: InstalledApp, _ items: [AppLeftover], _ total: Int64) -> PromptDialog {
        let sure = items.filter { $0.sure }
        let review = items.filter { !$0.sure }
        func line(_ l: AppLeftover) -> String { l.path + "   " + (l.size < 0 ? "—" : Fmt.size(l.size)) + "  -  " + l.match }
        var details = sure.map { line($0) }
        if !review.isEmpty {
            details.append("")
            details.append("Listed, but not moved (name only - check before removing):")
            details.append(contentsOf: review.map { line($0) })
        }
        return PromptDialog(icon: .danger, heading: "Uninstall \(a.name)?",
                            text: "The app and all its files (\(Fmt.count(sure.count)) item\(sure.count == 1 ? "" : "s"), \(Fmt.size(total))) are moved to the Trash.",
                            warning: MainWindowController.reviewNote(review, a.name), details: details,
                            buttons: [("Uninstall", .danger), ("Cancel", .secondary)], defaultIndex: 1, cancelIndex: 1)
    }

    /// "N items (size) match only by name: listed, but not moved. Check them in the list if they belong to App." ("" = none)
    static func reviewNote(_ review: [AppLeftover], _ app: String) -> String {
        if review.isEmpty { return "" }
        let n = review.count, size = review.reduce(Int64(0)) { $0 + max(0, $1.size) }
        return "\(Fmt.count(n)) item\(n == 1 ? "" : "s") (\(Fmt.size(size))) match only by name: listed, but not moved. "
            + "Check \(n == 1 ? "it" : "them") in the list if \(n == 1 ? "it belongs" : "they belong") to \(app)."
    }

    /// Asks a running app to quit and waits up to 5 s; false (and a message) when it is still running.
    private func quitIfRunning(_ a: InstalledApp, _ then: @escaping (Bool) -> Void) {
        let me = NSRunningApplication.current
        let running = NSWorkspace.shared.runningApplications.filter { (r: NSRunningApplication) -> Bool in
            if r == me { return false }
            if !a.bundleId.isEmpty && r.bundleIdentifier == a.bundleId { return true }
            guard let u = r.bundleURL else { return false }
            return PathUtil.same(u.path, a.path)
        }
        if running.isEmpty { then(true); return }
        statusLabel.stringValue = "Asking \(a.name) to quit..."
        for r in running { r.terminate() }
        let end = Date().addingTimeInterval(5)
        func poll() {
            if running.allSatisfy({ $0.isTerminated }) { then(true); return }
            if Date() > end {
                statusLabel.stringValue = "\(a.name) is still running."
                if !appsAuto { alert("\(a.name) is still running", "Quit it, then press Uninstall again.") }
                then(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
        }
        poll()
    }

    /// Moves the bundle and all its files that surely belong to it to the Trash, then checks what is left. Items matched
    /// only by name stay listed under the app, unchecked.
    private func trashAll(_ a: InstalledApp, _ items: [AppLeftover], _ review: [AppLeftover], _ total: Int64, _ done: ((Bool) -> Void)?) {
        let targets = items.map { DeleteTarget(path: $0.path, label: PathUtil.name($0.path), isDir: $0.isDir, size: max(0, $0.size)) }
        runDelete(targets, trash: appsTrash, showErrors: false) { [unowned self] _ in
            var left: [AppLeftover] = []
            for l in items where PathUtil.exists(l.path) {
                l.size = InstalledApp.measureItem(l.path)
                let admin = access(l.path, W_OK) != 0 || access(PathUtil.parent(l.path), W_OK) != 0
                l.needsAdmin = l.needsAdmin || admin
                l.note = l.needsAdmin ? "needs administrator" : "could not be moved (in use or protected)"
                l.checked = !l.needsAdmin
                left.append(l)
            }
            let named = review.filter { PathUtil.exists($0.path) }
            for l in named { l.checked = false }
            if left.isEmpty && named.isEmpty {
                self.apps?.removeAll { $0 === a }
                self.showApps()
                self.statusLabel.stringValue = "\(a.name) and all its files were moved to the Trash (\(Fmt.size(total)))."
                done?(true)
                return
            }
            if left.isEmpty {
                // Everything that surely belonged to it went; what matches only by name is listed, unchecked.
                a.uninstalled = true
                a.leftovers = named
                a.expanded = true
                self.showApps()
                self.selectApp(a)
                let k = named.count
                self.statusLabel.stringValue = "\(a.name) and its files were moved to the Trash (\(Fmt.size(total))). \(Fmt.count(k)) item\(k == 1 ? "" : "s") "
                    + "matching only by name \(k == 1 ? "is" : "are") listed unchecked: check \(k == 1 ? "it" : "them") to remove \(k == 1 ? "it" : "them")."
                done?(true)
                return
            }
            a.uninstalled = true
            a.leftovers = left + named
            a.expanded = true
            self.showApps()
            self.selectApp(a)
            let n = left.count
            let leftSize = left.reduce(Int64(0)) { $0 + max(0, $1.size) }
            self.statusLabel.stringValue = "\(a.name) was partly removed: \(Fmt.count(n)) item\(n == 1 ? "" : "s") could not be moved to the Trash (\(Fmt.size(leftSize)))."
            if !self.appsAuto {
                let admin = left.contains { $0.needsAdmin }
                let more = named.isEmpty ? "" : " " + MainWindowController.reviewNote(named, a.name)
                var msg = "\(Fmt.count(n)) item\(n == 1 ? "" : "s") (\(Fmt.size(leftSize))) could not be moved to the Trash: in use, protected or access denied. "
                msg += "They stay listed under the app; press Remove leftovers to try again"
                msg += admin ? " (items that need an administrator: remove them in Finder)." : "."
                msg += more
                let lines: [String] = left.map { $0.path + "  -  " + $0.note } + named.map { $0.path + "  -  " + $0.match }
                self.alert("\(a.name) was partly removed", msg, details: lines)
            }
            done?(false)
        }
    }

    /// Remove leftovers: moves the checked items of partly removed apps to the Trash, then measures what is left.
    func removeCheckedLeftovers(_ done: (() -> Void)? = nil) {
        if busy || scanning || appsWorking { done?(); return }
        let owners = (apps ?? []).filter { $0.uninstalled && !$0.checkedLeftovers.isEmpty }
        let picked = owners.flatMap { a in a.checkedLeftovers.map { (a, $0) } }
        if picked.isEmpty { done?(); return }
        let total = picked.reduce(Int64(0)) { $0 + max(0, $1.1.size) }
        let n = picked.count, s = n == 1 ? "" : "s"
        let run = { [unowned self] in
            let targets = picked.map { DeleteTarget(path: $0.1.path, label: PathUtil.name($0.1.path), isDir: $0.1.isDir, size: max(0, $0.1.size)) }
            self.runDelete(targets, trash: self.appsTrash) { [unowned self] _ in
                var complete: [InstalledApp] = []
                for a in owners {
                    var keep: [AppLeftover] = []
                    for l in a.leftovers ?? [] {
                        if !PathUtil.exists(l.path) { continue }
                        if picked.contains(where: { $0.1 === l }) {
                            l.size = InstalledApp.measureItem(l.path)
                            l.note = "partly removed"
                        }
                        keep.append(l)
                    }
                    a.leftovers = keep
                    if keep.isEmpty { complete.append(a) }
                }
                self.apps?.removeAll { a in complete.contains { $0 === a } }
                self.showApps()
                if complete.count == 1 { self.statusLabel.stringValue = "\(complete[0].name) was removed completely." }
                done?()
            }
        }
        if appsAuto { run(); return }
        let heading = owners.count == 1 ? "Move \(Fmt.count(n)) leftover\(s) of \(owners[0].name) to the Trash?"
                                        : "Move \(Fmt.count(n)) leftover\(s) of \(Fmt.count(owners.count)) apps to the Trash?"
        let d = PromptDialog(icon: .warn, heading: heading, text: "\(Fmt.size(total)) will be moved to the Trash. You can put the items back from there.",
                             details: picked.map { $0.1.path + "   " + ($0.1.size < 0 ? "—" : Fmt.size($0.1.size)) },
                             buttons: [("Move to Trash", .primary), ("Cancel", .secondary)], defaultIndex: 1, cancelIndex: 1)
        d.show(over: window) { i in if i == 0 { run() } else { done?() } }
    }
}

/// A fake app bundle and its leftovers for the self-test and the screenshots.
enum FakeApp {
    static let name = "DSA Test App"
    static let bundleId = "com.example.dsatestapp"

    static var leftoverPaths: [String] {
        let lib = PathUtil.home + "/Library"
        return [lib + "/Application Support/" + name, lib + "/Caches/" + bundleId, lib + "/Preferences/" + bundleId + ".plist"]
    }

    static func writeBundle(_ path: String, id: String, name: String, version: String, bytes: Int) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": version,
                                  "CFBundleExecutable": "DSATestApp", "CFBundlePackageType": "APPL"]
        _ = info.write(toFile: path + "/Contents/Info.plist", atomically: true)
        fm.createFile(atPath: path + "/Contents/MacOS/DSATestApp", contents: Data(count: bytes))
    }

    /// <apps>/DSA Test App.app (50 KB) and its 3 leftovers in ~/Library.
    static func create(in apps: String) -> String {
        let fm = FileManager.default
        let app = apps + "/" + name + ".app"
        writeBundle(app, id: bundleId, name: name, version: "1.0", bytes: 50 * 1024)
        let l = leftoverPaths
        try? fm.createDirectory(atPath: l[0], withIntermediateDirectories: true)
        fm.createFile(atPath: l[0] + "/data.bin", contents: Data(count: 20 * 1024))
        try? fm.createDirectory(atPath: l[1], withIntermediateDirectories: true)
        fm.createFile(atPath: l[1] + "/c.bin", contents: Data(count: 10 * 1024))
        let prefs: NSDictionary = ["selfTest": true]
        _ = prefs.write(toFile: l[2], atomically: true)
        return app
    }

    /// Removes the leftovers and whatever the tests moved to the Trash.
    static func cleanUp() {
        let fm = FileManager.default
        for p in leftoverPaths { try? fm.removeItem(atPath: p) }
        let trash = PathUtil.home + "/.Trash"
        for p in DeleteJob.children(trash) {
            let n = PathUtil.name(p)
            if n.hasPrefix(name) || n.hasPrefix(bundleId) || n.hasPrefix("Apple Fake") { try? fm.removeItem(atPath: p) }
        }
    }
}

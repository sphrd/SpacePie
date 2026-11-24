import Foundation

/// Apps tab: the folders an app made anywhere on the scanned drives (found in the scan index, every depth), who made each
/// one (the app, or the user), and the caches inside them offered in Suggestions ("Apps' cache").
extension MainWindowController {
    /// The names an app's folders go by (normalised: lower case letters and digits only).
    struct AppKeys {
        let app: InstalledApp
        var names = Set<String>(), strong = Set<String>(), pubKeys = Set<String>(), pubNames = Set<String>()

        /// A folder named like the app's developer (exactly, or a longer developer name starting with it).
        func isPublisherFolder(_ n: String) -> Bool {
            if n.count < 4 { return false }
            return pubKeys.contains { $0 == n || (n.count >= 5 && $0.hasPrefix(n)) }
        }
    }

    static func norm(_ s: String) -> String {
        var v = String.UnicodeScalarView()
        for u in s.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(u) { v.append(u) }
        return String(v)
    }

    /// Never matched: names many unrelated folders share.
    static let genericFolderNames: Set<String> = Set(InstalledApp.genericNames.map { MainWindowController.norm($0) }).union([
        "microsoft", "windows", "program", "programs", "common", "commonfiles", "update", "updater", "tools", "setup", "installer",
        "temp", "cache", "data", "files", "user", "users", "config", "settings", "logs", "bin", "lib", "app", "apps", "plugins",
        "driver", "drivers"])

    /// Folders never searched: code libraries and system bookkeeping (a package there is not the app's data).
    static let skipFolderNames: Set<String> = ["node_modules", "site-packages", "dist-packages", ".git", ".Trash", ".Trashes",
                                               ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".MobileBackups"]
    /// Bundles and libraries: their insides belong to them, never matched or searched.
    static let bundleSuffixes = [".app", ".framework", ".bundle", ".plugin", ".appex", ".kext", ".photoslibrary", ".musiclibrary",
                                 ".tvlibrary", ".xpc"]
    /// Never searched: macOS itself.
    static let systemPaths = ["/System", "/usr", "/bin", "/sbin", "/dev", "/cores", "/private/var/db", "/private/var/vm"]

    static func isBundleName(_ name: String) -> Bool {
        let l = name.lowercased()
        return bundleSuffixes.contains { l.hasSuffix($0) }
    }

    static func appKeys(_ a: InstalledApp) -> AppKeys {
        var k = AppKeys(app: a)
        func add(_ s: String, strong: Bool = false) {
            let n = norm(s)
            if n.count >= 4 && !genericFolderNames.contains(n) { k.names.insert(n); if strong { k.strong.insert(n) } }
        }
        add(a.name, strong: true)
        add(a.bundleId, strong: true)
        add((PathUtil.name(a.path) as NSString).deletingPathExtension, strong: true)
        // "Foo Pro 3" -> "Foo"
        for s in InstalledApp.shortNames(name: a.name.lowercased(), bundleId: "") { add(s) }
        // The developer: the second part of the bundle id ("adobe" of com.adobe.Acrobat), and the app's first word.
        let parts = a.bundleId.lowercased().split(separator: ".").map { String($0) }
        let words = a.name.split(separator: " ").map { String($0) }
        for p in [parts.count >= 2 ? parts[1] : "", words.count >= 2 ? words[0] : ""] {
            let n = norm(p)
            if n.count >= 4 && n != "apple" && n != "microsoft" { k.pubKeys.insert(n) }
        }
        // Inside the developer's folder the app often goes without the developer's name (Google/Chrome for
        // "Google Chrome"), by the last part of its bundle id (com.google.Chrome), or by its first word after the developer's.
        for n in k.names { for p in k.pubKeys where n.count >= p.count + 4 && n.hasPrefix(p) { k.pubNames.insert(String(n.dropFirst(p.count))) } }
        if parts.count >= 3 { let n = norm(parts[parts.count - 1]); if n.count >= 4 { k.pubNames.insert(n) } }
        if words.count > 2 && k.pubKeys.contains(norm(words[0])) { let n = norm(words[1]); if n.count >= 4 { k.pubNames.insert(n) } }
        k.pubNames.subtract(genericFolderNames)
        return k
    }

    final class FolderHits {
        var byApp: [ObjectIdentifier: [AppLeftover]] = [:]
        var nodes: [ObjectIdentifier: DirNode] = [:]
        func of(_ a: InstalledApp) -> [AppLeftover] { byApp[ObjectIdentifier(a)] ?? [] }
        func node(_ l: AppLeftover) -> DirNode? { nodes[ObjectIdentifier(l)] }
    }

    /// Every folder in the scanned trees named after an installed app (or, inside its developer's folder, after the app
    /// without the developer's name). The outermost match counts (its contents belong to it). Never inside a bundle, never
    /// a folder that holds an app's bundle, never in macOS's own folders. Runs on a background thread while the trees are
    /// held still (readInBackground).
    static func findAppFolders(_ scanned: [DirNode], _ all: [InstalledApp], only: InstalledApp? = nil) -> FolderHits {
        let hits = FolderHits()
        if scanned.isEmpty || all.isEmpty { return hits }
        let keys = all.map { appKeys($0) }
        var byName: [String: [Int]] = [:]
        func index(_ n: String, _ i: Int) { if !(byName[n]?.contains(i) ?? false) { byName[n, default: []].append(i) } }
        for (i, k) in keys.enumerated() {
            for n in k.names { index(n, i) }
            for p in k.pubKeys { for n in k.pubNames { index(p + "/" + n, i) } }
        }
        var above = Set<ObjectIdentifier>()
        for a in all {
            guard let n = findScanned(in: scanned, a.path, exact: true) else { continue }
            var p = n.parent
            while let x = p { above.insert(ObjectIdentifier(x)); p = x.parent }
        }
        var skip = Set<ObjectIdentifier>()
        for s in systemPaths { if let n = findScanned(in: scanned, s, exact: true), n.parent != nil { skip.insert(ObjectIdentifier(n)) } }
        var stack: [(DirNode, String)] = scanned.map { ($0, "") }
        while let e = stack.popLast() {
            let d = e.0, parentNorm = e.1
            if d.parent != nil && (skip.contains(ObjectIdentifier(d)) || skipFolderNames.contains(d.name) || isBundleName(d.name)) { continue }
            let n = d.parent == nil ? "" : norm(d.name)
            if n.count >= 4 && !above.contains(ObjectIdentifier(d)) {
                var matched: [Int] = byName[n] ?? []
                if parentNorm.count >= 4 { for i in byName[parentNorm + "/" + n] ?? [] where !matched.contains(i) { matched.append(i) } }
                if !matched.isEmpty {
                    let path = d.fullPath
                    for i in matched {
                        let a = keys[i].app
                        if let o = only, o !== a { continue }
                        let l = AppLeftover(path, "")
                        l.isDir = true
                        l.size = d.size
                        l.shared = matched.count
                        hits.byApp[ObjectIdentifier(a), default: []].append(l)
                        hits.nodes[ObjectIdentifier(l)] = d
                    }
                    continue
                }
            }
            for c in d.children.reversed() { stack.append((c, n)) }
        }
        return hits
    }

    static let areaApp = 0, areaTemp = 1, areaProgram = 2, areaUser = 3, areaOther = 4

    /// What kind of place path is in, and its label ("Support files (Library)", "Documents folder"...).
    static func areaOf(_ path: String) -> (area: Int, label: String) {
        let home = PathUtil.home, lib = home + "/Library"
        let places: [(String, Int, String)] = [
            (PathUtil.trim(NSTemporaryDirectory()), areaTemp, "Temporary files"),
            ("/private/var/folders", areaTemp, "Temporary files and caches"),
            ("/var/folders", areaTemp, "Temporary files and caches"),
            ("/private/tmp", areaTemp, "Temporary files"),
            ("/tmp", areaTemp, "Temporary files"),
            (lib + "/Mobile Documents", areaUser, "iCloud Drive"),
            (lib + "/CloudStorage", areaUser, "Cloud storage"),
            (lib + "/Caches", areaApp, "Cache (Library)"),
            (lib + "/Application Support", areaApp, "Support files (Library)"),
            (lib + "/Logs", areaApp, "Logs (Library)"),
            (lib + "/Containers", areaApp, "Container (Library)"),
            (lib + "/Group Containers", areaApp, "Container (Library)"),
            (lib + "/Preferences", areaApp, "Settings (Library)"),
            (lib, areaApp, "Data (Library)"),
            ("/Library/Caches", areaApp, "Cache (/Library)"),
            ("/Library/Application Support", areaApp, "Shared support files (/Library)"),
            ("/Library/Logs", areaApp, "Logs (/Library)"),
            ("/Library", areaApp, "Shared data (/Library)"),
            ("/Applications", areaProgram, "Applications folder"),
            (home + "/Applications", areaProgram, "Applications folder"),
        ]
        for (root, area, label) in places where !root.isEmpty && PathUtil.isWithin(path, root) { return (area, label) }
        if PathUtil.isWithin(path, home) && PathUtil.trim(path).count > PathUtil.trim(home).count + 1 {
            let first = String(PathUtil.trim(path).dropFirst(PathUtil.trim(home).count + 1).split(separator: "/").first ?? "")
            if first.hasPrefix(".") { return (areaApp, "Data (hidden folder in your home)") }
            return (areaUser, first + " folder")
        }
        return (areaOther, "Other folder")
    }

    /// What a folder holds, by size: 1 = mostly your files (documents, pictures, media, archives, code), 2 = mostly
    /// programs, 0 = not clear.
    static func contentVerdict(_ node: DirNode) -> Int {
        var user: Int64 = 0, prog: Int64 = 0, all: Int64 = 0
        var files = 0
        var stack = [node]
        outer: while let d = stack.popLast() {
            for f in d.fileList ?? [] {
                let s = FileIndex.measure(f)
                let cat = FileTypes.category(FileIndex.ext(f.name))
                all += s
                if cat == "Programs and libraries" { prog += s }
                else if cat != "Other" && cat != "Databases" && cat != "Installers" { user += s }
                files += 1
                if files > 200_000 { break outer }
            }
            stack.append(contentsOf: d.children)
        }
        if all <= 0 { return 0 }
        if user * 2 >= all { return 1 }
        if prog * 2 >= all { return 2 }
        return 0
    }

    /// Sets who made a found item and whether it adds to the app's size. Items that look like the user's own files (or
    /// unclear) become name-only matches: never moved by Uninstall, never checked.
    static func classify(_ a: InstalledApp, _ l: AppLeftover, _ node: DirNode?) {
        l.counts = false
        if PathUtil.same(l.path, a.path) { l.origin = AppLeftover.originApp; return }   // the bundle: programSize
        let (area, label) = areaOf(l.path)
        if l.kind.isEmpty { l.kind = label }
        if area == areaUser || area == areaOther {
            let v = node.map { contentVerdict($0) } ?? (area == areaUser ? 1 : 0)
            l.origin = v == 1 ? AppLeftover.originUser : v == 2 ? AppLeftover.originApp : AppLeftover.originUnsure
            if l.origin != AppLeftover.originApp { l.match = AppLeftover.nameOnly }
        } else {
            l.origin = area == areaTemp ? AppLeftover.originCache : AppLeftover.originApp
        }
        l.counts = (l.origin == AppLeftover.originApp || l.origin == AppLeftover.originCache) && l.shared == 1
            && !PathUtil.isWithin(l.path, a.path) && !PathUtil.isWithin(a.path, l.path)
    }

    /// The app's size again from its bundle and the found items it made.
    static func recountSize(_ a: InstalledApp) {
        guard !a.uninstalled, a.programSize > 0, let items = a.leftovers else { return }
        a.size = a.programSize + items.filter { $0.counts && $0.inside == nil && $0.size > 0 }.reduce(Int64(0)) { $0 + $1.size }
    }

    /// List load (background, trees held still): each app's size = its bundle + the folders it made on the scanned drives.
    static func addAppFolderSizes(_ scanned: [DirNode], _ found: [InstalledApp]) {
        let hits = findAppFolders(scanned, found)
        for a in found {
            let ls = hits.of(a)
            for l in ls { classify(a, l, hits.node(l)) }
            a.size = a.programSize + ls.filter { $0.counts && $0.size > 0 }.reduce(Int64(0)) { $0 + $1.size }
        }
    }

    /// Expanding an app (background, trees held still): adds the folders named after it anywhere on the scanned drives to
    /// what the leftover search found, drops items inside another listed item, and says who made each one.
    static func addScanFolders(_ a: InstalledApp, _ items: inout [AppLeftover], _ scanned: [DirNode], _ all: [InstalledApp]) {
        let keys = appKeys(a)
        let hits = findAppFolders(scanned, all, only: a)
        var nodes: [ObjectIdentifier: DirNode] = [:]
        for h in hits.of(a).sorted(by: { $0.path.count < $1.path.count }) {
            if items.contains(where: { PathUtil.same($0.path, h.path) }) { continue }
            if !PathUtil.isDir(h.path) { continue }                 // gone since the scan (e.g. moved to the Trash)
            items.append(h)
            if let n = hits.node(h) { nodes[ObjectIdentifier(h)] = n }
        }
        let bundle = items.first { PathUtil.same($0.path, a.path) }
        // A folder found inside another listed folder is part of it (the bundle aside: it is listed inside that folder).
        let listed = items
        items.removeAll { l in
            l !== bundle && listed.contains { o in o !== l && o.isDir && !PathUtil.same(o.path, l.path) && PathUtil.isWithin(l.path, o.path)
                && !PathUtil.isWithin(a.path, o.path) }
        }
        // Other installed apps' bundles: what is inside one is that app's; a folder holding one is never sure.
        let otherApps = all.filter { $0 !== a && !$0.uninstalled }.map { PathUtil.trim($0.path) }
        items.removeAll { l in l !== bundle && otherApps.contains { PathUtil.isWithin(l.path, $0) } }
        if let b = bundle {
            b.inside = items.filter { $0 !== b && $0.isDir && PathUtil.isWithin(a.path, $0.path) }.min { $0.path.count < $1.path.count }
        }
        for l in items {
            if l !== bundle && l.kind.isEmpty {
                // A match by name: how sure it belongs to the app.
                let leaf = norm(PathUtil.name(l.path)), parent = norm(PathUtil.name(PathUtil.parent(l.path)))
                if keys.strong.contains(leaf) { l.match = AppLeftover.exact }
                else if keys.names.contains(leaf) { l.match = keys.isPublisherFolder(parent) ? AppLeftover.sameDeveloper : AppLeftover.nameOnly }
                else { l.match = AppLeftover.sameDeveloper }       // in the developer's folder
            }
            let node = nodes[ObjectIdentifier(l)] ?? (l.isDir ? findScanned(in: scanned, l.path, exact: true) : nil)
            classify(a, l, node)
            if l !== bundle && l.isDir && otherApps.contains(where: { PathUtil.isWithin($0, l.path) }) {
                l.match = AppLeftover.nameOnly
                l.counts = false
                l.note = "holds another app"
            }
            l.checked = l.sure
        }
    }

    /// Folder names of caches apps fill on their own and make again when needed (normalised).
    static let cacheFolderNames: Set<String> = ["cache", "caches", "cachedata", "cachestorage", "codecache", "gpucache", "shadercache",
                                                "dawncache", "dawnwebgpucache", "dawngraphitecache", "grshadercache", "graphitedawncache",
                                                "webcache", "httpcache", "imagecache"]

    /// Suggestions: "Apps' cache", one location per cache folder of an installed app (its contents; the folder stays).
    /// Only in the app's own data folders in your home (~/Library, hidden folders), never in a bundle, never in a folder
    /// another app's name matches too, and nothing another suggestion already covers (User caches, browsers, developer
    /// caches). Runs on a background thread while the trees are held still.
    static func appCaches(_ scanned: [DirNode], _ installed: [InstalledApp], _ list: inout [Suggestion]) {
        if installed.isEmpty || scanned.isEmpty { return }
        let covered = list.flatMap { $0.targets }.filter { !$0.emptyTrash && !$0.path.isEmpty }.map { PathUtil.trim($0.path) }
        func taken(_ p: String) -> Bool { covered.contains { PathUtil.isWithin(p, $0) || PathUtil.isWithin($0, p) } }
        let s = Suggestion("Apps' cache", safe: true,
                           note: "Files installed apps keep to start and load faster. They are made again when needed; quit the app first so files in use can go too.")
        var seen = Set<String>()
        let hits = findAppFolders(scanned, installed)
        for a in installed {
            for l in hits.of(a) where l.shared == 1 {
                guard let node = hits.node(l), areaOf(l.path).area == areaApp, PathUtil.isWithin(l.path, PathUtil.home),
                      !PathUtil.isWithin(l.path, a.path) else { continue }
                var stack: [(DirNode, Int)] = node.children.map { ($0, 1) }
                while let e = stack.popLast() {
                    let d = e.0, depth = e.1
                    if skipFolderNames.contains(d.name) || isBundleName(d.name) { continue }
                    if cacheFolderNames.contains(norm(d.name)) {
                        let p = d.fullPath
                        if d.size >= 1 << 20 && !taken(p) && seen.insert(p).inserted {
                            let t = DeleteTarget(path: p, label: a.name + " - " + d.name, isDir: true, size: d.size, note: a.name)
                            t.contentsOnly = true
                            t.dir = d
                            s.targets.append(t)
                            s.size += d.size
                        }
                        continue
                    }
                    if depth < 5 { stack.append(contentsOf: d.children.map { ($0, depth + 1) }) }
                }
            }
        }
        if s.targets.isEmpty { return }
        s.location = s.targets.count == 1 ? s.targets[0].path : "\(Fmt.count(s.targets.count)) locations"
        list.append(s)
    }
}

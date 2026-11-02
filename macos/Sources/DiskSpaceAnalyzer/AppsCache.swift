import AppKit

/// The installed-apps list as last read (names, versions, bundles, ids, sizes, icons), so the Apps tab shows it at once
/// on the next start while it is read again in the background.
/// ~/Library/Application Support/DiskSpaceAnalyzer/apps.plist (binary plist).
enum AppsCache {
    static let version = 1
    static var fileOverride: String?      // self-test

    static var filePath: String {
        fileOverride ?? PathUtil.home + "/Library/Application Support/DiskSpaceAnalyzer/apps.plist"
    }

    struct Entry: Codable {
        var name, version, publisher, path, bundleId: String
        var size: Int64
        var installed: Double?
        var icon: Data?                   // PNG at row size (2x pixels)
    }
    struct File: Codable {
        var version: Int
        var apps: [Entry]
    }

    /// Takes what is saved from the apps (on the main thread); the PNGs are made and the file written in the background.
    static func save(_ apps: [InstalledApp], _ done: (() -> Void)? = nil) {
        let list = apps.filter { !$0.uninstalled }
        let rows = list.map { a -> (Entry, CGImage?) in
            (Entry(name: a.name, version: a.version, publisher: a.publisher, path: a.path, bundleId: a.bundleId, size: a.size,
                   installed: a.installed?.timeIntervalSince1970, icon: nil),
             a.icon?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
        let path = filePath
        DispatchQueue.global(qos: .utility).async {
            write(rows, path)
            if let d = done { DispatchQueue.main.async(execute: d) }
        }
    }

    private static func write(_ rows: [(Entry, CGImage?)], _ path: String) {
        let entries = rows.map { row -> Entry in
            var e = row.0
            if let cg = row.1 { e.icon = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) }
            return e
        }
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        guard let data = try? enc.encode(File(version: version, apps: entries)) else { return }
        try? FileManager.default.createDirectory(atPath: PathUtil.parent(path), withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// The saved list (largest first), or nil when there is none or it is from another version.
    static func load() -> [InstalledApp]? {
        guard let data = FileManager.default.contents(atPath: filePath),
              let f = try? PropertyListDecoder().decode(File.self, from: data), f.version == version else { return nil }
        let list = f.apps.map { e -> InstalledApp in
            let a = InstalledApp()
            a.name = e.name; a.version = e.version; a.path = e.path; a.bundleId = e.bundleId; a.size = e.size
            a.installed = e.installed.map { Date(timeIntervalSince1970: $0) }
            if let png = e.icon, let cg = NSBitmapImageRep(data: png)?.cgImage {
                a.icon = NSImage(cgImage: cg, size: InstalledApp.iconSize)
                a.iconRequested = true
            }
            return a
        }
        return InstalledApp.sorted(list)
    }
}

/// One reading of the installed apps' bundles and icons in the background (everything but the sizes, which come from
/// the scan). Started at launch, so it runs while the startup disk is scanned.
final class AppsRead {
    let roots: [String]
    private(set) var result: [InstalledApp]?
    private(set) var ms = 0                // how long the reading took
    private var waiters: [([InstalledApp]) -> Void] = []

    init(_ roots: [String]) {
        self.roots = roots
        DispatchQueue.global(qos: .userInitiated).async {
            let t = Date()
            let list = InstalledApp.readAll(roots, icons: true)
            let ms = Int(Date().timeIntervalSince(t) * 1000)
            DispatchQueue.main.async {
                self.result = list
                self.ms = ms
                let w = self.waiters
                self.waiters = []
                for f in w { f(list) }
            }
        }
    }

    /// f on the main thread with the apps read (at once when they are read already).
    func whenDone(_ f: @escaping ([InstalledApp]) -> Void) {
        if let r = result { f(r) } else { waiters.append(f) }
    }
}

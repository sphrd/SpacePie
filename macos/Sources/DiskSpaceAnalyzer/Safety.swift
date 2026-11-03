import Foundation
import Darwin

/// Folders kept in sync with a cloud service and other devices. Deleting there also deletes the files in the cloud and on
/// every synced device. iCloud Drive (~/Library/Mobile Documents, and ~/Desktop and ~/Documents when "Desktop & Documents
/// Folders" is on), File Provider folders in ~/Library/CloudStorage (OneDrive, Dropbox, Google Drive, Box...), and the
/// classic ~/Dropbox and ~/Google Drive folders.
enum SyncFolders {
    private static var cached: [(path: String, service: String)]?
    private static var loaded = Date.distantPast
    static var homeOverride: String?            // self-test

    private static var home: String { PathUtil.trim(homeOverride ?? PathUtil.home) }

    /// The synced folders (path, service), longest first; read again at most once a minute.
    static var roots: [(path: String, service: String)] {
        if let c = cached, Date().timeIntervalSince(loaded) < 60 { return c }
        let found = find()
        cached = found
        loaded = Date()
        return found
    }

    /// Forgets the list (read again on next use).
    static func reset() { cached = nil }

    /// The service that syncs path ("iCloud Drive", "OneDrive"...), or nil when it is not in a synced folder.
    static func service(for path: String) -> String? {
        if path.isEmpty { return nil }
        for r in roots where PathUtil.isWithin(path, r.path) { return r.service }
        return nil
    }

    private static func find() -> [(path: String, service: String)] {
        var out: [(path: String, service: String)] = []
        func add(_ p: String, _ service: String) {
            let t = PathUtil.trim(p)
            if !PathUtil.isDir(t) || out.contains(where: { PathUtil.same($0.path, t) }) { return }
            out.append((path: t, service: service))
        }
        let h = home
        add(h + "/Library/Mobile Documents", "iCloud Drive")
        // Desktop & Documents Folders in iCloud Drive: their synced copies live in iCloud Drive's own folder.
        let cloudDocs = h + "/Library/Mobile Documents/com~apple~CloudDocs"
        for name in ["Desktop", "Documents"] where PathUtil.exists(cloudDocs + "/" + name) { add(h + "/" + name, "iCloud Drive") }
        // File Provider folders: ~/Library/CloudStorage/<Service>-<account>.
        let storage = h + "/Library/CloudStorage"
        for p in DeleteJob.children(storage) where PathUtil.isDir(p) { add(p, serviceName(PathUtil.name(p))) }
        add(h + "/Dropbox", "Dropbox")
        add(h + "/Google Drive", "Google Drive")
        add(h + "/OneDrive", "OneDrive")
        add(h + "/Box", "Box")
        return out.sorted { $0.path.count > $1.path.count }
    }

    /// A readable service name from a CloudStorage folder name ("OneDrive-Personal", "GoogleDrive-me@gmail.com", "Box-Box").
    static func serviceName(_ folder: String) -> String {
        let head = folder.components(separatedBy: "-").first ?? folder
        for known in ["OneDrive", "Dropbox", "GoogleDrive", "Box", "iCloud", "MEGA", "pCloud", "Nextcloud", "ownCloud", "Sync", "Tresorit"]
        where head.lowercased().hasPrefix(known.lowercased()) {
            return known == "GoogleDrive" ? "Google Drive" : known
        }
        return head.isEmpty ? "a sync service" : head
    }
}

/// Volumes without a Trash (network volumes, some FAT / exFAT drives): Move to Trash fails there, so the confirmation
/// says which items are kept instead of moving them.
enum TrashCheck {
    /// Why item at path cannot go to the Trash (nil = it can). cache: results per volume.
    static func noTrash(_ path: String, _ cache: inout [String: String?]) -> String? {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeNameKey])
        let volume = values?.volume?.path ?? "/"
        if let known = cache[volume] { return known }
        var why: String?
        if !hasTrash(url) {
            let name = values?.volumeName ?? PathUtil.name(volume)
            why = (name.isEmpty ? volume : name) + " has no Trash"
        }
        cache[volume] = .some(why)
        return why
    }

    /// True when the volume holding url has a Trash for this user (it may be created on first use, as Finder does).
    static func hasTrash(_ url: URL) -> Bool {
        let fm = FileManager.default
        if (try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false)) != nil { return true }
        return (try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: true)) != nil
    }
}

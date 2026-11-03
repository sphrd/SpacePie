import AppKit

/// Scan files: a whole scan (every folder and file with sizes and dates, compressed) saved as a .dsascan file, to keep it,
/// compare later or send it to someone. Opened again it shows as a read-only entry in the tree, below the drives: every
/// view works on it, but nothing is rescanned, watched or deleted.
extension MainWindowController {
    static func isScanFile(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == Snapshot.scanFileExtension && FileManager.default.fileExists(atPath: path)
            && !PathUtil.isDir(path)
    }

    /// The header of a scan file for the scan that holds scope (the whole drive or folder, not just the part shown). Main
    /// thread; the body is Snapshot.serialize(scope.top, info), made while the trees are held still.
    func scanFileInfo(_ scope: DirNode) -> SnapshotInfo {
        let top = scope.top
        let r = rootOf(top)
        var info = SnapshotInfo()
        info.rootPath = r?.path ?? top.fullPath
        info.taken = r.map { $0.scanned == .distantPast ? Date() : $0.scanned } ?? Date()
        info.fullDiskAccess = FullDiskAccess.granted
        info.total = r?.total ?? 0
        info.free = r?.free ?? 0
        return info
    }

    /// Saves the scan that holds scope as a scan file (main thread; the self-test).
    func saveScanFile(_ scope: DirNode, _ path: String) throws {
        try Snapshot.writeScanFile(Snapshot.serialize(scope.top, scanFileInfo(scope)), to: path)
    }

    func openScanDialog() {
        if busy { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = false; p.canChooseFiles = true; p.allowsMultipleSelection = false
        p.allowedFileTypes = [Snapshot.scanFileExtension]
        p.message = "Open a saved scan (.\(Snapshot.scanFileExtension))"
        guard let w = window else { return }
        p.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .OK, let u = p.url else { return }
            self.openScanFile(u.path)
        }
    }

    /// Opens a scan file read-only (or shows it when it is open already).
    func openScanFile(_ file: String) {
        if busy { return }
        if let open = roots.first(where: { $0.readOnly && PathUtil.same($0.sourceFile, file) }) { selectRoot(open); return }
        statusLabel.stringValue = "Opening \(file)..."
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = Snapshot.loadScanFile(file)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard let l = loaded else {
                    self.statusLabel.stringValue = ""
                    self.alert("This is not a scan file", file + " could not be read as a Disk Space Analyzer scan (or it is damaged).")
                    return
                }
                let node = l.0, info = l.1
                let r = ScanRoot(path: info.rootPath)
                r.readOnly = true
                r.sourceFile = file
                r.scanned = info.taken
                r.total = info.total
                r.free = info.free
                r.node = node
                self.roots.append(r)
                self.sortRoots()
                self.refreshTree(node, fallback: r)
                self.viewsChanged()
                self.updateDriveLabel()
                let secs = Date().timeIntervalSince(started)
                self.statusLabel.stringValue = "Opened the scan of \(info.rootPath) from \(Fmt.date(info.taken)): \(Fmt.size(node.size)) in \(Fmt.count(node.files)) files and "
                    + "\(Fmt.count(node.dirs)) folders (\(String(format: "%.1f", secs)) s). It can be browsed, searched and exported; nothing in it is changed."
            }
        }
    }

    /// Removes a saved scan from the tree (the file stays where it is).
    func closeSavedScan(_ r: ScanRoot?) {
        guard let r = r, r.readOnly, !busy else { return }
        let top = r.node
        roots.removeAll { $0 === r }
        if active === r { active = nil; current = nil }
        if let t = top {
            navBack.removeAll { $0.node?.top === t }
            navForward.removeAll { $0.node?.top === t }
        }
        refreshTree(nil)
        viewsChanged()
        updateDriveLabel()
        updateButtons()
        statusLabel.stringValue = "Closed the saved scan of \(r.path)."
    }
}

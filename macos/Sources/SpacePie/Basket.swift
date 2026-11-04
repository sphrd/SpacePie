import AppKit

/// Delete list: items collected from any view, reviewed together, then moved to the Trash or deleted permanently. Also
/// the shared deletion flow (confirmation, progress, updating the scan afterwards).
extension MainWindowController {
    func buildBasketPage() -> Page {
        btnBasketRemove.tip = "Take the selected items off the list (they stay on the disk)"
        btnBasketClear.tip = "Empty the delete list (nothing is deleted)"
        btnBasketTrash.tip = "Move everything on the list to the Trash: restorable; the space is freed when the Trash is emptied"
        btnBasketDelete.tip = "Delete everything on the list now, bypassing the Trash"
        let p = Page("Delete list", [Column("name", "Name", 200), Column("size", "Size", 80, true), Column("size", "% of list", 125, true),
                                     Column("folder", "Location", 330), Column("note", "Note", 200)],
                     barColumn: 2, bar: ActionBar([btnBasketRemove, btnBasketClear, btnBasketTrash, btnBasketDelete], right: [btnBasketTrash, btnBasketDelete]))
        p.chartTitle = "Delete list"
        p.empty = "Nothing on the delete list."
        p.fill = { [unowned self] in self.fillBasket() }
        return p
    }

    func fillBasket() {
        let p = pBasket!
        let total = basket.reduce(Int64(0)) { $0 + $1.size }
        var rows: [ItemInfo] = []
        for t in basket {
            let it = ItemInfo()
            it.targets = [t]; it.name = t.label; it.size = t.size; it.folderIcon = t.isDir
            it.path = t.emptyTrash ? nil : t.path
            it.note = t.note
            it.percent = total > 0 ? 100 * Double(t.size) / Double(total) : 0
            it.folder = t.contentsOnly ? t.path : PathUtil.parent(t.path)
            it.cells = [it.name, Fmt.size(it.size), Fmt.pct(it.percent), it.folder, it.note]
            rows.append(it)
        }
        p.setRows(rows, "The delete list is empty.\nSelect files or folders in any view and press Add to delete list (⌘D), then review and delete them here.")
        p.setCaption(basket.isEmpty ? "Collect items here from any view, review them, then delete them together."
            : "\(Fmt.count(basket.count)) item\(basket.count == 1 ? "" : "s"), \(Fmt.size(total)).  Move to Trash can be undone (the space is freed when the Trash is emptied); Delete permanently frees it now.")
        p.chartSub = basket.isEmpty ? "" : Fmt.size(total) + " to free"
        p.chartTotal = 0
        updateButtons()
        if activePage === p { refreshChart() }
    }

    func updateBasketTitle() {
        let title = basket.isEmpty ? "Delete list" : "Delete list (\(Fmt.count(basket.count)))"
        if btnBasket.title == title { return }
        btnBasket.title = title
        layoutRoot()
    }

    func basketChanged() {
        updateBasketTitle()
        setStale(pBasket)
        updateButtons()
    }

    func addSelectionToBasket() {
        if busy || lastView === pBasket.table { return }
        let sel = selection().filter { $0.canDelete && !fromReadOnly($0) }
        if sel.isEmpty { return }
        var added = 0
        for it in sel { for t in DeleteTarget.from(it) where addTarget(t) { added += 1 } }
        basketChanged()
        let total = basket.reduce(Int64(0)) { $0 + $1.size }
        statusLabel.stringValue = added == 0 ? "Already on the delete list."
            : "Added \(Fmt.count(added)) item\(added == 1 ? "" : "s") to the delete list: now \(Fmt.count(basket.count)) item\(basket.count == 1 ? "" : "s"), \(Fmt.size(total)). Open the Delete list tab to review and delete them."
    }

    /// Adds a target unless it is already covered; drops entries that the new folder covers.
    @discardableResult
    func addTarget(_ t: DeleteTarget) -> Bool {
        if t.emptyTrash {
            if basket.contains(where: { $0.emptyTrash }) { return false }
            basket.append(t)
            return true
        }
        for b in basket where !b.emptyTrash {
            if PathUtil.same(b.path, t.path) && b.contentsOnly == t.contentsOnly { return false }
            if b.isDir && !PathUtil.same(b.path, t.path) && PathUtil.isWithin(t.path, b.path) { return false }   // inside a folder already listed
            if b.isDir && !b.contentsOnly && PathUtil.same(b.path, t.path) { return false }                       // the whole folder is listed
        }
        if t.isDir { basket.removeAll { !$0.emptyTrash && !PathUtil.same($0.path, t.path) && PathUtil.isWithin($0.path, t.path) } }
        if t.isDir && !t.contentsOnly { basket.removeAll { !$0.emptyTrash && PathUtil.same($0.path, t.path) && $0.contentsOnly } }
        basket.append(t)
        return true
    }

    func removeFromBasket() {
        let sel = pBasket.selectedItems.compactMap { $0.targets }.flatMap { $0 }
        if sel.isEmpty { return }
        basket.removeAll { b in sel.contains { $0 === b } }
        basketChanged()
    }

    func deleteBasket(trash: Bool) {
        if busy || scanning || basket.isEmpty { return }
        confirmAndDelete(basket, trash: trash) { [weak self] job in
            guard let self = self, job != nil else { return }
            self.basketChanged()
        }
    }

    func deleteSelected() { deleteSelection(trash: false) }
    func trashSelected() { deleteSelection(trash: true) }

    func deleteSelection(trash: Bool) {
        if busy || scanning { return }
        let sel = selection().filter { $0.canDelete && !fromReadOnly($0) }
        if sel.isEmpty { return }
        let targets = sel.flatMap { DeleteTarget.from($0) }
        confirmAndDelete(targets, trash: trash) { [weak self] job in
            guard let self = self, job != nil else { return }
            self.basketChanged()
        }
    }

    /// After a delete or a move to the Trash: every target still on the delete list and in the suggestions gets the
    /// size of what is left (from the updated index, or measured just now); targets that are gone, or folders whose
    /// contents were to go and are now empty, are dropped.
    func remeasureAfterDelete(_ done: [DeleteTarget], _ job: DeleteJob, _ measured: [String: Int64]) {
        let failed = job.failedPaths
        basket.removeAll { !remeasure($0, done, failed, measured) }
        if let list = suggestions {
            for s in list {
                var keep: [DeleteTarget] = [], checks: [Bool] = []
                for (i, t) in s.targets.enumerated() where remeasure(t, done, failed, measured) { keep.append(t); checks.append(s.isChecked(i)) }
                if keep.count != s.targets.count && !keep.isEmpty {
                    s.location = keep.count == 1 ? keep[0].path : "\(Fmt.count(keep.count)) locations"
                }
                s.targets = keep
                s.checked = checks
                s.size = keep.reduce(Int64(0)) { $0 + $1.size }
            }
            suggestions = list.filter { !$0.targets.isEmpty && $0.size > 0 }
        }
        updateBasketTitle()
    }

    /// Updates a target's size (and note) to what is left of it; false when nothing is left.
    func remeasure(_ t: DeleteTarget, _ done: [DeleteTarget], _ failed: [String], _ measured: [String: Int64]) -> Bool {
        if !PathUtil.exists(t.path) { return false }
        let touched = done.contains { PathUtil.isWithin(t.path, $0.path) || PathUtil.isWithin($0.path, t.path) }
        let left = failed.filter { PathUtil.isWithin($0, t.path) }.count
        if t.contentsOnly || t.emptyTrash {
            if let names = try? FileManager.default.contentsOfDirectory(atPath: t.path) {
                if !names.contains(where: { !t.exclude.contains($0) }) { return false }
            } else if touched && left == 0 { return false }
        }
        if t.isDir || t.emptyTrash {
            if let n = findScanned(t.path, exact: true), !n.insideSkipped { t.size = MainWindowController.sizeExcluding(n, t.exclude) }
            else if let m = measured[PathUtil.trim(t.path)] { t.size = m }
        } else {
            var st = stat()
            if lstat(t.path, &st) == 0 { t.size = DirNode.onDisk ? Int64(st.st_blocks) * 512 : Int64(st.st_size) }
        }
        if touched && left > 0 { t.note = "partly deleted -- \(Fmt.count(Int64(left))) item\(left == 1 ? "" : "s") in use or denied" }
        return true
    }

    /// Size of a folder without the named items directly inside it (kept when only the contents are deleted).
    static func sizeExcluding(_ n: DirNode, _ exclude: Set<String>) -> Int64 {
        var size = n.size
        for name in exclude { if let c = n.child(name) { size -= c.size } }
        return max(0, size)
    }

    static let riskyPaths = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private", "/opt"]

    /// The confirmation before deleting or moving to the Trash: every target on its own line with its size (and whether it
    /// is in a synced folder or kept because its volume has no Trash); for a permanent delete the red "Delete permanently"
    /// button, Cancel the default (Return and Escape). Button 0 goes ahead: with trash, when every target is kept it means
    /// "Delete permanently", when some are kept "Move the others".
    func deleteConfirmDialog(_ targets: [DeleteTarget], trash: Bool, synced: [ObjectIdentifier: String] = [:],
                             kept: [ObjectIdentifier: String] = [:]) -> PromptDialog {
        var total = targets.reduce(Int64(0)) { $0 + $1.size }
        let n = targets.count, s = n == 1 ? "" : "s"
        let details = targets.map { t -> String in
            var line = (t.emptyTrash ? "Empty the Trash" : PathUtil.trim(t.path) + (t.contentsOnly ? "  (contents)" : "")) + "   " + Fmt.size(t.size)
            if let why = kept[ObjectIdentifier(t)] { line += "  -  kept: " + why }
            if let svc = synced[ObjectIdentifier(t)] { line += "  -  synced with " + svc }
            return line
        }
        var warnings: [String] = []
        if trash && targets.contains(where: { $0.emptyTrash }) { warnings.append("The Trash itself is emptied: its items are deleted for good.") }
        if targets.contains(where: { t in !t.contentsOnly && !t.emptyTrash && MainWindowController.riskyPaths.contains { PathUtil.isWithin(t.path, $0) } }) {
            warnings.append("This includes macOS system, library or application content. Deleting it can break macOS or installed apps.")
        }
        // Synced folders: deleting here deletes in the cloud and on the other devices too.
        if !synced.isEmpty {
            var services: [String] = []
            for t in targets { if let svc = synced[ObjectIdentifier(t)], !services.contains(svc) { services.append(svc) } }
            let names = services.joined(separator: " and ")
            if n == 1 {
                warnings.append("It is in a folder synced with \(names). Deleting it here also deletes it in the cloud and on your other devices.")
            } else {
                let who = synced.count == n ? "They are all" : "\(Fmt.count(synced.count)) of them \(synced.count == 1 ? "is" : "are")"
                warnings.append("\(who) in folders synced with \(names). Deleting them here also deletes them in the cloud and on your other devices.")
            }
        }
        let warning = warnings.joined(separator: "\n")
        if trash && !kept.isEmpty {
            var reasons: [String] = []
            for t in targets { if let why = kept[ObjectIdentifier(t)], !reasons.contains(why) { reasons.append(why) } }
            let why = reasons.joined(separator: "; ")
            if kept.count == n {
                return PromptDialog(icon: .danger, heading: (n == 1 ? "This item" : "These items") + " can't go to the Trash",
                                    text: "\(n == 1 ? "It" : "They") would have to be deleted permanently: \(why). Nothing has been deleted.",
                                    warning: warning, details: details,
                                    buttons: [("Delete permanently", .danger), ("Cancel", .secondary)], defaultIndex: 1, cancelIndex: 1)
            }
            let keep = targets.filter { kept[ObjectIdentifier($0)] != nil }.reduce(Int64(0)) { $0 + $1.size }
            total -= keep
            let k = kept.count
            return PromptDialog(icon: .warn, heading: "Move \(Fmt.count(n)) item\(s) to the Trash?",
                                text: "\(Fmt.count(k)) of them (\(Fmt.size(keep))) can't go to the Trash: \(why). \(k == 1 ? "It is" : "They are") kept; the other \(Fmt.size(total)) go to the Trash.",
                                warning: warning, details: details,
                                buttons: [("Move the others", .primary), ("Cancel", .secondary)], defaultIndex: 1, cancelIndex: 1)
        }
        if trash {
            return PromptDialog(icon: .warn, heading: "Move \(Fmt.count(n)) item\(s) to the Trash?",
                                text: "\(Fmt.size(total)) will be moved to the Trash. You can put the items back from there; the space is freed when the Trash is emptied.",
                                warning: warning, details: details,
                                buttons: [("Move to Trash", .primary), ("Cancel", .secondary)], defaultIndex: 1, cancelIndex: 1)
        }
        return PromptDialog(icon: .danger, heading: "Delete \(Fmt.count(n)) item\(s) permanently?",
                            text: "\(Fmt.size(total)) will be deleted. This bypasses the Trash and cannot be undone.",
                            warning: warning, details: details,
                            buttons: [("Delete permanently", .danger), ("Cancel", .secondary)], defaultIndex: 1, cancelIndex: 1)
    }

    /// Targets in synced folders, with the service that syncs them (the Trash itself is never synced).
    func syncedTargets(_ targets: [DeleteTarget]) -> [ObjectIdentifier: String] {
        var out: [ObjectIdentifier: String] = [:]
        for t in targets where !t.emptyTrash {
            if let svc = SyncFolders.service(for: t.path) { out[ObjectIdentifier(t)] = svc }
        }
        return out
    }

    /// Targets on volumes without a Trash, with the reason (moving them to the Trash would fail).
    func trashlessTargets(_ targets: [DeleteTarget]) -> [ObjectIdentifier: String] {
        var out: [ObjectIdentifier: String] = [:]
        var cache: [String: String?] = [:]
        for t in targets where !t.emptyTrash {
            if let why = TrashCheck.noTrash(t.path, &cache) { out[ObjectIdentifier(t)] = why }
        }
        return out
    }

    /// After a delete: what could not be deleted (each "path  -  reason"), all of them. With elevate, button 0 retries
    /// as an administrator (macOS asks for the password); otherwise the only button is OK.
    func deleteErrorsDialog(_ errors: [String], trash: Bool, elevate: Bool = false) -> PromptDialog {
        let n = errors.count
        var text = n == 1 ? "It is in use or access was denied." : "They are in use or access was denied."
        if !FullDiskAccess.granted { text += " Tip: give SpacePie Full Disk Access (button in the toolbar), then try again." }
        let heading = "\(Fmt.count(n)) item\(n == 1 ? "" : "s") could not be \(trash ? "moved to the Trash" : "deleted")"
        if elevate {
            let warning = "Items owned by macOS or another user (installers put some in /Library) can only be changed by an administrator: "
                + "\(trash ? "Move" : "Delete") as administrator asks for your password once. Full Disk Access lets the app read them, not change them."
            return PromptDialog(icon: .warn, heading: heading, text: text, warning: warning, details: errors,
                                buttons: [(trash ? "Move as administrator..." : "Delete as administrator...", trash ? .primary : .danger), ("Close", .secondary)],
                                defaultIndex: 1, cancelIndex: 1)
        }
        return PromptDialog(icon: .warn, heading: heading, text: text, details: errors, buttons: [("OK", .primary)], defaultIndex: 0, cancelIndex: 0)
    }

    /// What of the targets is still on the disk after a delete: a whole target, or the items left inside a folder whose
    /// contents were to go (not the Trash's own items: those are only ever deleted).
    static func stillThere(_ targets: [DeleteTarget]) -> [String] {
        var out: [String] = []
        for t in targets where PathUtil.exists(t.path) && !t.emptyTrash {
            if t.contentsOnly { out.append(contentsOf: DeleteJob.children(t.path, t.exclude)) } else { out.append(PathUtil.trim(t.path)) }
        }
        return out
    }

    /// Removes paths as root after macOS's administrator prompt (one prompt for all), then updates the scan. then gets
    /// the result (nil when there was nothing to do, or in the self-test and screenshot runs, which never prompt).
    func removeAsAdmin(_ paths: [String], trash: Bool, what: String, _ then: @escaping (AdminRemove.Result?) -> Void) {
        let todo = paths.filter { PathUtil.exists($0) }
        if todo.isEmpty || selfTestDir != nil || autoAccept { then(nil); return }
        let n = todo.count
        statusLabel.stringValue = "Asking for an administrator password to \(trash ? "move" : "delete") \(Fmt.count(n)) item\(n == 1 ? "" : "s")..."
        let reason = "SpacePie needs an administrator password to \(trash ? "move \(what) to the Trash" : "delete \(what)")."
        DispatchQueue.global(qos: .userInitiated).async {
            let r = AdminRemove.run(todo, trash: trash, reason: reason)
            DispatchQueue.main.async {
                self.applyRemoved(r.removed)
                if r.cancelled { self.statusLabel.stringValue = "Cancelled: nothing more was removed." }
                else {
                    self.statusLabel.stringValue = "\(trash ? "Moved" : "Deleted") \(Fmt.count(r.removed.count)) item\(r.removed.count == 1 ? "" : "s") as administrator"
                        + (r.left.isEmpty ? "." : "; \(Fmt.count(r.left.count)) could not be removed.")
                }
                then(r)
            }
        }
    }

    /// Paths removed outside a delete job (as administrator) leave the scanned trees, the delete list and the suggestions.
    func applyRemoved(_ paths: [String]) {
        if paths.isEmpty { return }
        whenNoReaders {
            for p in paths {
                if let n = self.findScanned(p, exact: true), PathUtil.same(n.fullPath, p), n.parent != nil { self.removeNode(n) }
                else if let d = self.findScanned(PathUtil.parent(p), exact: true), PathUtil.same(d.fullPath, PathUtil.parent(p)) {
                    d.removeFileRec(PathUtil.name(p))
                }
            }
            self.basket.removeAll { !$0.emptyTrash && !PathUtil.exists($0.path) }
            self.current = self.current.flatMap { self.isAttached($0) ? $0 : nil }
            self.refreshTree(self.current)
            self.markSuggestionsDirty()
            self.viewsChanged()
            self.updateDriveLabel()
        }
    }

    /// Asks, deletes (or moves to the Trash) with the delete strip, then updates the scan. done(nil) when cancelled.
    func confirmAndDelete(_ targets: [DeleteTarget], trash: Bool, _ done: @escaping (DeleteJob?) -> Void) {
        let scannedRoots = roots.filter { !$0.readOnly }.compactMap { $0.node?.fullPath }
        if targets.contains(where: { t in !t.emptyTrash && !t.contentsOnly && scannedRoots.contains { PathUtil.same($0, t.path) } }) {
            alert("A scanned drive or folder cannot be deleted here", "Select items inside it instead.")
            done(nil)
            return
        }
        let synced = syncedTargets(targets)
        // Moving to the Trash: items on volumes without a Trash would stay; they are named, and kept or deleted permanently.
        let kept = trash ? trashlessTargets(targets) : [:]
        let others = targets.filter { kept[ObjectIdentifier($0)] == nil }
        if selfTestDir != nil {
            if others.isEmpty { done(nil); return }
            runDelete(others, trash: trash, done)
            return
        }
        deleteConfirmDialog(targets, trash: trash, synced: synced, kept: kept).show(over: window) { i in
            if i != 0 { done(nil); return }
            if trash && !kept.isEmpty && others.isEmpty { self.runDelete(targets, trash: false, done) }
            else if trash && !kept.isEmpty { self.runDelete(others, trash: true, done) }
            else { self.runDelete(targets, trash: trash, done) }
        }
    }

    private func attachedDir(_ t: DeleteTarget) -> DirNode? {
        if let d = t.dir, isAttached(d) { return d }
        return t.isDir ? findScanned(t.path, exact: true) : nil
    }

    func runDelete(_ targets: [DeleteTarget], trash: Bool, showErrors: Bool = true, _ done: @escaping (DeleteJob?) -> Void) {
        let dirTargets: [(DeleteTarget, DirNode?)] = targets.filter { $0.isDir }.map { ($0, attachedDir($0)) }
        let fileDirs: [(DeleteTarget, DirNode?)] = targets.filter { !$0.isDir }.map { t -> (DeleteTarget, DirNode?) in
            if let f = t.file, isAttached(f.dir) { return (t, f.dir as DirNode?) }
            return (t, findScanned(PathUtil.parent(t.path), exact: true))
        }
        let before = roots.compactMap { $0.node }.reduce(Int64(0)) { $0 + $1.size }
        let job = DeleteJob()
        job.trash = trash
        deleteJob = job
        deleteFinished = []
        deleteTargetPaths = targets.map { PathUtil.trim($0.path) }
        deleteRowsRemoved = 0
        beginOwnDelete(targets)
        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async {
            job.run(targets, trash: trash)
            job.current = "Updating the scan..."
            var fresh: [(DirNode, DirNode)] = []
            var measured: [String: Int64] = [:]       // what is left of folders that were not deleted completely
            for (t, dn) in dirTargets where PathUtil.exists(t.path) {
                let n = Scanner().run(t.path)
                if let dn = dn { fresh.append((dn, n)) }
                measured[PathUtil.trim(t.path)] = MainWindowController.sizeExcluding(n, t.exclude)
            }
            DispatchQueue.main.async {
                self.whenNoReaders {
                    // The folder open now (the window stayed browsable), or the nearest one left of it.
                    var target = self.current
                    for t in targets where !t.contentsOnly && !t.emptyTrash {
                        if let dn = self.attachedDir(t), let c = target, c.isUnder(dn) { target = dn.parent }
                    }
                    for (t, d) in fileDirs {
                        if let d = d, self.isAttached(d), !PathUtil.exists(t.path) { d.removeFileRec(PathUtil.name(t.path)) }
                    }
                    for (t, dn) in dirTargets {
                        if let dn = dn, self.isAttached(dn), dn.parent != nil, !PathUtil.exists(t.path) { self.removeNode(dn) }
                    }
                    for (old, new) in fresh where self.isAttached(old) {
                        self.replaceNode(old, new)
                        if target === old { target = new }
                    }
                    self.deleteJob = nil
                    self.setBusy(false)
                    self.endOwnDelete()
                    if let t = target, !self.isAttached(t) { target = nil }
                    self.remeasureAfterDelete(targets, job, measured)
                    self.current = nil
                    self.refreshTree(target ?? self.active?.node)
                    self.markSuggestionsDirty()
                    self.viewsChanged()
                    self.updateDriveLabel()
                    if let v = self.lastView, !v.isHiddenOrHasHiddenAncestor { self.window?.makeFirstResponder(v) }
                    let after = self.roots.compactMap { $0.node }.reduce(Int64(0)) { $0 + $1.size }
                    let freed = max(0, before - after)
                    let skipped = job.skipped > 0 ? ", \(Fmt.count(job.skipped)) in use were skipped" : ""
                    let errors = job.errors
                    if trash {
                        let moved = job.recycled
                        self.statusLabel.stringValue = "Moved \(Fmt.count(moved)) item\(moved == 1 ? "" : "s") (\(Fmt.size(freed))) to the Trash\(skipped)"
                            + (errors.isEmpty ? "." : ", \(Fmt.count(errors.count)) could not be moved.")
                    } else {
                        self.statusLabel.stringValue = "Freed \(Fmt.size(freed)). \(Fmt.count(job.filesDeleted)) files deleted\(skipped)"
                            + (errors.isEmpty ? "." : ", \(Fmt.count(errors.count)) items could not be deleted.")
                    }
                    if job.stopped { self.statusLabel.stringValue += "  Stopped: what was not deleted yet stays." }
                    if !errors.isEmpty && showErrors && self.selfTestDir == nil {
                        let stuck = MainWindowController.stillThere(targets)
                        self.deleteErrorsDialog(errors, trash: trash, elevate: !stuck.isEmpty).show(over: self.window) { i in
                            guard i == 0, !stuck.isEmpty else { return }
                            self.removeAsAdmin(stuck, trash: trash, what: "\(Fmt.count(stuck.count)) item\(stuck.count == 1 ? "" : "s")") { r in
                                guard let r = r, !r.left.isEmpty, !r.cancelled else { return }
                                self.alert("\(Fmt.count(r.left.count)) item\(r.left.count == 1 ? "" : "s") could not be removed, even as administrator",
                                           r.error ?? "macOS protects them (System Integrity Protection) or they are on a read-only volume.", details: r.left)
                            }
                        }
                    }
                    done(job)
                }
            }
        }
    }

    // MARK: Live rows while deleting

    /// Polled from the progress timer: rows of the open list whose file or folder was deleted just now (or that sit
    /// under a deleted folder), and rows whose delete target finished, leave the list; the chart follows.
    func applyDeleted(_ gone: [String], _ finished: [String]) {
        for f in finished { deleteFinished.insert(PathUtil.trim(f)) }
        if gone.isEmpty && finished.isEmpty { return }
        let set = Set(gone.map { PathUtil.trim($0) })
        pruneDeletedRows(activePage, set)
    }

    /// Takes the deleted rows out of a page (a tab opened during the delete, or the open one on a poll).
    func pruneDeletedRows(_ p: Page, _ gone: Set<String> = []) {
        let keepView = lastView
        let n = p.removeRows { self.rowDeleted($0, gone) || (gone.isEmpty && self.rowGoneFromDisk($0)) }
        lastView = keepView
        if n > 0 {
            deleteRowsRemoved += n
            if activePage === p { refreshChart() }
        }
    }

    /// True when the delete running now has removed the row's item: its path (or a folder holding it) was deleted, or
    /// its delete targets are all finished (a cleanup row of contents only: when its folder was emptied).
    func rowDeleted(_ it: ItemInfo, _ gone: Set<String> = []) -> Bool {
        if it.isSummary || it.isGroup { return false }
        if let ts = it.targets, !ts.isEmpty {
            return ts.allSatisfy { t in
                let k = PathUtil.trim(t.path)
                if deleteFinished.contains(k) { return t.contentsOnly || t.emptyTrash || !PathUtil.exists(k) }
                return !t.contentsOnly && !t.emptyTrash && pathDeleted(k, gone)
            }
        }
        guard let p = it.fullPath else { return false }
        return pathDeleted(p, gone)
    }

    private func pathDeleted(_ p: String, _ gone: Set<String>) -> Bool {
        var q = PathUtil.trim(p)
        while !q.isEmpty {
            if gone.contains(q) { return true }
            if deleteFinished.contains(q) && !PathUtil.exists(q) { return true }
            if q == "/" { return false }
            q = PathUtil.parent(q)
        }
        return false
    }

    /// A row inside one of the delete's targets whose item is no longer on the disk (lists filled during the delete).
    func rowGoneFromDisk(_ it: ItemInfo) -> Bool {
        if it.isSummary || it.isGroup || deleteTargetPaths.isEmpty { return false }
        var path: String?
        if let ts = it.targets { if ts.count == 1 && !ts[0].contentsOnly && !ts[0].emptyTrash { path = ts[0].path } }
        else { path = it.fullPath }
        guard let p = path, deleteTargetPaths.contains(where: { PathUtil.isWithin(p, $0) }) else { return false }
        return !PathUtil.exists(p)
    }
}

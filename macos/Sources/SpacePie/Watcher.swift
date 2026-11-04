import AppKit
import CoreServices

/// FSEvents stream on one scanned drive or folder; reports changed paths (in the app's spelling of the root) on the main
/// queue, and whether changes were lost (the kernel or the stream dropped events: a rescan is needed). Started with
/// `since` (a saved event id) it first replays the history since then and marks its end (historyDone).
final class LiveStream {
    struct Batch {
        var paths: [String] = []
        var lost = false               // some changes were not reported one by one
        var lostDirs: [String] = []    // folders to scan again as a whole (MustScanSubDirs)
        var historyDone = false
        var wrapped = false            // event ids wrapped around
    }

    let root: ScanRoot
    private let path: String
    private let real: String
    private var stream: FSEventStreamRef?
    private(set) var lastId: UInt64 = 0
    var onEvents: ((Batch) -> Void)?

    init?(_ root: ScanRoot, since: UInt64? = nil) {
        self.root = root
        path = PathUtil.trim(root.path)
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        real = realpath(path, &buf) != nil ? PathUtil.trim(String(cString: buf)) : path
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info = info else { return }
            let me = Unmanaged<LiveStream>.fromOpaque(info).takeUnretainedValue()
            let arr = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            let lost = UInt32(kFSEventStreamEventFlagMustScanSubDirs) | UInt32(kFSEventStreamEventFlagUserDropped) | UInt32(kFSEventStreamEventFlagKernelDropped)
            var b = Batch()
            for i in 0..<count {
                let f = flags[i]
                if f & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { b.historyDone = true; continue }
                if f & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0 { b.wrapped = true }
                if ids[i] > me.lastId { me.lastId = ids[i] }
                let p: String? = i < arr.count ? (arr[i] as? String).map { me.appPath($0) } : nil
                if f & lost != 0 { b.lost = true; if let p = p { b.lostDirs.append(p) } }
                if let p = p { b.paths.append(p) }
            }
            me.onEvents?(b)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes) | FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        let sinceWhen: FSEventStreamEventId = since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, [path] as CFArray,
                                          sinceWhen, 0.5, flags) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    /// FSEvents reports resolved paths (e.g. /private/var for /var): map them back onto the scanned root.
    private func appPath(_ p0: String) -> String {
        let p = PathUtil.trim(p0)
        if real != path && PathUtil.isWithin(p, real) { return path + p.dropFirst(real.count) }
        return p
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}

/// Live updates: every scanned drive or folder is watched, and the scan is updated in place every two seconds (a changed
/// folder's own files are read again; new folders are scanned; removed ones dropped). Nothing is rescanned as a whole.
/// When FSEvents reports that changes were lost, the status line suggests a rescan.
extension MainWindowController {
    func startWatching(_ r: ScanRoot, since: UInt64? = nil) {
        if r.readOnly { return }   // a saved scan opened from a file is never watched
        stopWatching(r)
        missed.removeAll { $0 === r }
        if liveTimer == nil {
            liveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.applyChanges() }
        }
        if let s = LiveStream(r, since: since) {
            s.onEvents = { [weak self, weak r] batch in
                guard let self = self, let r = r else { return }
                self.enqueue(r, batch)
            }
            streams.append(s)
        } else if r.replay != nil {
            DispatchQueue.main.async { [weak self] in self?.replayFailed(r, "no FSEvents stream") }
        }
        updateLiveLabel()
    }

    func stopWatching(_ r: ScanRoot) {
        for s in streams where s.root === r { s.stop() }
        streams.removeAll { $0.root === r }
    }

    func stopAllWatching() { for s in streams { s.stop() }; streams.removeAll() }

    private func enqueue(_ r: ScanRoot, _ b: LiveStream.Batch) {
        if let rep = r.replay {
            // Replaying the history since a snapshot: a lost root (or wrapped ids) means a full rescan; a lost subfolder
            // is scanned again as a whole.
            let root = PathUtil.trim(r.path)
            if b.wrapped { DispatchQueue.main.async { self.replayFailed(r, "the event ids wrapped around") }; return }
            if b.lostDirs.contains(where: { PathUtil.isWithin(root, $0) }) || (b.lost && b.lostDirs.isEmpty) {
                DispatchQueue.main.async { self.replayFailed(r, "macOS asks for a full rescan") }
                return
            }
            for d in b.lostDirs where !fsDeep.contains(d) { fsDeep.append(d) }
            rep.events += b.paths.count
            if b.historyDone {
                rep.historyDone = true
                rep.timer?.invalidate()
                DispatchQueue.main.async { self.applyChanges() }
            }
        } else if b.lost && !missed.contains(where: { $0 === r }) { missed.append(r); updateLiveLabel() }
        if fsPending.count > 200_000 {
            if r.replay != nil { DispatchQueue.main.async { self.replayFailed(r, "too many changes") } }
            return
        }
        // The echo of our own deletes is ignored (it is applied directly); every other change is queued, also while a
        // delete runs (applied when it ends).
        let ignoreOwn = ownDeleting || Date() < ownUntil
        for p in b.paths where !(ignoreOwn && isOwnPath(p)) { fsPending.append(p) }
    }

    /// Paths of our own delete: equal to or under one of its targets.
    func isOwnPath(_ p: String) -> Bool { ownPaths.contains { PathUtil.isWithin(p, $0) } }

    /// A delete starts: events for its targets (not the Trash they go to) are ignored while it runs and for 3 s after.
    func beginOwnDelete(_ targets: [DeleteTarget]) {
        ownPaths = targets.filter { !$0.emptyTrash }.map { PathUtil.trim($0.path) }
        ownDeleting = true
    }

    /// The delete ended (the scan was updated directly): queued events for its targets are dropped, the rest kept.
    func endOwnDelete() {
        ownDeleting = false
        ownUntil = Date().addingTimeInterval(3)
        fsPending.removeAll { isOwnPath($0) }
    }

    func updateLiveLabel() {
        for s in streams where !roots.contains(where: { $0 === s.root }) || s.root.node == nil { stopWatching(s.root) }
        missed.removeAll { m in !roots.contains { $0 === m } }
        if !missed.isEmpty {
            liveLabel.stringValue = "Changes missed - rescan"
            liveLabel.textColor = T.WARN_FG
            liveLabel.toolTip = "Too many changes happened at once on " + missed.map { $0.path }.joined(separator: ", ") + "; the scan may be out of date. Rescan (⌘R) to be sure."
        } else {
            liveLabel.stringValue = streams.isEmpty ? "" : "Live"
            liveLabel.textColor = T.MUTED
            liveLabel.toolTip = "The scanned drives and folders are watched; files that appear, change or go away update the results within seconds."
        }
        layoutStatus()
    }

    /// Caches and logs (suggestions themselves) change all the time: an open Suggestions view looks again at most every
    /// 20 s, and not while the user works in the list (pointer over it, rows selected, a button held), so rows never move
    /// under them. Called on every live-update tick, so a skipped refresh happens as soon as it is due.
    func refreshSuggestionsIfDue() {
        guard activePage === pSuggest, suggestDirty, !suggestFinding, !busy, !scanning, readers == 0,
              Date().timeIntervalSince(lastSuggestFind) >= 20, !userInSuggestions else { return }
        pSuggest.stale = false
        fillSuggestions(quiet: true)
    }

    func applyChanges() {
        checkLowSpaceStatus()
        refreshSuggestionsIfDue()
        if liveWorking { return }
        if busy || scanning || readers > 0 || (fsPending.isEmpty && fsDeep.isEmpty) {
            if livePending && !busy && !scanning && readers == 0 { refreshAfterLive() }
            if !busy && !scanning && readers == 0 && fsPending.isEmpty && fsDeep.isEmpty { finishReplays() }
            return
        }
        let batch = Array(fsPending.prefix(20000))
        fsPending.removeFirst(batch.count)
        let deep = fsDeep
        fsDeep.removeAll()
        // Everything that touches the disk (looking at each changed path, reading folders again, scanning new ones)
        // runs in the background while the trees are held still; only the small in-memory changes run here, so the
        // window never stops responding, however many changes arrive (e.g. replaying the history after a restart).
        let scanned = roots.filter { !$0.readOnly }.compactMap { $0.node }
        liveWorking = true
        readInBackground({ MainWindowController.planChanges(batch, deep, scanned) }, { [weak self] plan in
            guard let self = self else { return }
            self.liveWorking = false
            self.applyPlan(plan)
        })
    }

    /// What a batch of changed paths does to the trees, worked out off the main thread.
    final class LivePlan {
        var replace: [(DirNode, DirNode)] = []      // folder scanned again as a whole (lost events, downloaded again)
        var remove: [DirNode] = []
        var files: [(DirNode, [FileRec])] = []       // a folder's own files read again
        var add: [(DirNode, DirNode)] = []           // (parent, new folder scanned)
        var structure = false
    }

    static func planChanges(_ batch: [String], _ deep: [String], _ scanned: [DirNode]) -> LivePlan {
        let plan = LivePlan()
        func find(_ p: String, _ exact: Bool) -> DirNode? { MainWindowController.findScanned(in: scanned, p, exact: exact) }
        var handled: [String] = []                   // folders scanned again as a whole: nothing below them is looked at
        // Folders FSEvents could not report file by file: scanned again as a whole.
        for p in deep {
            guard let n = find(p, true), n.parent != nil, !n.insideSkipped else { continue }
            if PathUtil.isDir(p) { plan.replace.append((n, Scanner().run(p))) } else { plan.remove.append(n) }
            handled.append(PathUtil.trim(p))
            plan.structure = true
        }
        var refresh: [DirNode] = []
        var refreshIds = Set<ObjectIdentifier>()
        func refreshDir(_ d: DirNode) { if refreshIds.insert(ObjectIdentifier(d)).inserted { refresh.append(d) } }
        var added: [String] = []
        var seen = Set<String>()
        var revive: [DirNode] = []
        for p0 in batch {
            let p = PathUtil.trim(p0)
            if !seen.insert(p).inserted || handled.contains(where: { PathUtil.isWithin(p, $0) }) { continue }
            // Nothing inside a folder the scan did not enter is read: it would download it or make macOS ask for access.
            // A folder that was not downloaded and now is (opened in Finder) is scanned.
            if let holder = find(p, false), holder.insideSkipped {
                let hp = holder.fullPath
                if holder.skipped == .notDownloaded && PathUtil.isDir(hp) && !Dataless.isDataless(hp)
                    && !revive.contains(where: { $0 === holder }) { revive.append(holder) }
                continue
            }
            let node = find(p, true)
            let exists = PathUtil.exists(p)
            if let n = node, n.parent == nil { if exists { refreshDir(n) }; continue }   // the scanned root itself
            let parent = find(PathUtil.parent(p), true)
            if !exists {
                if let n = node { plan.remove.append(n); plan.structure = true }
                else if let par = parent { refreshDir(par) }
            } else if PathUtil.isDir(p) {
                if let n = node { refreshDir(n) }
                else if parent != nil { added.append(p); plan.structure = true }
            } else if let par = parent {
                refreshDir(par)
            }
        }
        for d in refresh { if let list = Scanner.readFiles(d) { plan.files.append((d, list)) } }
        var done = Set<String>()
        for p in added where done.insert(p).inserted {
            guard let parent = find(PathUtil.parent(p), true), parent.child(PathUtil.name(p)) == nil, PathUtil.isDir(p) else { continue }
            let fresh = Scanner().run(p)   // usually small (a new folder); large copies arrive folder by folder anyway
            fresh.name = PathUtil.name(p)
            plan.add.append((parent, fresh))
        }
        for d in revive where d.parent != nil {
            plan.replace.append((d, Scanner().run(d.fullPath)))
            plan.structure = true
        }
        return plan
    }

    /// Applies a plan on the main thread: only what is still attached (nothing else changed the trees meanwhile, but a
    /// folder may have been removed by an earlier step of the same plan).
    func applyPlan(_ plan: LivePlan) {
        for (old, fresh) in plan.replace where isAttached(old) { replaceNode(old, fresh) }
        for n in plan.remove where isAttached(n) { removeNode(n) }
        for (d, list) in plan.files where isAttached(d) { d.setFiles(list) }
        let now = Int64(Date().timeIntervalSince1970)
        for (parent, fresh) in plan.add where isAttached(parent) && parent.child(fresh.name) == nil {
            fresh.parent = parent
            fresh.modified = now
            parent.children.append(fresh)
            parent.addUp(fresh.bytes, fresh.alloc, fresh.files, fresh.dirs + 1)
        }
        if !plan.files.isEmpty || !plan.add.isEmpty || plan.structure {
            livePending = true
            markSuggestionsDirty()
            if plan.structure { deniedCache.removeAll(); for p in pages where p !== pContents { p.stale = true } }
        }
        if livePending && Date().timeIntervalSince(lastLiveRefresh) >= 4 { refreshAfterLive() }
        if fsPending.isEmpty && fsDeep.isEmpty { finishReplays() }
    }

    /// Shows live changes without disturbing the user: values update in place, the selection and scroll position stay.
    func refreshAfterLive() {
        livePending = false
        lastLiveRefresh = Date()
        refreshTreeQuietly()
        updateDriveLabel()
        refreshSuggestionsIfDue()
        guard let c = current, isAttached(c) else { return }
        if activePage !== pContents { return }
        if !contents.selectedRowIndexes.isEmpty || NSEvent.pressedMouseButtons != 0 { return }
        let first = contents.rows(in: contents.visibleRect).location
        let topName = first >= 0 && first < pContents.items.count ? pContents.items[first].name : nil
        showContents(c)
        if let n = topName, let i = pContents.items.firstIndex(where: { $0.name == n }) {
            contents.scrollRowToVisible(min(pContents.items.count - 1, i + max(0, contents.rows(in: contents.visibleRect).length - 1)))
            contents.scrollRowToVisible(i)
        }
    }
}

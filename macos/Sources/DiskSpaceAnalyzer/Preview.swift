import AppKit
import Quartz

/// The items Quick Look shows (the panel asks its data source).
final class QuickLookSource: NSObject, QLPreviewPanelDataSource {
    var urls: [URL] = []

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index >= 0 && index < urls.count else { return nil }
        return urls[index] as NSURL
    }
}

/// Preview and Get Info: Space opens Quick Look for the selected file or folder (in Contents, Files, Duplicates, the
/// Delete list, Changes and the tree; in Suggestions, Apps and System Space ticks checkboxes); ⌘I (and Get Info in the
/// context menu) opens Finder's info window. Items in iCloud that are not downloaded are never previewed: Quick Look
/// would download them.
extension MainWindowController {
    /// Space previews in the lists without checkboxes and in the tree.
    func spacePreviews(_ view: NSView) -> Bool {
        if view === outline { return true }
        let previewing: [Page?] = [pContents, pFiles, pDupes, pBasket, pChanges]
        for p in previewing { if let pg = p, view === pg.table { return true } }
        return false
    }

    /// The path of the one item selected (a file or a folder), or the folder shown when the tree has the focus.
    private func selectedPath() -> String? {
        let sel = selection()
        if sel.count == 1 { return sel[0].fullPath }
        if sel.isEmpty, lastView === outline, let c = current { return c.fullPath }
        return nil
    }

    /// Space: Quick Look of the selected file or folder (Space again, or Esc, closes it).
    func quickLookSelected() {
        let visible = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
        guard let path = selectedPath() else {
            if visible { QLPreviewPanel.shared().orderOut(nil) }
            return
        }
        // Space on the item already shown closes the preview.
        if visible && quickLookURLs.count == 1 && PathUtil.same(quickLookURLs[0].path, path) {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        let sel = selection()
        if sel.count == 1 && fromReadOnly(sel[0]) && !PathUtil.exists(path) {
            statusLabel.stringValue = "\(path) is in a saved scan and not on this Mac (any more)."
            return
        }
        if !PathUtil.exists(path) { statusLabel.stringValue = "\(path) is not on this Mac (any more)."; return }
        if Dataless.isDataless(path) || (sel.count == 1 && sel[0].file?.dataless == true) {
            statusLabel.stringValue = "\(PathUtil.name(path)) is in iCloud and not downloaded: Quick Look would download it."
            return
        }
        quickLookURLs = [URL(fileURLWithPath: path)]
        quickLookSource.urls = quickLookURLs
        let panel: QLPreviewPanel? = QLPreviewPanel.shared()
        if let ql = panel {
            if visible { ql.reloadData() } else { ql.makeKeyAndOrderFront(nil) }
        }
    }

    /// ⌘I: Finder's Get Info window of the selected item.
    func getInfoSelected() {
        guard let path = selectedPath() else { return }
        if !PathUtil.exists(path) { statusLabel.stringValue = "\(path) is not on this Mac (any more)."; return }
        let quoted = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Finder\"\n"
            + "open information window of (POSIX file \"\(quoted)\" as alias)\n"
            + "activate\n"
            + "end tell"
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            _ = script.executeAndReturnError(&error)
        }
        if let e = error {
            let msg = (e[NSAppleScript.errorMessage] as? String) ?? "Finder did not answer."
            statusLabel.stringValue = "Get Info failed: " + msg + " (allow Disk Space Analyzer to control Finder in System Settings > Privacy & Security > Automation)"
        }
    }
}

import Foundation

/// Where the app keeps its data. Versions 1.x were called Disk Space Analyzer and kept everything in
/// ~/Library/Application Support/DiskSpaceAnalyzer; the first start of SpacePie moves that folder (saved scans, history,
/// hash cache, apps list) to ~/Library/Application Support/SpacePie. If it cannot be moved, the old folder is used for this
/// session and the move is tried again next time.
enum AppData {
    static let dir: String = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory() + "/Library/Application Support"
        let current = base + "/SpacePie", old = base + "/DiskSpaceAnalyzer"
        if !fm.fileExists(atPath: current) && fm.fileExists(atPath: old) {
            do { try fm.moveItem(atPath: old, toPath: current) } catch { return old }
        }
        return current
    }()

    static func path(_ relative: String) -> String { dir + "/" + relative }
}

import Foundation

/// Where the app keeps its data: ~/Library/Application Support/SpacePie.
enum AppData {
    static let dir: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory() + "/Library/Application Support"
        return base + "/SpacePie"
    }()

    static func path(_ relative: String) -> String { dir + "/" + relative }
}

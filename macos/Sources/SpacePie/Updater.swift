import AppKit
import CryptoKit

struct ReleaseInfo {
    var version: [Int]
    var tag: String
    var pageURL: URL
    var assetURL: URL?
    var assetSize: Int64 = 0
    var sha256: String?
}

/// Self-update from the GitHub releases of this repository (same contract as the Windows app): find the latest
/// release, download SpacePie-macOS.dmg, verify size and the SHA-256 digest GitHub publishes, copy the app
/// out of the image next to the installed one and swap the bundles. The old bundle is removed at the next start.
/// Where it goes (installTarget): the app's own place; when macOS runs a downloaded app from a randomised read-only
/// copy (App Translocation), the place the user put it; when the app runs from the disk image or another read-only
/// place, the Applications folder.
enum Updater {
    static let repo = "sphrd/SpacePie"
    static let assetName = "SpacePie-macOS.dmg"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!

    static var currentString: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    static var current: [Int] { parse(currentString) }
    static var bundlePath: String { Bundle.main.bundlePath }

    static func parse(_ s: String) -> [Int] {
        var parts = s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        while parts.count < 3 { parts.append(0) }
        return Array(parts.prefix(3))
    }

    static func newer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<3 where a[i] != b[i] { return a[i] > b[i] }
        return false
    }

    static func short(_ v: [Int]) -> String { v.map(String.init).joined(separator: ".") }

    private static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue("SpacePie-macOS/\(currentString)", forHTTPHeaderField: "User-Agent")
        return r
    }

    static func latest() throws -> ReleaseInfo {
        var req = request(URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data = try syncData(req)
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = o["tag_name"] as? String, let page = (o["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw NSError(domain: "update", code: 1, userInfo: [NSLocalizedDescriptionKey: "unexpected answer from GitHub"])
        }
        var info = ReleaseInfo(version: parse(tag), tag: tag, pageURL: page)
        for a in (o["assets"] as? [[String: Any]]) ?? [] where (a["name"] as? String) == assetName {
            info.assetURL = (a["browser_download_url"] as? String).flatMap(URL.init(string:))
            info.assetSize = (a["size"] as? NSNumber)?.int64Value ?? 0
            if let d = a["digest"] as? String, d.hasPrefix("sha256:") { info.sha256 = String(d.dropFirst(7)).lowercased() }
        }
        return info
    }

    private static func syncData(_ req: URLRequest) throws -> Data {
        var result: Result<Data, Error> = .failure(NSError(domain: "update", code: 2))
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let e = err { result = .failure(e) }
            else if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                result = .failure(NSError(domain: "update", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: "GitHub answered \(h.statusCode)"]))
            } else { result = .success(data ?? Data()) }
            sem.signal()
        }.resume()
        sem.wait()
        return try result.get()
    }

    /// True when a file can be created in folder (probed by creating one).
    static func folderWritable(_ folder: String) -> Bool {
        let probe = folder + "/.spacepie-write-test-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: probe, contents: Data()) else { return false }
        try? FileManager.default.removeItem(atPath: probe)
        return true
    }

    /// Where the running bundle really is. A downloaded app that was not moved into place with Finder runs from a
    /// randomised read-only copy (App Translocation, /private/var/folders/.../AppTranslocation/...); the user's copy is
    /// the original. nil when the app is not translocated.
    static func translocationOriginal(_ path: String) -> String? {
        typealias IsFn = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        typealias OriginalFn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else { return nil }
        let url = URL(fileURLWithPath: path) as CFURL
        if let s = dlsym(h, "SecTranslocateIsTranslocatedURL") {
            var on = false
            if !unsafeBitCast(s, to: IsFn.self)(url, &on, nil) || !on { return nil }
        } else if !path.contains("/AppTranslocation/") { return nil }
        guard let s = dlsym(h, "SecTranslocateCreateOriginalPathForURL"),
              let original = unsafeBitCast(s, to: OriginalFn.self)(url, nil)?.takeRetainedValue() else { return nil }
        let p = (original as URL).path
        return p.isEmpty || p == path ? nil : p
    }

    /// The app as the user installed it (the original when macOS translocated it).
    static var installedPath: String { translocationOriginal(bundlePath) ?? bundlePath }

    /// Where Update now installs the new version: the installed app when its folder can be written to; else (the app
    /// runs from the disk image or a read-only place) SpacePie.app in /Applications, or in ~/Applications when
    /// /Applications can't be written to. nil when there is no such place.
    static func installTarget() -> String? {
        let own = installedPath
        let ownFolder = (own as NSString).deletingLastPathComponent
        if folderWritable(ownFolder) { return own }
        let name = (own as NSString).lastPathComponent.hasSuffix(".app") ? (own as NSString).lastPathComponent : "SpacePie.app"
        if folderWritable("/Applications") { return "/Applications/" + name }
        let user = PathUtil.home + "/Applications"
        try? FileManager.default.createDirectory(atPath: user, withIntermediateDirectories: true)
        if folderWritable(user) { return user + "/" + name }
        return nil
    }

    /// True when the update goes to another place than the app that runs (it runs from the disk image or a read-only place).
    static func installsElsewhere(_ target: String) -> Bool { !PathUtil.same(target, installedPath) }

    /// Downloads and verifies the disk image; returns its local path.
    static func download(_ r: ReleaseInfo, progress: @escaping (Int64, Int64) -> Void, cancelled: @escaping () -> Bool) throws -> String {
        guard let url = r.assetURL else { throw NSError(domain: "update", code: 3, userInfo: [NSLocalizedDescriptionKey: "no macOS download in this release"]) }
        let target = NSTemporaryDirectory() + "SpacePie-update.dmg"
        let delegate = DownloadDelegate(progress: progress, cancelled: cancelled)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session.downloadTask(with: request(url)).resume()
        delegate.done.wait()
        session.invalidateAndCancel()
        if let e = delegate.error { throw e }
        guard let tmp = delegate.location else { throw NSError(domain: "update", code: 4, userInfo: [NSLocalizedDescriptionKey: "download failed"]) }
        try? FileManager.default.removeItem(atPath: target)
        try FileManager.default.moveItem(at: tmp, to: URL(fileURLWithPath: target))
        let data = try Data(contentsOf: URL(fileURLWithPath: target), options: .mappedIfSafe)
        if r.assetSize > 0 && Int64(data.count) != r.assetSize {
            throw NSError(domain: "update", code: 5, userInfo: [NSLocalizedDescriptionKey: "download incomplete"])
        }
        if let want = r.sha256 {
            let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if got != want { throw NSError(domain: "update", code: 6, userInfo: [NSLocalizedDescriptionKey: "downloaded file does not match the release checksum"]) }
        }
        return target
    }

    /// Mounts the image, copies the app next to the target (installTarget()), swaps the bundles (a target that does not
    /// exist yet is simply created), unmounts.
    static func install(_ dmg: String, to target: String) throws {
        let fm = FileManager.default
        let mount = NSTemporaryDirectory() + "spacepie-update-mount-\(UUID().uuidString)"
        try fm.createDirectory(atPath: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount, "-force"]); try? fm.removeItem(atPath: mount) }
        guard let appName = try fm.contentsOfDirectory(atPath: mount).first(where: { $0.hasSuffix(".app") }) else {
            throw NSError(domain: "update", code: 7, userInfo: [NSLocalizedDescriptionKey: "no app found in the download"])
        }
        let staged = target + ".new", old = target + ".old"
        try? fm.removeItem(atPath: staged)
        try run("/usr/bin/ditto", [mount + "/" + appName, staged])
        // The new copy must open without Gatekeeper's prompt and never be translocated.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged])
        try? fm.removeItem(atPath: old)
        let existed = PathUtil.exists(target)
        do {
            if existed { try fm.moveItem(atPath: target, toPath: old) }
            do { try fm.moveItem(atPath: staged, toPath: target) }
            catch { if existed { try? fm.moveItem(atPath: old, toPath: target) }; throw error }
        } catch {
            try? fm.removeItem(atPath: staged)
            throw explain(error, target)
        }
    }

    /// macOS's App Management protection refuses to let an app change another app's bundle (EPERM): say where to allow it.
    private static func explain(_ error: Error, _ target: String) -> Error {
        let e = error as NSError
        let posix = (e.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
        guard e.code == NSFileWriteNoPermissionError || posix == Int(EPERM) || posix == Int(EACCES) else { return error }
        return NSError(domain: "update", code: 8, userInfo: [NSLocalizedDescriptionKey:
            "macOS did not let SpacePie replace \(target) -- allow SpacePie in System Settings > Privacy & Security > App Management, then press Update now again"])
    }

    /// Removes leftovers of an earlier update (next to the app as installed, also when it runs translocated).
    static func cleanUp() {
        DispatchQueue.global(qos: .utility).async {
            let app = installedPath
            for p in [app + ".old", app + ".new", NSTemporaryDirectory() + "SpacePie-update.dmg"] {
                try? FileManager.default.removeItem(atPath: p)
            }
        }
    }

    /// Starts the installed copy at path and quits this one.
    static func relaunch(_ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            throw NSError(domain: "update", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\((tool as NSString).lastPathComponent) failed: \(out.split(separator: "\n").first ?? "")"])
        }
        return out
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let done = DispatchSemaphore(value: 0)
    var location: URL?
    var error: Error?
    let progress: (Int64, Int64) -> Void
    let cancelled: () -> Bool

    init(progress: @escaping (Int64, Int64) -> Void, cancelled: @escaping () -> Bool) { self.progress = progress; self.cancelled = cancelled }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if cancelled() { downloadTask.cancel(); return }
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is deleted when this returns: move it to a stable place first.
        let keep = URL(fileURLWithPath: NSTemporaryDirectory() + "dsa-dl-\(UUID().uuidString)")
        do { try FileManager.default.moveItem(at: location, to: keep); self.location = keep } catch { self.error = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error { self.error = cancelled() ? NSError(domain: "update", code: -999, userInfo: [NSLocalizedDescriptionKey: "cancelled"]) : e }
        done.signal()
    }
}

/// Update flow in the update window (same frame as About): checking, up to date, update available, downloading with
/// progress and Cancel, installed with Restart now, and the error cases. Automatic checks stay silent unless there is
/// an update; manual checks always open the window.
final class UpdateController {
    private weak var parent: NSWindow?
    private var window: UpdateWindow?
    private var release: ReleaseInfo?
    private var checking = false
    private var downloading = false
    private var cancelFlag = false
    var canRestart: () -> Bool = { true }

    init(parent: NSWindow?) { self.parent = parent }

    private func show() -> UpdateWindow {
        let w = window ?? {
            let n = UpdateWindow()
            n.onClose = { [weak self] in self?.cancelFlag = true; self?.window = nil }
            window = n
            return n
        }()
        w.present(over: parent)
        return w
    }

    private func closeWindow() { window?.close() }

    func check(manual: Bool) {
        if checking || downloading { if manual { _ = show() }; return }
        checking = true
        if manual { show().setStep("Checking for updates...", "Looking for the latest release on GitHub.", [("Close", closeWindow)]) }
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try Updater.latest() }
            DispatchQueue.main.async {
                self.checking = false
                if manual && self.window == nil { return }                     // closed while checking
                switch result {
                case .failure(let e):
                    if manual {
                        self.show().setStep("Update check failed", "Could not check for updates: \(e.localizedDescription).",
                                            [("Close", self.closeWindow), ("Open download page", self.openPage)])
                    }
                case .success(let r):
                    self.release = r
                    if !Updater.newer(r.version, than: Updater.current) {
                        if manual {
                            self.show().setStep("You're up to date", "Version \(Updater.currentString) is the latest version.",
                                                [("Close", self.closeWindow), ("What's new", self.openPage)])
                        }
                    } else { self.offer() }
                }
            }
        }
    }

    private func offer() {
        guard let r = release else { return }
        let msg = "Version \(Updater.short(r.version)) is available -- you have \(Updater.currentString)."
        if r.assetURL == nil {
            show().setStep("Update available", msg, [("Open download page", openPage), ("Later", closeWindow)])
        } else {
            show().setStep("Update available", msg, [("Update now", startUpdate), ("What's new", openPage), ("Later", closeWindow)])
        }
    }

    private func openPage() { NSWorkspace.shared.open(release?.pageURL ?? Updater.releasesPage) }

    private func startUpdate() {
        guard let r = release else { return }
        guard let target = Updater.installTarget() else {
            show().setStep("Can't update here", "Neither this app's folder nor an Applications folder can be written to, so the update can't be installed -- download it from the release page.",
                           [("Open download page", openPage), ("Later", closeWindow)])
            return
        }
        let elsewhere = Updater.installsElsewhere(target)
        downloading = true; cancelFlag = false
        let label = "Version \(Updater.short(r.version))"
        let w = show()
        w.setStep("Downloading update", label + "...", progress: 0, [("Cancel", { [weak self] in self?.cancelFlag = true })])
        var last = Date.distantPast
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> Void in
                let file = try Updater.download(r, progress: { done, total in
                    if Date().timeIntervalSince(last) < 0.1 && done < total { return }
                    last = Date()
                    let t = total > 0 ? "\(label): \(Fmt.size(done)) of \(Fmt.size(total)) (\(Int(100 * Double(done) / Double(total))) %)" : "\(label): \(Fmt.size(done))"
                    let f = total > 0 ? Double(done) / Double(total) : 0
                    DispatchQueue.main.async { self.window?.setProgress(t, f) }
                }, cancelled: { self.cancelFlag })
                if self.cancelFlag { throw NSError(domain: "update", code: -999) }
                DispatchQueue.main.async { self.window?.setProgress("\(label): installing...", 1) }
                try Updater.install(file, to: target)
            }
            DispatchQueue.main.async {
                self.downloading = false
                switch result {
                case .failure(let e as NSError) where e.code == -999:
                    Updater.cleanUp()
                    if self.window != nil { self.offer() }
                case .failure(let e):
                    Updater.cleanUp()
                    self.show().setStep("Update failed", "\(e.localizedDescription). You can download it from the release page.",
                                        [("Open download page", self.openPage), ("Close", self.closeWindow)])
                case .success:
                    self.installed = target
                    let place = elsewhere ? " in \((target as NSString).deletingLastPathComponent)" : ""
                    self.show().setStep("Update installed", "Version \(Updater.short(r.version)) is installed\(place) -- restart the app to use it.",
                                        [("Restart now", self.restart), ("Later", self.closeWindow)])
                }
            }
        }
    }

    /// The copy installed by the last update (started by Restart now).
    private var installed: String?

    private func restart() {
        if !canRestart() { window?.setProgress("Wait until the current delete has finished, then restart.", -1); return }
        Updater.relaunch(installed ?? Updater.installedPath)
    }
}
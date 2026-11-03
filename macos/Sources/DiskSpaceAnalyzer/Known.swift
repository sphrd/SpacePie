import Foundation

/// What a well-known folder or file is, whether it can go, and what manages it.
final class KnownItem {
    let what: String          // short: "Swap files"
    let verdict: String       // "Keep", "Safe to delete", "Review first", "Managed by macOS"
    let explain: String       // one or two sentences
    let how: String?          // where to manage it (setting, tab, command); may be nil

    init(_ what: String, _ verdict: String, _ explain: String, _ how: String?) {
        self.what = what; self.verdict = verdict; self.explain = explain; self.how = how
    }

    /// Text for the list column: "Swap files - managed by macos".
    var short: String { what + " - " + verdict.lowercased() }

    /// Text for the hover box: what it is, the verdict, and how to manage it.
    var long: String { what + ": " + verdict + ".\n" + explain + (how.map { "\nHow: " + $0 } ?? "") }
}

/// Recognizes folders and files that macOS, browsers, developer tools and common apps create, so the list can say what
/// they are instead of leaving the user to guess. Matched by full path (with the user's home folder), by a path with one
/// variable folder (*), or by name anywhere for a few unmistakable names. Anything else is simply not labelled. Paths are
/// compared without regard to case (as APFS does by default).
enum Known {
    static let keep = "Keep", safe = "Safe to delete", review = "Review first", macOS = "Managed by macOS"

    private static var byPath: [String: KnownItem] = [:]
    private static var byName: [String: KnownItem] = [:]
    private static var byPattern: [(parts: [String], item: KnownItem)] = []
    private static var built = false
    private static let lock = NSLock()

    private static func I(_ what: String, _ verdict: String, _ explain: String, _ how: String?) -> KnownItem {
        KnownItem(what, verdict, explain, how)
    }

    private static func P(_ path: String, _ k: KnownItem) { byPath[PathUtil.trim(path).lowercased()] = k }

    /// A path with * for one folder name, e.g. ~/Library/Application Support/Firefox/Profiles/*/cache2.
    private static func W(_ pattern: String, _ k: KnownItem) {
        byPattern.append((parts: PathUtil.trim(pattern).lowercased().split(separator: "/").map { String($0) }, item: k))
    }

    private static func build() {
        let h = PathUtil.trim(PathUtil.home)
        let lib = h + "/Library"

        // ---- macOS
        P("/System", I("macOS", keep, "The operating system itself, on a sealed read-only volume. Space macOS reports as used that no folder shows is often local Time Machine snapshots or purgeable space.",
                       "System tab > Time Machine local snapshots and Purgeable space."))
        P("/Library", I("Shared app data", keep, "Settings, support files and caches that apps share between all users of this Mac.", "Uninstall apps you don't need (Apps tab)."))
        P("/Applications", I("Installed apps", keep, "The apps installed for all users.", "Uninstall what you don't need (Apps tab)."))
        P("/Users", I("User folders", keep, "Every user's documents, settings and app data.", nil))
        P("/private/var/vm", I("Swap files", macOS, "Virtual memory: macOS moves memory here when RAM is full, and keeps the sleep image. Removed and recreated by macOS itself.",
                               "Quit memory-hungry apps or restart; never delete by hand."))
        W("/private/var/vm/swapfile*", I("Swap file", macOS, "Virtual memory in use; macOS creates and removes these by itself.", "Restart to shrink them."))
        P("/private/var/vm/sleepimage", I("Sleep image", macOS, "Holds memory while the Mac sleeps (safe sleep). Recreated by macOS.", "pmset hibernatemode (advanced); leave it as it is."))
        P("/private/var/folders", I("Per-user temporary files and caches", macOS, "Temporary items and caches macOS and apps keep for each user; cleaned up at restart and over time.",
                                    "Restart the Mac; don't delete by hand."))
        P("/private/var/log", I("System logs", review, "Logs of macOS and its services; rotated and trimmed by macOS.", "Suggestions tab."))
        P("/private/var/db", I("System databases", keep, "Databases macOS needs (Spotlight, security, updates).", nil))
        P("/private/tmp", I("Temporary files", safe, "Scratch files of apps and tools; cleared at restart.", "Restart the Mac."))
        P("/Library/Caches", I("Shared caches", safe, "Caches of apps and macOS services for all users; rebuilt when needed.", "Suggestions tab."))
        P("/Library/Logs", I("Shared logs", safe, "Logs of apps and installers.", "Suggestions tab."))
        P("/Library/Updates", I("Downloaded macOS updates", macOS, "Updates Software Update downloaded; removed once installed.", "System Settings > General > Software Update."))
        P("/Library/Application Support", I("Shared app support files", keep, "Data apps keep for all users.", "Uninstall apps you don't need (Apps tab)."))
        P("/opt/homebrew", I("Homebrew (Apple silicon)", keep, "Command-line tools installed with Homebrew.", "brew cleanup; brew uninstall <formula>."))
        P("/usr/local/Homebrew", I("Homebrew (Intel)", keep, "Command-line tools installed with Homebrew.", "brew cleanup; brew uninstall <formula>."))
        P("/usr/local/Cellar", I("Homebrew packages", keep, "Packages installed with Homebrew, old versions included.", "brew cleanup removes old versions."))
        P("/Volumes/com.apple.TimeMachine.localsnapshots", I("Time Machine local snapshots", macOS, "Snapshots Time Machine keeps on this disk; macOS deletes them when space runs low.",
                                                             "System tab > Time Machine local snapshots."))
        P("/Library/Developer/CommandLineTools", I("Command Line Tools", keep, "Compilers and tools for developers (git, clang, swift).", "xcode-select --install installs them again if removed."))

        // ---- this user
        P(h + "/.Trash", I("Trash", safe, "Items you moved to the Trash; the space is freed when it is emptied.", "Suggestions tab, or Finder > Empty Trash."))
        P(lib, I("Your app data", keep, "Settings, caches and data of your apps (hidden folder).", "Apps tab removes an app with all its files."))
        P(lib + "/Caches", I("Your caches", safe, "Caches of your apps; rebuilt when needed (apps may start slower once).", "Suggestions tab."))
        P(lib + "/Logs", I("Your logs", safe, "Logs and crash reports of your apps.", "Suggestions tab."))
        P(lib + "/Containers", I("Sandboxed app data", keep, "Each sandboxed app's own data, settings and caches.", "Apps tab (uninstall removes its container)."))
        P(lib + "/Group Containers", I("Shared data of app groups", keep, "Data shared between apps of the same developer (Office, Messages...).", "Apps tab."))
        P(lib + "/Application Support", I("Your app support files", keep, "Data your apps keep: libraries, databases, downloads.", "Apps tab removes an app with all its files."))
        P(lib + "/Mail", I("Mail", keep, "Your mailboxes and attachments downloaded by Mail.", "Mail > Settings > Accounts: don't keep all attachments; delete old mail."))
        P(lib + "/Messages", I("Messages", review, "Your iMessage and SMS history with attachments.", "System Settings > General > Storage > Messages (review large attachments), or Messages > Settings > Keep messages."))
        P(lib + "/Safari", I("Safari data", keep, "Bookmarks, history and Reading List of Safari.", nil))
        P(lib + "/Caches/com.apple.Safari", I("Safari cache", safe, "Web pages and images Safari stored; downloaded again when needed.", "Safari > Settings > Advanced > Show features for web developers, then Develop > Empty Caches."))
        P(lib + "/Developer", I("Developer data", review, "Xcode build products, archives, device support and simulators.", nil))
        P(lib + "/Developer/Xcode/DerivedData", I("Xcode build files", safe, "Intermediate build products and indexes; Xcode rebuilds them.", "Xcode > Settings > Locations > Derived Data, or delete it."))
        P(lib + "/Developer/Xcode/Archives", I("Xcode archives", review, "Builds you archived for distribution; needed to symbolicate crash reports of released versions.", "Xcode > Window > Organizer > Archives."))
        P(lib + "/Developer/Xcode/iOS DeviceSupport", I("iOS device support", safe, "Debug symbols copied from each iOS version of your devices; copied again when a device is connected.", "Delete folders of iOS versions you no longer debug."))
        P(lib + "/Developer/Xcode/watchOS DeviceSupport", I("watchOS device support", safe, "Debug symbols of watchOS versions; copied again when needed.", nil))
        P(lib + "/Developer/CoreSimulator", I("iOS simulators", review, "Simulator devices with their apps and data, and simulator caches.", "xcrun simctl delete unavailable; Xcode > Settings > Platforms."))
        P(lib + "/Developer/CoreSimulator/Caches", I("Simulator caches", safe, "Caches of the iOS simulators; rebuilt when needed.", nil))
        P(lib + "/Application Support/MobileSync/Backup", I("iPhone and iPad backups", review, "Device backups made by Finder. For a lost or replaced phone this can be the only copy.",
                                                              "System tab > iPhone and iPad backups, or Finder > your device > Manage Backups."))
        P(lib + "/Mobile Documents", I("iCloud Drive", review, "Your iCloud Drive: deleting here deletes in iCloud and on your other devices too. Files not downloaded take no space here.",
                                       "Right-click a file in Finder > Remove Download to keep it only in iCloud."))
        P(lib + "/CloudStorage", I("Cloud storage folders", review, "OneDrive, Dropbox, Google Drive and others: deleting here deletes in the cloud too.", "Use the service's \"Free up space\" / online-only option."))
        P(lib + "/Caches/Homebrew", I("Homebrew downloads", safe, "Downloaded Homebrew packages and bottles.", "brew cleanup --prune=all"))
        P(lib + "/Containers/com.docker.docker", I("Docker Desktop data", review, "Docker's virtual disk with images, containers and volumes; it does not shrink by itself.",
                                                  "docker system prune, or Docker Desktop > Settings > Resources > Disk image size."))
        P(lib + "/Containers/com.docker.docker/Data/vms", I("Docker disk", review, "The virtual disk of Docker Desktop.", "docker system prune; Docker Desktop > Troubleshoot > Clean / Purge data."))
        P(lib + "/Caches/pip", I("pip cache", safe, "Downloaded Python packages.", "pip cache purge"))
        P(lib + "/Caches/Google/Chrome", I("Chrome cache", safe, "Web pages and images Chrome stored; downloaded again when needed.", "Chrome > Delete browsing data > Cached images and files."))
        P(lib + "/Caches/Microsoft Edge", I("Edge cache", safe, "Web pages and images Edge stored; downloaded again when needed.", "Edge > Clear browsing data > Cached images and files."))
        P(lib + "/Caches/Firefox", I("Firefox cache", safe, "Web pages and images Firefox stored.", "Firefox > Settings > Privacy > Clear Data."))
        P(lib + "/Application Support/Google/Chrome", I("Chrome profile", keep, "Bookmarks, passwords, history and cache of Chrome.", "Chrome > Settings > Privacy > Delete browsing data (cache)."))
        P(lib + "/Application Support/Microsoft Edge", I("Edge profile", keep, "Favorites, passwords, history and cache of Edge.", "Edge > Settings > Privacy > Clear browsing data (cache)."))
        P(lib + "/Application Support/Firefox", I("Firefox profiles", keep, "Bookmarks, passwords and history of Firefox.", nil))
        P(lib + "/Application Support/Code/Cache", I("VS Code cache", safe, "Web cache of VS Code.", nil))
        P(lib + "/Application Support/Code/CachedData", I("VS Code cache", safe, "Compiled code of older VS Code versions.", nil))
        P(lib + "/Android/sdk", I("Android SDK", review, "SDK platforms, system images and build tools.", "Android Studio > SDK Manager."))
        P(h + "/Music", I("Music", keep, "Your music library (Music app) and other audio.", "Music > Settings > Files; remove downloads of songs that are in the cloud."))
        P(h + "/Music/Music/Media.localized", I("Music media", review, "Songs and videos of the Music app library.", "Remove downloads of songs that are in the cloud (Music app)."))
        P(h + "/Music/iTunes", I("iTunes library", review, "An older iTunes library with its media.", nil))
        P(h + "/Movies", I("Movies", keep, "Your videos and projects (iMovie, Final Cut).", nil))
        P(h + "/Pictures", I("Pictures", keep, "Your pictures and the Photos library.", nil))
        P(h + "/Downloads", I("Downloads", review, "Everything downloaded with a browser; old installers and disk images often pile up here.", "Suggestions tab (old installers)."))
        P(h + "/Desktop", I("Desktop", keep, "Files on your desktop.", nil))
        P(h + "/Documents", I("Documents", keep, "Your documents.", nil))
        P(h + "/Dropbox", I("Dropbox", review, "Synced with Dropbox: deleting here deletes in the cloud and on other devices too.", "Dropbox > Make online-only."))
        P(h + "/Google Drive", I("Google Drive", review, "Synced with Google Drive: deleting here deletes in the cloud too.", nil))

        // ---- developer tools (caches rebuild themselves)
        P(h + "/.npm", I("npm cache", safe, "Downloaded npm packages.", "npm cache clean --force"))
        P(h + "/.npm/_cacache", I("npm cache", safe, "Downloaded npm packages.", "npm cache clean --force"))
        P(h + "/.yarn/berry/cache", I("Yarn cache", safe, "Downloaded Yarn packages.", "yarn cache clean"))
        P(lib + "/Caches/Yarn", I("Yarn cache", safe, "Downloaded Yarn packages.", "yarn cache clean"))
        P(lib + "/pnpm/store", I("pnpm store", safe, "Shared store of pnpm packages; projects link to it.", "pnpm store prune"))
        P(h + "/.gradle/caches", I("Gradle cache", safe, "Downloaded dependencies and build caches.", "Delete it; Gradle downloads what it needs again."))
        P(h + "/.gradle", I("Gradle data", review, "Gradle's caches, daemons and wrapper downloads.", nil))
        P(h + "/.m2/repository", I("Maven repository", safe, "Downloaded Maven dependencies.", "Delete it; Maven downloads what it needs again."))
        P(h + "/.cargo/registry", I("Cargo registry", safe, "Downloaded Rust crates.", "cargo cache --autoclean (cargo-cache), or delete it."))
        P(h + "/.rustup/toolchains", I("Rust toolchains", review, "Installed Rust compilers.", "rustup toolchain list / uninstall."))
        P(h + "/go/pkg/mod", I("Go module cache", safe, "Downloaded Go modules.", "go clean -modcache"))
        P(lib + "/Caches/go-build", I("Go build cache", safe, "Compiled Go packages.", "go clean -cache"))
        P(h + "/.nuget/packages", I("NuGet package cache", safe, "Downloaded .NET packages; restored again when a project builds.", "dotnet nuget locals all --clear"))
        P(h + "/.cache/huggingface", I("Hugging Face cache", review, "Downloaded AI models and datasets.", "huggingface-cli delete-cache"))
        P(h + "/.cache", I("Tool caches", review, "Caches of command-line tools.", nil))
        P(h + "/.ollama/models", I("Ollama models", review, "Downloaded AI models.", "ollama rm <model>"))
        P(h + "/.android/avd", I("Android emulators", review, "Android virtual devices with their disk images.", "Android Studio > Device Manager."))
        P(h + "/.docker", I("Docker settings", keep, "Docker's settings and credentials (the images are in Docker Desktop's disk).", nil))
        P(h + "/.vscode/extensions", I("VS Code extensions", keep, "Installed VS Code extensions.", "VS Code > Extensions."))
        P(h + "/.conda/pkgs", I("Conda package cache", safe, "Downloaded conda packages.", "conda clean --all"))
        P(h + "/anaconda3/pkgs", I("Conda package cache", safe, "Downloaded conda packages.", "conda clean --all"))
        P(h + "/miniconda3/pkgs", I("Conda package cache", safe, "Downloaded conda packages.", "conda clean --all"))
        P(h + "/.pyenv/versions", I("Python versions (pyenv)", review, "Python interpreters installed with pyenv.", "pyenv uninstall <version>"))
        P(h + "/.nvm/versions", I("Node.js versions (nvm)", review, "Node.js versions installed with nvm.", "nvm uninstall <version>"))
        P(h + "/.cocoapods", I("CocoaPods data", safe, "Spec repositories and caches of CocoaPods.", "pod cache clean --all"))
        P(lib + "/Caches/CocoaPods", I("CocoaPods cache", safe, "Downloaded pods.", "pod cache clean --all"))
        P(lib + "/Caches/com.apple.dt.Xcode", I("Xcode cache", safe, "Caches of Xcode; rebuilt when needed.", nil))

        // ---- patterns with one variable folder
        W(lib + "/Application Support/Google/Chrome/*/Service Worker", I("Chrome site storage", review, "Offline data of websites (service workers).", "Chrome > Settings > Privacy > Site settings."))
        W(lib + "/Caches/Google/Chrome/*/Cache", I("Chrome cache", safe, "Web pages and images Chrome stored; downloaded again when needed.", "Chrome > Delete browsing data > Cached images and files."))
        W(lib + "/Caches/Google/Chrome/*/Code Cache", I("Chrome code cache", safe, "Compiled scripts of websites.", nil))
        W(lib + "/Caches/Microsoft Edge/*/Cache", I("Edge cache", safe, "Web pages and images Edge stored; downloaded again when needed.", "Edge > Clear browsing data > Cached images and files."))
        W(lib + "/Caches/Firefox/Profiles/*/cache2", I("Firefox cache", safe, "Web pages and images Firefox stored.", "Firefox > Settings > Privacy > Clear Data."))
        W(lib + "/Developer/Xcode/iOS DeviceSupport/*", I("iOS device support", safe, "Debug symbols of one iOS version; copied again when a device with it is connected.", nil))
        W(lib + "/Developer/CoreSimulator/Devices/*", I("iOS simulator device", review, "One simulator with its apps and data.", "xcrun simctl delete <device>"))
        W(lib + "/Application Support/MobileSync/Backup/*", I("iPhone or iPad backup", review, "A device backup. For a lost or replaced phone this can be the only copy.",
                                                                "System tab > iPhone and iPad backups."))
        W(lib + "/CloudStorage/*", I("Cloud storage folder", review, "Synced with a cloud service: deleting here deletes in the cloud and on your other devices too.",
                                     "Use the service's \"Free up space\" / online-only option."))
        W(h + "/Pictures/*.photoslibrary", I("Photos library", keep, "Your Photos library: photos, videos and their edits. With iCloud Photos it may hold only small versions.",
                                             "Photos > Settings > iCloud > Optimize Mac Storage."))

        // ---- names that mean the same thing anywhere
        byName["node_modules"] = I("Project dependencies (npm)", safe, "Packages of a JavaScript project; reinstalled with npm install. Only in your own projects, never inside apps.",
                                   "Suggestions tab (node_modules of your projects).")
        byName[".git"] = I("Git repository data", keep, "The full history of a Git project.", "git gc to compact it.")
        byName["__pycache__"] = I("Python bytecode cache", safe, "Compiled Python files; recreated when the code runs.", nil)
        byName[".venv"] = I("Python virtual environment", review, "Packages installed for one Python project; recreated from its requirements.", nil)
        byName[".pytest_cache"] = I("pytest cache", safe, "Test run cache.", nil)
        byName[".mypy_cache"] = I("mypy cache", safe, "Type-check cache.", nil)
        byName[".next"] = I("Next.js build output", safe, "Built pages; recreated by the next build.", nil)
        byName[".nuxt"] = I("Nuxt build output", safe, "Built pages; recreated by the next build.", nil)
        byName[".terraform"] = I("Terraform providers", safe, "Downloaded providers of a Terraform project; terraform init gets them again.", nil)
        byName["deriveddata"] = I("Xcode build files", safe, "Intermediate build products and indexes; Xcode rebuilds them.", "Xcode > Settings > Locations > Derived Data.")
        byName[".spotlight-v100"] = I("Spotlight index", macOS, "The search index of this volume; rebuilt by macOS.", "System Settings > Siri & Spotlight > Spotlight Privacy.")
        byName[".fseventsd"] = I("File change log", macOS, "macOS's log of file changes on this volume (used by Time Machine and this app's live updates).", nil)
        byName[".documentrevisions-v100"] = I("Document versions", macOS, "Earlier versions of documents (File > Revert To) kept by macOS.", nil)
        byName[".trashes"] = I("Trash of this volume", safe, "Items moved to the Trash from this volume.", "Finder > Empty Trash.")
        byName[".mobilebackups"] = I("Time Machine local snapshots", macOS, "Local Time Machine data on older macOS versions.", "System tab > Time Machine local snapshots.")
        byName["backups.backupdb"] = I("Time Machine backups", keep, "Time Machine backups on this drive.", "Time Machine settings; delete old backups in the Time Machine browser.")
    }

    /// What the folder or file at path is; nil when it is not a known one. name: the item's name (for name rules).
    static func lookup(_ path: String, _ name: String?) -> KnownItem? {
        if path.isEmpty { return nil }
        lock.lock()
        if !built { build(); built = true }
        lock.unlock()
        let p = PathUtil.trim(path).lowercased()
        if let k = byPath[p] { return k }
        if let n = name, let k = byName[n.lowercased()] { return k }
        let parts = p.split(separator: "/").map { String($0) }
        for w in byPattern where w.parts.count == parts.count {
            var ok = true
            for i in 0..<parts.count where !matches(parts[i], w.parts[i]) { ok = false; break }
            if ok { return w.item }
        }
        return nil
    }

    /// One path part against one pattern part: "*" alone = any name; with a prefix / suffix ("swapfile*", "*.photoslibrary").
    private static func matches(_ part: String, _ pat: String) -> Bool {
        if pat == "*" { return true }
        if !pat.contains("*") { return part == pat }
        if pat.hasPrefix("*") { return part.hasSuffix(String(pat.dropFirst())) }
        if pat.hasSuffix("*") { return part.hasPrefix(String(pat.dropLast())) }
        return part == pat
    }
}

extension MainWindowController {
    /// The "What it is" text of a folder contents row (nil when the folder or file is not a known one).
    static func knownFor(_ it: ItemInfo) -> KnownItem? {
        if it.isSummary || it.isGroup { return nil }
        if it.isDir, let d = it.dir { return Known.lookup(d.fullPath, d.name) }
        if let f = it.file { return Known.lookup(f.fullPath, nil) }
        return nil
    }
}

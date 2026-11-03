using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;

namespace SpacePie
{
    /// <summary>What a well-known folder or file is, whether it can go, and what manages it.</summary>
    internal sealed class KnownItem
    {
        public string What;          // short: "Windows component store"
        public string Verdict;       // "Keep", "Safe to delete", "Review first", "Managed by Windows"
        public string Explain;       // one or two sentences
        public string How;           // where to manage it (setting, tab, command); may be null

        /// <summary>Text for the list column: "Windows component store - keep".</summary>
        public string Short { get { return What + " - " + Verdict.ToLowerInvariant(); } }

        /// <summary>Text for the hover box: what it is, the verdict, and how to manage it.</summary>
        public string Long
        {
            get { return What + ": " + Verdict + ".\n" + Explain + (string.IsNullOrEmpty(How) ? "" : "\nHow: " + How); }
        }
    }

    /// <summary>
    /// Recognizes folders and files that Windows, browsers, developer tools and common programs create, so the list can say
    /// what they are instead of leaving the user to guess. Matched by full path (with the user's own folders), by name in a
    /// known place, or by name anywhere for a few unmistakable names. Anything else is simply not labelled.
    /// </summary>
    internal static class Known
    {
        const string Keep = "Keep", Safe = "Safe to delete", Review = "Review first", Windows = "Managed by Windows";

        static readonly Dictionary<string, KnownItem> byPath = new Dictionary<string, KnownItem>(StringComparer.OrdinalIgnoreCase);
        static readonly Dictionary<string, KnownItem> byName = new Dictionary<string, KnownItem>(StringComparer.OrdinalIgnoreCase);
        static readonly List<KeyValuePair<Regex, KnownItem>> byPattern = new List<KeyValuePair<Regex, KnownItem>>();

        static KnownItem I(string what, string verdict, string explain, string how)
        {
            return new KnownItem { What = what, Verdict = verdict, Explain = explain, How = how };
        }

        static void P(string path, KnownItem k)
        {
            try
            {
                string p = Environment.ExpandEnvironmentVariables(path).TrimEnd('\\');
                if (p.IndexOf('%') < 0 && p.Length > 0) byPath[p] = k;
            }
            catch (Exception) { }
        }

        /// <summary>A path with * for one folder name, e.g. %LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2.</summary>
        static void W(string pattern, KnownItem k)
        {
            string p = Environment.ExpandEnvironmentVariables(pattern).TrimEnd('\\');
            if (p.IndexOf('%') >= 0) return;
            byPattern.Add(new KeyValuePair<Regex, KnownItem>(
                new Regex("^" + Regex.Escape(p).Replace(@"\*", @"[^\\]+") + "$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant), k));
        }

        static Known()
        {
            string sys = Path.GetPathRoot(Environment.SystemDirectory).TrimEnd('\\');
            string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string pd = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);

            // ---- Windows
            P(win, I("Windows", Keep, "The operating system itself.", "Clean it from the System tab (update leftovers) or Settings > System > Storage."));
            P(win + @"\WinSxS", I("Windows component store", Keep, "Every version of Windows' own files, for updates and repairs. Explorer overstates its size: most files are hard links into System32.", "System tab > Windows update leftovers > Clean up."));
            P(win + @"\System32", I("Windows system files", Keep, "Programs and libraries Windows runs on.", null));
            P(win + @"\SysWOW64", I("Windows 32-bit system files", Keep, "Windows' files for 32-bit programs.", null));
            P(win + @"\System32\DriverStore", I("Driver store", Keep, "Every driver package installed, so devices work when plugged in again.", "Old driver versions: Disk Cleanup > Clean up system files > Device driver packages."));
            P(win + @"\Installer", I("Installer cache", Keep, "Windows Installer keeps a copy of each program's installer here; programs need it to update, repair or uninstall.", "Uninstall programs you don't need (Apps tab)."));
            P(win + @"\SoftwareDistribution", I("Windows Update downloads", Windows, "Updates downloaded by Windows Update. Windows removes them once installed.", "Settings > System > Storage > Temporary files > Windows Update Cleanup."));
            P(win + @"\SoftwareDistribution\Download", I("Windows Update downloads", Safe, "Update files already downloaded; Windows downloads them again if still needed.", "Settings > System > Storage > Temporary files > Windows Update Cleanup."));
            P(win + @"\Temp", I("Windows temporary files", Safe, "Left over by installers and services. Files in use are skipped.", "Suggestions tab."));
            P(win + @"\Logs", I("Windows logs", Review, "Setup and servicing logs; useful when troubleshooting.", "Settings > System > Storage > Temporary files."));
            P(win + @"\Prefetch", I("Prefetch", Windows, "Speeds up starting programs; Windows keeps it small by itself.", null));
            P(win + @"\Minidump", I("Crash dumps", Safe, "Saved after a blue screen, for diagnosing it.", "Settings > System > Storage > Temporary files > System error memory dump files."));
            P(win + @"\MEMORY.DMP", I("Crash dump", Safe, "Saved after a blue screen, for diagnosing it.", "Settings > System > Storage > Temporary files > System error memory dump files."));
            P(win + @"\Panther", I("Windows setup logs", Review, "Logs of the last Windows installation or upgrade.", null));
            P(win + @"\assembly", I(".NET global assembly cache", Keep, "Shared .NET libraries used by installed programs.", null));
            P(win + @"\Microsoft.NET", I(".NET Framework", Keep, "The .NET Framework and its precompiled libraries.", null));
            P(win + @"\Fonts", I("Fonts", Keep, "Installed fonts.", "Settings > Personalization > Fonts."));
            P(win + @"\servicing", I("Windows servicing", Keep, "Used to install updates and features.", null));
            P(win + @"\Downloaded Program Files", I("Old browser add-ons", Safe, "ActiveX controls from Internet Explorer.", "Disk Cleanup."));
            P(sys + @"\Windows.old", I("Previous Windows installation", Safe, "Kept after an upgrade so you can go back (for 10 days). After that it only takes space.", "Settings > System > Storage > Temporary files > Previous Windows installation(s)."));
            P(sys + @"\$Recycle.Bin", I("Recycle Bin", Safe, "Deleted files of every user on this drive.", "Suggestions tab, or empty the Recycle Bin."));
            P(sys + @"\System Volume Information", I("Restore points and shadow copies", Windows, "System Restore points, File History snapshots and the search index.", "System tab > Restore points and shadow copies."));
            P(sys + @"\pagefile.sys", I("Page file", Windows, "Virtual memory: Windows moves memory here when RAM is full.", "Settings > System > About > Advanced system settings > Performance > Virtual memory."));
            P(sys + @"\hiberfil.sys", I("Hibernation file", Windows, "Holds memory while the PC hibernates; also used by Fast Startup.", "System tab > Hibernation and page file."));
            P(sys + @"\swapfile.sys", I("Swap file", Windows, "Used by Store apps when they are suspended.", null));
            P(sys + @"\DumpStack.log.tmp", I("Crash dump log", Windows, "Recreated by Windows at every start.", null));
            P(sys + @"\$WINDOWS.~BT", I("Windows upgrade files", Safe, "Temporary files of a Windows upgrade; removed when it is finished.", "Settings > System > Storage > Temporary files > Temporary Windows installation files."));
            P(sys + @"\$Windows.~WS", I("Windows upgrade files", Safe, "Temporary files of a Windows upgrade.", "Settings > System > Storage > Temporary files."));
            P(sys + @"\$GetCurrent", I("Windows upgrade files", Safe, "Left over by the Windows update assistant.", null));
            P(sys + @"\ESD", I("Windows upgrade image", Safe, "Download of a Windows upgrade.", null));
            P(sys + @"\MSOCache", I("Office installation cache", Review, "Office's own installer copy; needed to repair Office without the original media.", null));
            P(sys + @"\Intel", I("Intel driver files", Review, "Logs and extracted files of Intel driver installers.", null));
            P(sys + @"\AMD", I("AMD driver installer files", Safe, "Files the AMD driver installer extracted; not needed after installing.", null));
            P(sys + @"\NVIDIA", I("NVIDIA driver installer files", Safe, "Files the NVIDIA driver installer extracted; not needed after installing.", null));
            P(sys + @"\Recovery", I("Windows recovery", Keep, "Recovery environment used to repair Windows.", null));
            P(sys + @"\PerfLogs", I("Performance logs", Review, "Reports from Windows' performance tools; usually empty.", null));
            P(sys + @"\Users", I("User folders", Keep, "Every user's documents, settings and app data.", null));
            P(sys + @"\ProgramData", I("Shared app data", Review, "Data that programs share between users (hidden folder).", null));
            P(pf, I("Installed programs", Keep, "64-bit programs.", "Uninstall what you don't need (Apps tab)."));
            P(sys + @"\Program Files (x86)", I("Installed programs (32-bit)", Keep, "32-bit programs.", "Uninstall what you don't need (Apps tab)."));
            P(pf + @"\WindowsApps", I("Microsoft Store apps", Keep, "Store apps; protected by Windows.", "Apps tab, or Settings > Apps > Installed apps."));
            P(pd + @"\Package Cache", I("Installer package cache", Review, "Visual Studio, .NET and other installers keep their packages here to repair and uninstall.", "Remove the programs, not this folder."));
            P(pd + @"\Microsoft\Windows\WER", I("Error reports", Safe, "Windows Error Reporting files for crashed programs.", "Settings > System > Storage > Temporary files > Windows error reports."));
            P(pd + @"\Microsoft\Windows Defender", I("Microsoft Defender", Keep, "Defender's definitions and quarantine.", null));
            P(pd + @"\Microsoft\Search", I("Search index", Windows, "Windows Search index.", "Settings > Privacy & security > Searching Windows > Advanced indexing options > Rebuild."));
            P(pd + @"\NVIDIA Corporation\Downloader", I("NVIDIA driver downloads", Safe, "Driver packages downloaded by GeForce Experience / NVIDIA app.", null));
            P(pd + @"\Docker", I("Docker data", Review, "Docker's images, containers and volumes.", "docker system prune (or System tab > Virtual disks for its WSL disk)."));

            // ---- this user
            P(@"%TEMP%", I("Your temporary files", Safe, "Left over by programs and installers. Files in use are skipped.", "Suggestions tab."));
            P(@"%LOCALAPPDATA%\Temp", I("Your temporary files", Safe, "Left over by programs and installers. Files in use are skipped.", "Suggestions tab."));
            P(@"%LOCALAPPDATA%\CrashDumps", I("Crash dumps", Safe, "Memory dumps saved when programs crashed.", null));
            P(@"%LOCALAPPDATA%\Packages", I("Store app data", Keep, "Settings and data of Microsoft Store apps.", "Apps tab (uninstall), or the app's Reset in Settings > Apps."));
            P(@"%LOCALAPPDATA%\Microsoft\Windows\INetCache", I("Internet cache", Safe, "Web cache of Windows and older apps.", "Settings > System > Storage > Temporary files."));
            P(@"%LOCALAPPDATA%\Microsoft\Windows\Explorer", I("Thumbnail cache", Safe, "Explorer's thumbnails; rebuilt when needed.", "Settings > System > Storage > Temporary files > Thumbnails."));
            P(@"%LOCALAPPDATA%\Microsoft\Windows\WER", I("Error reports", Safe, "Windows Error Reporting files for crashed programs.", null));
            P(@"%LOCALAPPDATA%\Google\Chrome\User Data", I("Chrome profile", Keep, "Bookmarks, passwords, history and cache of Chrome.", "Chrome > Settings > Privacy > Delete browsing data (cache)."));
            P(@"%LOCALAPPDATA%\Microsoft\Edge\User Data", I("Edge profile", Keep, "Favorites, passwords, history and cache of Edge.", "Edge > Settings > Privacy > Clear browsing data (cache)."));
            P(@"%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data", I("Brave profile", Keep, "Bookmarks, passwords, history and cache of Brave.", "Brave > Settings > Privacy > Delete browsing data."));
            P(@"%APPDATA%\Mozilla\Firefox\Profiles", I("Firefox profiles", Keep, "Bookmarks, passwords and history of Firefox.", null));
            P(@"%LOCALAPPDATA%\Mozilla\Firefox\Profiles", I("Firefox cache", Safe, "Firefox's cache (the profile itself is in Roaming).", "Firefox > Settings > Privacy > Clear Data."));
            P(@"%APPDATA%\Apple Computer\MobileSync\Backup", I("iPhone and iPad backups", Review, "Device backups made by iTunes / Apple Devices. For a lost or replaced phone this can be the only copy.", "Apple Devices / iTunes > Manage Backups."));
            P(@"%APPDATA%\Microsoft\Teams", I("Teams (classic) data", Review, "Cache and data of classic Teams.", null));
            P(@"%LOCALAPPDATA%\Microsoft\OneDrive", I("OneDrive app", Keep, "The OneDrive program and its logs.", null));
            P(@"%LOCALAPPDATA%\Docker", I("Docker Desktop data", Review, "Docker Desktop's WSL disk and logs.", "System tab > Virtual disks (WSL, Docker) > Shrink, or docker system prune."));
            P(@"%LOCALAPPDATA%\wsl", I("WSL disks", Review, "Virtual disks of WSL Linux distributions.", "System tab > Virtual disks (WSL, Docker) > Shrink."));
            P(@"%USERPROFILE%\Downloads", I("Downloads", Review, "Everything downloaded with a browser; old installers often pile up here.", "Suggestions tab (old installers)."));
            P(@"%USERPROFILE%\OneDrive", I("OneDrive", Review, "Synced with OneDrive: deleting here deletes in the cloud and on other devices too.", "Make files online-only: right-click > Free up space."));

            // ---- developer tools (caches rebuild themselves)
            P(@"%USERPROFILE%\.nuget\packages", I("NuGet package cache", Safe, "Downloaded .NET packages; restored again when a project builds.", "dotnet nuget locals all --clear"));
            P(@"%LOCALAPPDATA%\NuGet", I("NuGet caches", Safe, "HTTP and plugin caches of NuGet.", "dotnet nuget locals all --clear"));
            P(@"%LOCALAPPDATA%\npm-cache", I("npm cache", Safe, "Downloaded npm packages.", "npm cache clean --force"));
            P(@"%APPDATA%\npm-cache", I("npm cache", Safe, "Downloaded npm packages.", "npm cache clean --force"));
            P(@"%LOCALAPPDATA%\Yarn\Cache", I("Yarn cache", Safe, "Downloaded Yarn packages.", "yarn cache clean"));
            P(@"%LOCALAPPDATA%\pnpm\store", I("pnpm store", Safe, "Shared store of pnpm packages; projects link to it.", "pnpm store prune"));
            P(@"%LOCALAPPDATA%\pnpm-cache", I("pnpm cache", Safe, "Metadata cache of pnpm.", null));
            P(@"%LOCALAPPDATA%\pip\cache", I("pip cache", Safe, "Downloaded Python packages.", "pip cache purge"));
            P(@"%LOCALAPPDATA%\uv\cache", I("uv cache", Safe, "Downloaded Python packages of uv.", "uv cache clean"));
            P(@"%USERPROFILE%\.gradle\caches", I("Gradle cache", Safe, "Downloaded dependencies and build caches.", "Delete it; Gradle downloads what it needs again."));
            P(@"%USERPROFILE%\.m2\repository", I("Maven repository", Safe, "Downloaded Maven dependencies.", "Delete it; Maven downloads what it needs again."));
            P(@"%USERPROFILE%\.cargo\registry", I("Cargo registry", Safe, "Downloaded Rust crates.", "cargo cache --autoclean (cargo-cache), or delete it."));
            P(@"%USERPROFILE%\go\pkg\mod", I("Go module cache", Safe, "Downloaded Go modules.", "go clean -modcache"));
            P(@"%LOCALAPPDATA%\go-build", I("Go build cache", Safe, "Compiled Go packages.", "go clean -cache"));
            P(@"%USERPROFILE%\.android\avd", I("Android emulators", Review, "Android virtual devices with their disk images.", "Android Studio > Device Manager."));
            P(@"%LOCALAPPDATA%\Android\Sdk", I("Android SDK", Review, "SDK platforms, system images and build tools.", "Android Studio > SDK Manager."));
            P(@"%USERPROFILE%\.ollama\models", I("Ollama models", Review, "Downloaded AI models.", "ollama rm <model>"));
            P(@"%USERPROFILE%\.cache\huggingface", I("Hugging Face cache", Review, "Downloaded AI models and datasets.", "huggingface-cli delete-cache"));
            P(@"%USERPROFILE%\.vscode\extensions", I("VS Code extensions", Keep, "Installed VS Code extensions.", "VS Code > Extensions."));
            P(@"%APPDATA%\Code\Cache", I("VS Code cache", Safe, "Web cache of VS Code.", null));
            P(@"%APPDATA%\Code\CachedData", I("VS Code cache", Safe, "Compiled code of older VS Code versions.", null));
            P(@"%LOCALAPPDATA%\Microsoft\VisualStudio", I("Visual Studio data", Review, "Settings, component caches and logs of Visual Studio.", null));
            P(@"%LOCALAPPDATA%\JetBrains", I("JetBrains caches", Review, "Caches and indexes of JetBrains IDEs, also of old versions.", "Delete folders of IDE versions you no longer use."));
            P(@"%USERPROFILE%\.conda\pkgs", I("Conda package cache", Safe, "Downloaded conda packages.", "conda clean --all"));
            P(@"%USERPROFILE%\anaconda3\pkgs", I("Conda package cache", Safe, "Downloaded conda packages.", "conda clean --all"));
            P(@"%USERPROFILE%\miniconda3\pkgs", I("Conda package cache", Safe, "Downloaded conda packages.", "conda clean --all"));
            P(@"%USERPROFILE%\.cache", I("Tool caches", Review, "Caches of command-line tools.", null));

            // ---- games
            foreach (var steam in new[] { @"%ProgramFiles(x86)%\Steam", @"%ProgramFiles%\Steam" })
            {
                P(steam + @"\steamapps", I("Steam games", Keep, "Installed Steam games.", "Steam > Library > Manage > Uninstall."));
                P(steam + @"\steamapps\shadercache", I("Steam shader cache", Safe, "Precompiled shaders; rebuilt when games start.", "Steam > Settings > Downloads > Clear cache."));
                P(steam + @"\steamapps\downloading", I("Steam downloads in progress", Review, "Unfinished game downloads.", null));
            }
            P(@"%ProgramFiles%\Epic Games", I("Epic Games", Keep, "Games from the Epic Games Store.", "Epic Games Launcher > Library > Uninstall."));

            // ---- patterns with one variable folder
            W(@"%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache", I("Chrome cache", Safe, "Web pages and images Chrome stored; downloaded again when needed.", "Chrome > Delete browsing data > Cached images and files."));
            W(@"%LOCALAPPDATA%\Google\Chrome\User Data\*\Code Cache", I("Chrome code cache", Safe, "Compiled scripts of websites.", null));
            W(@"%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Cache", I("Edge cache", Safe, "Web pages and images Edge stored; downloaded again when needed.", "Edge > Clear browsing data > Cached images and files."));
            W(@"%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Code Cache", I("Edge code cache", Safe, "Compiled scripts of websites.", null));
            W(@"%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2", I("Firefox cache", Safe, "Web pages and images Firefox stored.", "Firefox > Settings > Privacy > Clear Data."));
            W(@"%LOCALAPPDATA%\Packages\*\LocalCache", I("Store app cache", Safe, "Cache of a Store app.", null));
            W(@"%LOCALAPPDATA%\Packages\*\LocalState\ext4.vhdx", I("WSL disk", Review, "The virtual disk of a WSL Linux distribution; it never shrinks by itself.", "System tab > Virtual disks (WSL, Docker) > Shrink."));
            W(@"%USERPROFILE%\.vscode\extensions\*", I("VS Code extension", Keep, "An installed VS Code extension.", "VS Code > Extensions."));

            // ---- names that mean the same thing anywhere
            byName["node_modules"] = I("Project dependencies (npm)", Safe, "Packages of a JavaScript project; reinstalled with npm install. Only in your own projects, never inside programs.", "Suggestions tab (node_modules of your projects).");
            byName[".git"] = I("Git repository data", Keep, "The full history of a Git project.", "git gc to compact it.");
            byName["__pycache__"] = I("Python bytecode cache", Safe, "Compiled Python files; recreated when the code runs.", null);
            byName[".venv"] = I("Python virtual environment", Review, "Packages installed for one Python project; recreated from its requirements.", null);
            byName[".pytest_cache"] = I("pytest cache", Safe, "Test run cache.", null);
            byName[".mypy_cache"] = I("mypy cache", Safe, "Type-check cache.", null);
            byName[".gradle"] = I("Gradle data", Review, "Gradle's caches and wrapper downloads (in a project: its build cache).", null);
            byName[".next"] = I("Next.js build output", Safe, "Built pages; recreated by the next build.", null);
            byName[".nuxt"] = I("Nuxt build output", Safe, "Built pages; recreated by the next build.", null);
            byName[".terraform"] = I("Terraform providers", Safe, "Downloaded providers of a Terraform project; terraform init gets them again.", null);
            byName["$Recycle.Bin"] = I("Recycle Bin", Safe, "Deleted files of every user on this drive.", "Suggestions tab, or empty the Recycle Bin.");
            byName["System Volume Information"] = I("Restore points and shadow copies", Windows, "System Restore points and volume snapshots of this drive.", "System tab > Restore points and shadow copies.");
        }

        /// <summary>What the folder or file at path is; null when it is not a known one.</summary>
        public static KnownItem Lookup(string path, string name)
        {
            if (string.IsNullOrEmpty(path)) return null;
            KnownItem k;
            string p = path.TrimEnd('\\');
            if (byPath.TryGetValue(p, out k)) return k;
            if (name != null && byName.TryGetValue(name, out k)) return k;
            foreach (var w in byPattern) if (w.Key.IsMatch(p)) return w.Value;
            return null;
        }
    }
}

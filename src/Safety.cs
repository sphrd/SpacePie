using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace SpacePie
{
    /// <summary>
    /// What Windows really does with "Move to Recycle Bin": an item larger than the drive's Recycle Bin, any item on a drive
    /// whose bin is turned off ("Don't move files to the Recycle Bin"), and items on drives without a bin (USB sticks,
    /// network shares) are deleted permanently. These are found before deleting so the confirmation can say so.
    /// </summary>
    internal static class RecycleLimits
    {
        public sealed class Bin
        {
            public string Drive;
            public bool Exists = true;       // false: no Recycle Bin on this drive (removable, network)
            public bool Off;                 // the bin is turned off: everything is deleted at once
            public long Capacity;            // largest size the bin keeps (bytes)
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetVolumeNameForVolumeMountPointW(string mountPoint, StringBuilder name, int size);

        public static Bin For(string path)
        {
            string drive = null;
            try { drive = Path.GetPathRoot(path); } catch (Exception) { }
            var bin = new Bin { Drive = drive ?? path };
            if (string.IsNullOrEmpty(drive) || drive.StartsWith(@"\\")) { bin.Exists = false; return bin; }
            long total = 0;
            try
            {
                var di = new DriveInfo(drive);
                if (di.DriveType == DriveType.Removable || di.DriveType == DriveType.Network || di.DriveType == DriveType.CDRom) { bin.Exists = false; return bin; }
                total = di.TotalSize;
            }
            catch (Exception) { }
            // Windows' default when the size was never set: 10 % of the first 40 GB, 5 % of the rest.
            long gb40 = 40L << 30;
            bin.Capacity = total <= gb40 ? total / 10 : gb40 / 10 + (total - gb40) / 20;
            try
            {
                var sb = new StringBuilder(64);
                if (!GetVolumeNameForVolumeMountPointW(drive, sb, sb.Capacity)) return bin;
                var m = Regex.Match(sb.ToString(), @"\{[0-9a-fA-F\-]+\}");
                if (!m.Success) return bin;
                using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\" + m.Value))
                {
                    if (k == null) return bin;
                    var cap = k.GetValue("MaxCapacity");
                    if (cap is int && (int)cap > 0) bin.Capacity = (long)(int)cap << 20;   // megabytes
                    var nuke = k.GetValue("NukeOnDelete");
                    bin.Off = nuke is int && (int)nuke != 0;
                }
            }
            catch (Exception) { }
            return bin;
        }

        /// <summary>Why Windows would delete this item permanently instead of moving it to the Recycle Bin (null = it won't).</summary>
        public static string WouldDeletePermanently(string path, long size, Dictionary<string, Bin> cache)
        {
            string drive;
            try { drive = Path.GetPathRoot(path) ?? path; } catch (Exception) { drive = path; }
            Bin b;
            if (!cache.TryGetValue(drive, out b)) cache[drive] = b = For(path);
            if (!b.Exists) return drive.TrimEnd('\\') + " has no Recycle Bin";
            if (b.Off) return "the Recycle Bin is turned off for " + drive.TrimEnd('\\');
            if (b.Capacity > 0 && size > b.Capacity) return "larger than the Recycle Bin on " + drive.TrimEnd('\\') + " (" + Fmt.Size(b.Capacity) + ")";
            return null;
        }
    }

    /// <summary>
    /// Folders kept in sync with a cloud service or other devices. Deleting there also deletes the files in the cloud and
    /// on every synced device. Found from Windows' list of sync roots (OneDrive, Dropbox, Google Drive, iCloud, Box...), the
    /// OneDrive settings, Dropbox's info.json, Google Drive for desktop and Syncthing's configuration.
    /// </summary>
    internal static class SyncFolders
    {
        static List<KeyValuePair<string, string>> roots;
        static DateTime loaded;

        /// <summary>The synced folders (path, service), longest first; read again at most once a minute.</summary>
        public static List<KeyValuePair<string, string>> Roots
        {
            get
            {
                if (roots == null || (DateTime.UtcNow - loaded).TotalSeconds > 60) { roots = Find(); loaded = DateTime.UtcNow; }
                return roots;
            }
        }

        /// <summary>The service that syncs path ("OneDrive", "Dropbox"...), or null when it is not in a synced folder.</summary>
        public static string ServiceFor(string path)
        {
            if (string.IsNullOrEmpty(path)) return null;
            foreach (var r in Roots)
            {
                string root = r.Key.TrimEnd('\\');
                if (path.Equals(root, StringComparison.OrdinalIgnoreCase) || path.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase)) return r.Value;
            }
            return null;
        }

        static List<KeyValuePair<string, string>> Find()
        {
            var found = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            Action<string, string> add = (p, svc) =>
            {
                if (string.IsNullOrWhiteSpace(p)) return;
                try
                {
                    p = Environment.ExpandEnvironmentVariables(p.Trim().Trim('"')).TrimEnd('\\');
                    // A drive root ("G:", Google Drive's virtual drive) is allowed; other paths must be longer.
                    bool driveRoot = p.Length == 2 && p[1] == ':';
                    if ((p.Length < 3 && !driveRoot) || !Directory.Exists(driveRoot ? p + "\\" : p)) return;
                    if (!found.ContainsKey(p)) found[p] = svc;
                }
                catch (Exception) { }
            };
            // Windows cloud files API: every provider registers its sync roots here.
            try
            {
                using (var k = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager"))
                    if (k != null)
                        foreach (var id in k.GetSubKeyNames())
                            using (var sk = k.OpenSubKey(id))
                            {
                                if (sk == null) continue;
                                string svc = ServiceName(id, sk.GetValue("DisplayNameResource") as string);
                                using (var u = sk.OpenSubKey("UserSyncRoots"))
                                    if (u != null) foreach (var v in u.GetValueNames()) add(u.GetValue(v) as string, svc);
                            }
            }
            catch (Exception) { }
            // OneDrive (also when it isn't registered as a sync root).
            foreach (var v in new[] { "OneDrive", "OneDriveConsumer", "OneDriveCommercial" }) add(Environment.GetEnvironmentVariable(v), "OneDrive");
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\OneDrive\Accounts"))
                    if (k != null)
                        foreach (var a in k.GetSubKeyNames())
                            using (var ak = k.OpenSubKey(a)) if (ak != null) add(ak.GetValue("UserFolder") as string, "OneDrive");
            }
            catch (Exception) { }
            // Dropbox: info.json lists the folder of each account.
            foreach (var dir in new[] { Environment.SpecialFolder.ApplicationData, Environment.SpecialFolder.LocalApplicationData })
                try
                {
                    string f = Path.Combine(Environment.GetFolderPath(dir), @"Dropbox\info.json");
                    if (!File.Exists(f)) continue;
                    foreach (Match m in Regex.Matches(File.ReadAllText(f), "\"path\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""))
                        add(Regex.Unescape(m.Groups[1].Value), "Dropbox");
                }
                catch (Exception) { }
            // Google Drive for desktop: a virtual drive named "Google Drive"; mirrored folders are in its settings.
            try
            {
                foreach (var d in DriveInfo.GetDrives())
                    try { if (d.IsReady && d.VolumeLabel.IndexOf("Google Drive", StringComparison.OrdinalIgnoreCase) >= 0) add(d.RootDirectory.FullName, "Google Drive"); }
                    catch (Exception) { }
                using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Google\DriveFS\Share"))
                    if (k != null) add(k.GetValue("BasePath") as string, "Google Drive");
            }
            catch (Exception) { }
            add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Google Drive"), "Google Drive");
            add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "iCloudDrive"), "iCloud");
            // Syncthing: <folder ... path="..."> in config.xml.
            foreach (var cfg in new[] { @"%LOCALAPPDATA%\Syncthing\config.xml", @"%APPDATA%\Syncthing\config.xml" })
                try
                {
                    string f = Environment.ExpandEnvironmentVariables(cfg);
                    if (!File.Exists(f)) continue;
                    foreach (Match m in Regex.Matches(File.ReadAllText(f), "<folder\\b[^>]*\\bpath=\"([^\"]+)\""))
                        add(System.Net.WebUtility.HtmlDecode(m.Groups[1].Value), "Syncthing");
                }
                catch (Exception) { }
            // Resilio Sync keeps its folders in a database; only the default folder is checked.
            add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Resilio Sync"), "Resilio Sync");
            return found.OrderByDescending(kv => kv.Key.Length).ToList();
        }

        /// <summary>A readable service name from the sync root id ("OneDrive!S-1-5-...!Personal|...") or its display name.</summary>
        static string ServiceName(string id, string display)
        {
            string head = id.Split('!')[0];
            foreach (var known in new[] { "OneDrive", "Dropbox", "GoogleDrive", "iCloud", "Box", "MEGA", "pCloud", "Nextcloud", "ownCloud", "Sync.com", "Tresorit" })
                if (head.IndexOf(known, StringComparison.OrdinalIgnoreCase) >= 0 || (display ?? "").IndexOf(known, StringComparison.OrdinalIgnoreCase) >= 0)
                    return known == "GoogleDrive" ? "Google Drive" : known;
            return head.Length > 0 ? head : "a sync service";
        }
    }
}

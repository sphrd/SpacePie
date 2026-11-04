using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

namespace SpacePie
{
    /// <summary>
    /// Suggestions the user never wants to see again: a whole suggestion (by name) or one location (by path), kept in
    /// %LOCALAPPDATA%\SpacePie\ignored-suggestions.txt ("s&lt;TAB&gt;name" / "t&lt;TAB&gt;path" lines).
    /// </summary>
    internal static class IgnoreList
    {
        public static string FileOverride;        // self-test
        static readonly object gate = new object();
        static HashSet<string> names, paths;

        static string FilePath { get { return FileOverride ?? AppData.Path("ignored-suggestions.txt"); } }

        static void Load()
        {
            lock (gate)
            {
                if (names != null) return;
                names = new HashSet<string>(StringComparer.Ordinal);
                paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                try
                {
                    if (!File.Exists(FilePath)) return;
                    foreach (var line in File.ReadAllLines(FilePath, Encoding.UTF8))
                    {
                        if (line.Length < 3 || line[1] != '\t') continue;
                        if (line[0] == 's') names.Add(line.Substring(2));
                        else if (line[0] == 't') paths.Add(line.Substring(2).TrimEnd('\\'));
                    }
                }
                catch (Exception) { }
            }
        }

        /// <summary>Reads the file again on next use (the self-test points it elsewhere).</summary>
        public static void Reset() { lock (gate) { names = null; paths = null; } }

        public static int Count { get { Load(); lock (gate) return names.Count + paths.Count; } }

        /// <summary>One line per ignored item, for the list the user can review.</summary>
        public static List<string> Lines
        {
            get
            {
                Load();
                lock (gate)
                    return names.OrderBy(n => n, StringComparer.CurrentCultureIgnoreCase).Select(n => "All of \"" + n + "\"")
                        .Concat(paths.OrderBy(p => p, StringComparer.OrdinalIgnoreCase)).ToList();
            }
        }

        public static void Add(string name, string path)
        {
            Load();
            lock (gate)
            {
                if (name != null) names.Add(name);
                if (path != null) paths.Add(path.TrimEnd('\\'));
            }
            Save();
        }

        public static void Clear()
        {
            Load();
            lock (gate) { names.Clear(); paths.Clear(); }
            Save();
        }

        static void Save()
        {
            try
            {
                List<string> lines;
                lock (gate) lines = names.OrderBy(n => n).Select(n => "s\t" + n).Concat(paths.OrderBy(p => p).Select(p => "t\t" + p)).ToList();
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
                File.WriteAllLines(FilePath, lines, new UTF8Encoding(false));
            }
            catch (Exception) { }
        }

        /// <summary>The suggestions without what is ignored (whole suggestions by name, locations by path).</summary>
        public static List<Suggestion> Apply(List<Suggestion> list)
        {
            Load();
            HashSet<string> n, p;
            lock (gate) { n = new HashSet<string>(names); p = new HashSet<string>(paths, StringComparer.OrdinalIgnoreCase); }
            if (n.Count == 0 && p.Count == 0) return list;
            var kept = new List<Suggestion>();
            foreach (var s in list)
            {
                if (n.Contains(s.Name)) continue;
                s.Targets.RemoveAll(t => !t.RecycleBin && p.Contains(t.Path.TrimEnd('\\')));
                s.Remeasure();
                if (s.Targets.Count == 0 || s.Size <= 0) continue;
                if (!s.Targets[0].RecycleBin)
                    s.Location = s.Targets.Count == 1 ? s.Targets[0].Path : string.Format("{0:N0} locations", s.Targets.Count);
                kept.Add(s);
            }
            return kept;
        }
    }

    internal sealed partial class MainForm
    {
        RoundButton btnSugIgnored;
        ToolStripMenuItem miIgnoreSuggestion;

        /// <summary>
        /// More places other cleaners look (CleanMyMac-style system junk, mail attachments, unfinished downloads, leftovers
        /// of removed apps and users), with the same rules as the rest: one line on what deleting means, items to review
        /// start unchecked, never anything inside a program. Runs on a background thread.
        /// </summary>
        void FindMoreSuggestions(List<DirNode> scanned, List<Suggestion> list)
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            DateTime now = DateTime.UtcNow;

            // Old Windows logs (setup, servicing, updates): the files still written to are newer than a week.
            var logs = new Suggestion { Name = "Windows logs", Safe = true, NeedsAdmin = true, Note = "Logs of Windows setup, updates and services older than a week. Only needed to investigate a problem." };
            foreach (var f in FilesBelow(Path.Combine(win, "Logs"), 6))
            {
                string ext = f.Extension.ToLowerInvariant();
                if ((ext == ".log" || ext == ".etl" || ext == ".cab" || ext == ".old") && f.LastWriteTimeUtc < now.AddDays(-7) && f.Length > 0)
                {
                    logs.Targets.Add(new DeleteTarget { Path = f.FullName, Label = f.Name, Size = f.Length, Note = "old log" });
                    logs.Size += f.Length;
                }
            }
            Finish(list, logs, true);

            // Outlook: attachments it saved while they were opened (it gets them again from the message).
            Contents(list, "Outlook attachments", Path.Combine(local, @"Microsoft\Windows\INetCache\Content.Outlook"), true, false,
                "Attachments Outlook saved when you opened them. Outlook gets them again from the message when needed.");

            // Unfinished downloads in Downloads and on the Desktop (older than a day).
            var partial = new Suggestion { Name = "Unfinished downloads", Safe = true, Note = "Downloads in Downloads or on the Desktop that never finished (older than a day). They can't be opened; download again if needed." };
            var partialExt = new[] { ".crdownload", ".part", ".partial", ".opdownload", ".download", ".!ut", ".!qb", ".filepart" };
            foreach (var dir in new[] { Path.Combine(home, "Downloads"), Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory) })
                foreach (var f in FilesBelow(dir, 4))
                    if (partialExt.Any(x => f.Name.EndsWith(x, StringComparison.OrdinalIgnoreCase)) && f.LastWriteTimeUtc < now.AddDays(-1) && f.Length > 0)
                    {
                        partial.Targets.Add(new DeleteTarget { Path = f.FullName, Label = f.Name, Size = f.Length, Note = "unfinished download" });
                        partial.Size += f.Length;
                    }
            Finish(list, partial, true);

            // Disk images in the scanned drives not opened for 30 days (not those in Downloads: "Old installers" lists them).
            var images = new Suggestion { Name = "Disk images", Safe = false, Note = "Disk images (.iso, .img) not opened for 30 days: usually installers already used. Keep the ones you still need." };
            string downloads = Path.Combine(home, "Downloads").TrimEnd('\\');
            long monthAgo = now.AddDays(-30).ToFileTimeUtc();
            foreach (var r in scanned)
                foreach (var d in r.Descendants())
                {
                    if (d.FileList == null) continue;
                    string dp = d.FullPath;
                    if (string.Equals(dp.TrimEnd('\\'), downloads, StringComparison.OrdinalIgnoreCase) || IsSystemOrAppPath(dp)) continue;
                    for (int i = 0; i < d.FileList.Length; i++)
                    {
                        var f = d.FileList[i];
                        string ext = Path.GetExtension(f.Name).ToLowerInvariant();
                        if (ext != ".iso" && ext != ".img") continue;
                        long size = FileIndex.Measure(ref d.FileList[i]);
                        if (size < 10L << 20 || f.OnlineOnly || f.LastUse <= 0 || f.LastUse > monthAgo) continue;
                        images.Targets.Add(new DeleteTarget { Path = Native.Join(dp, f.Name), Label = f.Name, Size = size, Note = "disk image" });
                        images.Size += size;
                    }
                }
            Finish(list, images, true);

            // Old versions of self-updating apps (Squirrel: Discord, Slack, Teams classic...): app-x.y.z folders beside
            // Update.exe; the newest is the one in use.
            var versions = new Suggestion { Name = "Old app versions", Safe = true, Note = "Earlier versions self-updating apps (Discord, Slack...) keep after updating. The newest version is kept." };
            foreach (var appDir in SafeDirs(local))
            {
                if (!File.Exists(Path.Combine(appDir, "Update.exe"))) continue;
                var vers = new List<KeyValuePair<Version, string>>();
                foreach (var d in SafeDirs(appDir))
                {
                    string n = Path.GetFileName(d);
                    Version v;
                    if (n.StartsWith("app-", StringComparison.OrdinalIgnoreCase) && Version.TryParse(n.Substring(4), out v)) vers.Add(new KeyValuePair<Version, string>(v, d));
                }
                if (vers.Count < 2) continue;
                foreach (var kv in vers.OrderByDescending(x => x.Key).Skip(1))
                {
                    long size = MeasureFolder(kv.Value);
                    if (size <= 0) continue;
                    versions.Targets.Add(new DeleteTarget { Path = kv.Value, Label = Path.GetFileName(appDir) + " " + kv.Key, IsDir = true, Size = size, Note = "older version" });
                    versions.Size += size;
                }
            }
            Finish(list, versions, true);

            // Data of Store apps that are no longer installed (their package family is not registered for this user).
            var families = RegisteredPackageFamilies();
            var store = new Suggestion { Name = "Leftovers of removed apps", Safe = false, Note = "Data of Microsoft Store apps that are no longer installed. Check them before deleting." };
            if (families.Count > 0)
                foreach (var d in SafeDirs(Path.Combine(local, "Packages")))
                {
                    string fam = Path.GetFileName(d);
                    if (families.Contains(fam) || fam.IndexOf('_') < 0) continue;
                    // Changed in the last 30 days: something still uses it.
                    try { if (Directory.GetLastWriteTimeUtc(d) > now.AddDays(-30)) continue; } catch (Exception) { continue; }
                    long size = MeasureFolder(d);
                    if (size <= 0) continue;
                    store.Targets.Add(new DeleteTarget { Path = d, Label = fam.Substring(0, fam.IndexOf('_')), IsDir = true, Size = size, Note = "app not installed" });
                    store.Size += size;
                }
            Finish(list, store, true);

            // Profile folders in C:\Users without a user account (left after removing the account).
            var users = new Suggestion { Name = "Deleted users", Safe = false, NeedsAdmin = true, Note = "Folders of user accounts that no longer exist. Check that nothing in them is still needed." };
            var profiles = ProfileFolders();
            string usersDir = Path.GetDirectoryName(home.TrimEnd('\\'));
            if (profiles.Count > 0 && !string.IsNullOrEmpty(usersDir))
                foreach (var d in SafeDirs(usersDir))
                {
                    string n = Path.GetFileName(d);
                    if (profiles.Contains(d.TrimEnd('\\')) || new[] { "Public", "Default", "Default User", "All Users", "defaultuser0" }.Contains(n, StringComparer.OrdinalIgnoreCase)) continue;
                    try
                    {
                        if ((File.GetAttributes(d) & FileAttributes.ReparsePoint) != 0) continue;
                        if (Directory.GetLastWriteTimeUtc(d) > now.AddDays(-30)) continue;
                    }
                    catch (Exception) { continue; }
                    long size = MeasureFolder(d);
                    if (size <= 0) continue;
                    users.Targets.Add(new DeleteTarget { Path = d, Label = n, IsDir = true, Size = size, Note = "no such user" });
                    users.Size += size;
                }
            Finish(list, users, true);
        }

        /// <summary>Program, Windows, ProgramData and AppData folders: never suggested from the index.</summary>
        static bool IsSystemOrAppPath(string path)
        {
            foreach (var sf in new[] { Environment.SpecialFolder.Windows, Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86,
                                       Environment.SpecialFolder.CommonApplicationData, Environment.SpecialFolder.ApplicationData, Environment.SpecialFolder.LocalApplicationData })
            {
                string root = Environment.GetFolderPath(sf);
                if (root.Length > 0 && (path.Equals(root, StringComparison.OrdinalIgnoreCase) || path.StartsWith(root.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))) return true;
            }
            return path.IndexOf(@"\$Recycle.Bin", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        static IEnumerable<string> SafeDirs(string dir)
        {
            try { return Directory.Exists(dir) ? Directory.GetDirectories(dir) : new string[0]; } catch (Exception) { return new string[0]; }
        }

        /// <summary>Files in dir and its subfolders down to depth levels; unreadable folders and links are skipped.</summary>
        static List<FileInfo> FilesBelow(string dir, int depth)
        {
            var found = new List<FileInfo>();
            var stack = new Stack<KeyValuePair<string, int>>();
            if (Directory.Exists(dir)) stack.Push(new KeyValuePair<string, int>(dir, 0));
            while (stack.Count > 0)
            {
                var cur = stack.Pop();
                try
                {
                    var di = new DirectoryInfo(cur.Key);
                    found.AddRange(di.GetFiles());
                    if (cur.Value < depth)
                        foreach (var sub in di.GetDirectories())
                            if ((sub.Attributes & FileAttributes.ReparsePoint) == 0) stack.Push(new KeyValuePair<string, int>(sub.FullName, cur.Value + 1));
                }
                catch (Exception) { }
            }
            return found;
        }

        /// <summary>Package families registered for this user (Store apps and Windows components); empty when unreadable.</summary>
        static HashSet<string> RegisteredPackageFamilies()
        {
            var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Families"))
                    if (k != null) foreach (var n in k.GetSubKeyNames()) set.Add(n);
            }
            catch (Exception) { }
            return set;
        }

        /// <summary>Profile folders of the accounts on this PC (ProfileList); empty when unreadable.</summary>
        static HashSet<string> ProfileFolders()
        {
            var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                using (var k = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64).OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"))
                    if (k != null)
                        foreach (var sid in k.GetSubKeyNames())
                            using (var s = k.OpenSubKey(sid))
                            {
                                var v = s == null ? null : s.GetValue("ProfileImagePath") as string;
                                if (!string.IsNullOrEmpty(v)) set.Add(Environment.ExpandEnvironmentVariables(v).TrimEnd('\\'));
                            }
            }
            catch (Exception) { }
            return set;
        }

        // ---------------------------------------------------------------- ignore list in the Suggestions view

        /// <summary>Never suggest the selected rows again (a suggestion by name, a location by path); they leave the list at once.</summary>
        void IgnoreSelectedSuggestions()
        {
            if (suggestions == null) return;
            var sel = pSuggest.List.SelectedItems.Cast<ListViewItem>().Select(i => (ItemInfo)i.Tag).ToList();
            int n = 0;
            foreach (var it in sel)
            {
                var s = it.Data as Suggestion;
                var t = it.Data as DeleteTarget;
                if (s != null) { IgnoreList.Add(s.Name, null); n++; }
                else if (t != null && !t.RecycleBin) { IgnoreList.Add(null, t.Path); n++; }
                else if (t != null && it.GroupOf != null && it.GroupOf.Data is Suggestion) { IgnoreList.Add(((Suggestion)it.GroupOf.Data).Name, null); n++; }
            }
            if (n == 0) return;
            suggestions = IgnoreList.Apply(suggestions);
            ShowSuggestions();
            statusLabel.Text = string.Format("Not suggested again: {0:N0} item{1}. Ignored ({2:N0})... in the Suggestions bar lists them.", n, n == 1 ? "" : "s", IgnoreList.Count);
        }

        /// <summary>The ignored items, with Stop ignoring all.</summary>
        void ShowIgnoredSuggestions()
        {
            var lines = IgnoreList.Lines;
            if (lines.Count == 0) return;
            string r = Alert(AlertIcon.Logo, string.Format("{0:N0} item{1} never suggested", lines.Count, lines.Count == 1 ? " is" : "s are"),
                "You chose not to see these in Suggestions again.", null, lines, "Close", "Stop ignoring all");
            if (r != "Stop ignoring all") return;
            IgnoreList.Clear();
            suggestionsDirty = true;
            FillSuggestions();
        }

        void UpdateIgnoredButton()
        {
            if (btnSugIgnored == null) return;
            int n = IgnoreList.Count;
            string text = string.Format("Ignored ({0:N0})...", n);
            if (btnSugIgnored.Visible == (n > 0) && btnSugIgnored.Text == text) return;
            btnSugIgnored.Text = text;
            btnSugIgnored.Visible = n > 0;
            if (btnSugIgnored.Parent != null) btnSugIgnored.Parent.PerformLayout();
        }
    }
}

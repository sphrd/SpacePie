using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace SpacePie
{
    /// <summary>
    /// Apps tab: the folders an app made anywhere on the scanned drives (found in the scan index, every depth), who made each
    /// one (the app, or the user), and which of them can go while the app stays installed (caches, temporary files, logs,
    /// crash dumps).
    /// </summary>
    internal sealed partial class MainForm
    {
        /// <summary>The names an app's folders go by.</summary>
        sealed class AppKeys
        {
            public InstalledApp App;
            public HashSet<string> Names, Strong, PubKeys, PubNames;

            /// <summary>A folder named like the app's developer (exactly, or a longer developer name starting with it).</summary>
            public bool IsPublisherFolder(string norm)
            {
                if (norm.Length < 4) return false;
                foreach (var p in PubKeys) if (p == norm || norm.Length >= 5 && p.StartsWith(norm)) return true;
                return false;
            }
        }

        /// <summary>Never matched: names many unrelated folders share.</summary>
        static readonly HashSet<string> GenericNames = new HashSet<string>
        {
            "microsoft", "windows", "program", "programs", "common", "commonfiles", "update", "updater", "tools", "setup", "installer",
            "temp", "cache", "data", "files", "user", "users", "config", "settings", "logs", "bin", "lib", "app", "apps", "plugins", "driver", "drivers"
        };

        static readonly HashSet<string> CompanyWords = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "inc", "llc", "ltd", "limited", "corp", "corporation", "co", "company", "gmbh", "ag", "sa", "srl", "bv", "plc", "incorporated", "the",
            "software", "technologies", "technology", "systems"
        };

        /// <summary>Folders never searched: system folders and code libraries (a package there is not the app's data).</summary>
        static readonly HashSet<string> SkipFolders = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "$Recycle.Bin", "System Volume Information", "WindowsApps", "node_modules", "site-packages", "dist-packages", ".git", "WinSxS"
        };

        static AppKeys KeysOf(InstalledApp a)
        {
            var k = new AppKeys { App = a, Names = CandidateNames(a), Strong = StrongNames(a), PubKeys = PublisherKeys(a.Publisher), PubNames = new HashSet<string>() };
            // Inside the developer's folder the app often drops the developer's name: Adobe\Acrobat for "Adobe Acrobat".
            foreach (var n in k.Names)
                foreach (var p in k.PubKeys)
                    if (n.Length >= p.Length + 4 && n.StartsWith(p)) k.PubNames.Add(n.Substring(p.Length));
            // ...or keeps only its first word: Adobe\Acrobat for "Adobe Acrobat Reader".
            var words = (a.Name ?? "").Split(new[] { ' ', '-', '(', ')' }, StringSplitOptions.RemoveEmptyEntries);
            if (words.Length > 2 && k.PubKeys.Contains(Norm(words[0])) && Norm(words[1]).Length >= 4) k.PubNames.Add(Norm(words[1]));
            k.PubNames.ExceptWith(GenericNames);
            return k;
        }

        /// <summary>Normalised developer names: in full, without "Inc."/"Software"..., and the first word ("Adobe" of "Adobe Inc.").</summary>
        static HashSet<string> PublisherKeys(string publisher)
        {
            var s = new HashSet<string>();
            Action<string> add = x => { string n = Norm(x); if (n.Length >= 4 && !n.StartsWith("microsoft") && !GenericNames.Contains(n)) s.Add(n); };
            add(publisher);
            var words = (publisher ?? "").Split(new[] { ' ', ',', '.', '-', '(', ')' }, StringSplitOptions.RemoveEmptyEntries);
            add(string.Join(" ", words.Where(w => !CompanyWords.Contains(w))));
            if (words.Length > 0) add(words[0]);
            return s;
        }

        sealed class FolderHits
        {
            public readonly Dictionary<InstalledApp, List<Leftover>> ByApp = new Dictionary<InstalledApp, List<Leftover>>();
            public readonly Dictionary<Leftover, DirNode> Nodes = new Dictionary<Leftover, DirNode>();

            public List<Leftover> Of(InstalledApp a)
            {
                List<Leftover> l;
                return ByApp.TryGetValue(a, out l) ? l : new List<Leftover>();
            }
        }

        /// <summary>
        /// Every folder in the scanned trees named after an installed app (or, inside its developer's folder, after the app
        /// without the developer's name). The outermost match counts (its contents belong to it). Never inside a program
        /// folder (that is the program's), never a folder holding a program folder, never in Windows except Windows\Temp.
        /// Runs on a background thread; a tree that changes meanwhile ends the search with what was found.
        /// </summary>
        static FolderHits FindAppFolders(List<DirNode> scanned, List<InstalledApp> all, InstalledApp only)
        {
            var hits = new FolderHits();
            if (scanned == null || scanned.Count == 0 || all == null) return hits;
            var keys = all.Select(KeysOf).ToList();
            // name -> apps; "publisher\name" -> apps that use name only inside their developer's folder
            var byName = new Dictionary<string, List<AppKeys>>();
            Action<string, AppKeys> index = (n, k) =>
            {
                List<AppKeys> l;
                if (!byName.TryGetValue(n, out l)) byName[n] = l = new List<AppKeys>();
                if (!l.Contains(k)) l.Add(k);
            };
            foreach (var k in keys)
            {
                foreach (var n in k.Names) index(n, k);
                foreach (var p in k.PubKeys) foreach (var n in k.PubNames) index(p + "\\" + n, k);
            }
            var locations = new HashSet<DirNode>();
            var aboveLocations = new HashSet<DirNode>();
            foreach (var a in all)
            {
                var n = Resolve(scanned, a.Location);
                if (n == null || n.Parent == null) continue;
                locations.Add(n);
                for (var p = n.Parent; p != null; p = p.Parent) aboveLocations.Add(p);
            }
            var winNode = Resolve(scanned, Environment.GetFolderPath(Environment.SpecialFolder.Windows));
            var stack = new Stack<KeyValuePair<DirNode, string>>();
            foreach (var r in scanned) stack.Push(new KeyValuePair<DirNode, string>(r, ""));
            try
            {
                while (stack.Count > 0)
                {
                    var e = stack.Pop();
                    var d = e.Key;
                    if (d.Parent != null && (locations.Contains(d) || SkipFolders.Contains(d.Name))) continue;
                    if (d == winNode)
                    {
                        var t = d.Child("Temp");
                        if (t != null) stack.Push(new KeyValuePair<DirNode, string>(t, "windows"));
                        continue;
                    }
                    string n = d.Parent == null ? "" : Norm(d.Name);
                    if (n.Length >= 4 && !aboveLocations.Contains(d))
                    {
                        List<AppKeys> direct, viaPub = null;
                        byName.TryGetValue(n, out direct);
                        if (e.Value.Length >= 4) byName.TryGetValue(e.Value + "\\" + n, out viaPub);
                        var matched = (direct ?? new List<AppKeys>()).Concat(viaPub ?? new List<AppKeys>()).Distinct().ToList();
                        if (matched.Count > 0)
                        {
                            string path = d.FullPath;
                            foreach (var k in matched)
                            {
                                if (only != null && k.App != only) continue;
                                var l = new Leftover { Path = path, Label = d.Name, IsDir = true, Size = d.Size, Shared = matched.Count };
                                if (!hits.ByApp.ContainsKey(k.App)) hits.ByApp[k.App] = new List<Leftover>();
                                hits.ByApp[k.App].Add(l);
                                hits.Nodes[l] = d;
                            }
                            continue;
                        }
                    }
                    if (d.Children != null)
                        for (int i = d.Children.Count - 1; i >= 0; i--) stack.Push(new KeyValuePair<DirNode, string>(d.Children[i], n));
                }
            }
            catch (Exception) { }
            return hits;
        }

        /// <summary>The scanned folder at exactly path, or null.</summary>
        static DirNode Resolve(List<DirNode> roots, string path)
        {
            if (string.IsNullOrEmpty(path) || roots == null) return null;
            path = path.TrimEnd('\\');
            try
            {
                foreach (var r in roots)
                {
                    string rp = r.FullPath.TrimEnd('\\');
                    if (!IsWithin(path, rp)) continue;
                    var n = r;
                    foreach (var part in path.Substring(rp.Length).Split(new[] { '\\' }, StringSplitOptions.RemoveEmptyEntries))
                    {
                        n = n.Child(part);
                        if (n == null) break;
                    }
                    if (n != null) return n;
                }
            }
            catch (Exception) { }   // the tree changed while it was read
            return null;
        }

        const int AreaApp = 0, AreaTemp = 1, AreaProgram = 2, AreaUser = 3, AreaOther = 4;

        /// <summary>What kind of place path is in, and its label ("Shared data (ProgramData)", "Documents folder"...).</summary>
        static string AreaOf(string path, out int area)
        {
            Func<Environment.SpecialFolder, string> sf = Environment.GetFolderPath;
            string local = sf(Environment.SpecialFolder.LocalApplicationData), home = sf(Environment.SpecialFolder.UserProfile);
            string win = sf(Environment.SpecialFolder.Windows);
            var places = new[]
            {
                Tuple.Create(Path.GetTempPath(), AreaTemp, "Temporary files (Temp)"),
                Tuple.Create(Path.Combine(win, "Temp"), AreaTemp, "Temporary files (Windows\\Temp)"),
                Tuple.Create(Path.Combine(local, "Packages"), AreaApp, "App data (Store package)"),
                Tuple.Create(Path.Combine(local, "Programs"), AreaProgram, "Program folder"),
                Tuple.Create(local, AreaApp, "Data and cache (AppData\\Local)"),
                Tuple.Create(sf(Environment.SpecialFolder.ApplicationData), AreaApp, "Settings (AppData\\Roaming)"),
                Tuple.Create(Path.Combine(home, "AppData", "LocalLow"), AreaApp, "Data (AppData\\LocalLow)"),
                Tuple.Create(sf(Environment.SpecialFolder.CommonApplicationData), AreaApp, "Shared data (ProgramData)"),
                Tuple.Create(sf(Environment.SpecialFolder.CommonProgramFiles), AreaProgram, "Shared program files (Common Files)"),
                Tuple.Create(sf(Environment.SpecialFolder.CommonProgramFilesX86), AreaProgram, "Shared program files (Common Files)"),
                Tuple.Create(sf(Environment.SpecialFolder.ProgramFiles), AreaProgram, "Program folder"),
                Tuple.Create(sf(Environment.SpecialFolder.ProgramFilesX86), AreaProgram, "Program folder"),
            };
            foreach (var p in places)
                if (!string.IsNullOrEmpty(p.Item1) && IsWithin(path, p.Item1.TrimEnd('\\'))) { area = p.Item2; return p.Item3; }
            if (!string.IsNullOrEmpty(home) && IsWithin(path, home.TrimEnd('\\')) && path.Length > home.TrimEnd('\\').Length + 1)
            {
                string first = path.Substring(home.TrimEnd('\\').Length + 1).Split('\\')[0];
                if (first.StartsWith(".")) { area = AreaApp; return "Data (hidden folder in your profile)"; }
                area = AreaUser;
                return first + " folder";
            }
            area = AreaOther;
            return "Other folder";
        }

        /// <summary>What a folder holds, by size: 1 = mostly your files (documents, pictures, media, archives, code), 2 = mostly programs, 0 = not clear.</summary>
        static int ContentVerdict(DirNode node)
        {
            long user = 0, prog = 0, all = 0;
            int files = 0;
            try
            {
                foreach (var d in node.Descendants())
                {
                    if (d.FileList == null) continue;
                    for (int i = 0; i < d.FileList.Length; i++)
                    {
                        long s = FileIndex.Measure(ref d.FileList[i]);
                        string cat = FileTypes.CategoryOf(FileIndex.Extension(d.FileList[i].Name));
                        all += s;
                        if (cat == "Programs and libraries") prog += s;
                        else if (cat != "Other" && cat != "Databases" && cat != "Installers") user += s;
                        if (++files > 200000) break;
                    }
                    if (files > 200000) break;
                }
            }
            catch (Exception) { return 0; }   // the tree changed while it was read
            if (all <= 0) return 0;
            if (user * 2 >= all) return 1;
            if (prog * 2 >= all) return 2;
            return 0;
        }

        /// <summary>Sets who made a found item and whether it adds to the app's size.</summary>
        static void Classify(InstalledApp a, Leftover l, DirNode node)
        {
            l.Counts = false;
            if (l.IsRegistry) { l.Origin = Leftover.OriginApp; return; }
            bool hasLoc = !string.IsNullOrEmpty(a.Location);
            if (hasLoc && SamePath(l.Path, a.Location)) { l.Origin = Leftover.OriginApp; return; }   // counted in ProgramSize
            if (l.Kind == "Shortcut" || l.Kind == "Start menu folder") { l.Origin = Leftover.OriginApp; l.Counts = true; return; }
            int area;
            string kind = AreaOf(l.Path, out area);
            if (string.IsNullOrEmpty(l.Kind)) l.Kind = kind;
            if (area == AreaUser || area == AreaOther)
            {
                int v = node != null ? ContentVerdict(node) : area == AreaUser ? 1 : 0;
                l.Origin = v == 1 ? Leftover.OriginUser : v == 2 ? Leftover.OriginApp : Leftover.OriginUnsure;
                if (l.Origin != Leftover.OriginApp) l.Match = Leftover.NameOnly;
            }
            else l.Origin = area == AreaTemp ? Leftover.OriginCache : Leftover.OriginApp;
            l.Counts = l.Origin == Leftover.OriginApp || l.Origin == Leftover.OriginCache;
            if (l.Shared > 1) l.Counts = false;
            if (hasLoc && (IsWithin(l.Path, a.Location) || IsWithin(a.Location, l.Path))) l.Counts = false;
            // Without a measured program folder the registry's estimate already covers the program files.
            if (area == AreaProgram && (!hasLoc || a.SizeEstimated)) l.Counts = false;
            // A Store app's package data is already in its program size.
            if (a.IsStore && !string.IsNullOrEmpty(a.PackageFamilyName) &&
                IsWithin(l.Path, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Packages", a.PackageFamilyName))) l.Counts = false;
        }

        /// <summary>Can be checked and deleted: only once the app is uninstalled (nothing of an installed app is deleted).</summary>
        static bool Removable(InstalledApp a, Leftover l) { return a.Uninstalled; }

        /// <summary>Folder names of caches apps fill on their own and make again when needed (normalised).</summary>
        static readonly HashSet<string> CacheNames = new HashSet<string>
        {
            "cache", "caches", "cachedata", "cachestorage", "codecache", "gpucache", "shadercache", "dawncache", "dawnwebgpucache",
            "dawngraphitecache", "grshadercache", "graphitedawncache", "webcache", "httpcache", "imagecache"
        };

        /// <summary>
        /// Suggestions: "Apps' cache", one location per cache folder of an installed app (its contents, the folder stays).
        /// Only in the app's own data folders (AppData, ProgramData, hidden profile folders), never in a program folder,
        /// never in a folder another app's name matches too, and nothing another suggestion already covers (browsers, Temp,
        /// developer caches). Runs on a background thread, from the scan index.
        /// </summary>
        void AppCaches(List<DirNode> scanned, List<InstalledApp> installed, List<Suggestion> list)
        {
            if (installed == null || installed.Count == 0 || scanned == null || scanned.Count == 0) return;
            var covered = list.SelectMany(x => x.Targets).Where(t => !t.RecycleBin && !string.IsNullOrEmpty(t.Path)).Select(t => t.Path.TrimEnd('\\')).ToList();
            var programs = installed.Where(a => !string.IsNullOrEmpty(a.Location)).Select(a => a.Location.TrimEnd('\\')).ToList();
            Func<string, bool> taken = p => covered.Any(c => IsWithin(p, c) || IsWithin(c, p)) || programs.Any(loc => IsWithin(p, loc));
            string progData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            var s = new Suggestion
            {
                Name = "Apps' cache", Safe = true,
                Note = "Files installed apps keep to start and load faster. They are made again when needed; close the app first so files in use can go too."
            };
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var hits = FindAppFolders(scanned, installed, null);
            foreach (var a in installed)
                foreach (var l in hits.Of(a))
                {
                    if (l.Shared > 1) continue;
                    var node = hits.Nodes[l];
                    int area;
                    AreaOf(l.Path, out area);
                    if (area != AreaApp || node.Children == null || programs.Any(loc => IsWithin(l.Path, loc) || IsWithin(loc, l.Path))) continue;
                    var stack = new Stack<KeyValuePair<DirNode, int>>();
                    foreach (var c in node.Children) stack.Push(new KeyValuePair<DirNode, int>(c, 1));
                    while (stack.Count > 0)
                    {
                        var e = stack.Pop();
                        var d = e.Key;
                        if (SkipFolders.Contains(d.Name)) continue;
                        if (CacheNames.Contains(Norm(d.Name)))
                        {
                            string p = d.FullPath;
                            if (d.Size >= 1L << 20 && !taken(p) && seen.Add(p))
                            {
                                s.Targets.Add(new DeleteTarget { Path = p, Label = a.Name + " - " + d.Name, IsDir = true, ContentsOnly = true, Size = d.Size, Dir = d, Note = a.Name });
                                s.Size += d.Size;
                                if (IsWithin(p, progData)) s.NeedsAdmin = true;
                            }
                            continue;
                        }
                        if (e.Value < 5 && d.Children != null) foreach (var c in d.Children) stack.Push(new KeyValuePair<DirNode, int>(c, e.Value + 1));
                    }
                }
            if (s.Targets.Count == 0) return;
            s.Location = s.Targets.Count == 1 ? s.Targets[0].Path : string.Format("{0:N0} locations", s.Targets.Count);
            list.Add(s);
        }

        /// <summary>Total size of items, each byte once (items inside another listed item are part of it).</summary>
        static long LeftoverTotal(IEnumerable<Leftover> items) { return items.Where(l => l.Inside == null).Sum(l => l.Size); }

        /// <summary>The app's size again from its program folder and the found folders it made.</summary>
        static void RecountSize(InstalledApp a, List<Leftover> found)
        {
            if (a.Uninstalled || found == null || a.ProgramSize <= 0) return;   // no measured program size: keep the size it has
            a.Size = a.ProgramSize + found.Where(l => l.Counts && l.Inside == null && !l.IsRegistry).Sum(l => l.Size);
        }
    }
}

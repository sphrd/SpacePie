using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace SpacePie
{
    /// <summary>Folder sizes of an earlier scan (folders only, no file names), kept to show what changed since.</summary>
    internal sealed class PrevNode
    {
        public string Name;
        public long Bytes, Alloc, Files;
        public Dictionary<string, PrevNode> Children;

        public long Size { get { return DirNode.OnDisk ? Alloc : Bytes; } }

        public PrevNode Child(string name)
        {
            PrevNode c;
            return Children != null && Children.TryGetValue(name, out c) ? c : null;
        }
    }

    /// <summary>
    /// Saves a compact copy of every full scan (folder names and sizes, gzip) in %LOCALAPPDATA%\SpacePie\history,
    /// one file per scanned drive or folder, and loads the previous one for comparison. Nothing leaves the computer.
    /// </summary>
    internal static class History
    {
        const int Magic = 0x31415344;   // "DSA1"
        const int MaxFiles = 10;

        public static string Folder
        {
            get { return AppData.Path("history"); }
        }

        static string FileFor(string rootPath)
        {
            var sb = new StringBuilder();
            foreach (char c in rootPath.TrimEnd('\\').ToLowerInvariant()) sb.Append(char.IsLetterOrDigit(c) ? c : '_');
            return Path.Combine(Folder, sb + ".dsa");
        }

        public static PrevNode Load(string rootPath, out DateTime when)
        {
            return LoadFile(FileFor(rootPath), out when);
        }

        /// <summary>Reads a saved folder tree (the last full scan, or an archived one); null if missing or unreadable.</summary>
        public static PrevNode LoadFile(string f, out DateTime when)
        {
            when = DateTime.MinValue;
            if (!File.Exists(f)) return null;
            try
            {
                using (var fs = File.OpenRead(f))
                using (var gz = new GZipStream(fs, CompressionMode.Decompress))
                using (var r = new BinaryReader(gz, Encoding.UTF8))
                {
                    if (r.ReadInt32() != Magic) return null;
                    when = DateTime.FromFileTimeUtc(r.ReadInt64()).ToLocalTime();
                    r.ReadString();
                    return ReadNode(r);
                }
            }
            catch (Exception) { return null; }
        }

        static PrevNode ReadNode(BinaryReader r)
        {
            // Iterative: very deep trees would overflow the stack.
            var root = new PrevNode();
            var stack = new Stack<KeyValuePair<PrevNode, int>>();
            int children = Fill(r, root);
            stack.Push(new KeyValuePair<PrevNode, int>(root, children));
            while (stack.Count > 0)
            {
                var top = stack.Pop();
                if (top.Value == 0) continue;
                stack.Push(new KeyValuePair<PrevNode, int>(top.Key, top.Value - 1));
                var c = new PrevNode();
                int cc = Fill(r, c);
                if (top.Key.Children == null) top.Key.Children = new Dictionary<string, PrevNode>(StringComparer.OrdinalIgnoreCase);
                top.Key.Children[c.Name] = c;
                stack.Push(new KeyValuePair<PrevNode, int>(c, cc));
            }
            return root;
        }

        static int Fill(BinaryReader r, PrevNode n)
        {
            n.Name = r.ReadString();
            n.Bytes = r.ReadInt64();
            n.Alloc = r.ReadInt64();
            n.Files = r.ReadInt64();
            return r.ReadInt32();
        }

        public static void Save(string rootPath, DirNode root)
        {
            Directory.CreateDirectory(Folder);
            string f = FileFor(rootPath), tmp = f + ".tmp";
            using (var fs = File.Create(tmp))
            using (var gz = new GZipStream(fs, CompressionLevel.Fastest))
            using (var w = new BinaryWriter(gz, Encoding.UTF8))
            {
                w.Write(Magic);
                w.Write(DateTime.UtcNow.ToFileTimeUtc());
                w.Write(rootPath);
                foreach (var d in root.Descendants())   // pre-order, children in list order
                {
                    w.Write(d.Name ?? "");
                    w.Write(d.Bytes);
                    w.Write(d.Alloc);
                    w.Write(d.Files);
                    w.Write(d.Children != null ? d.Children.Count : 0);
                }
            }
            if (File.Exists(f)) File.Delete(f);
            File.Move(tmp, f);
            // Only the last scan of each drive or folder is kept, and only for the 10 most recently scanned ones.
            try
            {
                foreach (var old in new DirectoryInfo(Folder).GetFiles("*.dsa").OrderByDescending(x => x.LastWriteTimeUtc).Skip(MaxFiles)) old.Delete();
            }
            catch (Exception) { }
        }

        // ---------------------------------------------------------------- timeline and archived scans

        /// <summary>Totals of one scan, for the timeline (56 bytes each, at most 1,000 per drive or folder).</summary>
        public sealed class Point
        {
            public DateTime When;
            public long Bytes, Alloc, Files, Dirs, Total, Free;
            public long Size { get { return DirNode.OnDisk ? Alloc : Bytes; } }
        }

        const int MaxPoints = 1000;
        /// <summary>Archived scans per drive or folder: at most one per day, the last 12 days with a scan.</summary>
        const int MaxArchived = 12;
        /// <summary>Archived scans keep only folders of at least this size (smaller ones never make the Changes list anyway).</summary>
        const long ArchiveMinFolder = 4L << 20;

        static string Key(string rootPath)
        {
            var sb = new StringBuilder();
            foreach (char c in rootPath.TrimEnd('\\').ToLowerInvariant()) sb.Append(char.IsLetterOrDigit(c) ? c : '_');
            return sb.ToString();
        }

        static string TimelineFile(string rootPath) { return Path.Combine(Folder, Key(rootPath) + ".timeline"); }

        static string ArchiveDir(string rootPath) { return Path.Combine(Folder, Key(rootPath)); }

        /// <summary>Adds this scan's totals to the drive's or folder's timeline (older points beyond 1,000 are dropped).</summary>
        public static void AppendTimeline(string rootPath, DirNode root, long total, long free)
        {
            Directory.CreateDirectory(Folder);
            string f = TimelineFile(rootPath);
            var pts = Timeline(rootPath);
            pts.Add(new Point { When = DateTime.Now, Bytes = root.Bytes, Alloc = root.Alloc, Files = root.Files, Dirs = root.Dirs, Total = total, Free = free });
            if (pts.Count > MaxPoints) pts.RemoveRange(0, pts.Count - MaxPoints);
            string tmp = f + ".tmp";
            using (var w = new BinaryWriter(File.Create(tmp)))
                foreach (var p in pts)
                {
                    w.Write(p.When.ToUniversalTime().ToBinary()); w.Write(p.Bytes); w.Write(p.Alloc); w.Write(p.Files);
                    w.Write(p.Dirs); w.Write(p.Total); w.Write(p.Free);
                }
            if (File.Exists(f)) File.Delete(f);
            File.Move(tmp, f);
        }

        /// <summary>Every recorded scan of the drive or folder, oldest first.</summary>
        public static List<Point> Timeline(string rootPath)
        {
            var list = new List<Point>();
            string f = TimelineFile(rootPath);
            if (!File.Exists(f)) return list;
            try
            {
                using (var r = new BinaryReader(File.OpenRead(f)))
                    while (r.BaseStream.Position + 56 <= r.BaseStream.Length)
                        list.Add(new Point
                        {
                            When = DateTime.FromBinary(r.ReadInt64()).ToLocalTime(), Bytes = r.ReadInt64(), Alloc = r.ReadInt64(), Files = r.ReadInt64(),
                            Dirs = r.ReadInt64(), Total = r.ReadInt64(), Free = r.ReadInt64()
                        });
            }
            catch (Exception) { }
            return list;
        }

        /// <summary>
        /// Keeps a small copy of this scan (folders of 4 MB or more, names and sizes) for comparing any two scans later. One per
        /// day: a later scan the same day replaces it. Only the last 12 are kept, for the 10 most recently scanned drives/folders.
        /// </summary>
        public static void Archive(string rootPath, DirNode root)
        {
            string dir = ArchiveDir(rootPath);
            Directory.CreateDirectory(dir);
            var now = DateTime.Now;
            foreach (var old in new DirectoryInfo(dir).GetFiles("*.dsa"))
            {
                DateTime t;
                if (TryParseArchiveName(old.Name, out t) && t.Date == now.Date) try { old.Delete(); } catch (Exception) { }
            }
            string f = Path.Combine(dir, now.ToString("yyyyMMdd-HHmmss") + ".dsa"), tmp = f + ".tmp";
            using (var fs = File.Create(tmp))
            using (var gz = new GZipStream(fs, CompressionLevel.Fastest))
            using (var w = new BinaryWriter(gz, Encoding.UTF8))
            {
                w.Write(Magic);
                w.Write(DateTime.UtcNow.ToFileTimeUtc());
                w.Write(rootPath);
                var stack = new Stack<DirNode>();
                stack.Push(root);
                while (stack.Count > 0)
                {
                    var d = stack.Pop();
                    var kids = d.Children == null ? new List<DirNode>() : d.Children.Where(c => Math.Max(c.Bytes, c.Alloc) >= ArchiveMinFolder).ToList();
                    w.Write(d.Name ?? "");
                    w.Write(d.Bytes);
                    w.Write(d.Alloc);
                    w.Write(d.Files);
                    w.Write(kids.Count);
                    for (int i = kids.Count - 1; i >= 0; i--) stack.Push(kids[i]);
                }
            }
            File.Move(tmp, f);
            try
            {
                foreach (var old in new DirectoryInfo(dir).GetFiles("*.dsa").OrderByDescending(x => x.Name, StringComparer.Ordinal).Skip(MaxArchived)) old.Delete();
                // Drives or folders not scanned for a long time lose their archive and timeline (like the last-scan files).
                foreach (var od in new DirectoryInfo(Folder).GetDirectories().OrderByDescending(x => x.LastWriteTimeUtc).Skip(MaxFiles))
                {
                    try { File.Delete(Path.Combine(Folder, od.Name + ".timeline")); } catch (Exception) { }
                    od.Delete(true);
                }
            }
            catch (Exception) { }
        }

        static bool TryParseArchiveName(string name, out DateTime when)
        {
            return DateTime.TryParseExact(Path.GetFileNameWithoutExtension(name), "yyyyMMdd-HHmmss", System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.None, out when);
        }

        /// <summary>The archived scans of a drive or folder (time, file), newest first.</summary>
        public static List<KeyValuePair<DateTime, string>> Archived(string rootPath)
        {
            var list = new List<KeyValuePair<DateTime, string>>();
            string dir = ArchiveDir(rootPath);
            if (!Directory.Exists(dir)) return list;
            try
            {
                foreach (var f in new DirectoryInfo(dir).GetFiles("*.dsa"))
                {
                    DateTime t;
                    if (TryParseArchiveName(f.Name, out t)) list.Add(new KeyValuePair<DateTime, string>(t, f.FullName));
                }
            }
            catch (Exception) { }
            list.Sort((a, b) => b.Key.CompareTo(a.Key));
            return list;
        }
    }

    internal sealed partial class MainForm
    {

        /// <summary>After a full scan: keep the previous scan for comparison and save this one (in the background).</summary>
        void RememberScan(ScanRoot r, DirNode result, bool complete)
        {
            if (!complete || r.ReadOnly) return;
            string path = r.Path;
            long total = r.Total, free = r.Free;
            Task.Factory.StartNew(() =>
            {
                DateTime when;
                var prev = History.Load(path, out when);
                try { History.Save(path, result); } catch (Exception) { }
                // The timeline gets every scan (a few bytes); the archive one small copy per day.
                try { History.AppendTimeline(path, result, total, free); } catch (Exception) { }
                try { History.Archive(path, result); } catch (Exception) { }
                return new KeyValuePair<PrevNode, DateTime>(prev, when);
            }).ContinueWith(t =>
            {
                if (IsDisposed || t.IsFaulted) return;
                if (r.Previous == null || t.Result.Key != null) { r.Previous = t.Result.Key; r.PreviousTime = t.Result.Value; }
                if (current != null && current.Top == r.Node && ActivePage == pContents) ShowContents(current);
                pChanges.Stale = true;
                if (ActivePage == pChanges) { pChanges.Stale = false; FillChanges(); }
            }, TaskScheduler.FromCurrentSynchronizationContext());
        }

        /// <summary>The previous scan's node for a scanned folder (null when unknown).</summary>
        PrevNode PrevOf(DirNode d)
        {
            var r = d != null ? RootOf(d.Top) : null;
            if (r == null || r.Previous == null) return null;
            var chain = new List<DirNode>();
            for (var n = d; n.Parent != null; n = n.Parent) chain.Add(n);
            var p = r.Previous;
            for (int i = chain.Count - 1; i >= 0 && p != null; i--) p = p.Child(chain[i].Name);
            return p;
        }

        /// <summary>Change of each child folder of d since the previous scan, for the Change column.</summary>
        void SetChanges(DirNode d, List<ItemInfo> items)
        {
            var prev = PrevOf(d);
            if (prev == null) return;
            foreach (var it in items)
            {
                if (!it.IsDir) continue;
                var pc = prev.Child(it.Dir.Name);
                it.Change = pc != null ? it.Dir.Size - pc.Size : it.Dir.Size;
                if (pc == null) it.Note = "new";
            }
        }

        static string ChangeText(ItemInfo it)
        {
            if (it.Change == long.MinValue) return "";
            if (it.Note == "new") return "new";
            if (it.Change == 0) return "-";
            return (it.Change > 0 ? "+" : "-") + Fmt.Size(Math.Abs(it.Change));
        }

        string ChangeCaption(DirNode d)
        {
            var r = RootOf(d.Top);
            var prev = PrevOf(d);
            if (r == null || prev == null) return "";
            long delta = d.Size - prev.Size;
            if (delta == 0) return string.Format("  -  no change since the scan of {0:yyyy-MM-dd HH:mm}", r.PreviousTime);
            return string.Format("  -  {0}{1} since the scan of {2:yyyy-MM-dd HH:mm}", delta >= 0 ? "+" : "-", Fmt.Size(Math.Abs(delta)), r.PreviousTime);
        }

        // ---------------------------------------------------------------- comparing any two scans

        /// <summary>One side of a comparison: a folder of the scan in memory (Dir) or of a saved scan (Prev).</summary>
        sealed class Side
        {
            public DirNode Dir;
            public PrevNode Prev;

            public static Side Of(DirNode d) { return d != null ? new Side { Dir = d } : null; }
            public static Side Of(PrevNode p) { return p != null ? new Side { Prev = p } : null; }

            public string Name { get { return Dir != null ? Dir.Name : Prev.Name; } }
            public long Size { get { return Dir != null ? Dir.Size : Prev.Size; } }

            public IEnumerable<Side> Kids()
            {
                if (Dir != null) { if (Dir.Children != null) foreach (var c in Dir.Children) yield return Of(c); }
                else if (Prev.Children != null) foreach (var c in Prev.Children.Values) yield return Of(c);
            }

            public Side Child(string name) { return Dir != null ? Of(Dir.Child(name)) : Of(Prev.Child(name)); }
        }

        /// <summary>A scan that can be compared: the one in memory now, the previous full scan, or an archived one.</summary>
        sealed class ScanChoice
        {
            public string Label;
            public DateTime When;
            public bool Now, Previous;
            public string File;      // archived scan
        }

        ChoiceBox changeFrom, changeTo;
        HistoryStrip historyStrip;
        List<ScanChoice> fromChoices = new List<ScanChoice>(), toChoices = new List<ScanChoice>();
        readonly Dictionary<string, PrevNode> archiveCache = new Dictionary<string, PrevNode>(StringComparer.OrdinalIgnoreCase);
        ScanRoot changesRoot;

        Page BuildChangesPage()
        {
            var list = NewList(new[] { "Folder", "Change", "Now", "Before" },
                new[] { "name", "change", "size", "files" }, new[] { 380, 100, 90, 90 }, -1);
            changeFrom = new ChoiceBox("From: ", "Previous scan");
            changeTo = new ChoiceBox("To: ", "Now");
            tips.SetToolTip(changeFrom, "The earlier scan to compare: the previous scan in full, or one kept per day (folders of 4 MB or more)");
            tips.SetToolTip(changeTo, "The later scan: this one, or a kept earlier one");
            changeFrom.SelectedIndexChanged += (s, e) => FillChanges();
            changeTo.SelectedIndexChanged += (s, e) => FillChanges();
            var p = AddPage("Changes", list, MakeBar(changeFrom, changeTo));
            historyStrip = new HistoryStrip { Dock = DockStyle.Top };
            historyStrip.PointClicked += when =>
            {
                // Clicking a day on the timeline compares from that day's kept scan.
                int k = fromChoices.FindIndex(c => !c.Now && c.When.Date == when.Date);
                if (k >= 0) changeFrom.SelectedIndex = k;
            };
            // Docked between the From / To bar and the list (index 0 docks last: list, spacer, strip, bar, caption).
            p.Root.Controls.Add(historyStrip);
            p.Root.Controls.SetChildIndex(historyStrip, 2);
            p.ChartTitle = "Growth";
            p.ChartScope = "of the growth";
            p.Empty = "Nothing grew since the previous scan.";
            p.Fill = FillChanges;
            return p;
        }

        /// <summary>Lists the scans of the active drive or folder in the From / To boxes, keeping the choices when possible.</summary>
        void LoadScanChoices(ScanRoot r)
        {
            var oldFrom = changesRoot == r && changeFrom.SelectedIndex < fromChoices.Count ? fromChoices[changeFrom.SelectedIndex] : null;
            var oldTo = changesRoot == r && changeTo.SelectedIndex < toChoices.Count ? toChoices[changeTo.SelectedIndex] : null;
            changesRoot = r;
            var archived = History.Archived(r.Path)
                // The copy kept of the scan in memory is "Now", not an earlier scan.
                .Where(a => r.Scanned == DateTime.MinValue || Math.Abs((a.Key - r.Scanned).TotalMinutes) > 2).ToList();
            fromChoices = new List<ScanChoice>();
            if (r.Previous != null)
                fromChoices.Add(new ScanChoice { Previous = true, When = r.PreviousTime, Label = "Previous scan, " + r.PreviousTime.ToString("yyyy-MM-dd HH:mm") });
            foreach (var a in archived)
                if (r.Previous == null || Math.Abs((a.Key - r.PreviousTime).TotalMinutes) > 2)
                    fromChoices.Add(new ScanChoice { File = a.Value, When = a.Key, Label = a.Key.ToString("yyyy-MM-dd HH:mm") });
            fromChoices.Sort((a, b) => b.When.CompareTo(a.When));
            toChoices = new List<ScanChoice> { new ScanChoice { Now = true, When = r.Scanned, Label = "Now (this scan)" } };
            toChoices.AddRange(fromChoices.Where(c => !c.Previous || r.Previous != null));
            int fi = oldFrom != null ? fromChoices.FindIndex(c => c.When == oldFrom.When) : -1;
            int ti = oldTo != null ? toChoices.FindIndex(c => c.When == oldTo.When && c.Now == oldTo.Now) : -1;
            changeFrom.SetChoices(fromChoices.Count > 0 ? fromChoices.Select(c => c.Label).ToArray() : new[] { "No earlier scan yet" }, Math.Max(0, fi));
            changeTo.SetChoices(toChoices.Select(c => c.Label).ToArray(), Math.Max(0, ti));
            changeFrom.Enabled = fromChoices.Count > 1;
            changeTo.Enabled = toChoices.Count > 1;
        }

        Side SideFor(ScanChoice c, ScanRoot r)
        {
            if (c == null) return null;
            if (c.Now) return Side.Of(r.Node);
            if (c.Previous) return Side.Of(r.Previous);
            PrevNode p;
            if (!archiveCache.TryGetValue(c.File, out p))
            {
                DateTime when;
                p = History.LoadFile(c.File, out when);
                if (archiveCache.Count > 8) archiveCache.Clear();
                archiveCache[c.File] = p;
            }
            return Side.Of(p);
        }

        void FillChanges()
        {
            var p = pChanges;
            var r = active;
            p.ChartTitle = "Growth";
            if (r != null && r.Node != null && !r.ReadOnly)
            {
                LoadScanChoices(r);
                var points = History.Timeline(r.Path);
                historyStrip.SetPoints(points, r.IsDrive);
                historyStrip.Visible = points.Count > 0;
            }
            else historyStrip.Visible = false;
            if (r == null || r.Node == null || r.ReadOnly || fromChoices.Count == 0)
            {
                p.Caption.Text = r == null || r.Node == null ? "Nothing scanned yet."
                    : r.ReadOnly ? "A saved scan opened from a file has no history here. Open the drive or folder itself to see what changed."
                    : "No earlier scan of " + r.Path + " to compare with yet. Every full scan is remembered; scan again later to see what changed.";
                p.ChartSub = "";
                p.Empty = "No earlier scan to compare with.";
                SetRows(p.List, new List<ListViewItem>(), "No earlier scan of this drive or folder to compare with yet.\nScan it again later to see which folders grew or shrank.");
                if (ActivePage == p) RefreshChart();
                return;
            }
            var from = fromChoices[Math.Min(changeFrom.SelectedIndex, fromChoices.Count - 1)];
            var to = toChoices[Math.Min(changeTo.SelectedIndex, toChoices.Count - 1)];
            historyStrip.Mark(from.When, to.Now ? DateTime.Now : to.When);
            if (!to.Now && to.When <= from.When)
            {
                p.Caption.Text = "Pick a later scan in To than in From.";
                SetRows(p.List, new List<ListViewItem>(), "The To scan must be later than the From scan.");
                p.ChartSub = "";
                if (ActivePage == p) RefreshChart();
                return;
            }
            var a = SideFor(from, r);
            var b = SideFor(to, r);
            if (a == null || b == null)
            {
                p.Caption.Text = "That scan could not be read.";
                SetRows(p.List, new List<ListViewItem>(), "That scan could not be read.");
                if (ActivePage == p) RefreshChart();
                return;
            }
            // A folder is listed when its change is big enough and not mostly explained by one of its subfolders.
            long threshold = Math.Max(10L << 20, b.Size / 1000);
            var found = new List<Tuple<Side, Side, string>>();
            var removed = new List<KeyValuePair<string, Side>>();
            var stack = new Stack<Tuple<Side, Side, string>>();
            stack.Push(Tuple.Create(b, a, r.Node.FullPath));
            while (stack.Count > 0)
            {
                var kv = stack.Pop();
                Side d = kv.Item1, pn = kv.Item2;
                long delta = d.Size - (pn != null ? pn.Size : 0);
                if (Math.Abs(delta) < threshold) continue;
                bool explained = false;
                foreach (var c in d.Kids())
                {
                    var pc = pn != null ? pn.Child(c.Name) : null;
                    long cd = c.Size - (pc != null ? pc.Size : 0);
                    if (Math.Abs(cd) >= threshold) stack.Push(Tuple.Create(c, pc, Native.Join(kv.Item3, c.Name)));
                    if (Math.Abs(cd) >= Math.Abs(delta) * 0.8 && Math.Sign(cd) == Math.Sign(delta)) explained = true;
                }
                if (pn != null)
                    foreach (var pc in pn.Kids())
                        if (d.Child(pc.Name) == null && pc.Size >= threshold)
                        {
                            removed.Add(new KeyValuePair<string, Side>(Native.Join(kv.Item3, pc.Name), pc));
                            if (pc.Size >= Math.Abs(delta) * 0.8 && delta < 0) explained = true;
                        }
                if (!explained) found.Add(kv);
            }
            var rows = new List<ListViewItem>();
            long grew = 0, shrank = 0;
            foreach (var kv in found.OrderByDescending(x => Math.Abs(x.Item1.Size - (x.Item2 != null ? x.Item2.Size : 0))).Take(500))
            {
                long before = kv.Item2 != null ? kv.Item2.Size : 0, delta = kv.Item1.Size - before;
                // Folders of the scan in memory can be opened; folders of a kept scan are only named.
                var it = kv.Item1.Dir != null ? ItemInfo.ForDir(kv.Item1.Dir, 0) : new ItemInfo { FolderIcon = true, Path = kv.Item3, Size = kv.Item1.Size };
                it.Name = kv.Item3;
                it.Change = delta;
                it.Files = before;
                it.ChartValue = Math.Max(0, delta);
                if (kv.Item2 == null) it.Note = "new";
                if (delta > 0) grew += delta; else shrank -= delta;
                rows.Add(Row(it, it.Name, ChangeText(it), Fmt.Size(kv.Item1.Size), kv.Item2 != null ? Fmt.Size(before) : "new"));
            }
            foreach (var kv in removed.OrderByDescending(x => x.Value.Size).Take(100))
            {
                var it = new ItemInfo { Name = kv.Key, Change = -kv.Value.Size, Files = kv.Value.Size, FolderIcon = true, ChartValue = 0, IsSummary = false };
                shrank += kv.Value.Size;
                var lvi = Row(it, it.Name, ChangeText(it), to.Now ? "removed" : "removed or small", Fmt.Size(kv.Value.Size));
                lvi.ForeColor = Theme.MUTED;
                rows.Add(lvi);
            }
            rows.Sort((x, y) => { var i1 = (ItemInfo)x.Tag; var i2 = (ItemInfo)y.Tag; return Math.Abs(i2.Change).CompareTo(Math.Abs(i1.Change)); });
            long total = b.Size - a.Size;
            string span = to.Now ? string.Format("Since the scan of {0:yyyy-MM-dd HH:mm}", from.When)
                : string.Format("From {0:yyyy-MM-dd HH:mm} to {1:yyyy-MM-dd HH:mm}", from.When, to.When);
            SetRows(p.List, rows, "No folder changed by more than " + Fmt.Size(threshold) + " " + (to.Now ? "since that scan." : "between these scans."));
            p.Caption.Text = string.Format("{0}: {1}{2} in total  -  folders that changed by {3} or more (grew {4}, shrank {5}).",
                span, total >= 0 ? "+" : "-", Fmt.Size(Math.Abs(total)), Fmt.Size(threshold), Fmt.Size(grew), Fmt.Size(shrank));
            p.ChartSub = string.Format("+{0} {1}", Fmt.Size(grew), to.Now ? "since " + from.When.ToString("yyyy-MM-dd") : "from " + from.When.ToString("yyyy-MM-dd") + " to " + to.When.ToString("yyyy-MM-dd"));
            p.ChartTotal = 0;
            p.Empty = to.Now ? "Nothing grew since that scan." : "Nothing grew between these scans.";
            if (ActivePage == p) RefreshChart();
        }
    }

    /// <summary>
    /// Timeline of a drive's (or folder's) scans: used space (drives) or scanned size (folders) over time, one dot per scan,
    /// the two compared scans marked. Hover shows a scan's date and size; clicking picks the day to compare from.
    /// </summary>
    internal sealed class HistoryStrip : Control
    {
        List<History.Point> points = new List<History.Point>();
        bool drive;
        DateTime markA, markB;
        int hover = -1;
        readonly List<PointF> dots = new List<PointF>();
        public event Action<DateTime> PointClicked;

        public HistoryStrip()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            SetStyle(ControlStyles.Selectable, false);
            BackColor = Theme.SURFACE;
            Font = Theme.FONT_9;
            Height = Theme.S(84);
        }

        public void SetPoints(List<History.Point> pts, bool isDrive)
        {
            points = pts ?? new List<History.Point>();
            drive = isDrive && points.Any(p => p.Total > 0);
            hover = -1;
            Invalidate();
        }

        public void Mark(DateTime a, DateTime b) { markA = a; markB = b; Invalidate(); }

        long Value(History.Point p) { return drive && p.Total > 0 ? p.Total - p.Free : p.Size; }

        int Nearest(DateTime t)
        {
            int best = -1;
            double bd = double.MaxValue;
            for (int i = 0; i < points.Count; i++)
            {
                double d = Math.Abs((points[i].When - t).TotalMinutes);
                if (d < bd) { bd = d; best = i; }
            }
            return best;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(BackColor);
            dots.Clear();
            if (points.Count == 0) return;
            int pad = Theme.S(10), top = Theme.FONT_9.Height + Theme.S(8), bottom = Height - Theme.S(14);
            var plot = new Rectangle(pad, top, Width - 2 * pad, Math.Max(10, bottom - top));
            using (var b = new SolidBrush(Theme.BG)) g.FillRectangle(b, plot);
            long min = points.Min(x => Value(x)), max = points.Max(x => Value(x));
            if (max == min) { max += 1L << 30; min = Math.Max(0, min - (1L << 30)); }
            DateTime t0 = points[0].When, t1 = points[points.Count - 1].When;
            double span = Math.Max(1, (t1 - t0).TotalSeconds);
            for (int i = 0; i < points.Count; i++)
            {
                float x = points.Count == 1 ? plot.X + plot.Width / 2f : plot.X + Theme.S(6) + (float)((points[i].When - t0).TotalSeconds / span) * (plot.Width - Theme.S(12));
                float y = plot.Bottom - Theme.S(5) - (float)((double)(Value(points[i]) - min) / (max - min)) * (plot.Height - Theme.S(10));
                dots.Add(new PointF(x, y));
            }
            g.SmoothingMode = SmoothingMode.AntiAlias;
            if (dots.Count > 1)
                using (var pen = new Pen(Theme.ACCENT, Math.Max(1.5f, 1.5f * Theme.Scale)) { LineJoin = LineJoin.Round })
                    g.DrawLines(pen, dots.ToArray());
            int ia = markA != DateTime.MinValue ? Nearest(markA) : -1, ib = markB != DateTime.MinValue ? Nearest(markB) : -1;
            for (int i = 0; i < dots.Count; i++)
            {
                bool marked = i == ia || i == ib;
                float rad = Theme.S(marked || i == hover ? 5 : 3);
                using (var b = new SolidBrush(marked ? Theme.ACCENT_LIGHT : i == hover ? Theme.FG : Theme.ACCENT))
                    g.FillEllipse(b, dots[i].X - rad, dots[i].Y - rad, 2 * rad, 2 * rad);
            }
            g.SmoothingMode = SmoothingMode.Default;
            const TextFormatFlags f = TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding;
            string title = (drive ? "Used space" : "Size") + string.Format(" over {0:N0} scan{1}", points.Count, points.Count == 1 ? "" : "s");
            TextRenderer.DrawText(g, title, Font, new Point(pad, Theme.S(4)), Theme.MUTED, f);
            int show = hover >= 0 ? hover : points.Count - 1;
            var p = points[show];
            string info = string.Format("{0:yyyy-MM-dd HH:mm}  -  {1}{2}", p.When, Fmt.Size(Value(p)), drive && p.Total > 0 ? " used, " + Fmt.Size(p.Free) + " free" : "");
            TextRenderer.DrawText(g, info, Font, new Rectangle(pad, Theme.S(4), Width - 2 * pad, Font.Height), hover >= 0 ? Theme.FG : Theme.MUTED, f | TextFormatFlags.Right);
            TextRenderer.DrawText(g, t0.ToString("yyyy-MM-dd"), Font, new Point(pad, bottom), Theme.MUTED, f);
            if (points.Count > 1)
                TextRenderer.DrawText(g, t1.ToString("yyyy-MM-dd"), Font, new Rectangle(pad, bottom, Width - 2 * pad, Font.Height), Theme.MUTED, f | TextFormatFlags.Right);
        }

        int Hit(Point p)
        {
            int best = -1;
            float bd = Theme.S(12);
            for (int i = 0; i < dots.Count; i++)
            {
                float d = Math.Abs(dots[i].X - p.X);
                if (d <= bd) { bd = d; best = i; }
            }
            return best;
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            int h = Hit(e.Location);
            Cursor = h >= 0 ? Cursors.Hand : Cursors.Default;
            if (h != hover) { hover = h; Invalidate(); }
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            if (hover != -1) { hover = -1; Invalidate(); }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            int h = e.Button == MouseButtons.Left ? Hit(e.Location) : -1;
            if (h >= 0 && PointClicked != null) PointClicked(points[h].When);
        }
    }
}
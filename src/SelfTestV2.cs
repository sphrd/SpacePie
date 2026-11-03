using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SpacePie
{
    /// <summary>Self-test of the v2.0 features (run inside --cli selftest, on the scratch folder's scan).</summary>
    internal sealed partial class MainForm
    {
        async Task SelfTestV2(Action<bool, string> check)
        {
            string dir = SelfTestDir;
            var top = FindScanned(dir, true);

            // Last opened: the folder walk records each file's last-access time (never before its last change).
            {
                var files = top.Descendants().Where(d => d.FileList != null).SelectMany(d => d.FileList).ToList();
                check(files.Count > 0 && files.All(f => f.Accessed > 0 && f.LastUse >= f.Modified),
                    string.Format("last opened: every file has a last-access time ({0} files)", files.Count));
                var flt = new FileFilter { UsedBefore = DateTime.Now.AddYears(-1).ToFileTime() };
                long n, sz;
                FileIndex.Largest(top, 100, flt, out n, out sz);
                check(n == 0, "last opened: \"not opened for 1 year\" finds nothing among files just made (" + n + ")");
            }

            // Search in everything scanned: files and folders by name, across every scanned root.
            {
                var flt = new FileFilter { Patterns = new[] { "node_modules" } };
                long dc;
                var dirs = FileIndex.Folders(roots.Where(r => r.Node != null).Select(r => r.Node), 100, flt, out dc);
                long fc, fs;
                var files = FileIndex.Largest(roots.Where(r => r.Node != null).Select(r => r.Node), 100, new FileFilter { Patterns = new[] { "*.bin" } }, out fc, out fs);
                check(dc >= 1 && dirs.All(d => d.Name.Equals("node_modules", StringComparison.OrdinalIgnoreCase)) && fc >= 1 && files.All(f => f.Name.EndsWith(".bin")),
                    string.Format("search: folders by name ({0} node_modules) and files by pattern ({1} *.bin) in everything scanned", dc, fc));
            }

            // Treemap: rectangles fill the area in true proportion.
            {
                var sizes = new List<double> { 50, 25, 12.5, 6.25, 6.25 };
                var rects = PieChart.Squarify(sizes, new RectangleF(0, 0, 400, 300));
                double area = rects.Sum(r => r.Width * (double)r.Height);
                bool prop = true;
                for (int i = 0; i < sizes.Count; i++) prop &= Math.Abs(rects[i].Width * rects[i].Height / 120000.0 - sizes[i] / 100) < 0.01;
                bool inside = rects.All(r => r.Left >= -0.5 && r.Top >= -0.5 && r.Right <= 400.5 && r.Bottom <= 300.5);
                check(Math.Abs(area - 120000) < 1 && prop && inside, "treemap: rectangles fill the area, each in proportion to its size");
                chart.Treemap = true;
                UpdateChart(top);
                chart.Refresh();
                check(chart.TileCount > 0, "treemap: the folder contents are drawn as " + chart.TileCount + " rectangles");
                chart.Treemap = chartMode.SelectedIndex == 1;
                UpdateChart(top);
            }

            // Back / Forward and the path bar.
            {
                var a = FindScanned(Path.Combine(dir, "A"), true) ?? top.Children[0];
                SelectDir(top);
                SelectDir(a);
                bool crumbOk = crumbs.Count == 3;
                GoBack();
                bool back = current == top;
                GoForward();
                bool fwd = current == a;
                SelectDir(top);
                check(crumbOk && back && fwd, string.Format("navigation: path bar shows This PC and 2 folders, Back returns to the folder before ({0}), Forward goes again ({1})", back, fwd));

                // Contents is a tree-list: a folder expands in place, its rows one level deeper right below it.
                var ex = top.Children.FirstOrDefault(HasContent);
                int before = contents.Items.Count;
                expandedDirs.Add(ex);
                RefillContents();
                int at = contents.Items.Cast<ListViewItem>().ToList().FindIndex(x => ((ItemInfo)x.Tag).Dir == ex);
                bool below = at >= 0 && at + 1 < contents.Items.Count && ((ItemInfo)contents.Items[at + 1].Tag).Depth == 1;
                int grown = contents.Items.Count - before;
                expandedDirs.Remove(ex);
                RefillContents();
                check(ex != null && below && grown > 0 && contents.Items.Count == before, string.Format(
                    "tree-list: expanding {0} shows its {1} rows below it at depth 1, collapsing hides them", ex != null ? ex.Name : "?", grown));

                // Up from the top of a scan leads to This PC (every drive and scanned folder), then disabled.
                GoUp();
                bool pc = thisPc && current == null && contents.Items.Count == roots.Count && !btnUp.Enabled;
                // Only drives count: the scanned test folder shows its own size and gets no chart slice.
                var folderRow = contents.Items.Cast<ListViewItem>().Select(x => (ItemInfo)x.Tag).FirstOrDefault(x => x.Dir == top);
                bool noDouble = folderRow != null && folderRow.Size == top.Size && folderRow.ChartSize == 0;
                check(noDouble, "this pc: a scanned folder shows its own size (" + (folderRow != null ? Fmt.Size(folderRow.Size) : "?") + "), not its drive's, and is not in the chart");
                SelectDir(top);
                check(pc && !thisPc, "this pc: Up from the scanned folder lists the " + roots.Count + " drives and folders; Up is then disabled");
            }

            // Sorting by any column: grouped lists move whole groups and sort members inside them; the order survives refills.
            {
                var lv = new SizeListView();
                lv.SetColumns(new[] { "Name", "Size" }, new[] { "name", "size" }, new[] { 100, 60 });
                lv.Grouped = true;
                Func<List<ListViewItem>> build = () =>
                {
                    var rows = new List<ListViewItem>();
                    foreach (var g in new[] { "Beta", "Alpha", "Gamma" })
                    {
                        var head = new ItemInfo { Name = g, Size = g.Length * 100 };
                        rows.Add(new ListViewItem(new[] { g, "" }) { Tag = head });
                        foreach (var m in new[] { "z", "a", "m" })
                            rows.Add(new ListViewItem(new[] { g + m, "" }) { Tag = new ItemInfo { Name = g + "-" + m, Size = m[0], GroupOf = head } });
                    }
                    return rows;
                };
                lv.Items.AddRange(build().ToArray());
                lv.SortBy(0);
                Func<string> order = () => string.Join(",", lv.Items.Cast<ListViewItem>().Select(x => ((ItemInfo)x.Tag).Name));
                string want = "Alpha,Alpha-a,Alpha-m,Alpha-z,Beta,Beta-a,Beta-m,Beta-z,Gamma,Gamma-a,Gamma-m,Gamma-z";
                bool sorted = order() == want;
                SetRows(lv, build(), "");
                bool kept = order() == want;
                lv.Dispose();
                check(sorted && kept, "sorting: by name moves whole groups and sorts inside them (" + sorted + "), and a refill keeps the order (" + kept + ")");
            }

            // Well-known folders are named, with what to do about them.
            {
                string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
                var k1 = Known.Lookup(win + @"\WinSxS", "WinSxS");
                var k2 = Known.Lookup(@"D:\work\app\node_modules", "node_modules");
                var k3 = Known.Lookup(Path.Combine(dir, "A"), "A");
                check(k1 != null && k1.Verdict == "Keep" && k2 != null && k2.Verdict.StartsWith("Safe") && k3 == null,
                    "known folders: WinSxS = keep, node_modules = safe to delete, an ordinary folder has no label");
            }

            // Folders that could not be read are counted for the banner.
            {
                var fake = new DirNode { Name = "locked", Parent = top, Denied = true };
                top.Children.Add(fake);
                deniedCache.Clear();
                UpdateUnreadBanner(top);
                bool shown = unreadBanner.Visible && unreadBanner.Message.StartsWith("1 folder");
                top.Children.Remove(fake);
                deniedCache.Clear();
                UpdateUnreadBanner(top);
                check(shown && !unreadBanner.Visible, "unreadable: the banner counts folders that could not be read, and hides when there are none");
            }

            // Recycle Bin limits and synced folders are known before deleting.
            {
                var bins = new Dictionary<string, RecycleLimits.Bin>(StringComparer.OrdinalIgnoreCase);
                var bin = RecycleLimits.For(dir);
                string tooBig = RecycleLimits.WouldDeletePermanently(Path.Combine(dir, "x"), bin.Capacity + 1, bins);
                string fits = RecycleLimits.WouldDeletePermanently(Path.Combine(dir, "x"), 1, bins);
                check(!bin.Exists || bin.Off || (bin.Capacity > 0 && tooBig != null && tooBig.Contains("larger") && fits == null),
                    string.Format("recycle bin: {0} holds items up to {1}; a bigger one is reported as deleted permanently", bin.Drive, Fmt.Size(bin.Capacity)));
                var sync = SyncFolders.Roots;
                bool ok = sync.All(r => SyncFolders.ServiceFor(Path.Combine(r.Key, "some file.txt")) != null) && SyncFolders.ServiceFor(dir) == null;
                check(ok, string.Format("synced folders: {0} found ({1}); files in them are recognized, the scratch folder is not",
                    sync.Count, string.Join(", ", sync.Select(r => r.Value).Distinct())));
            }

            // Scan files: saved, opened read-only next to the live scan, never confused with it, then closed.
            {
                string file = Path.Combine(Path.GetDirectoryName(dir.TrimEnd('\\')), Path.GetFileName(dir.TrimEnd('\\')) + Snapshot.ScanFileExtension);
                SaveScanFile(top, file);
                var back = Snapshot.LoadFrom(file);
                bool same = back != null && back.Node.Files == top.Files && back.Node.Dirs == top.Dirs && back.Node.Bytes == top.Bytes &&
                            string.Equals(back.Root, RootOf(top).Path, StringComparison.OrdinalIgnoreCase);
                OpenScanFile(file);
                for (int i = 0; i < 40 && !roots.Any(r => r.ReadOnly); i++) await Task.Delay(100);
                var ro = roots.FirstOrDefault(r => r.ReadOnly);
                bool separate = ro != null && ro.Node != top && FindScanned(dir, true) == top && FindRoot(RootOf(top).Path) == RootOf(top);
                bool guarded = ro != null && ro.Node.Children != null && FromReadOnly(ItemInfo.ForDir(ro.Node.Children[0], 0));
                CloseSavedScan(ro);
                bool closed = !roots.Any(r => r.ReadOnly);
                try { File.Delete(file); } catch (Exception) { }
                check(same && separate && guarded && closed, string.Format(
                    "scan file: saved and read back identical ({0}), opened read-only beside the live scan ({1}), its items can't be deleted ({2}), closed ({3})",
                    same, separate, guarded, closed));
            }

            // History: every scan adds a timeline point; one small copy is kept per day for comparisons.
            {
                for (int i = 0; i < 20 && History.Timeline(RootOf(top).Path).Count == 0; i++) await Task.Delay(250);
                var tl = History.Timeline(RootOf(top).Path);
                var ar = History.Archived(RootOf(top).Path);
                DateTime when;
                var kept = ar.Count > 0 ? History.LoadFile(ar[0].Value, out when) : null;
                check(tl.Count >= 1 && ar.Count == 1 && kept != null && tl.Last().Files > 0,
                    string.Format("history: {0} timeline point(s), {1} kept copy for today, read back ({2})", tl.Count, ar.Count, kept != null));
            }
        }
    }
}

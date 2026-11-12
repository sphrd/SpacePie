using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SpacePie
{
    /// <summary>A known place that usually holds space that can be freed, with what deleting it means.</summary>
    internal sealed class Suggestion
    {
        public string Name, Note, Location;
        public bool Safe;                         // safe = rebuilt or re-downloaded automatically
        public bool NeedsAdmin;
        public List<DeleteTarget> Targets = new List<DeleteTarget>();
        public long Size;
        public bool Expanded;

        /// <summary>0 none, 1 all, 2 some of the targets checked.</summary>
        public int CheckState
        {
            get
            {
                int n = Targets.Count(t => t.Checked);
                return n == 0 ? 0 : n == Targets.Count ? 1 : 2;
            }
        }

        public void Remeasure() { Size = Targets.Sum(t => t.Size); }
    }

    internal sealed partial class MainForm
    {
        int suggestGen;
        List<Suggestion> suggestions;
        /// <summary>The scanned data changed since the suggestions were found (scan, rescan, live change, delete).</summary>
        bool suggestionsDirty;
        DateTime lastSuggestFind = DateTime.MinValue;
        bool suggestFinding;

        /// <summary>
        /// A scan is done: look for space that can be freed right away in the background (next to the installed apps),
        /// so the Suggestions view is ready when it is opened.
        /// </summary>
        void FindSuggestionsAfterScan()
        {
            if (pSuggest == null || SelfTestDir != null || ShotDir != null) return;
            pSuggest.Stale = false;
            FillSuggestions();
        }

        RoundButton btnSugDelete;
        Headline sugHeadline;

        Page BuildSuggestionsPage()
        {
            var refresh = Btn("Refresh", ButtonKind.Secondary, "Look for space that can be freed again", () => { suggestionsDirty = true; FillSuggestions(); });
            refresh.Glyph = Theme.DrawRefresh;
            var all = Btn("Select all", ButtonKind.Secondary, "Check every suggestion and every location in it", () => CheckAllSuggestions(true));
            var none = Btn("Deselect all", ButtonKind.Secondary, "Uncheck everything", () => CheckAllSuggestions(false));
            var expandAll = Btn("Expand all", ButtonKind.Secondary, "Show what every suggestion holds", () => ExpandAllSuggestions(true));
            var collapseAll = Btn("Collapse all", ButtonKind.Secondary, "Close every suggestion and folder", () => ExpandAllSuggestions(false));
            // Full size and next to the amount, apart from the toolbar's Delete permanently (which works on the selection).
            btnSugDelete = Btn("Clean up permanently", ButtonKind.Danger, "Delete the checked items for good, bypassing the Recycle Bin (Ctrl+Shift+D)", () => DeleteCheckedSuggestions(false));
            btnSugDelete.Icon = Icons.Trash;
            btnSugIgnored = Btn("Ignored", ButtonKind.Secondary, "Items you chose never to see again (right-click a suggestion > Never suggest this); stop ignoring them here", ShowIgnoredSuggestions);
            btnSugIgnored.Visible = IgnoreList.Count > 0;
            btnSugIgnored.Text = string.Format("Ignored ({0:N0})...", IgnoreList.Count);
            foreach (var b in new[] { refresh, all, none, expandAll, collapseAll, btnSugIgnored }) b.Compact = true;
            var list = NewList(new[] { "Name", "Size", "% of suggestions", "Location", "What deleting means" },
                new[] { "name", "size", "size", "folder", "note" }, new[] { 260, 90, 150, 300, 420 }, 2);
            list.GlyphClicked += SuggestionGlyph;
            list.Grouped = true;
            list.KeepMemberOrder = true;   // members are a tree, sorted level by level in ShowSuggestions
            list.KeyDown += (s, e) =>
            {
                if (e.KeyCode == Keys.Space) { ToggleSelectedSuggestions(); e.Handled = true; }
                else if (e.KeyCode == Keys.Right || e.KeyCode == Keys.Left) { ExpandSelectedSuggestions(e.KeyCode == Keys.Right); e.Handled = true; }
            };
            var p = AddPage("Suggestions", list, MakeBar(refresh, all, none, expandAll, collapseAll, btnSugIgnored));
            // The amount checked, large and bold in the tab's colour, out of all that was found; the cleanup button at the right.
            sugHeadline = new Headline
            {
                Dock = DockStyle.Top, Font = Theme.FONT_HEADLINE, ForeColor = Theme.SUGGEST, BackColor = Theme.SURFACE,
                Padding = new Padding(S(2), 0, 0, 0), Action = btnSugDelete
            };
            p.Root.Controls.Add(sugHeadline);
            p.ChartTitle = "Cleanup suggestions";
            p.ChartScope = "of the suggestions";
            p.Empty = "Nothing to suggest.";
            p.Fill = FillSuggestions;
            return p;
        }

        void FillSuggestions()
        {
            var p = pSuggest;
            if (suggestions != null && !suggestionsDirty) { ShowSuggestions(); return; }
            // Already looking (started after the scan) and nothing changed since: that search shows its result; meanwhile
            // the chart shows this view (never the previous view's chart).
            if (suggestFinding && !suggestionsDirty) { SuggestionsChartWhileLooking(); return; }
            suggestionsDirty = false;
            lastSuggestFind = DateTime.UtcNow;
            // Keep the user's choices across a new search: ticks by path, expanded suggestions by name.
            var ticks = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            var open = new HashSet<string>();
            if (suggestions != null)
                foreach (var s in suggestions)
                {
                    if (s.Expanded) open.Add(s.Name);
                    foreach (var tg in s.Targets) ticks[tg.RecycleBin ? "<bin>" : tg.Path] = tg.Checked;
                }
            int gen = ++suggestGen;
            // The first time the list says it is looking; later the rows stay while it looks again (no jumping).
            if (suggestions == null)
            {
                p.Caption.Text = "Looking for space that can be freed...";
                if (sugHeadline != null) { sugHeadline.Text = "Looking..."; sugHeadline.Sub = ""; }
                SetRows(p.List, new List<ListViewItem>(), "Looking for space that can be freed...");
            }
            SuggestionsChartWhileLooking();
            UpdateSuggestionButtons();
            var scanned = roots.Where(r => r.Node != null && !r.ReadOnly).Select(r => r.Node).ToList();
            List<Suggestion> found = null;
            suggestFinding = true;
            Task.Factory.StartNew(() => { found = FindSuggestions(scanned); })
                .ContinueWith(t =>
                {
                    if (gen != suggestGen || IsDisposed) return;
                    suggestFinding = false;
                    var before = suggestions;
                    suggestions = StableOrder(t.IsFaulted ? new List<Suggestion>() : found, before);
                    sugRead.Clear();   // folders read for expanded rows outside the scans: read again when shown
                    // Safe suggestions start ticked, "review first" ones unticked; earlier choices are kept.
                    foreach (var s in suggestions)
                    {
                        s.Expanded = open.Contains(s.Name);
                        foreach (var tg in s.Targets)
                        {
                            bool was;
                            tg.Checked = ticks.TryGetValue(tg.RecycleBin ? "<bin>" : tg.Path, out was) ? was : s.Safe;
                        }
                    }
                    ShowSuggestions();
                }, TaskScheduler.FromCurrentSynchronizationContext());
        }

        /// <summary>
        /// The suggestions as a tree: one row per suggestion (chevron, checkbox). Expanded, a suggestion with several
        /// locations shows one row per location (named by its own folder or file); a suggestion of one folder shows what is
        /// in it right away. Folders open further like Contents (subfolders and files, each with its full path). Children
        /// share their suggestion's chart slice. Row order: largest suggestion first.
        /// </summary>
        void ShowSuggestions()
        {
            var p = pSuggest;
            foreach (var s in suggestions) s.Remeasure();
            long total = suggestions.Sum(s => s.Size);
            var lv = p.List;
            string top = lv.TopItem != null ? ((ItemInfo)lv.TopItem.Tag).Name : null;
            var rows = new List<ListViewItem>();
            foreach (var s in suggestions.Where(x => x.Size > 0))
            {
                var shown = s.Targets.Where(x => x.Size > 0).ToList();
                var only = shown.Count == 1 ? shown[0] : null;
                bool oneFolder = only != null && only.IsDir && !only.RecycleBin;
                var head = new ItemInfo
                {
                    Targets = s.Targets, Data = s, Name = s.Name, Size = s.Size, FolderIcon = true, Folder = s.Location,
                    Path = s.Targets.Count == 1 && !s.Targets[0].RecycleBin ? s.Targets[0].Path : null,
                    Note = s.Note + (s.NeedsAdmin && !isAdmin ? "  Needs Run as administrator." : ""),
                    Percent = total > 0 ? 100.0 * s.Size / total : 0, Check = s.CheckState,
                    Expandable = shown.Count > 1 || oneFolder, Expanded = s.Expanded
                };
                var lvi = Row(head, head.Name, Fmt.Size(head.Size), head.Percent.ToString("0.0") + " %", head.Folder, head.Note);
                if (!s.Safe) lvi.ForeColor = Theme.WARN_FG;
                rows.Add(lvi);
                if (!s.Expanded || !head.Expandable) continue;
                if (oneFolder) { AddSuggestionContents(head, only.Path, 0, rows, s.Safe, total); continue; }
                var level = shown.Select(tg => new ItemInfo
                {
                    Targets = new List<DeleteTarget> { tg }, Data = tg, GroupOf = head, Name = tg.Label, Size = tg.Size, TreeRow = true,
                    FolderIcon = tg.IsDir || tg.RecycleBin, Folder = tg.RecycleBin ? "All drives" : tg.Path, Path = tg.RecycleBin ? null : tg.Path,
                    Note = tg.ContentsOnly ? "contents only" : tg.Note, Percent = total > 0 ? 100.0 * tg.Size / total : 0, Check = tg.Checked ? 1 : 0,
                    Expandable = tg.IsDir && !tg.RecycleBin, Expanded = tg.IsDir && !tg.RecycleBin && sugOpenDirs.Contains(tg.Path)
                }).ToList();
                level.Sort(lv.Sorter.Compare);
                foreach (var it in level)
                {
                    var c = Row(it, it.Name, Fmt.Size(it.Size), it.Percent.ToString("0.0") + " %", it.Folder, it.Note);
                    if (!s.Safe) c.ForeColor = Theme.WARN_FG;
                    rows.Add(c);
                    if (it.Expanded) AddSuggestionContents(head, it.Path, 1, rows, s.Safe, total);
                }
            }
            SetRows(lv, rows, "Nothing to suggest: no caches, temporary files or leftovers worth deleting were found.");
            if (top != null)
                foreach (ListViewItem it in lv.Items)
                    if (((ItemInfo)it.Tag).Name == top) { try { lv.TopItem = it; } catch (Exception) { } break; }
            var ticked = CheckedSuggestionTargets();
            sugHeadline.Text = rows.Count == 0 ? "Nothing to free" : Fmt.Size(ticked.Sum(t => t.Size)) + " selected";
            sugHeadline.Sub = rows.Count == 0 ? "" : "out of " + Fmt.Size(total) + " detected";
            p.Caption.Text = rows.Count == 0 ? "No caches, temporary files or leftovers worth deleting were found." : string.Format(
                "Checked: {0:N0} item{1}.  White: safe, rebuilt or downloaded again when needed.  Amber: review first.",
                ticked.Count, ticked.Count == 1 ? "" : "s");
            p.ChartSub = Fmt.Size(total) + " can be freed";
            p.ChartTotal = 0;
            UpdateSuggestionButtons();
            if (ActivePage == p) RefreshChart();
        }

        // Folders opened inside the suggestions (by path), and folders read for them that no scan covers.
        readonly HashSet<string> sugOpenDirs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string, DirNode> sugRead = new Dictionary<string, DirNode>(StringComparer.OrdinalIgnoreCase);
        readonly HashSet<string> sugReading = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        /// <summary>The folder at path from the scans; one outside them is read in the background the first time it is
        /// opened (null meanwhile, then the rows are shown again).</summary>
        DirNode SuggestionDir(string path)
        {
            var n = FindScanned(path, true);
            if (n != null) return n;
            DirNode read;
            if (sugRead.TryGetValue(path, out read)) return read;
            if (sugReading.Add(path))
                Task.Factory.StartNew(() => { try { return new Scanner().Run(path); } catch (Exception) { return null; } })
                    .ContinueWith(t =>
                    {
                        sugReading.Remove(path);
                        if (IsDisposed) return;
                        sugRead[path] = t.Result ?? new DirNode();
                        if (suggestions != null) ShowSuggestions();
                    }, TaskScheduler.FromCurrentSynchronizationContext());
            return null;
        }

        /// <summary>
        /// What is in a folder of a suggestion, as rows at depth (like Contents): subfolders, which open further, and files,
        /// each with its full path; sorted like the list. Plain rows: they are deleted with their suggestion or location.
        /// </summary>
        void AddSuggestionContents(ItemInfo head, string path, int depth, List<ListViewItem> rows, bool safe, long total)
        {
            Func<ItemInfo, ListViewItem> add = it =>
            {
                it.GroupOf = head; it.TreeRow = true; it.Depth = depth;
                var r = Row(it, it.Name, it.IsSummary && it.Size == 0 ? "" : Fmt.Size(it.Size),
                    it.IsSummary ? "" : it.Percent.ToString("0.0") + " %", it.Folder ?? "", it.Note ?? "");
                if (!safe && !it.IsSummary) r.ForeColor = Theme.WARN_FG;
                rows.Add(r);
                return r;
            };
            var d = SuggestionDir(path);
            if (d == null) { add(new ItemInfo { IsSummary = true, Name = "Looking at what is in it..." }); return; }
            var level = new List<ItemInfo>();
            if (d.Children != null) foreach (var c in d.Children) level.Add(ItemInfo.ForDir(c, total));
            var files = Scanner.ListFiles(d);
            files.Sort(FileEntry.BySizeDesc);
            for (int i = 0; i < files.Count && i < MaxFilesShown; i++) level.Add(ItemInfo.ForFile(files[i], total));
            foreach (var it in level) it.Folder = it.FullPath;
            if (level.Count == 0) { add(new ItemInfo { IsSummary = true, Name = d.Denied ? "Can't be read." : "Nothing in it." }); return; }
            level.Sort(pSuggest.List.Sorter.Compare);
            foreach (var it in level)
            {
                if (it.IsDir)
                {
                    it.Expandable = HasContent(it.Dir);
                    it.Expanded = it.Expandable && sugOpenDirs.Contains(it.Dir.FullPath);
                }
                add(it);
                if (it.Expanded) AddSuggestionContents(head, it.Dir.FullPath, depth + 1, rows, safe, total);
            }
            if (files.Count > MaxFilesShown)
            {
                long rest = 0;
                for (int i = MaxFilesShown; i < files.Count; i++) rest += files[i].Size;
                add(new ItemInfo
                {
                    IsSummary = true, Name = string.Format("[{0:N0} smaller files not listed]", files.Count - MaxFilesShown),
                    Size = rest, Percent = total > 0 ? 100.0 * rest / total : 0
                });
            }
        }

        /// <summary>The folder a row opens: a location of a suggestion, or a folder inside one (null for anything else).</summary>
        static string SuggestionFolderOf(ItemInfo info)
        {
            var t = info.Data as DeleteTarget;
            if (t != null) return t.IsDir && !t.RecycleBin ? t.Path : null;
            return info.IsDir && info.Dir != null ? info.Dir.FullPath : null;
        }

        /// <summary>While the suggestions are being looked for: the open view's chart shows the ones found last, or the working
        /// logo the first time.</summary>
        void SuggestionsChartWhileLooking()
        {
            if (ActivePage != pSuggest || scanning) return;
            if (pSuggest.List.Items.Count > 0) { RefreshChart(); return; }
            rowSlice.Clear();
            chart.ShowLogo(pSuggest.ChartTitle, "", "Looking for space that can be freed...", true);
        }

        /// <summary>Found again: the suggestions keep the places they had (only their sizes change), new ones follow,
        /// largest first; the first time, largest first.</summary>
        static List<Suggestion> StableOrder(List<Suggestion> found, List<Suggestion> old)
        {
            var bySize = found.OrderByDescending(x => x.Size).ToList();
            if (old == null || old.Count == 0) return bySize;
            var place = new Dictionary<string, int>();
            for (int i = 0; i < old.Count; i++) place[old[i].Name] = i;
            var kept = found.Where(x => place.ContainsKey(x.Name)).OrderBy(x => place[x.Name]).ToList();
            kept.AddRange(bySize.Where(x => !place.ContainsKey(x.Name)));
            return kept;
        }

        /// <summary>Caches and temporary folders (suggestions themselves) change all the time: an open Suggestions view
        /// looks again at most every 20 s, and not while the user works in the list (pointer over it, rows selected, a
        /// mouse button held). Called on every live-update tick, so a skipped refresh happens as soon as it is due.</summary>
        void RefreshSuggestionsIfDue()
        {
            if (ActivePage != pSuggest || !suggestionsDirty || busy || scanning || (DateTime.UtcNow - lastSuggestFind).TotalSeconds < 20) return;
            if (SelfTestDir == null)
            {
                var lv = pSuggest.List;
                if (lv.SelectedIndices.Count > 0 || Control.MouseButtons != MouseButtons.None) return;
                if (lv.Visible && lv.ClientRectangle.Contains(lv.PointToClient(Cursor.Position))) return;
            }
            pSuggest.Stale = false;
            FillSuggestions();
        }

        List<DeleteTarget> CheckedSuggestionTargets()
        {
            if (suggestions == null) return new List<DeleteTarget>();
            return suggestions.SelectMany(s => s.Targets).Where(t => t.Checked && t.Size > 0).ToList();
        }

        void UpdateSuggestionButtons()
        {
            if (btnSugDelete == null) return;
            btnSugDelete.Enabled = CheckedSuggestionTargets().Count > 0 && !busy && !scanning;
            UpdateIgnoredButton();
        }

        void SuggestionGlyph(ListViewItem lvi, bool checkbox)
        {
            var info = (ItemInfo)lvi.Tag;
            var s = info.Data as Suggestion;
            if (!checkbox)
            {
                if (s != null) s.Expanded = !s.Expanded;
                else { var dir = SuggestionFolderOf(info); if (dir != null && !sugOpenDirs.Remove(dir)) sugOpenDirs.Add(dir); }
                ShowSuggestions();
                return;
            }
            if (s != null) { bool on = s.CheckState != 1; foreach (var t in s.Targets) t.Checked = on; }
            else { var t = info.Data as DeleteTarget; if (t != null) t.Checked = !t.Checked; }
            ShowSuggestions();
        }

        void ToggleSelectedSuggestions()
        {
            var sel = pSuggest.List.SelectedItems.Cast<ListViewItem>().Select(i => (ItemInfo)i.Tag).ToList();
            if (sel.Count == 0) return;
            var targets = sel.SelectMany(i => i.Data is Suggestion ? ((Suggestion)i.Data).Targets : i.Data is DeleteTarget ? new List<DeleteTarget> { (DeleteTarget)i.Data } : new List<DeleteTarget>()).Distinct().ToList();
            bool on = targets.Any(t => !t.Checked);
            foreach (var t in targets) t.Checked = on;
            var keep = sel.Select(i => i.Name).ToList();
            ShowSuggestions();
            foreach (ListViewItem it in pSuggest.List.Items) it.Selected = keep.Contains(((ItemInfo)it.Tag).Name);
        }

        void ExpandSelectedSuggestions(bool expand)
        {
            var sel = pSuggest.List.SelectedItems.Cast<ListViewItem>().Select(i => (ItemInfo)i.Tag).ToList();
            if (sel.Count == 0) return;
            var keep = new HashSet<object>();
            foreach (var i in sel)
            {
                var s = i.Data as Suggestion;
                if (s != null) { s.Expanded = expand; keep.Add(s); continue; }
                var dir = SuggestionFolderOf(i);
                if (dir != null && i.Expandable) { if (expand) sugOpenDirs.Add(dir); else sugOpenDirs.Remove(dir); keep.Add(dir); continue; }
                // Left on a row inside a suggestion closes the suggestion.
                var owner = i.GroupOf != null ? i.GroupOf.Data as Suggestion : null;
                if (!expand && owner != null) { owner.Expanded = false; keep.Add(owner); }
            }
            ShowSuggestions();
            foreach (ListViewItem it in pSuggest.List.Items)
            {
                var info = (ItemInfo)it.Tag;
                it.Selected = (info.Data is Suggestion && keep.Contains(info.Data)) || (SuggestionFolderOf(info) != null && keep.Contains(SuggestionFolderOf(info)));
            }
        }

        /// <summary>Expand all opens every suggestion (one level); Collapse all closes them and every folder opened in them.</summary>
        void ExpandAllSuggestions(bool expand)
        {
            if (suggestions == null) return;
            foreach (var s in suggestions) s.Expanded = expand;
            if (!expand) sugOpenDirs.Clear();
            ShowSuggestions();
        }

        void CheckAllSuggestions(bool on)
        {
            if (suggestions == null) return;
            foreach (var s in suggestions) foreach (var t in s.Targets) t.Checked = on;
            ShowSuggestions();
        }

        void AddCheckedSuggestions()
        {
            var ticked = CheckedSuggestionTargets();
            int added = ticked.Count(AddTarget);
            BasketChanged();
            statusLabel.Text = string.Format("Added {0:N0} suggested item{1} to the delete list: now {2:N0} item{3}, {4}.",
                added, added == 1 ? "" : "s", basket.Count, basket.Count == 1 ? "" : "s", Fmt.Size(basket.Sum(t => t.Size)));
        }

        async void DeleteCheckedSuggestions(bool recycle)
        {
            if (busy || scanning) return;
            var ticked = CheckedSuggestionTargets();
            if (ticked.Count == 0) return;
            var job = await ConfirmAndDelete(ticked, recycle);
            if (job == null) return;
            AfterDeleteRemeasure(ticked);
        }
        // ---------------------------------------------------------------- catalogue

        static string Env(string name) { return Environment.GetEnvironmentVariable(name) ?? ""; }

        List<Suggestion> FindSuggestions(List<DirNode> scanned)
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string progData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            string sysDrive = Path.GetPathRoot(win);
            var list = new List<Suggestion>();

            long rbItems;
            long rb = DeleteJob.RecycleBinSize(out rbItems);
            if (rb > 0)
                list.Add(new Suggestion
                {
                    Name = "Recycle Bin", Location = string.Format("All drives ({0:N0} items)", rbItems), Safe = true, Size = rb,
                    Note = "Deleted items waiting in the bin. Emptying it frees the space for good.",
                    Targets = { new DeleteTarget { RecycleBin = true, Label = "Recycle Bin", Note = "empty the bin", Size = rb } }
                });

            Contents(list, "Temporary files", Path.GetTempPath(), true, false, "Files programs left behind. Files in use are skipped.");
            Contents(list, "Windows temporary files", Path.Combine(win, "Temp"), true, true, "Windows' own temporary files. Files in use are skipped.");
            Contents(list, "Windows Update downloads", Path.Combine(win, @"SoftwareDistribution\Download"), true, true,
                "Installed update packages. Windows downloads them again if it needs them.");
            Contents(list, "Delivery Optimization cache", Path.Combine(win, @"ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"),
                true, true, "Update pieces shared with other PCs. Rebuilt as needed.");
            var dumps = new Suggestion { Name = "Crash dumps", Safe = true, Note = "Memory dumps from crashed programs and Windows. Only needed to investigate a crash." };
            AddContents(dumps, Path.Combine(local, "CrashDumps"));
            AddContents(dumps, Path.Combine(win, "Minidump"));
            AddFile(dumps, Path.Combine(win, "MEMORY.DMP"));
            AddContents(dumps, Path.Combine(progData, @"Microsoft\Windows\WER\ReportArchive"));
            AddContents(dumps, Path.Combine(progData, @"Microsoft\Windows\WER\ReportQueue"));
            Finish(list, dumps, true);
            var thumbs = new Suggestion { Name = "Thumbnail cache", Safe = true, Note = "Explorer's picture previews. Rebuilt when folders are opened; files in use are skipped." };
            string explorer = Path.Combine(local, @"Microsoft\Windows\Explorer");
            if (Directory.Exists(explorer))
                try { foreach (var f in Directory.GetFiles(explorer, "thumbcache_*.db")) AddFile(thumbs, f); } catch (Exception) { }
            Finish(list, thumbs, false);

            Browser(list, "Microsoft Edge cache", Path.Combine(local, @"Microsoft\Edge\User Data"));
            Browser(list, "Google Chrome cache", Path.Combine(local, @"Google\Chrome\User Data"));
            Browser(list, "Brave cache", Path.Combine(local, @"BraveSoftware\Brave-Browser\User Data"));
            Browser(list, "Opera cache", Path.Combine(Env("APPDATA"), @"Opera Software\Opera Stable"));
            var firefox = new Suggestion { Name = "Firefox cache", Safe = true, Note = "Web pages stored to load faster. Close Firefox first; sites load a little slower once." };
            string ffProfiles = Path.Combine(local, @"Mozilla\Firefox\Profiles");
            if (Directory.Exists(ffProfiles))
                try { foreach (var d in Directory.GetDirectories(ffProfiles)) AddContents(firefox, Path.Combine(d, "cache2")); } catch (Exception) { }
            Finish(list, firefox, false);

            const string dev = "Developer cache: downloaded packages. Downloaded again when a project needs them.";
            Contents(list, "npm cache", Path.Combine(local, "npm-cache"), true, false, dev);
            Contents(list, "Yarn cache", Path.Combine(local, @"Yarn\Cache"), true, false, dev);
            Contents(list, "pnpm store", Path.Combine(local, @"pnpm\store"), true, false, dev);
            Contents(list, "pip cache", Path.Combine(local, @"pip\Cache"), true, false, dev);
            Contents(list, "NuGet packages", Path.Combine(home, @".nuget\packages"), true, false, dev);
            Contents(list, "Gradle caches", Path.Combine(home, @".gradle\caches"), true, false, dev);
            Contents(list, "Maven repository", Path.Combine(home, @".m2\repository"), true, false, dev);
            Contents(list, "Cargo registry cache", Path.Combine(home, @".cargo\registry\cache"), true, false, dev);
            Contents(list, "Go build cache", Path.Combine(local, "go-build"), true, false, dev);

            // node_modules folders of the user's own projects (outermost only). Never inside installed programs or tools: those
            // ship their packages in node_modules too (VS Code, Windows widgets, Electron apps, editor extensions).
            var nm = new Suggestion { Name = "node_modules folders", Safe = true, Note = "JavaScript packages of projects. Restored with npm install (or yarn / pnpm)." };
            foreach (var r in scanned)
                foreach (var d in OutermostNamed(r, "node_modules", IsAppFolder))
                {
                    if (!IsProjectModules(d.FullPath)) continue;
                    nm.Targets.Add(new DeleteTarget { Path = d.FullPath, Label = d.Parent != null ? d.Parent.Name + @"\node_modules" : d.Name, IsDir = true, Dir = d, Size = d.Size, Note = "node_modules" });
                    nm.Size += d.Size;
                }
            if (nm.Targets.Count > 0) { nm.Location = string.Format("{0:N0} projects in the scanned drives", nm.Targets.Count); list.Add(nm); }

            // Old installers and disk images in Downloads: worth a look, not automatic.
            var dl = new Suggestion { Name = "Old installers in Downloads", Safe = false, Note = "Setup files and disk images older than 30 days. Keep the ones you still need." };
            string downloads = Path.Combine(home, "Downloads");
            if (Directory.Exists(downloads))
            {
                var exts = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".exe", ".msi", ".msix", ".iso", ".img", ".zip", ".7z", ".rar" };
                try
                {
                    foreach (var f in new DirectoryInfo(downloads).GetFiles())
                        if (exts.Contains(f.Extension) && f.LastWriteTime < DateTime.Now.AddDays(-30))
                        {
                            dl.Targets.Add(new DeleteTarget { Path = f.FullName, Label = f.Name, Size = f.Length, Note = "old download" });
                            dl.Size += f.Length;
                        }
                }
                catch (Exception) { }
                dl.Location = downloads;
            }
            if (dl.Targets.Count > 0) list.Add(dl);

            string old = Path.Combine(sysDrive, "Windows.old");
            if (Directory.Exists(old))
            {
                var s = new Suggestion
                {
                    Name = "Previous Windows installation", Location = old, Safe = false, NeedsAdmin = true,
                    Note = "Windows.old. After deleting it you can no longer go back to the previous version of Windows."
                };
                s.Size = MeasureFolder(old);
                s.Targets.Add(new DeleteTarget { Path = old, Label = "Windows.old", IsDir = true, Size = s.Size, Note = "previous Windows" });
                list.Add(s);
            }
            FindMoreSuggestions(scanned, list);
            return IgnoreList.Apply(list);
        }

        void Contents(List<Suggestion> list, string name, string dir, bool safe, bool admin, string note)
        {
            var s = new Suggestion { Name = name, Safe = safe, NeedsAdmin = admin, Note = note };
            AddContents(s, dir);
            Finish(list, s, false);
        }

        void Browser(List<Suggestion> list, string name, string userData)
        {
            var s = new Suggestion { Name = name, Safe = true, Note = "Web pages stored to load faster. Close the browser first; sites load a little slower once." };
            if (Directory.Exists(userData))
            {
                var profiles = new List<string> { userData };
                try { profiles.AddRange(Directory.GetDirectories(userData)); } catch (Exception) { }
                foreach (var p in profiles)
                    foreach (var c in new[] { @"Cache\Cache_Data", "Code Cache", "GPUCache", @"Service Worker\CacheStorage" })
                        AddContents(s, Path.Combine(p, c));
            }
            Finish(list, s, false);
        }

        void AddContents(Suggestion s, string dir)
        {
            if (!Directory.Exists(dir)) return;
            long size = MeasureFolder(dir);
            if (size <= 0) return;
            s.Targets.Add(new DeleteTarget { Path = dir.TrimEnd('\\'), Label = s.Name, IsDir = true, ContentsOnly = true, Size = size, Note = "contents only" });
            s.Size += size;
        }

        void AddFile(Suggestion s, string file)
        {
            try
            {
                var fi = new FileInfo(file);
                if (!fi.Exists || fi.Length == 0) return;
                s.Targets.Add(new DeleteTarget { Path = file, Label = fi.Name, Size = fi.Length, Note = s.Name });
                s.Size += fi.Length;
            }
            catch (Exception) { }
        }

        static void Finish(List<Suggestion> list, Suggestion s, bool multi)
        {
            if (s.Targets.Count == 0 || s.Size <= 0) return;
            s.Location = s.Targets.Count == 1 ? s.Targets[0].Path : string.Format("{0:N0} locations", s.Targets.Count);
            if (s.Targets.Count > 1) foreach (var t in s.Targets) if (t.Label == s.Name) t.Label = Native.FileName(t.Path.TrimEnd('\\'));
            list.Add(s);
        }

        /// <summary>Size of a folder: from the scanned tree when it is there, otherwise read now.</summary>
        long MeasureFolder(string dir)
        {
            DirNode n = null;
            try { n = (DirNode)Invoke(new Func<DirNode>(() => FindScanned(dir, true))); } catch (Exception) { }
            if (n != null) return n.Size;
            try { var r = new Scanner().Run(dir); return r.Size; } catch (Exception) { return 0; }
        }

        static IEnumerable<DirNode> OutermostNamed(DirNode root, string name, Func<DirNode, bool> skip)
        {
            var stack = new Stack<DirNode>();
            stack.Push(root);
            while (stack.Count > 0)
            {
                var n = stack.Pop();
                if (n != root && skip != null && skip(n)) continue;
                if (n != root && string.Equals(n.Name, name, StringComparison.OrdinalIgnoreCase)) { yield return n; continue; }
                if (n.Children != null) foreach (var c in n.Children) stack.Push(c);
            }
        }

        static readonly string[] AppRoots =
        {
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        };

        /// <summary>Folders that hold installed programs or tools, never searched for project node_modules: Windows, Program
        /// Files (incl. WindowsApps), ProgramData, AppData, and hidden tool folders such as .vscode, .cursor, .nvm.</summary>
        static bool IsAppFolder(DirNode n)
        {
            if (n.Name.StartsWith(".") || n.Name.Equals("$Recycle.Bin", StringComparison.OrdinalIgnoreCase)) return true;
            string p = n.FullPath;
            return AppRoots.Any(r => !string.IsNullOrEmpty(r) && string.Equals(p.TrimEnd('\\'), r.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase));
        }

        /// <summary>
        /// A node_modules folder of a user project: package.json next to it, and nothing in its path that marks an installed
        /// app or tool (system and program folders, AppData, hidden tool folders, "resources\app" of Electron apps, editor
        /// "extensions").
        /// </summary>
        internal static bool IsProjectModules(string path)
        {
            string parent = Native.ParentDir(path);
            if (string.IsNullOrEmpty(parent) || !File.Exists(Path.Combine(parent, "package.json"))) return false;
            if (AppRoots.Any(r => !string.IsNullOrEmpty(r) && IsWithin(path, r))) return false;
            foreach (var part in path.Split('\\'))
                if (part.StartsWith(".") || part.Equals("extensions", StringComparison.OrdinalIgnoreCase) ||
                    part.Equals("resources", StringComparison.OrdinalIgnoreCase) || part.Equals("WindowsApps", StringComparison.OrdinalIgnoreCase))
                    return false;
            return true;
        }
    }
}

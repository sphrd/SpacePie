using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace SpacePie
{
    /// <summary>
    /// System tab: space Windows itself uses (update leftovers in WinSxS, restore points, hibernation and page file, WSL and
    /// Docker virtual disks), a registry check of safe categories, and the drives with their health. Groups expand into
    /// items; every item says what it is, its size or what can be freed, what it means, and what can be done about it.
    /// </summary>
    internal sealed partial class MainForm
    {
        Page pSystem;
        List<SysGroup> sysGroups;
        List<RegIssue> regIssues;
        List<DriveHealth> sysDrives;
        DismInfo sysDism;
        bool sysAnalyzing;
        double sysAnalyzePct = -1;
        volatile bool sysCancel;
        bool sysRunning, sysCancelWired, statusHooked;
        Dictionary<SysAct, RoundButton> sysButtons;
        Panel sysBar, sysBanner;
        RoundButton sysBannerButton;
        string sysBannerText = "", lowStatus;
        readonly HashSet<string> lowWarned = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        static readonly SysAct[] SysActOrder =
        {
            SysAct.AnalyzeStore, SysAct.CleanStore, SysAct.DeleteOldestShadow, SysAct.DeleteAllButNewest, SysAct.HibernateOff,
            SysAct.HibernateOn, SysAct.ShrinkDisk, SysAct.RemoveRegistry, SysAct.ShowSuggestions
        };

        static string ActName(SysAct a)
        {
            switch (a)
            {
                case SysAct.AnalyzeStore: return "Analyze";
                case SysAct.CleanStore: return "Clean up";
                case SysAct.DeleteOldestShadow: return "Delete oldest";
                case SysAct.DeleteAllButNewest: return "Delete all but newest";
                case SysAct.HibernateOff: return "Turn off hibernation";
                case SysAct.HibernateOn: return "Turn on hibernation";
                case SysAct.ShrinkDisk: return "Shrink";
                case SysAct.RemoveRegistry: return "Remove checked";
                case SysAct.ShowSuggestions: return "Show suggestions";
                default: return "";
            }
        }

        Page BuildSystemPage()
        {
            var refresh = Btn("Refresh", ButtonKind.Secondary, "Read everything again", RefreshSystem);
            refresh.Glyph = Theme.DrawRefresh;
            refresh.Compact = true;
            sysButtons = new Dictionary<SysAct, RoundButton>
            {
                { SysAct.AnalyzeStore, Btn("Analyze", ButtonKind.Secondary, "Measure the component store with DISM (about a minute)", () => OnSysAction(SysAct.AnalyzeStore)) },
                { SysAct.CleanStore, Btn("Clean up...", ButtonKind.Danger, "Remove Windows update leftovers with DISM (can take many minutes)", () => OnSysAction(SysAct.CleanStore)) },
                { SysAct.DeleteOldestShadow, Btn("Delete oldest restore point...", ButtonKind.Danger, "Delete the oldest restore point (shadow copy) of this drive", () => OnSysAction(SysAct.DeleteOldestShadow)) },
                { SysAct.DeleteAllButNewest, Btn("Delete all but the newest...", ButtonKind.Danger, "Keep only the newest restore point of this drive", () => OnSysAction(SysAct.DeleteAllButNewest)) },
                { SysAct.HibernateOff, Btn("Turn off hibernation...", ButtonKind.Warn, "powercfg /h off: deletes hiberfil.sys", () => OnSysAction(SysAct.HibernateOff)) },
                { SysAct.HibernateOn, Btn("Turn on hibernation...", ButtonKind.Secondary, "powercfg /h on", () => OnSysAction(SysAct.HibernateOn)) },
                { SysAct.ShrinkDisk, Btn("Shrink...", ButtonKind.Warn, "Stop WSL, then compact the virtual disk", () => OnSysAction(SysAct.ShrinkDisk)) },
                { SysAct.RemoveRegistry, Btn("Remove checked...", ButtonKind.Warn, "Remove the checked broken registry entries (saved to a .reg backup first)", () => OnSysAction(SysAct.RemoveRegistry)) },
                { SysAct.ShowSuggestions, Btn("Show suggestions", ButtonKind.Secondary, "Open the Suggestions tab: space that can be freed", () => OnSysAction(SysAct.ShowSuggestions)) },
            };
            foreach (var b in sysButtons.Values) { b.Compact = true; b.Tag = "right"; b.Visible = false; }
            var list = NewList(new[] { "Name", "Size", "Can free", "What it means", "Action", "Location" },
                new[] { "name", "size", "free", "note", "cat", "folder" }, new[] { 280, 140, 90, 520, 170, 320 }, -1);
            list.Grouped = true;
            list.ContextMenuStrip = null;
            list.GlyphClicked += SystemGlyph;
            list.SelectedIndexChanged += (s, e) => UpdateSystemButtons();
            list.DoubleClick += (s, e) =>
            {
                var info = list.SelectedItems.Count == 1 ? list.SelectedItems[0].Tag as ItemInfo : null;
                var g = info != null ? info.Data as SysGroup : null;
                if (g != null) ExpandSysGroup(g, !g.Expanded);
            };
            list.KeyDown += (s, e) =>
            {
                if (e.KeyCode == Keys.Space) { ToggleSelectedRegistry(); e.Handled = true; }
                else if (e.KeyCode == Keys.Right || e.KeyCode == Keys.Left)
                {
                    foreach (var g in SelectedSysGroups()) ExpandSysGroup(g, e.KeyCode == Keys.Right);
                    e.Handled = true;
                }
            };
            var items = new List<Control> { refresh };
            items.AddRange(SysActOrder.Select(a => (Control)sysButtons[a]));
            sysBar = MakeBar(items.ToArray());
            var p = AddPage("System", list, sysBar);

            // Amber attention banner above the caption while a drive is almost full.
            sysBanner = new Panel { Dock = DockStyle.Top, Height = Theme.FONT.Height + S(26), BackColor = Theme.SURFACE, Visible = false };
            sysBannerButton = Btn("Show suggestions", ButtonKind.Secondary, "Open the Suggestions tab: space that can be freed", ShowSuggestionsTab);
            sysBannerButton.Compact = true;
            sysBanner.Controls.Add(sysBannerButton);
            sysBanner.Layout += (s, e) =>
            {
                var sz = sysBannerButton.GetPreferredSize(Size.Empty);
                sysBannerButton.Bounds = new Rectangle(sysBanner.Width - sz.Width - S(10), (sysBanner.Height - S(6) - sz.Height) / 2, sz.Width, sz.Height);
            };
            sysBanner.Paint += (s, e) =>
            {
                var g = e.Graphics;
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                var r = new Rectangle(0, 0, sysBanner.Width - 1, sysBanner.Height - S(6));
                Theme.FillRound(g, r, S(8), Theme.WARN_BG, Theme.WARN_BORDER);
                int ic = S(18);
                Theme.DrawWarningSign(g, new Rectangle(S(10), (r.Height - ic) / 2, ic, ic), Theme.WARN);
                int x = S(10) + ic + S(10);
                CutText.Begin(sysBanner);
                CutText.Draw(g, sysBanner, sysBannerText, Theme.FONT, new Rectangle(x, 0, Math.Max(0, sysBannerButton.Left - x - S(10)), r.Height), Theme.WARN_FG,
                    TextFormatFlags.VerticalCenter);
            };
            sysBanner.Resize += (s, e) => sysBanner.Invalidate();
            p.Root.Controls.Add(sysBanner);
            p.ChartTitle = "System";
            p.ChartScope = "of what can be freed";
            p.Empty = "Nothing read yet.";
            p.Fill = FillSystem;
            return p;
        }

        // ---------------------------------------------------------------- loading

        /// <summary>Called when a scan ends: the low-space warning (once per drive), and after a drive scan the tab loads in the background.</summary>
        void SystemAfterScan(bool driveScan)
        {
            if (SelfTestDir != null || ShotDir != null || pSystem == null) return;
            try { LowSpaceCheck(Health.ReadDrives(false), true); } catch (Exception) { }
            if (driveScan && sysGroups == null) FillSystem();
        }

        void FillSystem()
        {
            if (sysGroups != null) { ShowSystem(); return; }
            sysGroups = new List<SysGroup>
            {
                new SysGroup { Key = "store", Name = "Windows update leftovers", NeedsAdmin = true, Actions = { SysAct.AnalyzeStore, SysAct.CleanStore },
                    Note = "Old versions of Windows files in C:\\Windows\\WinSxS that updates replaced." },
                new SysGroup { Key = "restore", Name = "Restore points and shadow copies", NeedsAdmin = true,
                    Note = "Snapshots to undo system changes and older versions of files." },
                new SysGroup { Key = "hiber", Name = "Hibernation and page file", Note = "Large hidden files Windows keeps in the drive's root folder." },
                new SysGroup { Key = "disks", Name = "Virtual disks (WSL, Docker)", Note = "Linux disks that grow but never shrink by themselves." },
                new SysGroup { Key = "registry", Name = "Registry check", Actions = { SysAct.RemoveRegistry },
                    Note = "Entries that point at programs which no longer exist. Removed entries are backed up first." },
                new SysGroup { Key = "drives", Name = "Drives", Expanded = true, Note = "Free space and the health the disks report." },
            };
            foreach (var g in sysGroups)
            {
                if (g.Key == "store") { g.Items = ReadStoreGroup(sysDism, sysAnalyzing, sysAnalyzePct); g.Loaded = true; }
                else { var t = LoadSysGroup(g); }
            }
            ShowSystem();
        }

        void RefreshSystem()
        {
            if (sysGroups == null) { FillSystem(); return; }
            foreach (var g in sysGroups)
            {
                if (g.Key == "store") { g.Items = ReadStoreGroup(sysDism, sysAnalyzing, sysAnalyzePct); continue; }
                var t = LoadSysGroup(g);
            }
            ShowSystem();
        }

        Task RefreshSysGroup(string key)
        {
            var g = sysGroups != null ? sysGroups.FirstOrDefault(x => x.Key == key) : null;
            if (g == null) return Task.FromResult(0);
            if (key == "store") { g.Items = ReadStoreGroup(sysDism, sysAnalyzing, sysAnalyzePct); ShowSystem(); return Task.FromResult(0); }
            return LoadSysGroup(g);
        }

        async Task LoadSysGroup(SysGroup g)
        {
            if (g.Loading) return;
            g.Loading = true;
            ShowSystem();
            List<SysItem> items = null;
            bool admin = isAdmin;
            try { await Task.Run(() => { items = ReadSysGroup(g.Key, admin); }); }
            catch (Exception) { }
            g.Loading = false;
            g.Loaded = true;
            g.Items = items ?? new List<SysItem> { new SysItem { Name = "Could not be read", Info = true, Muted = true, SizeText = "" } };
            if (g.Key == "drives" && sysDrives != null) LowSpaceCheck(sysDrives, false);
            if (!IsDisposed) ShowSystem();
        }

        /// <summary>Reads one group (background thread).</summary>
        List<SysItem> ReadSysGroup(string key, bool admin)
        {
            switch (key)
            {
                case "restore": return ReadShadowGroup(admin);
                case "hiber": return ReadHiberGroup(Health.ReadDrives(false));
                case "disks": return ReadDiskGroup();
                case "registry":
                {
                    var found = FindBrokenRegistry();
                    var old = regIssues != null ? regIssues.ToDictionary(r => r.Display, r => r.Checked) : new Dictionary<string, bool>();
                    foreach (var r in found)
                    {
                        bool was;
                        if (r.NeedsAdmin && !admin) { r.Checked = false; r.Note = "needs administrator"; }
                        if (old.TryGetValue(r.Display, out was)) r.Checked = was;
                    }
                    regIssues = found;
                    return ReadRegistryGroup(found);
                }
                case "drives":
                {
                    var d = Health.ReadDrives(true);
                    sysDrives = d;
                    return ReadDriveGroup(d);
                }
                default: return new List<SysItem>();
            }
        }

        // ---------------------------------------------------------------- showing

        void ShowSystem()
        {
            var p = pSystem;
            if (p == null || sysGroups == null) return;
            var lv = p.List;
            object keepSel = lv.SelectedItems.Count == 1 ? ((ItemInfo)lv.SelectedItems[0].Tag).Data : null;
            var topInfo = lv.TopItem != null ? (ItemInfo)lv.TopItem.Tag : null;
            object top = topInfo != null ? topInfo.Data : null;
            var rows = new List<ListViewItem>();
            long total = 0;
            bool elevated = isAdmin;
            foreach (var g in sysGroups)
            {
                long reclaim = g.Items.Sum(i => Math.Max(0, i.Reclaim));
                long size = g.Key == "drives" ? 0 : g.Items.Where(i => i.Size > 0 && !(g.Key == "store" && i.Info)).Sum(i => i.Size);
                total += reclaim;
                bool adminBlocked = g.NeedsAdmin && !elevated;
                var head = new ItemInfo
                {
                    Data = g, IsGroup = true, Name = g.Name + (g.Loaded && !g.Items.All(i => i.Muted) && g.Key != "store" ? string.Format("  ({0:N0})", g.Items.Count) : ""),
                    Size = reclaim, ChartValue = reclaim, Note = g.Note, Expandable = true, Expanded = g.Expanded,
                    Check = g.Key == "registry" && regIssues != null && regIssues.Count > 0 ? RegCheckState() : -1
                };
                string act = adminBlocked ? "needs administrator" : string.Join(" / ", g.Actions.Select(ActName));
                if (g.Key == "drives" && g.Items.Any(i => i.Actions.Contains(SysAct.ShowSuggestions))) act = ActName(SysAct.ShowSuggestions);
                head.Category = act;
                var hr = Row(head, head.Name, g.Loading ? "reading..." : size > 0 ? Fmt.Size(size) : "", reclaim > 0 ? Fmt.Size(reclaim) : "",
                    g.Note, act, "");
                int level = g.Items.Count > 0 ? g.Items.Max(i => i.Level) : 0;
                hr.ForeColor = level == 2 ? Theme.DANGER_FG : level == 1 ? Theme.WARN_FG : adminBlocked ? Theme.MUTED : Theme.FG;
                rows.Add(hr);
                if (!g.Expanded) continue;
                if (g.Loading && !g.Loaded)
                {
                    var wait = new ItemInfo { GroupOf = head, IsSummary = true, Name = "Reading..." };
                    rows.Add(Row(wait, wait.Name, "", "", "", "", ""));
                    continue;
                }
                foreach (var it in g.Items)
                {
                    var reg = it.Data as RegIssue;
                    bool blocked = it.NeedsAdmin && !elevated && (it.Actions.Count > 0 || reg != null);
                    var info = new ItemInfo
                    {
                        Data = it, GroupOf = head, Name = it.Name, Size = Math.Max(0, it.Size), ChartValue = Math.Max(0, it.Reclaim), Path = it.Path,
                        Folder = it.Location, Note = it.Meaning, FolderIcon = g.Key != "hiber" && g.Key != "disks", Check = reg != null ? (reg.Checked ? 1 : 0) : -1
                    };
                    string sizeText = it.SizeText ?? (it.Size >= 0 ? Fmt.Size(it.Size) : "");
                    string action = blocked ? "needs administrator" : it.ActionText ?? string.Join(" / ", it.Actions.Select(ActName));
                    if (reg != null && !blocked) action = reg.Checked ? "remove (checked)" : "keep";
                    info.Category = action;
                    var r = Row(info, it.Name, sizeText, it.Reclaim > 0 ? Fmt.Size(it.Reclaim) : "", it.Meaning, action, it.Location);
                    r.ForeColor = it.Level == 2 ? Theme.DANGER_FG : it.Level == 1 ? Theme.WARN_FG : it.Muted || blocked ? Theme.MUTED : Theme.FG;
                    rows.Add(r);
                }
            }
            SetRows(lv, rows, "Reading...");
            if (top != null)
                foreach (ListViewItem it in lv.Items) if (((ItemInfo)it.Tag).Data == top) { try { lv.TopItem = it; } catch (Exception) { } break; }
            if (keepSel != null)
                foreach (ListViewItem it in lv.Items) if (((ItemInfo)it.Tag).Data == keepSel) { it.Selected = true; break; }
            p.Caption.Text = "Space Windows itself uses, broken registry entries and drive health. Expand a group; select a row for its actions." +
                (elevated ? "" : "  Muted rows need administrator rights (Run as administrator).");
            p.ChartSub = total > 0 ? Fmt.Size(total) + " can be freed" : "Nothing measured to free yet";
            p.ChartTotal = 0;
            UpdateSystemButtons();
            if (ActivePage == p) RefreshChart();
        }

        int RegCheckState()
        {
            int n = regIssues.Count(r => r.Checked);
            return n == 0 ? 0 : n == regIssues.Count ? 1 : 2;
        }

        void ExpandSysGroup(SysGroup g, bool expand)
        {
            g.Expanded = expand;
            // Windows update leftovers: measured the first time the group is opened (DISM takes about a minute).
            if (expand && g.Key == "store" && sysDism == null && !sysAnalyzing && isAdmin && SelfTestDir == null && ShotDir == null) AnalyzeStore();
            ShowSystem();
        }

        void SystemGlyph(ListViewItem lvi, bool checkbox)
        {
            var info = (ItemInfo)lvi.Tag;
            var g = info.Data as SysGroup;
            if (!checkbox) { if (g != null) ExpandSysGroup(g, !g.Expanded); return; }
            if (g != null && g.Key == "registry" && regIssues != null) { bool on = RegCheckState() != 1; foreach (var r in regIssues) r.Checked = on; }
            else { var it = info.Data as SysItem; var r = it != null ? it.Data as RegIssue : null; if (r != null) r.Checked = !r.Checked; }
            ShowSystem();
        }

        void ToggleSelectedRegistry()
        {
            if (regIssues == null) return;
            var sel = pSystem.List.SelectedItems.Cast<ListViewItem>().Select(i => (ItemInfo)i.Tag).ToList();
            var rs = sel.SelectMany(i => i.Data is SysGroup && ((SysGroup)i.Data).Key == "registry" ? regIssues
                : i.Data is SysItem && ((SysItem)i.Data).Data is RegIssue ? new List<RegIssue> { (RegIssue)((SysItem)i.Data).Data } : new List<RegIssue>()).Distinct().ToList();
            if (rs.Count == 0) return;
            bool on = rs.Any(r => !r.Checked);
            foreach (var r in rs) r.Checked = on;
            ShowSystem();
        }

        List<SysGroup> SelectedSysGroups()
        {
            return pSystem.List.SelectedItems.Cast<ListViewItem>().Select(i => (ItemInfo)i.Tag)
                .Select(i => i.Data as SysGroup ?? (i.GroupOf != null ? i.GroupOf.Data as SysGroup : null)).Where(x => x != null).Distinct().ToList();
        }

        /// <summary>The selected row: its group and (for an item row) the item.</summary>
        SysGroup SelectedSys(out SysItem item)
        {
            item = null;
            var lv = pSystem != null ? pSystem.List : null;
            if (lv == null || lv.SelectedItems.Count != 1) return null;
            var info = (ItemInfo)lv.SelectedItems[0].Tag;
            item = info.Data as SysItem;
            return info.Data as SysGroup ?? (info.GroupOf != null ? info.GroupOf.Data as SysGroup : null);
        }

        List<SysAct> SelectedActs()
        {
            SysItem it;
            var g = SelectedSys(out it);
            if (g == null) return new List<SysAct>();
            if (it != null) return it.Actions;
            var acts = new List<SysAct>(g.Actions);
            if (g.Key == "drives" && g.Items.Any(i => i.Actions.Contains(SysAct.ShowSuggestions))) acts.Add(SysAct.ShowSuggestions);
            return acts;
        }

        void UpdateSystemButtons()
        {
            if (sysButtons == null) return;
            var acts = SelectedActs();
            bool idle = !busy && !scanning;
            bool changed = false;
            foreach (var kv in sysButtons)
            {
                bool vis = acts.Contains(kv.Key);
                if (kv.Value.Visible != vis) { kv.Value.Visible = vis; changed = true; }
                bool en = kv.Key == SysAct.ShowSuggestions || idle;
                if (kv.Key == SysAct.AnalyzeStore) en = !sysAnalyzing;
                if (kv.Key == SysAct.RemoveRegistry) en = idle && regIssues != null && regIssues.Any(r => r.Checked);
                kv.Value.Enabled = en;
            }
            if (changed && sysBar != null) sysBar.PerformLayout();
        }

        // ---------------------------------------------------------------- low space

        static string LowText(List<DriveHealth> low)
        {
            if (low.Count == 1)
                return string.Format("Drive {0} is almost full: {1} free of {2} ({3:0} %).", low[0].Letter, Fmt.Size(low[0].Free), Fmt.Size(low[0].Total), low[0].FreePercent);
            return "Drives " + string.Join(", ", low.Select(d => d.Letter)) + " are almost full (" +
                string.Join(", ", low.Select(d => string.Format("{0} {1} free", d.Letter, Fmt.Size(d.Free)))) + ").";
        }

        /// <summary>Banner in the System tab while a drive is low; with status, an amber status line once per drive per session.</summary>
        void LowSpaceCheck(List<DriveHealth> drives, bool status)
        {
            var low = Health.LowDrives(drives);
            string text = low.Count > 0 ? LowText(low) + "  Free space with the suggestions." : "";
            if (sysBanner != null)
            {
                sysBannerText = text;
                sysBanner.Visible = low.Count > 0;
                sysBanner.Invalidate();
            }
            if (!status) return;
            var fresh = low.Where(d => lowWarned.Add(d.Root)).ToList();
            if (fresh.Count == 0) return;
            if (!statusHooked)
            {
                statusHooked = true;
                statusLabel.TextChanged += (s, e) =>
                {
                    if (lowStatus != null && statusLabel.Text == lowStatus) return;
                    lowStatus = null;
                    statusLabel.ForeColor = Theme.MUTED;
                    statusLabel.Cursor = Cursors.Default;
                };
                statusLabel.Click += (s, e) => { if (lowStatus != null && statusLabel.Text == lowStatus) ShowSuggestionsTab(); };
            }
            lowStatus = LowText(fresh) + "  Show suggestions";
            statusLabel.Text = lowStatus;
            statusLabel.ForeColor = Theme.WARN_FG;
            statusLabel.Cursor = Cursors.Hand;
        }

        void ShowSuggestionsTab()
        {
            if (pSuggest != null) viewTabs.SelectedIndex = pages.IndexOf(pSuggest);
        }

        // ---------------------------------------------------------------- actions

        static bool ActNeedsAdmin(SysAct a)
        {
            return a != SysAct.ShowSuggestions && a != SysAct.RemoveRegistry;
        }

        void AskAdmin(string what)
        {
            if (Alert(AlertIcon.Warn, what + " needs administrator rights",
                    "Windows only allows this for an administrator. Restart SpacePie as administrator and choose it again.", null, null,
                    "Run as administrator", "Cancel") == "Run as administrator")
                RestartAsAdmin();
        }

        async void OnSysAction(SysAct a)
        {
            if (a == SysAct.ShowSuggestions) { ShowSuggestionsTab(); return; }
            if (a != SysAct.AnalyzeStore && (busy || scanning)) { statusLabel.Text = "Wait until the current scan or job has finished."; return; }
            SysItem it;
            var g = SelectedSys(out it);
            if (ActNeedsAdmin(a) && !isAdmin) { AskAdmin(ActName(a)); return; }
            try
            {
                switch (a)
                {
                    case SysAct.AnalyzeStore: AnalyzeStore(); break;
                    case SysAct.CleanStore: await CleanStore(); break;
                    case SysAct.DeleteOldestShadow:
                    case SysAct.DeleteAllButNewest:
                        if (it != null && it.Data is ShadowStorage) await DeleteShadows((ShadowStorage)it.Data, a == SysAct.DeleteAllButNewest);
                        break;
                    case SysAct.HibernateOff: await SetHibernation(false, it); break;
                    case SysAct.HibernateOn: await SetHibernation(true, it); break;
                    case SysAct.ShrinkDisk: if (it != null && it.Data is VirtualDisk) await ShrinkDisk((VirtualDisk)it.Data); break;
                    case SysAct.RemoveRegistry:
                    {
                        var items = regIssues != null ? regIssues.Where(r => r.Checked).ToList() : new List<RegIssue>();
                        if (items.Count == 0) return;
                        if (items.Any(r => r.NeedsAdmin) && !isAdmin) { AskAdmin("Removing machine-wide (HKLM) entries"); return; }
                        await RemoveRegistry(items, true);
                        break;
                    }
                }
            }
            catch (Exception ex) { statusLabel.Text = ActName(a) + " failed: " + ex.Message; }
        }

        void WireSysCancel()
        {
            if (sysCancelWired) return;
            sysCancelWired = true;
            EventHandler cancel = (s, e) =>
            {
                if (!sysRunning) return;
                sysCancel = true;
                ((RoundButton)s).Enabled = false;
            };
            scanBar.CancelButton.Click += cancel;
            deleteBar.CancelButton.Click += cancel;
        }

        /// <summary>A long action in the background with the progress strip (red for anything that deletes); the window stays usable.</summary>
        async Task SysRun(bool danger, string text, bool canCancel, Action<Action<string, string, double>> work)
        {
            var bar = danger ? deleteBar : scanBar;
            WireSysCancel();
            sysCancel = false;
            sysRunning = true;
            busy = true;
            bar.Start(text);
            bar.CancelButton.Enabled = canCancel;
            UpdateButtons();
            Action<string, string, double> report = (t, d, f) =>
            {
                try { BeginInvoke(new Action(() => { if (sysRunning) bar.SetProgress(t, d, f); })); } catch (Exception) { }
            };
            try { await Task.Run(() => work(report)); }
            finally
            {
                sysRunning = false;
                bar.Stop();
                bar.CancelButton.Enabled = true;
                busy = false;
                UpdateButtons();
                if (drivesChanged) BeginInvoke(new Action(RefreshDrives));
            }
        }

        static long FreeOn(string root)
        {
            try { return new DriveInfo(root).AvailableFreeSpace; } catch (Exception) { return 0; }
        }

        static string Dur(TimeSpan t)
        {
            return t.TotalMinutes >= 1 ? string.Format("{0} min {1} s", (int)t.TotalMinutes, t.Seconds) : string.Format("{0:0} s", t.TotalSeconds);
        }

        async void AnalyzeStore()
        {
            if (sysAnalyzing) return;
            if (!isAdmin) { AskAdmin("Analyzing the component store"); return; }
            sysAnalyzing = true;
            sysAnalyzePct = -1;
            await RefreshSysGroup("store");
            statusLabel.Text = "Analyzing Windows update leftovers (Dism /AnalyzeComponentStore, about a minute)...";
            string output = null;
            int code = -1;
            int shown = -1;
            await Task.Run(() =>
            {
                code = RunTool(Sys32("Dism.exe"), "/English /Online /Cleanup-Image /AnalyzeComponentStore", o =>
                {
                    double pc = LastPercent(o);
                    if ((int)pc == shown) return;
                    shown = (int)pc;
                    sysAnalyzePct = pc;
                    try { BeginInvoke(new Action(() => { var t = RefreshSysGroup("store"); })); } catch (Exception) { }
                }, () => IsDisposed, out output);
            });
            sysAnalyzing = false;
            sysAnalyzePct = -1;
            if (IsDisposed) return;
            if (code == 0)
            {
                sysDism = ParseDismAnalyze(output);
                statusLabel.Text = string.Format("Component store: {0}; a cleanup frees about {1} (recommended: {2}).", sysDism.Actual >= 0 ? Fmt.Size(sysDism.Actual) : "size unknown",
                    Fmt.Size(sysDism.Estimate), sysDism.Recommended == true ? "yes" : "no");
            }
            else statusLabel.Text = "DISM could not analyze the component store (error " + code + "): " + LastLine(output);
            await RefreshSysGroup("store");
        }

        async Task CleanStore()
        {
            if (Alert(AlertIcon.Danger, "Clean up Windows update leftovers?",
                    "DISM removes the older versions of Windows components that newer updates replaced" +
                    (sysDism != null ? " (about " + Fmt.Size(sysDism.Estimate) + ")" : "") + ". This cannot be undone: installed updates can no longer be uninstalled afterwards.",
                    "It can take many minutes. The window stays usable; don't shut down the PC meanwhile.", null, "Clean up", "Cancel") != "Clean up") return;
            string root = SystemRoot;
            long before = FreeOn(root);
            var sw = Stopwatch.StartNew();
            string output = null;
            int code = -1;
            await SysRun(true, "Cleaning up Windows update leftovers...", false, report =>
            {
                code = RunTool(Sys32("Dism.exe"), "/English /Online /Cleanup-Image /StartComponentCleanup", o =>
                {
                    double pc = LastPercent(o);
                    report(pc >= 0 ? string.Format("Cleaning up Windows update leftovers: {0:0.0} %", pc) : "Cleaning up Windows update leftovers...",
                        "Dism /Online /Cleanup-Image /StartComponentCleanup  --  this can take many minutes", pc >= 0 ? pc / 100 : -1);
                }, null, out output);
            });
            long freed = FreeOn(root) - before;
            statusLabel.Text = code == 0
                ? string.Format("Windows update leftovers cleaned up in {0}: {1} freed on {2}.", Dur(sw.Elapsed), Fmt.Size(Math.Max(0, freed)), root.TrimEnd('\\'))
                : "The cleanup did not finish (DISM error " + code + "): " + LastLine(output);
            sysDism = null;
            var t = RefreshSysGroup("drives");
            await RefreshSysGroup("store");
            if (code == 0) AnalyzeStore();
        }

        async Task DeleteShadows(ShadowStorage st, bool allButNewest)
        {
            string vol = st.Volume;
            if (Alert(AlertIcon.Danger, allButNewest ? "Delete all restore points on " + vol + " except the newest?" : "Delete the oldest restore point on " + vol + "?",
                    "This cannot be undone: Windows can no longer be returned to the state of " + (allButNewest ? "those points" : "that point") +
                    ", and the previous versions of files kept with " + (allButNewest ? "them" : "it") + " are gone.",
                    "Restore points take " + Fmt.Size(Math.Max(0, st.Used)) + " on " + vol + " now.", null, "Delete", "Cancel") != "Delete") return;
            long before = FreeOn(vol + "\\");
            int deleted = 0, code = 0;
            string output = null;
            string vss = Sys32("vssadmin.exe");
            await SysRun(true, "Deleting restore points on " + vol + "...", allButNewest, report =>
            {
                if (!allButNewest)
                {
                    code = RunTool(vss, "delete shadows /for=" + vol + " /oldest /quiet", null, null, out output);
                    if (code == 0) deleted = 1;
                    return;
                }
                string list;
                RunTool(vss, "list shadows /for=" + vol, null, null, out list);
                var mine = ParseVssShadows(list).Where(s => s.Volume == vol).OrderBy(s => s.Created).ToList();
                for (int i = 0; i < mine.Count - 1 && !sysCancel; i++)
                {
                    report(string.Format("Deleting restore points on {0}: {1} of {2}", vol, i + 1, mine.Count - 1), "Restore point of " + mine[i].Created.ToString("yyyy-MM-dd HH:mm"), (double)i / (mine.Count - 1));
                    code = RunTool(vss, "delete shadows /shadow=" + mine[i].Id + " /quiet", null, null, out output);
                    if (code != 0) break;
                    deleted++;
                }
            });
            long freed = FreeOn(vol + "\\") - before;
            statusLabel.Text = code == 0 || deleted > 0
                ? string.Format("Deleted {0:N0} restore point{1} on {2}: {3} freed.", deleted, deleted == 1 ? "" : "s", vol, Fmt.Size(Math.Max(0, freed)))
                : "The restore points could not be deleted (vssadmin error " + code + "): " + LastLine(output);
            var t = RefreshSysGroup("drives");
            await RefreshSysGroup("restore");
        }

        async Task SetHibernation(bool on, SysItem it)
        {
            string root = SystemRoot.TrimEnd('\\');
            string answer = on
                ? Alert(AlertIcon.Logo, "Turn on hibernation?", "Windows creates the hibernation file (hiberfil.sys) on " + root + " again; it takes up to about 40 % of the memory's size. Hibernate and Fast Startup work again.",
                    null, null, "Turn on", "Cancel")
                : Alert(AlertIcon.Warn, "Turn off hibernation?", "Deletes the hibernation file (hiberfil.sys" + (it != null && it.Size > 0 ? ", " + Fmt.Size(it.Size) : "") + ") on " + root +
                    ". Hibernate and Fast Startup stop working until you turn hibernation on again here.", null, null, "Turn off", "Cancel");
            if (answer != (on ? "Turn on" : "Turn off")) return;
            long before = FreeOn(root + "\\");
            string output = null;
            int code = -1;
            await SysRun(!on, on ? "Turning on hibernation..." : "Turning off hibernation...", false, report =>
            {
                code = RunTool(Sys32("powercfg.exe"), on ? "/h on" : "/h off", null, null, out output);
            });
            long diff = FreeOn(root + "\\") - before;
            statusLabel.Text = code != 0 ? "powercfg could not change hibernation (error " + code + "): " + LastLine(output)
                : on ? "Hibernation is on again." : string.Format("Hibernation is off: {0} freed on {1}.", Fmt.Size(Math.Max(0, diff)), root);
            var t = RefreshSysGroup("drives");
            await RefreshSysGroup("hiber");
        }

        async Task ShrinkDisk(VirtualDisk v)
        {
            if (Alert(AlertIcon.Warn, "Shrink " + Path.GetFileName(v.Path) + "?",
                    "First every running Linux distribution and Docker Desktop are stopped (wsl --shutdown): save your work in them. Then the virtual disk is " +
                    "compacted, so the space Linux no longer uses goes back to Windows. It can take several minutes.",
                    "They start again the next time you open them.", new List<string> { v.Path + "\t" + Fmt.Size(v.Size) }, "Shrink", "Cancel") != "Shrink") return;
            long before = FileSize(v.Path);
            string output = null;
            int code = -1;
            await SysRun(false, "Shrinking " + Path.GetFileName(v.Path) + "...", false, report =>
            {
                report("Stopping Linux (wsl --shutdown)...", v.Path, -1);
                string wsl = Sys32("wsl.exe"), ignore;
                if (File.Exists(wsl)) RunTool(wsl, "--shutdown", null, null, out ignore);
                // Wait until the disk is released.
                for (int i = 0; i < 60; i++)
                {
                    try { using (new FileStream(v.Path, FileMode.Open, FileAccess.Read, FileShare.None)) break; }
                    catch (Exception) { System.Threading.Thread.Sleep(500); }
                }
                string script = Path.Combine(Path.GetTempPath(), "dsa-compact-" + Guid.NewGuid().ToString("N") + ".txt");
                File.WriteAllText(script, "select vdisk file=\"" + v.Path + "\"\r\nattach vdisk readonly\r\ncompact vdisk\r\ndetach vdisk\r\n");
                try
                {
                    code = RunTool(Sys32("diskpart.exe"), "/s \"" + script + "\"", o =>
                    {
                        double pc = LastPercent(o);
                        report(pc >= 0 ? string.Format("Shrinking the virtual disk: {0:0} %", pc) : "Shrinking the virtual disk...", v.Path, pc >= 0 ? pc / 100 : -1);
                    }, null, out output);
                }
                finally { try { File.Delete(script); } catch (Exception) { } }
            });
            long after = FileSize(v.Path);
            statusLabel.Text = code == 0
                ? string.Format("Shrank {0}: {1} -> {2} ({3} freed).", Path.GetFileName(v.Path), Fmt.Size(before), Fmt.Size(after), Fmt.Size(Math.Max(0, before - after)))
                : "The virtual disk could not be shrunk (diskpart error " + code + "): " + LastLine(output);
            var t = RefreshSysGroup("drives");
            await RefreshSysGroup("disks");
        }

        /// <summary>Removes broken registry entries after a .reg backup; returns the backup file.</summary>
        async Task<string> RemoveRegistry(List<RegIssue> items, bool confirm)
        {
            if (items.Count == 0) return null;
            if (confirm && SelfTestDir == null && Alert(AlertIcon.Warn,
                    string.Format("Remove {0:N0} broken registry entr{1}?", items.Count, items.Count == 1 ? "y" : "ies"),
                    "They point at programs that no longer exist. Nothing else is touched.",
                    "Each one is saved to a .reg backup first (in " + BackupFolder + "); open that file to put them back.",
                    items.Select(r => r.Category + ": " + r.Display + "\t" + r.Name).ToList(), "Remove", "Cancel") != "Remove") return null;
            var errors = new List<string>();
            string backup = null;
            int k = 0;
            await SysRun(true, "Removing broken registry entries...", false, report =>
            {
                backup = RemoveRegIssues(items, errors, r =>
                {
                    k++;
                    report(string.Format("Removing broken registry entries: {0:N0} of {1:N0}", k, items.Count), r.Display, (double)k / items.Count);
                });
            });
            int removed = items.Count - errors.Count;
            statusLabel.Text = string.Format("Removed {0:N0} broken registry entr{1}{2}.{3}", removed, removed == 1 ? "y" : "ies",
                errors.Count > 0 ? string.Format(", {0:N0} could not be removed", errors.Count) : "", backup != null ? " Backup: " + backup : "");
            if (errors.Count > 0 && SelfTestDir == null) ShowDeleteErrors(errors, "removed");
            await RefreshSysGroup("registry");
            return backup;
        }

        // ---------------------------------------------------------------- self-test (no changes to the machine except its own test keys)

        const string DismSample = "Deployment Image Servicing and Management tool\r\nVersion: 10.0.19041.844\r\n\r\nImage Version: 10.0.19045.3803\r\n\r\n" +
            "[===========================99.7%========================= ]\r\n[==========================100.0%==========================]\r\n\r\n" +
            "Component Store (WinSxS) information:\r\n\r\nWindows Explorer Reported Size of Component Store : 8.12 GB\r\n\r\nActual Size of Component Store : 7.89 GB\r\n\r\n" +
            "    Shared with Windows : 5.71 GB\r\n    Backups and Disabled Features : 1.95 GB\r\n    Cache and Temporary Data :  222.53 MB\r\n\r\n" +
            "Date of Last Cleanup : 2023-12-13 10:04:50\r\n\r\nNumber of Reclaimable Packages : 3\r\nComponent Store Cleanup Recommended : Yes\r\n\r\nThe operation completed successfully.\r\n";

        const string VssShadowsSample = "vssadmin 1.1 - Volume Shadow Copy Service administrative command-line tool\r\n(C) Copyright 2001-2013 Microsoft Corp.\r\n\r\n" +
            "Contents of shadow copy set ID: {b5946137-7b9f-4925-af80-51abd60b20d5}\r\n   Contained 1 shadow copies at creation time: 10/1/2023 2:28:12 PM\r\n" +
            "      Shadow Copy ID: {e1ab3a13-1111-4c2a-9a8e-0f5c9d0a0001}\r\n         Original Volume: (C:)\\\\?\\Volume{4c1b0b5e-0000-0000-0000-100000000000}\\\r\n" +
            "         Shadow Copy Volume: \\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\r\n         Provider: 'Microsoft Software Shadow Copy provider 1.0'\r\n" +
            "         Type: ClientAccessibleWriters\r\n\r\n" +
            "Contents of shadow copy set ID: {c5946137-7b9f-4925-af80-51abd60b20d6}\r\n   Contained 1 shadow copies at creation time: 11/15/2023 9:05:00 AM\r\n" +
            "      Shadow Copy ID: {e1ab3a13-2222-4c2a-9a8e-0f5c9d0a0002}\r\n         Original Volume: (C:)\\\\?\\Volume{4c1b0b5e-0000-0000-0000-100000000000}\\\r\n\r\n" +
            "Contents of shadow copy set ID: {d5946137-7b9f-4925-af80-51abd60b20d7}\r\n   Contained 1 shadow copies at creation time: 11/20/2023 9:05:00 AM\r\n" +
            "      Shadow Copy ID: {e1ab3a13-3333-4c2a-9a8e-0f5c9d0a0003}\r\n         Original Volume: (D:)\\\\?\\Volume{5c1b0b5e-0000-0000-0000-100000000000}\\\r\n";

        const string VssStorageSample = "vssadmin 1.1 - Volume Shadow Copy Service administrative command-line tool\r\n(C) Copyright 2001-2013 Microsoft Corp.\r\n\r\n" +
            "Shadow Copy Storage association\r\n   For volume: (C:)\\\\?\\Volume{4c1b0b5e-0000-0000-0000-100000000000}\\\r\n" +
            "   Shadow Copy Storage volume: (C:)\\\\?\\Volume{4c1b0b5e-0000-0000-0000-100000000000}\\\r\n" +
            "   Used Shadow Copy Storage space: 1.23 GB (2%)\r\n   Allocated Shadow Copy Storage space: 1.5 GB (3%)\r\n   Maximum Shadow Copy Storage space: 4.66 GB (10%)\r\n\r\n" +
            "Shadow Copy Storage association\r\n   For volume: (D:)\\\\?\\Volume{5c1b0b5e-0000-0000-0000-100000000000}\\\r\n" +
            "   Shadow Copy Storage volume: (D:)\\\\?\\Volume{5c1b0b5e-0000-0000-0000-100000000000}\\\r\n" +
            "   Used Shadow Copy Storage space: 500 MB (1%)\r\n   Allocated Shadow Copy Storage space: 600 MB (1%)\r\n   Maximum Shadow Copy Storage space: UNBOUNDED (100%)\r\n";

        /// <summary>Screenshot: every group loaded and expanded, the hibernation file selected (its actions show in the bar).</summary>
        async Task PrepareSystemShot()
        {
            for (int k = 0; k < 600 && (sysGroups == null || sysGroups.Any(g => g.Loading || !g.Loaded)); k++) await Task.Delay(200);
            if (sysGroups == null) return;
            foreach (var g in sysGroups) g.Expanded = true;
            ShowSystem();
            foreach (ListViewItem it in pSystem.List.Items)
            {
                var si = ((ItemInfo)it.Tag).Data as SysItem;
                if (si == null || si.Actions.Count == 0 || si.Data is DriveHealth) continue;
                it.Selected = true;
                break;
            }
            UpdateSystemButtons();
        }

        async Task SelfTestSystem(Action<bool, string> check)
        {
            const string runName = "DSA SelfTest Startup", validName = "DSA SelfTest Valid";
            string orphanKey = UninstallPath + @"\DSA-SelfTest-Orphan";
            string gone = Path.Combine(SelfTestDir, "gone");
            try
            {
                check(pSystem != null && pages.IndexOf(pSystem) == pages.IndexOf(pApps) + 1 && pages.IndexOf(pApps) == pages.IndexOf(pSuggest) + 1,
                    "system: the System tab comes right after Apps (" + string.Join(", ", pages.Select(p => p.Title)) + ")");

                // Parsing: DISM and vssadmin outputs (fixed samples), sizes and progress.
                var d = ParseDismAnalyze(DismSample);
                check(d.Actual == ParseSize("7.89 GB") && d.Backups == (long)Math.Round(1.95 * (1L << 30)) && d.Cache == (long)Math.Round(222.53 * (1L << 20)) &&
                      d.Shared == ParseSize("5.71 GB") && d.Recommended == true && d.Reclaimable == 3 && d.Estimate == d.Backups + d.Cache,
                    string.Format("system: DISM analysis parsed (actual {0}, backups {1}, cache {2}, recommended {3})", Fmt.Size(d.Actual), Fmt.Size(d.Backups), Fmt.Size(d.Cache), d.Recommended));
                check(LastPercent("[==========   23.4%          ]\r[===============  57.0%     ]\r") == 57.0 && LastPercent("  10 percent completed\r\n  100 percent completed") == 100 &&
                      ParseSize("1,024 bytes") == 1024 && ParseSize("UNBOUNDED (100%)") == -1, "system: progress percentages and sizes parsed");
                var sh = ParseVssShadows(VssShadowsSample);
                check(sh.Count == 3 && sh.Count(s => s.Volume == "C:") == 2 && sh[0].Id == "{e1ab3a13-1111-4c2a-9a8e-0f5c9d0a0001}" && sh[2].Volume == "D:" &&
                      sh[0].Created.Year == 2023 && sh[0].Created < sh[1].Created,
                    "system: vssadmin list shadows parsed (" + sh.Count + " shadow copies)");
                var st = ParseVssStorage(VssStorageSample);
                check(st.Count == 2 && st[0].Volume == "C:" && st[0].Used == ParseSize("1.23 GB") && st[0].Max == ParseSize("4.66 GB") && st[1].Used == 500L << 20 && st[1].Max == -1,
                    "system: vssadmin list shadowstorage parsed (used, maximum, unbounded)");
                check(CommandTarget("\"C:\\x y\\a.exe\" /s") == "C:\\x y\\a.exe" && CommandTarget("C:\\Program Files\\x\\a.exe -min") == "C:\\Program Files\\x\\a.exe" &&
                      CommandTarget("rundll32.exe C:\\x\\b.dll,Entry") == "C:\\x\\b.dll" && CommandTarget("ctfmon.exe") == null && CommandTarget("cmd /c echo") == null,
                    "system: command lines parsed into the program they start");

                // Registry check on fake entries: a startup value and an uninstall entry pointing at missing programs, and a valid startup value.
                if (Directory.Exists(gone)) Directory.Delete(gone, true);
                using (var k = Registry.CurrentUser.CreateSubKey(RunPath))
                {
                    k.SetValue(runName, "\"C:\\nonexistent\\dsa-missing.exe\" /x");
                    k.SetValue(validName, "\"" + Application.ExecutablePath + "\" /y");
                }
                using (var k = Registry.CurrentUser.CreateSubKey(orphanKey))
                {
                    k.SetValue("DisplayName", "DSA SelfTest Orphan");
                    k.SetValue("InstallLocation", gone);
                    k.SetValue("UninstallString", "\"" + Path.Combine(gone, "unins.exe") + "\"");
                }
                viewTabs.SelectedIndex = pages.IndexOf(pSystem);
                FillSystem();
                for (int i = 0; i < 600 && (sysGroups == null || sysGroups.Any(g => g.Loading || !g.Loaded)); i++) await Task.Delay(100);
                await RefreshSysGroup("registry");
                Func<RegIssue> runIssue = () => regIssues == null ? null : regIssues.FirstOrDefault(r => r.Hive == RegistryHive.CurrentUser && r.ValueName == runName);
                Func<RegIssue> orphan = () => regIssues == null ? null : regIssues.FirstOrDefault(r => r.Hive == RegistryHive.CurrentUser && r.SubKey == orphanKey && r.ValueName == null);
                check(runIssue() != null && runIssue().Target == "C:\\nonexistent\\dsa-missing.exe", "system: a startup entry whose program is missing is found as broken");
                check(orphan() != null && orphan().Category == "Uninstall entry", "system: an uninstall entry whose folder and uninstaller are gone is found as broken");
                check(regIssues != null && !regIssues.Any(r => r.ValueName == validName), "system: a startup entry pointing at an existing program is not flagged");
                var regGroup = sysGroups.First(g => g.Key == "registry");
                check(regGroup.Items.Any(i => i.Data == runIssue()) && regGroup.Items.Any(i => i.Data == orphan()), "system: both are listed in the Registry check group");

                // Remove only the two test entries (nothing else on this machine is touched): backup first, then delete.
                var mine = new List<RegIssue> { runIssue(), orphan() };
                string backup = await RemoveRegistry(mine, false);
                string text = backup != null && File.Exists(backup) ? File.ReadAllText(backup, System.Text.Encoding.Unicode) : "";
                check(text.StartsWith("Windows Registry Editor Version 5.00") && text.Contains("\"" + runName + "\"=") && text.Contains("dsa-missing.exe") && text.Contains("DSA-SelfTest-Orphan") &&
                      text.Contains("DSA SelfTest Orphan"), "system: removing creates a .reg backup with both entries (" + (backup ?? "none") + ")");
                bool valueGone, validKept, keyGone;
                using (var k = Registry.CurrentUser.OpenSubKey(RunPath)) { valueGone = k.GetValue(runName) == null; validKept = k.GetValue(validName) != null; }
                using (var k = Registry.CurrentUser.OpenSubKey(orphanKey)) keyGone = k == null;
                check(valueGone && keyGone && validKept, "system: both were deleted (the value as a value), the valid startup entry and the Run key stay");
                check(runIssue() == null && orphan() == null, "system: the Registry check group no longer lists them");
                if (backup != null) try { File.Delete(backup); } catch (Exception) { }

                // Drives: a row for the system drive with free and total space.
                var drives = Health.ReadDrives(true);
                var sysd = drives.FirstOrDefault(x => string.Equals(x.Root, SystemRoot, StringComparison.OrdinalIgnoreCase));
                var driveRows = sysGroups.First(g => g.Key == "drives").Items;
                check(sysd != null && sysd.Total > 0 && sysd.Free > 0 && sysd.Free <= sysd.Total &&
                      driveRows.Any(i => i.Data is DriveHealth && ((DriveHealth)i.Data).Root == SystemRoot && i.SizeText.Contains(" free of ")),
                    "system: drive row for " + SystemRoot + " with free/total" + (sysd != null ? " (" + Fmt.Size(sysd.Free) + " free of " + Fmt.Size(sysd.Total) + ", " + sysd.HealthText + ")" : ""));
                var low = new DriveHealth { Root = "Z:\\", Free = 5L << 30, Total = 1000L << 30 };
                var ok = new DriveHealth { Root = "Y:\\", Free = 300L << 30, Total = 1000L << 30 };
                var pct = new DriveHealth { Root = "X:\\", Free = 20L << 30, Total = 400L << 30 };
                check(low.LowSpace && !ok.LowSpace && pct.LowSpace, "system: low space = under 10 GB or under 10 % free");
                check(Health.HealthName(0) == "Healthy" && Health.HealthName(1) == "Warning" && Health.HealthName(2) == "Unhealthy" && Health.HealthName(null) == "",
                    "system: disk health states mapped");
                viewTabs.SelectedIndex = pages.IndexOf(pContents);
            }
            catch (Exception ex) { check(false, "system: exception " + ex); }
            finally
            {
                try { using (var k = Registry.CurrentUser.OpenSubKey(RunPath, true)) if (k != null) { k.DeleteValue(runName, false); k.DeleteValue(validName, false); } } catch (Exception) { }
                try { Registry.CurrentUser.DeleteSubKeyTree(orphanKey, false); } catch (Exception) { }
            }
        }
    }
}

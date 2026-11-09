using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace SpacePie
{
    /// <summary>
    /// Getting around and knowing what you look at: Back / Forward through the folders opened, the path bar above the
    /// folder contents, the banner naming folders that could not be read, and labels for well-known folders.
    /// </summary>
    internal sealed partial class MainForm
    {
        // ---------------------------------------------------------------- back / forward

        readonly List<KeyValuePair<DirNode, string>> navBack = new List<KeyValuePair<DirNode, string>>(), navForward = new List<KeyValuePair<DirNode, string>>();
        bool navigating;
        RoundButton btnBack, btnForward;
        Breadcrumb crumbs;
        Banner unreadBanner;
        RoundButton unreadAdmin;
        /// <summary>Scanned trees whose unreadable-folders banner was closed (shown again after the next scan).</summary>
        readonly HashSet<DirNode> unreadClosed = new HashSet<DirNode>();
        const int MaxHistory = 100;

        void BuildNavigation()
        {
            btnBack = Btn("Back", ButtonKind.Secondary, "Back to the folder shown before (Alt+Left)", GoBack);
            btnBack.Glyph = (g, r, c) => Theme.DrawArrow(g, r, c, true);
            btnForward = Btn("Forward", ButtonKind.Secondary, "Forward again (Alt+Right)", GoForward);
            btnForward.Glyph = (g, r, c) => Theme.DrawArrow(g, r, c, false);
            btnBack.Compact = btnForward.Compact = true;

            crumbs = new Breadcrumb();
            crumbs.PartClicked += o =>
            {
                if (busy) return;
                if (o == ThisPcPart) { ShowThisPc(); return; }
                var d = o as DirNode;
                if (d != null && IsAttached(d)) SelectDir(d);
            };

            unreadBanner = new Banner();
            unreadBanner.AddButton("Show them", "List the folders that could not be read", tips, ShowUnreadable);
            unreadAdmin = unreadBanner.AddButton("Run as administrator", "Restart elevated: administrators can read these folders (and drives are read from the master file table)", tips, RestartAsAdmin);
            unreadAdmin.Visible = !isAdmin;
            unreadBanner.Closed += (s, e) => { if (current != null && IsAttached(current)) unreadClosed.Add(current.Top); };
            // Top to bottom: banner, navigation row (Back, Forward, Up, Rescan, then the path bar), caption, list
            // (the last docked control is the topmost).
            var navRow = new Panel { Dock = DockStyle.Top, BackColor = Theme.SURFACE };
            var navButtons = new[] { btnBack, btnForward, btnUp, btnRescan };
            crumbs.Dock = DockStyle.None;
            navRow.Controls.AddRange(navButtons);
            navRow.Controls.Add(crumbs);
            navRow.Layout += (s, e) =>
            {
                // A narrow list pane (or a large zoom): the buttons flow onto more lines, the path bar onto a line of its own.
                int gap = S(6), x = 0, y = 0, rowW = navRow.ClientSize.Width;
                int ch = crumbs.Font.Height + S(12);
                int h = Math.Max(ch, navButtons[0].GetPreferredSize(Size.Empty).Height);
                foreach (var b in navButtons)
                {
                    var p = b.GetPreferredSize(Size.Empty);
                    if (x > 0 && x + p.Width > rowW) { x = 0; y += h + S(4); }
                    b.Bounds = new Rectangle(x, y + (h - p.Height) / 2, p.Width, p.Height);
                    x += p.Width + gap;
                }
                x += S(4);
                if (rowW - x < S(120)) { x = 0; y += h + S(4); }
                crumbs.Bounds = new Rectangle(x, y + (h - ch) / 2, Math.Max(S(20), rowW - x), ch);
                if (navRow.Height != y + h + S(4)) navRow.Height = y + h + S(4);
            };
            pContents.Root.Controls.Add(navRow);
            pContents.Root.Controls.Add(unreadBanner);
        }

        /// <summary>Called whenever a folder is opened: remembers the one shown before, for Back.</summary>
        void RecordNavigation(DirNode from, DirNode to)
        {
            if (navigating || from == null || to == null || from == to || !IsAttached(from)) return;
            navBack.Add(new KeyValuePair<DirNode, string>(from, from.FullPath));
            if (navBack.Count > MaxHistory) navBack.RemoveAt(0);
            navForward.Clear();
        }

        void GoBack() { Step(navBack, navForward); }

        void GoForward() { Step(navForward, navBack); }

        /// <summary>Opens the most recent folder of from that still exists in a scan; the folder shown now goes to to.</summary>
        void Step(List<KeyValuePair<DirNode, string>> from, List<KeyValuePair<DirNode, string>> to)
        {
            if (busy) return;
            while (from.Count > 0)
            {
                var entry = from[from.Count - 1];
                from.RemoveAt(from.Count - 1);
                // The same folder object while it is still in a scan (also in a saved scan); otherwise by its path.
                var d = IsAttached(entry.Key) ? entry.Key : FindScanned(entry.Value, true);
                if (d == null) continue;
                if (current != null) to.Add(new KeyValuePair<DirNode, string>(current, current.FullPath));
                navigating = true;
                try
                {
                    SelectDir(d);
                    if (!ActivePage.FollowsFolder) viewTabs.SelectedIndex = pages.IndexOf(pContents);
                }
                finally { navigating = false; }
                break;
            }
            UpdateNavButtons();
        }

        void UpdateNavButtons()
        {
            if (btnBack == null) return;
            btnBack.Enabled = !busy && navBack.Count > 0;
            btnForward.Enabled = !busy && navForward.Count > 0;
        }

        /// <summary>Mouse back / forward buttons and keyboard media keys arrive as WM_APPCOMMAND from whatever control has focus.</summary>
        bool AppCommand(ref Message m)
        {
            const int WM_APPCOMMAND = 0x319;
            if (m.Msg != WM_APPCOMMAND) return false;
            int cmd = (int)(((long)m.LParam >> 16) & 0x0FFF);
            if (cmd == 1) { GoBack(); m.Result = (IntPtr)1; return true; }       // APPCOMMAND_BROWSER_BACKWARD
            if (cmd == 2) { GoForward(); m.Result = (IntPtr)1; return true; }    // APPCOMMAND_BROWSER_FORWARD
            return false;
        }

        /// <summary>The item belongs to a saved scan opened from a file (browsed only, never changed).</summary>
        bool FromReadOnly(ItemInfo it)
        {
            DirNode d = it.IsDir ? it.Dir : it.File != null ? it.File.Dir : null;
            var r = d != null ? RootOf(d.Top) : null;
            return r != null && r.ReadOnly;
        }

        // ---------------------------------------------------------------- path bar

        /// <summary>This PC, then the drive (unscanned) or every folder from the scanned top down to d.</summary>
        void UpdateCrumbs(DirNode d, ScanRoot unscanned = null)
        {
            if (crumbs == null) return;
            var parts = new List<KeyValuePair<string, object>> { new KeyValuePair<string, object>("This PC", ThisPcPart) };
            if (unscanned != null) parts.Add(new KeyValuePair<string, object>(unscanned.DisplayName, unscanned));
            if (d != null)
            {
                var chain = new List<DirNode>();
                for (var n = d; n != null; n = n.Parent) chain.Insert(0, n);
                var r = RootOf(chain[0]);
                foreach (var n in chain)
                    parts.Add(new KeyValuePair<string, object>(n.Parent == null ? (r != null && r.IsDrive ? r.DisplayName : n.Name.TrimEnd('\\')) : n.Name, n));
            }
            crumbs.SetParts(parts);
            crumbs.Visible = parts.Count > 0;
        }

        // ---------------------------------------------------------------- folders that could not be read

        /// <summary>Unreadable folders per scanned tree (cached until the tree changes).</summary>
        readonly Dictionary<DirNode, List<DirNode>> deniedCache = new Dictionary<DirNode, List<DirNode>>();

        List<DirNode> DeniedUnder(DirNode top)
        {
            List<DirNode> list;
            if (deniedCache.TryGetValue(top, out list)) return list;
            list = top.Descendants().Where(n => n.Denied).ToList();
            deniedCache[top] = list;
            return list;
        }

        /// <summary>Shows or hides the banner for the tree that holds d: how many folders could not be read and what to do.</summary>
        void UpdateUnreadBanner(DirNode d)
        {
            if (unreadBanner == null) return;
            if (d == null || !IsAttached(d)) { unreadBanner.Message = null; return; }
            var r = RootOf(d.Top);
            var denied = DeniedUnder(d.Top);
            var here = denied.Where(n => n.IsUnder(d)).ToList();
            if (here.Count == 0 || (r != null && r.ReadOnly) || unreadClosed.Contains(d.Top)) { unreadBanner.Message = null; return; }
            // As administrator the folders still closed are closed to every program (SYSTEM-only, other accounts): nothing
            // the user can do, so nothing is shown.
            if (!UnreadFixable) { unreadBanner.Message = null; return; }
            unreadAdmin.Visible = true;
            unreadBanner.Message = string.Format("{0:N0} folder{1} {2} could not be read (access denied); {3} size{4} {5} not in these totals. Run as administrator to read them.",
                here.Count, here.Count == 1 ? "" : "s", d.Parent == null ? "in this scan" : "in here", here.Count == 1 ? "its" : "their",
                here.Count == 1 ? "" : "s", here.Count == 1 ? "is" : "are");
            unreadBanner.PerformLayout();
        }

        /// <summary>Self-test: whether running as administrator would open the folders (null = ask the system).</summary>
        internal bool? UnreadCanElevate;

        /// <summary>Running as administrator would open (most of) the folders that could not be read.</summary>
        bool UnreadFixable { get { return UnreadCanElevate ?? !isAdmin; } }

        void ShowUnreadable()
        {
            var d = current;
            if (d == null || !IsAttached(d)) return;
            var here = DeniedUnder(d.Top).Where(n => n.IsUnder(d)).ToList();
            if (here.Count == 0 || !UnreadFixable) return;
            var lines = here.Take(2000).Select(n => n.FullPath + "\taccess denied").ToList();
            if (here.Count > lines.Count) lines.Add(string.Format("... and {0:N0} more", here.Count - lines.Count));
            Alert(AlertIcon.Warn, string.Format("{0:N0} folder{1} could not be read", here.Count, here.Count == 1 ? "" : "s"),
                "Windows refused access, so what is inside them is not counted. Most belong to Windows or to other users.",
                isAdmin ? "Some folders stay closed even to administrators (other users' profiles, system-protected folders)."
                    : "Run as administrator (in the toolbar, or here) to read most of them; whole drives are then read from the master file table, which sees everything.",
                lines, "OK");
        }

        // ---------------------------------------------------------------- what is this folder

        /// <summary>The "What it is" column of a folder contents row (empty when the folder or file is not a known one).</summary>
        static KnownItem KnownFor(ItemInfo it)
        {
            if (it == null || it.IsSummary) return null;
            if (it.IsDir) return Known.Lookup(it.Dir.FullPath, it.Dir.Name);
            if (it.File != null) return Known.Lookup(it.File.FullPath, null);
            return null;
        }
    }
}

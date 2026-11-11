using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SpacePie
{
    /// <summary>A top-level entry of the tree: a drive (scanned or not) or a folder the user scanned.</summary>
    internal sealed class ScanRoot
    {
        public string Path = "";
        public bool IsDrive, IsSystem;
        public string Label = "";
        public long Total, Free;                 // capacity of the drive that holds Path (0 = unknown)
        public DirNode Node;                     // null until scanned
        public bool Scanning;
        public PrevNode Previous;                // the scan before the current one (for the Changes view)
        public ulong JournalId;                  // NTFS change journal and its position when Node's scan started (0 = unknown)
        public long JournalUsn;
        public bool Complete;                    // Node is a whole scan (not stopped), so it can be saved for a fast restart
        public DateTime PreviousTime;
        /// <summary>A scan opened from a file (Open scan): browsed only; nothing is rescanned, watched or deleted.</summary>
        public bool ReadOnly;
        public string SourceFile;
        public DateTime Scanned;

        public string DisplayName
        {
            get
            {
                if (ReadOnly) return Path + "  (saved scan, " + Scanned.ToString("yyyy-MM-dd HH:mm") + ")";
                return IsDrive && Label.Length > 0 ? Path + "  " + Label : Path;
            }
        }
    }

    internal sealed partial class MainForm : Form
    {
        const string AppName = "SpacePie";
        const int TopCount = 1000;
        const int MaxFilesShown = 2000;

        readonly bool isAdmin;

        DirNode current;
        readonly List<ScanRoot> roots = new List<ScanRoot>();
        ScanRoot active;
        bool drivesChanged;
        bool scanning;
        ScanRoot scanRoot;
        ScanBar scanBar;
        /// <summary>Red delete progress strip (same place and shape as the scan bar).</summary>
        ScanBar deleteBar;
        UpdateManager updates;
        /// <summary>Scanned tree of the root that holds the current selection (null when that root is not scanned).</summary>
        DirNode root { get { return active != null ? active.Node : null; } }
        Scanner scanner;
        DeleteJob deleteJob;
        bool busy;
        Control lastView;

        readonly PathInput pathBox;
        readonly Label pathLabel;
        readonly RoundButton btnBrowse, btnScan, btnUp, btnRescan, btnExplorer, btnAddList, btnDelete, btnAdmin, btnExport, btnBasket;
        readonly TitleBar titleBar;
        readonly Segmented measure;
        readonly Panel toolbar;
        readonly Panel mainArea;
        /// <summary>The list pane (middle); the toolbar's selection buttons line up with its edges.</summary>
        readonly RoundedPanel listPanel;
        readonly SplitContainer split2;
        readonly PieChart chart;
        readonly Segmented chartMode;
        static string TreemapMarker { get { return AppData.Path("treemap"); } }
        readonly SizeListView contents;
        readonly Label statusLabel, driveLabel;
        readonly BusyOverlay overlay;
        readonly System.Windows.Forms.Timer uiTimer;
        readonly ContextMenuStrip menu;
        readonly ToolTip tips = new ToolTip();
        ToolStripMenuItem miOpen, miPreview, miExplorer, miCopy, miProps, miRescan, miAddList, miRecycle, miDelete, miCloseScan;

        public MainForm(string initialPath)
        {
            // One dark tooltip for buttons, list rows and tree nodes.
            Splash.Status("Building the main window");
            // Text drawn cut off ("...") anywhere in this window is shown in full on hover.
            CutText.Hover += (c, text) => { if (!IsDisposed && c.FindForm() == this) Hover(c, text); };
            tips.OwnerDraw = true;
            tips.Popup += (s, e) =>
            {
                var sz = TextRenderer.MeasureText(tips.GetToolTip(e.AssociatedControl), Theme.FONT_9);
                e.ToolTipSize = new Size(sz.Width + S(16), sz.Height + S(10));
            };
            tips.Draw += (s, e) =>
            {
                e.Graphics.Clear(Theme.SURFACE);
                using (var pen = new Pen(Theme.BORDER)) e.Graphics.DrawRectangle(pen, 0, 0, e.Bounds.Width - 1, e.Bounds.Height - 1);
                TextRenderer.DrawText(e.Graphics, e.ToolTipText, Theme.FONT_9, new Rectangle(S(8), S(5), e.Bounds.Width - S(16), e.Bounds.Height - S(10)),
                    Theme.FG, TextFormatFlags.NoPrefix | TextFormatFlags.Left);
            };
            using (var g = CreateGraphics()) { Theme.Dpi = g.DpiX / 96f; Theme.Scale = Theme.Dpi * Theme.Zoom; }
            isAdmin = new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);

            Text = AppName + (isAdmin ? " (Administrator)" : "");
            Font = Theme.FONT;
            BackColor = Theme.BG;
            ForeColor = Theme.FG;
            AutoScaleMode = AutoScaleMode.None;
            // 1280x760 by default, at most 85 % of the working area so it always fits with room around it.
            var wa = Screen.FromPoint(Cursor.Position).WorkingArea;
            Size = new Size(Math.Min(S(1280), wa.Width * 85 / 100), Math.Min(S(760), wa.Height * 85 / 100));
            MinimumSize = new Size(Math.Min(S(900), wa.Width), Math.Min(S(520), wa.Height));
            // Placed explicitly in the working area (CenterScreen put the window partly below the taskbar).
            StartPosition = FormStartPosition.Manual;
            Location = new Point(wa.X + (wa.Width - Width) / 2, wa.Y + (wa.Height - Height) / 2);
            KeyPreview = true;
            AllowDrop = true;
            Padding = new Padding(S(15), S(36) + S(4), S(15), 0);   // top: the custom title bar (placed at 0,0 below)
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch (Exception) { }

            // Toolbar: path row, then the actions that work on the selection
            Splash.Status("Listing drives");
            pathLabel = new Label { Text = "Location:", AutoSize = true, ForeColor = Theme.FG, BackColor = Theme.BG, Font = Theme.FONT };
            pathBox = new PathInput();
            foreach (var d in DriveInfo.GetDrives())
                if (d.IsReady) pathBox.Choices.Add(d.Name);
            pathBox.Submitted += (s, e) => StartScan();
            pathBox.ChoiceCommitted += (s, e) => StartScan();
            tips.SetToolTip(pathBox.Box, "Drive or folder to analyze (you can also drag a folder onto the window)");

            btnBrowse = Btn("Choose...", ButtonKind.Secondary, "Choose a folder", Browse);
            btnScan = Btn("Scan", ButtonKind.Primary, "Analyze the drive or folder (Enter)", StartScan);
            btnAdmin = Btn("Run as administrator", ButtonKind.Secondary, "Restart elevated to read folders that need admin rights", RestartAsAdmin);
            btnAdmin.Visible = !isAdmin;
            btnUp = Btn("Up", ButtonKind.Secondary, "Go to the parent folder (Backspace)", GoUp);
            btnUp.Glyph = Theme.DrawArrowUp;
            btnRescan = Btn("Rescan folder", ButtonKind.Secondary, "Rescan the selected folder (F5)", RescanSelected);
            btnRescan.Glyph = Theme.DrawRefresh;
            btnUp.Compact = btnRescan.Compact = true;
            btnExplorer = Btn("Show in Explorer", ButtonKind.Secondary, "Open the selected item in Windows Explorer", ShowInExplorer);
            btnAddList = Btn("Add to delete list", ButtonKind.Secondary, "Collect the selected items in the delete list; review them there, then delete them together (Ctrl+D)", AddSelectionToBasket);
            btnDelete = Btn("Delete permanently", ButtonKind.Danger, "Permanently delete the selected items, bypassing the Recycle Bin (Ctrl+Shift+D)", DeleteSelected);
            // The delete list is always one click away, just left of Delete permanently (also in the views bar while
            // DeleteListInViewsBar is on).
            btnBasket = Btn("Delete list", ButtonKind.Warn, "Review everything collected for deletion, then move it to the Recycle Bin or delete it permanently",
                () => { if (pBasket != null) viewTabs.SelectedIndex = pages.IndexOf(pBasket); });
            btnExport = Btn("Export...", ButtonKind.Secondary, "Save the scan as an HTML report, a CSV file, or a scan file to open again later", ExportScan);
            btnOpenScan = Btn("Import...", ButtonKind.Secondary, "Import a scan saved with Export (" + Snapshot.ScanFileExtension + "): browse it read-only, next to the drives", OpenScanDialog);
            btnBrowse.Icon = Icons.Folder;
            btnScan.Icon = Icons.Scan;
            btnAdmin.Icon = Icons.Shield;
            btnExplorer.Icon = Icons.Reveal;
            btnAddList.Icon = Icons.TrashAdd;
            btnAddList.Fore = Theme.WARN;   // the delete list's colour (its views bar row)
            btnBasket.Icon = Icons.Trash;
            btnBasket.ExtraRight = 4;   // about a space after "Delete list": a little more room on its right
            btnDelete.Icon = Icons.Danger;
            btnOpenScan.Icon = Icons.Import;
            btnExport.Icon = Icons.Export;

            measure = new Segmented("Size", "Size on disk");
            measure.SelectedIndex = DirNode.OnDisk ? 1 : 0;
            measure.SelectedIndexChanged += (s, e) => SetMeasure(measure.SelectedIndex == 1);
            tips.SetToolTip(measure, "Size: file lengths, as Explorer shows them. Size on disk: the space really used (compression, clusters, online-only cloud files)");

            toolbar = new Panel { Dock = DockStyle.Top, BackColor = Theme.BG };
            toolbar.Controls.AddRange(new Control[] { pathLabel, pathBox, btnBrowse, btnScan, btnAdmin, btnExplorer, btnAddList, btnBasket, btnDelete, btnExport, btnOpenScan, measure });
            toolbar.Layout += (s, e) => LayoutToolbar();

            // Context menu
            menu = new ContextMenuStrip
            {
                Renderer = new DarkRenderer(), BackColor = Theme.SURFACE, ForeColor = Theme.FG, Font = Theme.FONT,
                ShowImageMargin = false, Padding = new Padding(0, S(4), 0, S(4)), DropShadowEnabled = !Theme.HasDwmCorners
            };
            miOpen = new ToolStripMenuItem("Open folder", null, (s, e) => OpenSelected());
            miPreview = new ToolStripMenuItem("Preview", null, (s, e) => PreviewSelected()) { ShortcutKeyDisplayString = "Space" };
            miExplorer = new ToolStripMenuItem("Show in Explorer", null, (s, e) => ShowInExplorer());
            miCopy = new ToolStripMenuItem("Copy path", null, (s, e) => CopyPath());
            miProps = new ToolStripMenuItem("Properties", null, (s, e) => ShowProperties()) { ShortcutKeyDisplayString = "Alt+Enter" };
            miRescan = new ToolStripMenuItem("Rescan folder", null, (s, e) => RescanSelected()) { ShortcutKeyDisplayString = "F5" };
            miAddList = new ToolStripMenuItem("Add to delete list", null, (s, e) => AddSelectionToBasket()) { ShortcutKeyDisplayString = "Ctrl+D" };
            miRecycle = new ToolStripMenuItem("Move to Recycle Bin...", null, (s, e) => RecycleSelected());
            miDelete = new ToolStripMenuItem("Delete permanently...", null, (s, e) => DeleteSelected()) { ShortcutKeyDisplayString = "Ctrl+Shift+D" };
            miCloseScan = new ToolStripMenuItem("Close saved scan", null, (s, e) => CloseSavedScan(SelectedSavedScan()));
            miIgnoreSuggestion = new ToolStripMenuItem("Never suggest this", null, (s, e) => IgnoreSelectedSuggestions());
            var sepIgnore = new ToolStripSeparator();
            menu.Items.AddRange(new ToolStripItem[] { miIgnoreSuggestion, sepIgnore, miOpen, miPreview, miExplorer, miCopy, miProps, miRescan, new ToolStripSeparator(), miAddList, miRecycle, miDelete, miCloseScan });
            foreach (ToolStripItem it in menu.Items) it.ForeColor = Theme.FG;
            miDelete.ForeColor = Theme.WARN_FG;
            menu.Opened += (s, e) => Theme.RoundPopup(menu.Handle);
            menu.Opening += (s, e) =>
            {
                if (menu.SourceControl != null) lastView = menu.SourceControl;
                var sel = GetSelection();
                bool any = sel.Count > 0 && !busy;
                miOpen.Enabled = any && sel.Count == 1;
                miPreview.Enabled = any && sel.Count == 1 && (sel[0].IsDir || sel[0].File != null);
                miProps.Enabled = any && sel.Count == 1;
                miExplorer.Enabled = any;
                miCopy.Enabled = any;
                miRescan.Enabled = any && !scanning && sel.Count == 1 && sel[0].IsDir && !FromReadOnly(sel[0]);
                bool deletable = any && !scanning && sel.All(i => i.CanDelete && !FromReadOnly(i));
                miAddList.Enabled = any && sel.All(i => i.CanDelete && !FromReadOnly(i));
                miAddList.Visible = lastView != (pBasket != null ? pBasket.List : null);
                miRecycle.Enabled = deletable;
                miDelete.Enabled = deletable;
                miCloseScan.Visible = SelectedSavedScan() != null;
                miIgnoreSuggestion.Visible = sepIgnore.Visible = pSuggest != null && lastView == pSuggest.List;
                miIgnoreSuggestion.Enabled = pSuggest != null && pSuggest.List.SelectedItems.Count > 0;
            };

            Splash.Status("Creating the lists");
            // Folder contents (the first view); the other views are built in Views.cs.
            contents = new SizeListView { ContextMenuStrip = menu };
            contents.SetColumns(new[] { "Name", "Size", "% of parent", "Change", "Files", "Folders", "Modified", "What it is" },
                new[] { "name", "size", "size", "change", "files", "dirs", "mod", "cat" }, new[] { 300, 90, 170, 90, 80, 70, 140, 300 });
            contents.BarColumn = 2;
            // Folders expand in place (tree-list): the arrow, or Right / Left on the keyboard.
            contents.GlyphClicked += ContentsGlyph;
            listPanel = new RoundedPanel(12, 8) { Dock = DockStyle.Fill };
            BuildViews(listPanel);
            BuildNavigation();

            // Pie chart pane (right). It is drawn from sizes already in memory, never from the disk.
            Splash.Status("Preparing the chart");
            chart = new PieChart { Dock = DockStyle.Fill };
            chart.SliceClicked += sl => { if (sl.Dir != null && !busy) SelectDir(sl.Dir); };
            chart.CenterClicked += () => { if (ActivePage == pContents) GoUp(); };
            chart.HoverChanged += i => ActivePage.List.SetHighlight(RowsForChartHover(i, chart.HoverDir));
            var chartPanel = new RoundedPanel(12, 8) { Dock = DockStyle.Fill };
            chartPanel.Controls.Add(chart);
            // Pie or treemap, top right of the chart pane; the choice is remembered (a marker file).
            chartMode = new Segmented("Pie", "Treemap") { Font = Theme.FONT_9 };
            chart.Treemap = File.Exists(TreemapMarker);
            chartMode.SelectedIndex = chart.Treemap ? 1 : 0;
            chartMode.SelectedIndexChanged += (s, e) =>
            {
                chart.Treemap = chartMode.SelectedIndex == 1;
                try
                {
                    if (chart.Treemap) { Directory.CreateDirectory(Path.GetDirectoryName(TreemapMarker)); File.WriteAllText(TreemapMarker, ""); }
                    else if (File.Exists(TreemapMarker)) File.Delete(TreemapMarker);
                }
                catch (Exception) { }
            };
            tips.SetToolTip(chartMode, "Show the open list as a pie chart or as a treemap (rectangles sized by space)");
            chart.Controls.Add(chartMode);
            chart.Resize += (s, e) =>
            {
                var cs = chartMode.GetPreferredSize(Size.Empty);
                chartMode.Bounds = new Rectangle(chart.Width - cs.Width - S(10), S(10), cs.Width, cs.Height);
                chart.TitleRightMargin = cs.Width + S(10);
            };
            split2 = new SplitContainer { Dock = DockStyle.Fill, SplitterWidth = S(10), BackColor = Theme.BG, FixedPanel = FixedPanel.Panel2, TabStop = false };
            split2.Panel1.BackColor = Theme.BG;
            split2.Panel2.BackColor = Theme.BG;
            split2.Panel1.Controls.Add(listPanel);
            split2.Panel2.Controls.Add(chartPanel);
            // Views bar on the left (it also spans the gap to the list, which its selected tab bridges), then the list and
            // the chart.
            mainArea = new Panel { Dock = DockStyle.Fill, BackColor = Theme.BG };
            mainArea.Controls.Add(split2);
            mainArea.Controls.Add(viewTabs);
            viewTabs.PaneRadius = S(12);
            viewTabs.PaneBounds = () =>
            {
                if (!listPanel.IsHandleCreated || !viewTabs.IsHandleCreated) return Rectangle.Empty;
                return new Rectangle(viewTabs.PointToClient(listPanel.PointToScreen(Point.Empty)), listPanel.Size);
            };
            viewTabs.JointChanged += (s, e) => UpdateJoints();
            // The toolbar's selection buttons follow the list pane's edges (window size, splitter, zoom).
            listPanel.SizeChanged += (s, e) => { toolbar.PerformLayout(); viewTabs.Invalidate(); UpdateJoints(); };
            split2.LocationChanged += (s, e) => toolbar.PerformLayout();

            // Status line
            var status = new Panel { Dock = DockStyle.Bottom, Height = Theme.FONT_9.Height + S(16), BackColor = Theme.BG };
            statusLabel = new EllipsisLabel
            {
                Text = "Choose a drive or folder and press Scan.", Dock = DockStyle.Fill,
                Font = Theme.FONT_9, ForeColor = Theme.MUTED, BackColor = Theme.BG, TextAlign = ContentAlignment.MiddleLeft
            };
            driveLabel = new Label
            {
                Dock = DockStyle.Right, AutoSize = true, Font = Theme.FONT_9, ForeColor = Theme.MUTED, BackColor = Theme.BG,
                TextAlign = ContentAlignment.MiddleRight, Padding = new Padding(0, S(8), 0, 0)
            };
            liveLabel = new Label
            {
                Dock = DockStyle.Right, AutoSize = true, Font = Theme.FONT_9, ForeColor = Theme.MUTED, BackColor = Theme.BG,
                TextAlign = ContentAlignment.MiddleRight, Padding = new Padding(S(12), S(8), S(12), 0)
            };
            status.Controls.Add(statusLabel);
            status.Controls.Add(liveLabel);
            status.Controls.Add(driveLabel);

            // Version in the status line; click it to check for updates by hand.
            var versionLink = new Label
            {
                Text = "v" + Updater.Short(Updater.Current), Dock = DockStyle.Right, AutoSize = true, Font = Theme.FONT_9,
                ForeColor = Theme.MUTED, BackColor = Theme.BG, Cursor = Cursors.Hand, TextAlign = ContentAlignment.MiddleRight,
                Padding = new Padding(S(16), S(8), S(12), 0)
            };
            tips.SetToolTip(versionLink, "Check for updates");
            versionLink.MouseEnter += (s, e) => versionLink.ForeColor = Theme.ACCENT;
            versionLink.MouseLeave += (s, e) => versionLink.ForeColor = Theme.MUTED;
            versionLink.Click += (s, e) => updates.Check(true);
            status.Controls.Add(versionLink);
            updates = new UpdateManager(this) { CanRestart = () => !busy };

            overlay = new BusyOverlay();
            overlay.CancelButton.Click += (s, e) =>
            {
                if (scanner == null) return;
                scanner.Cancel();
                overlay.CancelButton.Enabled = false;
            };

            // Docking runs from the last-added control back: status (bottom), toolbar (top), scan bar (top, under those), then the panes fill the rest.
            scanBar = new ScanBar { Dock = DockStyle.Top };
            scanBar.CancelButton.Click += (s, e) =>
            {
                if (scanner == null) return;
                scanner.Cancel();
                scanBar.CancelButton.Enabled = false;
            };
            deleteBar = new ScanBar(true) { Dock = DockStyle.Top };
            deleteBar.CancelButton.Click += (s, e) =>
            {
                var j = deleteJob;
                if (j == null) return;
                j.Stop = true;
                deleteBar.CancelButton.Enabled = false;
            };
            // Custom title bar (logo, name, menu items, window buttons) replacing the native caption. It spans the full
            // width, so it is placed at (0, 0) and anchored instead of docked (docking would respect the side padding).
            Splash.Status("Opening the window");
            titleBar = new TitleBar();
            titleBar.AddItem("About", ShowAbout);
            titleBar.AddItem("Check for updates", () => updates.Check(true));
            Activated += (s, e) => titleBar.Active = true;
            Deactivate += (s, e) => titleBar.Active = false;
            Resize += (s, e) => titleBar.Invalidate();
            TextChanged += (s, e) => titleBar.Invalidate();

            Controls.Add(mainArea);
            Controls.Add(deleteBar);
            Controls.Add(scanBar);
            Controls.Add(toolbar);
            Controls.Add(status);
            Controls.Add(titleBar);
            titleBar.Bounds = new Rectangle(0, 0, ClientSize.Width, titleBar.Height);
            titleBar.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            Controls.Add(overlay);
            // The overlay covers the client area below the title bar (toolbar and status line too), so it is anchored,
            // not docked; the title bar stays usable (move, minimise, close) while it shows.
            overlay.Bounds = new Rectangle(0, titleBar.Height, ClientSize.Width, ClientSize.Height - titleBar.Height);
            overlay.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
            overlay.BringToFront();

            uiTimer = new System.Windows.Forms.Timer { Interval = 150 };
            uiTimer.Tick += (s, e) => UpdateProgress();

            DragEnter += (s, e) => { if (e.Data.GetDataPresent(DataFormats.FileDrop)) e.Effect = DragDropEffects.Copy; };
            DragDrop += (s, e) =>
            {
                var files = e.Data.GetData(DataFormats.FileDrop) as string[];
                if (files == null || files.Length == 0 || busy || scanning) return;
                string p = files[0];
                if (IsScanFile(p)) { OpenScanFile(p); return; }
                if (!Directory.Exists(p)) p = Path.GetDirectoryName(p);
                pathBox.Text = p;
                StartScan();
            };

            Shown += (s, e) =>
            {
                Splash.End(this);
                // The chart pane is 4/5 as wide as it is tall (a large chart, the list keeps more room; at least 380 px).
                int chartW = Math.Max(S(220), Math.Min(split2.Height * 4 / 5, split2.Width - S(380) - split2.SplitterWidth));
                split2.SplitterDistance = Math.Max(S(200), split2.Width - chartW - split2.SplitterWidth);
                toolbar.PerformLayout();
                LoadDrives();
                RefreshTree(null);
                ShowPage();
                // The system drive is analyzed automatically; other drives are listed and scanned on demand.
                if (IsScanFile(initialPath)) { ScanPath(Path.GetPathRoot(Environment.SystemDirectory)); OpenScanFile(initialPath); }
                else if (!string.IsNullOrEmpty(initialPath)) ScanPath(initialPath);
                else ScanPath(Path.GetPathRoot(Environment.SystemDirectory));
                // The installed apps (registry, Store, logos) are read while the drive is scanned; sizes follow from the scan.
                if (SelfTestDir == null) PrefetchApps();
                // Look for a newer release in the background; silent unless there is one.
                if (ShotDir == null && SelfTestDir == null)
                {
                    var later = new System.Windows.Forms.Timer { Interval = 3000 };
                    later.Tick += (s2, e2) => { later.Dispose(); updates.Check(false); };
                    later.Start();
                }
            };
            FormClosing += (s, e) => { if (scanner != null) scanner.Cancel(); };
            FormClosed += (s, e) => SaveSnapshots();
            UpdateButtons();
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            Theme.DarkTitleBar(Handle);
            // Recalculate the frame now that WM_NCCALCSIZE removes the caption.
            SetWindowPos(Handle, IntPtr.Zero, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0020);   // NOSIZE|NOMOVE|NOZORDER|NOACTIVATE|FRAMECHANGED
        }

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        static extern int GetSystemMetrics(int index);

        /// <summary>
        /// Removes the native caption but keeps the resize borders: after the default calculation, the client area's top
        /// edge is put back where the window's top is (when maximised, below the part that sticks out of the screen).
        /// </summary>
        bool CustomFrame(ref Message m)
        {
            const int WM_NCCALCSIZE = 0x83, WM_NCHITTEST = 0x84;
            if (m.Msg == WM_NCCALCSIZE && m.WParam != IntPtr.Zero)
            {
                int top = System.Runtime.InteropServices.Marshal.ReadInt32(m.LParam, 4);
                base.WndProc(ref m);
                if (WindowState == FormWindowState.Maximized)
                    top += GetSystemMetrics(33) + GetSystemMetrics(92);   // SM_CYSIZEFRAME + SM_CXPADDEDBORDER
                System.Runtime.InteropServices.Marshal.WriteInt32(m.LParam, 4, top);
                m.Result = IntPtr.Zero;
                return true;
            }
            if (m.Msg == WM_NCHITTEST)
            {
                base.WndProc(ref m);
                if ((int)m.Result != 1) return true;                           // not HTCLIENT: borders etc. stay native
                var p = PointToClient(new Point((short)((long)m.LParam & 0xFFFF), (short)(((long)m.LParam >> 16) & 0xFFFF)));
                int edge = GetSystemMetrics(33) + GetSystemMetrics(92);
                if (WindowState != FormWindowState.Maximized && p.Y < edge)
                    m.Result = (IntPtr)(p.X < edge * 2 ? 13 : p.X > ClientSize.Width - edge * 2 ? 14 : 12);   // HTTOPLEFT / HTTOPRIGHT / HTTOP
                else if (titleBar != null && p.Y < titleBar.Height)
                    m.Result = (IntPtr)2;                                      // HTCAPTION: drag, double-click, Snap, system menu
                return true;
            }
            return false;
        }

        static int S(int v) { return Theme.S(v); }

        RoundButton Btn(string text, ButtonKind kind, string tip, Action click)
        {
            var b = new RoundButton(text, kind);
            b.Click += (s, e) => click();
            tips.SetToolTip(b, tip);
            return b;
        }

        /// <summary>
        /// Trial: the delete list is a row of the views bar (WARN, like Suggestions has its own colour), so the views bar
        /// tab merges into the pane for it, and the toolbar has no Delete list button. False: the button is back, left
        /// of Delete permanently, and turns into the delete list's tab.
        /// </summary>
        const bool DeleteListInViewsBar = true;

        void LayoutToolbar()
        {
            int w = toolbar.ClientSize.Width, gap = S(6), groupGap = S(16), stackGap = S(10);
            var bs = btnScan.GetPreferredSize(Size.Empty);
            int h = Math.Max(bs.Height, pathBox.PreferredHeight);
            btnBasket.Visible = !DeleteListInViewsBar;

            // The list pane's edges: the Location row and Show in Explorer start at its left edge, the delete buttons end at
            // its right edge.
            int paneL = 0, paneR = -1;
            if (listPanel != null && listPanel.IsHandleCreated && toolbar.IsHandleCreated && listPanel.Width > 0)
            {
                paneL = Math.Max(0, toolbar.PointToClient(listPanel.PointToScreen(Point.Empty)).X);
                paneR = paneL + listPanel.Width;
            }

            int right = w, adminW = 0;
            if (btnAdmin.Visible)
            {
                var a = btnAdmin.GetPreferredSize(Size.Empty);
                btnAdmin.Bounds = new Rectangle(w - a.Width, 0, a.Width, h);
                right = btnAdmin.Left - groupGap;
                adminW = a.Width + groupGap;
            }
            var sb = btnScan.GetPreferredSize(Size.Empty);
            btnScan.Bounds = new Rectangle(right - sb.Width, 0, sb.Width, h);
            var bb = btnBrowse.GetPreferredSize(Size.Empty);
            btnBrowse.Bounds = new Rectangle(btnScan.Left - gap - bb.Width, 0, bb.Width, h);
            pathLabel.Location = new Point(paneL, (h - pathLabel.Height) / 2);
            int px = pathLabel.Right + gap;
            pathBox.Bounds = new Rectangle(px, 0, Math.Max(S(120), btnBrowse.Left - gap - px), h);

            int y = h + S(8);
            var ms = measure.GetPreferredSize(Size.Empty);
            var es = btnExport.GetPreferredSize(Size.Empty);
            var os = btnOpenScan.GetPreferredSize(Size.Empty);
            int rightW = os.Width + gap + es.Width + groupGap + ms.Width;
            // Add to delete list, (Delete list,) Delete permanently sit together, a little apart.
            var stack = DeleteListInViewsBar ? new[] { btnAddList, btnDelete } : new[] { btnAddList, btnBasket, btnDelete };
            var ex = btnExplorer.GetPreferredSize(Size.Empty);
            var spref = stack.Select(b => b.GetPreferredSize(Size.Empty).Width).ToArray();
            int deleteW = spref.Sum() + stackGap * (stack.Length - 1);

            // The window never gets narrower than both toolbar rows need on one line each (both start at the pane).
            int row1 = paneL + pathLabel.Width + gap + S(120) + gap + bb.Width + gap + sb.Width + adminW;
            int row2 = paneL + ex.Width + groupGap + deleteW + groupGap + rightW;
            int minW = Math.Max(row1, row2) + Padding.Horizontal + (Width - ClientSize.Width);
            var wa = Screen.FromControl(this).WorkingArea;
            minW = Math.Min(Math.Max(minW, S(900)), wa.Width);
            if (MinimumSize.Width != minW) MinimumSize = new Size(minW, MinimumSize.Height);

            // The delete buttons end at the pane's right edge (or, when the right-hand group leaves no room for that, as
            // far right as they fit; when even that is too narrow they flow from the left).
            if (paneR < 0) paneR = w - rightW - groupGap;
            int minR = paneL + ex.Width + groupGap + deleteW;
            int deleteR = Math.Min(Math.Max(paneR, minR), w - rightW - groupGap);
            if (deleteR >= minR)
            {
                btnExplorer.Bounds = new Rectangle(paneL, y, ex.Width, h);
                int x = deleteR;
                for (int i = stack.Length - 1; i >= 0; i--)
                {
                    x -= spref[i];
                    stack[i].Bounds = new Rectangle(x, y, spref[i], h);
                    x -= stackGap;
                }
            }
            else
            {
                // A narrow window (or a large zoom): the buttons flow from the left, onto more rows when needed.
                var sel = new[] { btnExplorer }.Concat(stack).ToArray();
                var pref = new[] { ex.Width }.Concat(spref).ToArray();
                int x = 0;
                for (int i = 0; i < sel.Length; i++)
                {
                    if (i == 1) x += groupGap - gap;
                    else if (i > 1) x += stackGap - gap;
                    if (x > 0 && x + pref[i] > w) { x = 0; y += h + S(8); }
                    sel[i].Bounds = new Rectangle(x, y, pref[i], h);
                    x += pref[i] + gap;
                }
                // The right-hand group moves to a row of its own when there is no room for it.
                if (x - gap + groupGap > w - rightW) y += h + S(8);
            }
            measure.Bounds = new Rectangle(w - ms.Width, y, ms.Width, h);
            btnExport.Bounds = new Rectangle(measure.Left - groupGap - es.Width, y, es.Width, h);
            btnOpenScan.Bounds = new Rectangle(btnExport.Left - gap - os.Width, y, os.Width, h);
            int total = y + h + S(10);
            if (toolbar.Height != total) toolbar.Height = total;
            MergeBasketButton(y, h, stackGap);
        }

        // Where the Delete list button joins the list pane (pane coordinates), while the delete list is open.
        bool basketJoined, basketCurveLeft, basketCurveRight;
        int basketJoinFrom, basketJoinTo;

        /// <summary>
        /// While the delete list is open its button is that view's tab: on the toolbar's last row, right above the list
        /// pane, it reaches down across the gap and merges into the pane's top edge. Its sides curve out from the level of
        /// the neighbouring buttons' bottoms and meet the pane right under the gaps beside it (Theme.TabPath).
        /// </summary>
        void MergeBasketButton(int lastRowY, int h, int sideGap)
        {
            bool open = pBasket != null && viewTabs != null && ActivePage == pBasket;
            btnBasket.Selected = open && !DeleteListInViewsBar;
            basketJoined = false;
            int f = sideGap, rad = S(12);   // the curves reach as far out as the gap to the neighbouring buttons
            var face = btnBasket.Bounds;   // just laid out at its normal size
            if (btnBasket.Selected && face.Y == lastRowY && listPanel != null && listPanel.IsHandleCreated && toolbar.IsHandleCreated)
            {
                var pane = new Rectangle(toolbar.PointToClient(listPanel.PointToScreen(Point.Empty)), listPanel.Size);
                int below = pane.Top - face.Bottom;
                if (below >= 0 && below <= S(24) && face.Left >= pane.Left && face.Right <= pane.Right)
                {
                    basketCurveLeft = below >= S(3) && face.Left - f >= pane.Left + rad;
                    basketCurveRight = below >= S(3) && face.Right + f <= pane.Right - rad;
                    btnBasket.Bounds = new Rectangle(face.Left - f, face.Top, face.Width + 2 * f, h + below);
                    btnBasket.SetMerge(below, f, basketCurveLeft, basketCurveRight);
                    basketJoinFrom = (basketCurveLeft ? face.Left - f : face.Left) - pane.Left;
                    basketJoinTo = (basketCurveRight ? face.Right + f : face.Right) - pane.Left;
                    basketJoined = true;
                }
            }
            if (!basketJoined)
            {
                btnBasket.SetMerge(0, 0, false, false);
                btnBasket.Bounds = face;
            }
            UpdateJoints();
        }

        /// <summary>The open view's tab merges into the list pane: the Delete list button above it, or the views bar row.</summary>
        void UpdateJoints()
        {
            if (listPanel == null || viewTabs == null) return;
            if (basketJoined)
            {
                listPanel.SetJoint(DockStyle.Top, basketJoinFrom, basketJoinTo, basketCurveLeft, basketCurveRight);
                return;
            }
            int top, bottom;
            bool curveTop, curveBottom;
            if (!listPanel.IsHandleCreated || !viewTabs.IsHandleCreated || !viewTabs.Joint(out top, out bottom, out curveTop, out curveBottom))
            {
                listPanel.SetJoint(DockStyle.None);
                return;
            }
            int dy = listPanel.PointToClient(viewTabs.PointToScreen(Point.Empty)).Y, f = Theme.TabFlare;
            listPanel.SetJoint(DockStyle.Left, (curveTop ? top - f : top) + dy, (curveBottom ? bottom + f : bottom) + dy, curveTop, curveBottom);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (e.KeyCode == Keys.F1) { ShowAbout(); e.Handled = true; return; }
            // Zoom: Ctrl+Plus / Ctrl+Minus (also on the number pad), Ctrl+0 = 100 % (before the lists see Ctrl+Plus).
            if (e.Control && !e.Alt && (e.KeyCode == Keys.Oemplus || e.KeyCode == Keys.Add)) { ZoomStep(1); e.Handled = e.SuppressKeyPress = true; return; }
            if (e.Control && !e.Alt && (e.KeyCode == Keys.OemMinus || e.KeyCode == Keys.Subtract)) { ZoomStep(-1); e.Handled = e.SuppressKeyPress = true; return; }
            if (e.Control && !e.Alt && !e.Shift && (e.KeyCode == Keys.D0 || e.KeyCode == Keys.NumPad0)) { SetZoom(1f); e.Handled = e.SuppressKeyPress = true; return; }
            if (e.Alt && e.KeyCode == Keys.Left) { GoBack(); e.Handled = true; return; }
            if (e.Alt && e.KeyCode == Keys.Enter && lastView != null && lastView.Focused) { ShowProperties(); e.Handled = e.SuppressKeyPress = true; return; }
            if (e.KeyCode == Keys.Space && e.Modifiers == Keys.None && lastView != null && lastView.Focused && SpacePreviews())
            { PreviewSelected(); e.Handled = e.SuppressKeyPress = true; return; }
            if (e.Alt && e.KeyCode == Keys.Right) { GoForward(); e.Handled = true; return; }
            if (pathBox.Box.Focused) return;
            if (e.KeyCode == Keys.Delete || (e.KeyCode == Keys.D && e.Control && e.Shift)) { DeleteSelected(); e.Handled = true; }
            else if (e.KeyCode == Keys.D && e.Control) { AddSelectionToBasket(); e.Handled = true; }
            else if (e.KeyCode == Keys.F5) { RescanSelected(); e.Handled = true; }
            else if (e.KeyCode == Keys.Back) { GoUp(); e.Handled = true; }
            else if (e.KeyCode == Keys.Enter) { OpenSelected(); e.Handled = true; }
            else if ((e.KeyCode == Keys.Right || e.KeyCode == Keys.Left) && e.Modifiers == Keys.None && lastView == contents && contents.Focused && ExpandSelected(e.KeyCode == Keys.Right))
                e.Handled = true;
            else if (e.KeyCode == Keys.C && e.Control) { CopyPath(); e.Handled = true; }
            else if (e.KeyCode == Keys.Insert) { AddSelectionToBasket(); e.Handled = true; }
            else if (e.KeyCode == Keys.F && e.Control) { ShowFilesSearch(); e.Handled = true; }
        }

        /// <summary>The saved scan whose top folder is selected in the list (null otherwise).</summary>
        ScanRoot SelectedSavedScan()
        {
            var sel = lastView == contents ? GetSelection() : new List<ItemInfo>();
            var d = sel.Count == 1 && sel[0].IsDir ? sel[0].Dir : null;
            var r = d != null && d.Parent == null ? RootOf(d) : null;
            return r != null && r.ReadOnly ? r : null;
        }

        void ShowAbout()
        {
            using (var f = new AboutForm(() => updates.Check(true))) f.ShowDialog(this);
        }

        // ---------------------------------------------------------------- scanning

        static Task RunThread(Action action)
        {
            var tcs = new TaskCompletionSource<bool>();
            var t = new Thread(() =>
            {
                try { action(); tcs.SetResult(true); }
                catch (Exception ex) { tcs.SetException(ex); }
            }, 16 * 1024 * 1024) { IsBackground = true };
            t.Start();
            return tcs.Task;
        }

        string NormalizePath(string path)
        {
            path = path.Trim().Trim('"');
            if (path.Length == 2 && path[1] == ':') path += "\\";
            path = Path.GetFullPath(path);
            if (path.Length > 3 && path.EndsWith("\\") && !path.StartsWith(@"\\")) path = path.TrimEnd('\\');
            return path;
        }

        void ScanPath(string path)
        {
            if (busy || scanning) return;
            pathBox.Text = path;
            StartScan();
        }

        /// <summary>Scans in the background; the window stays usable and the scan bar shows progress.</summary>
        async void StartScan()
        {
            if (busy || scanning) return;
            string path;
            try { path = NormalizePath(pathBox.Text); }
            catch (Exception ex) { Alert(AlertIcon.Warn, "That is not a valid path", ex.Message, null, null, "OK"); return; }
            if (!Directory.Exists(path))
            {
                Alert(AlertIcon.Warn, "Folder not found", path, null, null, "OK");
                return;
            }
            pathBox.Text = path;
            var r = FindRoot(path);
            bool isNew = r == null;
            if (isNew)
            {
                r = new ScanRoot { Path = path };
                RefreshCapacity(r);
                roots.Add(r);
                SortRoots();
            }
            // First scan of a drive in this session: show its saved scan at once and catch up from the change journal.
            if (r.Node == null && r.IsDrive && SelfTestDir == null && ShotDir == null && Snapshot.Exists(path) && await FastStart(r)) return;
            var s = new Scanner();
            scanner = s;
            scanRoot = r;
            r.Scanning = true;
            var oldNode = r.Node;
            ulong jid = 0; long jusn = 0;
            bool journal = r.IsDrive && Snapshot.QueryJournal(path, out jid, out jusn);
            SetScanning(true, "Scanning " + r.Path + "...");
            // Show the root being scanned unless the user is already looking at something else that is scanned.
            RefreshTree(current);
            if (current == null || current.Top == oldNode) { if (oldNode == null) SelectRoot(r); }

            var sw = Stopwatch.StartNew();
            DirNode result = null;
            Exception error = null;
            try { await RunThread(() => result = s.Run(path, true)); }
            catch (Exception ex) { error = ex; }
            sw.Stop();
            r.Scanning = false;
            scanner = null;
            scanRoot = null;
            SetScanning(false, null);
            if (error != null)
            {
                if (isNew) roots.Remove(r);
                RefreshTree(current);
                Alert(AlertIcon.Warn, "The scan failed", error.Message, null, null, "OK");
                return;
            }

            r.Node = result;
            r.Scanned = DateTime.Now;
            r.Complete = !s.Cancelled;
            r.JournalId = journal ? jid : 0;
            r.JournalUsn = journal ? jusn : 0;
            RefreshCapacity(r);
            RememberScan(r, result, !s.Cancelled);
            StartWatching(r);
            // Keep the user's place: map a selection inside the old tree onto the new one; otherwise stay put,
            // unless nothing scanned was selected (e.g. at startup), then open the new result.
            DirNode target;
            if (current != null && oldNode != null && current.Top == oldNode) target = FindByPath(result, current.FullPath) ?? result;
            else if (active != null && active != r) target = current;   // browsing another drive: stay there
            else target = result;
            if (active == r) current = null;
            RefreshTree(target);
            ViewsChanged();
            UpdateDriveLabel();
            statusLabel.Text = string.Format("{0}: {1} in {2:N0} files and {3:N0} folders - scanned in {4:0.00} s, {5}{6}",
                result.Name, Fmt.Size(result.Size), result.Files, result.Dirs, sw.Elapsed.TotalSeconds, s.Method,
                s.Cancelled ? "  (stopped - partial results)" : "");
            if (fastStartNote != null) { statusLabel.Text += "  " + fastStartNote; fastStartNote = null; }
            if (ShotDir != null && !shotsStarted) { shotsStarted = true; RunShots(); }
            if (SelfTestDir != null && !shotsStarted) { shotsStarted = true; RunSelfTest(); }
            // A drive is scanned: list the installed apps right away in the background (their sizes come from this scan),
            // so the Apps tab is ready when it is opened.
            if (r.IsDrive && !s.Cancelled && (apps == null || appsFromCache) && !appsLoading && SelfTestDir == null) FillApps();
            if (!s.Cancelled) FindSuggestionsAfterScan();
            if (!s.Cancelled) SystemAfterScan(r.IsDrive);
        }

        /// <summary>Deepest scanned folder under root that matches fullPath (root itself if nothing deeper matches).</summary>
        static DirNode FindByPath(DirNode root, string fullPath)
        {
            string rp = root.FullPath.TrimEnd('\\');
            if (!fullPath.StartsWith(rp, StringComparison.OrdinalIgnoreCase)) return null;
            var node = root;
            foreach (var part in fullPath.Substring(rp.Length).Split(new[] { '\\' }, StringSplitOptions.RemoveEmptyEntries))
            {
                DirNode next = null;
                if (node.Children != null)
                    foreach (var c in node.Children)
                        if (string.Equals(c.Name, part, StringComparison.OrdinalIgnoreCase)) { next = c; break; }
                if (next == null) break;
                node = next;
            }
            return node;
        }

        // ---------------------------------------------------------------- drives and scan roots

        static bool SamePath(string a, string b)
        {
            return string.Equals(a.TrimEnd('\\'), b.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
        }

        ScanRoot FindRoot(string path) { return roots.FirstOrDefault(r => !r.ReadOnly && SamePath(r.Path, path)); }

        ScanRoot RootOf(DirNode top) { return top == null ? null : roots.FirstOrDefault(r => r.Node == top); }

        void SortRoots()
        {
            roots.Sort((a, b) =>
            {
                if (a.ReadOnly != b.ReadOnly) return a.ReadOnly ? 1 : -1;
                if (a.IsSystem != b.IsSystem) return a.IsSystem ? -1 : 1;
                if (a.IsDrive != b.IsDrive) return a.IsDrive ? -1 : 1;
                return string.Compare(a.Path, b.Path, StringComparison.OrdinalIgnoreCase);
            });
        }

        static void RefreshCapacity(ScanRoot r)
        {
            if (r.ReadOnly) return;   // a saved scan keeps the capacity it was saved with
            try
            {
                var d = new DriveInfo(Path.GetPathRoot(r.Path));
                if (!d.IsReady) return;
                r.Total = d.TotalSize;
                r.Free = d.TotalFreeSpace;
            }
            catch (Exception) { }
        }

        /// <summary>Adds ready drives, drops drives that went away (e.g. an unplugged USB disk).</summary>
        void LoadDrives()
        {
            string sys = Path.GetPathRoot(Environment.SystemDirectory);
            var ready = new List<DriveInfo>();
            foreach (var d in DriveInfo.GetDrives())
            {
                // Mapped network drives are not listed: checking a disconnected share can block for seconds.
                // A network path can still be typed into the path box and scanned.
                if (d.DriveType == DriveType.Network) continue;
                try { if (d.IsReady) ready.Add(d); } catch (Exception) { }
            }
            roots.RemoveAll(r => r.IsDrive && !r.ReadOnly && !ready.Any(d => SamePath(d.Name, r.Path)));
            foreach (var d in ready)
            {
                var r = FindRoot(d.Name);
                if (r == null) { r = new ScanRoot { Path = d.Name }; roots.Add(r); }
                r.IsDrive = true;
                r.IsSystem = SamePath(d.Name, sys);
                string label = "";
                try { label = d.VolumeLabel; } catch (Exception) { }
                string kind = d.DriveType == DriveType.Removable ? "removable" : d.DriveType == DriveType.Network ? "network"
                    : d.DriveType == DriveType.CDRom ? "optical" : "";
                if (string.IsNullOrEmpty(label)) label = d.DriveType == DriveType.Fixed ? "Local disk" : "";
                r.Label = label + (kind.Length > 0 ? (label.Length > 0 ? " - " : "") + kind : "");
                RefreshCapacity(r);
            }
            if (active != null && !roots.Contains(active)) { active = null; current = null; }
            SortRoots();
            pathBox.Choices.Clear();
            foreach (var r in roots) if (r.IsDrive) pathBox.Choices.Add(r.Path);
        }

        protected override void WndProc(ref Message m)
        {
            if (CustomFrame(ref m)) return;
            if (AppCommand(ref m)) return;
            base.WndProc(ref m);
            // WM_DEVICECHANGE: DBT_DEVICEARRIVAL / DBT_DEVICEREMOVECOMPLETE -> refresh the drive list.
            if (m.Msg == 0x219 && (m.WParam == (IntPtr)0x8000 || m.WParam == (IntPtr)0x8004))
            {
                if (busy || scanning) drivesChanged = true;
                else BeginInvoke(new Action(RefreshDrives));
            }
        }

        void RefreshDrives()
        {
            if (busy || scanning) { drivesChanged = true; return; }
            drivesChanged = false;
            LoadDrives();
            RefreshTree(current);
        }

        void ShowUnscanned(ScanRoot r)
        {
            thisPc = false;
            current = null;
            active = r;
            RefreshCapacity(r);
            if (!busy) pathBox.Text = r.Path;
            contents.ResetHover();
            contents.Items.Clear();
            UpdateCrumbs(null, r);
            if (unreadBanner != null) unreadBanner.Message = null;
            contents.EmptyText = r.Scanning
                ? "Scanning " + r.DisplayName + "...\nThe results appear here when the scan finishes. You can browse other drives meanwhile."
                : r.DisplayName + " has not been scanned yet.\nPress Scan, or double-click the drive, to analyze it.";
            contents.Invalidate();
            ViewsChanged();
            pContents.Caption.Text = r.DisplayName + (r.Scanning ? "  -  scanning..." : "  -  not scanned");
            if (ActivePage == pContents) UpdateChartUnscanned(r);
            UpdateDriveLabel();
            UpdateButtons();
        }

        // ---------------------------------------------------------------- pie chart

        /// <summary>Folder contents row -> index of the pie slice that contains it.</summary>
        readonly Dictionary<ListViewItem, int> rowSlice = new Dictionary<ListViewItem, int>();
        const int MaxOwnSlices = 50;          // every row of at least 2 % of the total (7.2 degrees) gets a slice of its own
        const double MinOwnShare = 0.02;      // (2 % allows at most 50); all smaller rows together form one "smaller items" slice

        /// <summary>
        /// Slices for a list exactly as displayed, in row order: every row of at least 2 % of the total has a slice of its own
        /// (true proportions); all smaller rows together form one "smaller items" slice, placed where the first of them is.
        /// Rows of a group (duplicates) join their group's slice. Fills rowSlice so hover links rows and slices both ways.
        /// </summary>
        List<ChartSlice> BuildSlices(SizeListView lv, long total, string scope)
        {
            rowSlice.Clear();
            // Only the top level of a tree-list (Contents): expanded rows are inside their folder's slice.
            var rows = lv.Items.Cast<ListViewItem>().Where(it => it.Tag is ItemInfo && ((ItemInfo)it.Tag).Depth == 0).ToList();
            total = Math.Max(1, total);
            var own = new HashSet<ListViewItem>(rows
                .Where(it => ((ItemInfo)it.Tag).GroupOf == null && ((ItemInfo)it.Tag).ChartSize > 0 && ((ItemInfo)it.Tag).ChartSize >= MinOwnShare * total)
                .OrderByDescending(it => ((ItemInfo)it.Tag).ChartSize).Take(MaxOwnSlices));

            var slices = new List<ChartSlice>();
            var headSlice = new Dictionary<ItemInfo, int>();
            ChartSlice rest = null;
            int restIndex = -1;
            int colour = 0;
            foreach (var it in rows)
            {
                var info = (ItemInfo)it.Tag;
                int head;
                if (info.GroupOf != null && headSlice.TryGetValue(info.GroupOf, out head))
                {
                    slices[head].Rows.Add(it);
                    rowSlice[it] = head;
                    continue;
                }
                long size = info.ChartSize;
                int at;
                if (own.Contains(it))
                {
                    var s = new ChartSlice
                    {
                        Label = info.Name, Size = size, Color = Theme.CHART[colour++ % Theme.CHART.Length],
                        Detail = string.Format("{0:0.0} % {1}", 100.0 * size / total, scope),
                        Dir = info.IsDir && IsAttached(info.Dir) ? info.Dir : null
                    };
                    s.Rows.Add(it);
                    slices.Add(s);
                    at = slices.Count - 1;
                }
                else
                {
                    if (rest == null) { rest = new ChartSlice { Color = Theme.CHART_OTHER }; slices.Add(rest); restIndex = slices.Count - 1; }
                    rest.Rows.Add(it);
                    rest.Size += Math.Max(0, size);
                    at = restIndex;
                }
                rowSlice[it] = at;
                headSlice[info] = at;
            }
            foreach (var s in rest != null ? new[] { rest } : new ChartSlice[0])
            {
                int n = s.Rows.Count(r => ((ItemInfo)r.Tag).GroupOf == null);
                s.Label = n == 1 ? ((ItemInfo)s.Rows[0].Tag).Name : string.Format("{0:N0} smaller items", n);
                s.Detail = string.Format("{0:0.0} % {1}", 100.0 * s.Size / total, scope);
            }
            return slices;
        }

        /// <summary>Folder contents chart; a drive root also gets "System / not readable" and "Free space" at the end.</summary>
        void UpdateChart(DirNode d)
        {
            if (scanning) { ShowScanLogo(); return; }
            var r = RootOf(d.Top);
            if (r != null) RefreshCapacity(r);
            var slices = BuildSlices(contents, d.Size, "of folder");
            string title = d.Parent == null && r != null ? r.DisplayName : d.Name, sub = d.FullPath;
            if (d.Parent == null && r != null && (r.IsDrive || (r.ReadOnly && r.Path.Length <= 3)) && r.Total > 0)
            {
                long used = r.Total - r.Free;
                if (used - d.Size > 0)
                    slices.Add(new ChartSlice
                    {
                        Label = "System / not readable", Size = used - d.Size, Color = Theme.PILL,
                        Detail = string.Format("{0:0.0} % of drive", 100.0 * (used - d.Size) / r.Total)
                    });
                slices.Add(new ChartSlice
                {
                    Label = "Free space", Size = r.Free, Color = Theme.CHART_FREE, Empty = true,
                    Detail = string.Format("{0:0.0} % of drive", 100.0 * r.Free / r.Total)
                });
                sub = string.Format("{0} used of {1}  -  {2} free", Fmt.Size(used), Fmt.Size(r.Total), Fmt.Size(r.Free));
            }
            chart.SetData(title, sub, slices, ContentsRings(d));
            chart.SetCenter(d.Parent == null && r != null ? (r.IsDrive ? r.DisplayName : Native.FileName(r.Path)) : d.Name, d.Parent != null);
        }

        /// <summary>Outer rings around the folder contents chart: subfolders and their subfolders.</summary>
        static int ContentsRings(DirNode d) { return 2; }

        /// <summary>
        /// While the scan bar shows, the chart pane shows the logo, whatever tab is open (the numbers are still changing);
        /// when the scan is done the logo turns into the chart.
        /// </summary>
        void ShowScanLogo()
        {
            rowSlice.Clear();
            var r = scanRoot ?? active;
            string sub = r != null && r.Total > 0
                ? string.Format("{0} used of {1}  -  {2} free", Fmt.Size(r.Total - r.Free), Fmt.Size(r.Total), Fmt.Size(r.Free))
                : (r != null ? r.Path : "");
            chart.ShowLogo(r != null ? r.DisplayName : "", sub, "", true);
        }

        /// <summary>Nothing scanned yet: the chart pane shows the app logo; it morphs into the chart once the scan is done.</summary>
        void UpdateChartUnscanned(ScanRoot r)
        {
            rowSlice.Clear();
            string sub = r.Total > 0
                ? string.Format("{0} used of {1}  -  {2} free", Fmt.Size(r.Total - r.Free), Fmt.Size(r.Total), Fmt.Size(r.Free))
                : r.Path;
            // While it scans the logo's working loop says enough: no text under it.
            chart.ShowLogo(r.DisplayName, sub, r.Scanning ? "" : "Not scanned yet. Press Scan, or double-click the drive.", r.Scanning || scanning);
        }

        /// <summary>Blocking work (permanent delete): full-window overlay.</summary>
        void SetBusy(bool value)
        {
            busy = value;
            if (value)
            {
                overlay.ShowBusy("Starting...", false);
                uiTimer.Start();
            }
            else
            {
                if (!scanning) uiTimer.Stop();
                overlay.HideBusy();
            }
            mainArea.Enabled = !value;
            UpdateButtons();
            if (!value && drivesChanged) BeginInvoke(new Action(RefreshDrives));
        }

        /// <summary>Background scan: the scan bar shows progress; browsing stays possible, changes to the disk do not.</summary>
        void SetScanning(bool value, string text)
        {
            scanning = value;
            if (value)
            {
                scanBar.Start(text);
                uiTimer.Start();
                if (IsHandleCreated && ActivePage != null) RefreshChart();
            }
            else
            {
                if (!busy) uiTimer.Stop();
                scanBar.Stop();
            }
            UpdateButtons();
            if (!value && drivesChanged) BeginInvoke(new Action(RefreshDrives));
        }

        void UpdateButtons()
        {
            bool idle = !busy && !scanning;
            btnScan.Enabled = idle;
            btnBrowse.Enabled = idle;
            pathBox.Enabled = !busy;
            btnUp.Enabled = !busy && !thisPc && (current != null || active != null);
            btnRescan.Enabled = idle && root != null;
            btnExplorer.Enabled = !busy && root != null;
            btnDelete.Enabled = idle && root != null;
            btnAddList.Enabled = !busy && root != null;
            btnExport.Enabled = !busy && root != null;
            btnOpenScan.Enabled = !busy;
            measure.Enabled = !busy;
            if (btnBasketRecycle != null) btnBasketRecycle.Enabled = btnBasketDelete.Enabled = idle && basket.Count > 0;
            // A saved scan opened from a file is only browsed.
            if (active != null && active.ReadOnly) btnRescan.Enabled = btnDelete.Enabled = btnAddList.Enabled = false;
            UpdateNavButtons();
            UpdateSuggestionButtons();
            UpdateAppButtons();
            UpdateSystemButtons();
            UpdateLinkButton();
        }

        void UpdateProgress()
        {
            var s = scanner;
            var j = deleteJob;
            if (s != null)
            {
                var r = scanRoot;
                long bytes = Interlocked.Read(ref s.BytesSeen);
                string where = r != null ? r.Path : "";
                string detail = string.Format("{0:N0} files, {1:N0} folders  --  {2}",
                    Interlocked.Read(ref s.FilesSeen), Interlocked.Read(ref s.DirsSeen), Fmt.Shorten(s.Current, 90));
                // A whole drive has a known total (its used space), so the bar can show real progress.
                bool driveRoot = r != null && r.IsDrive && r.Total > 0 && SamePath(r.Path, s.RootPath ?? "");
                long used = driveRoot ? r.Total - r.Free : 0;
                if (s.Cancelled)
                    scanBar.SetProgress("Cancelling... (finishing current folder)", detail, -1);
                else if (used > 0)
                {
                    // Size on disk against the drive's used space (both count allocated clusters); file lengths would run
                    // ahead (online-only cloud files, sparse and compressed files). Past 99 % it says it is finishing,
                    // never "X of Y" with X larger than Y.
                    double frac;
                    string text = DriveProgress(where, Interlocked.Read(ref s.AllocSeen), used, out frac);
                    scanBar.SetProgress(text, detail, frac);
                }
                else
                    scanBar.SetProgress(string.Format("Scanning {0}: {1} so far", Fmt.Shorten(s.RootPath ?? where, 60), Fmt.Size(bytes)), detail, -1);
            }
            if (j != null && deleteBar.Visible) UpdateDeleteProgress(j);
        }

        /// <summary>The status of a whole-drive scan: size on disk found so far of the used space; from 99 % on it says it
        /// is finishing (hard links, compression and system files make the two differ a little).</summary>
        internal static string DriveProgress(string root, long found, long used, out double fraction)
        {
            double f = (double)found / Math.Max(1L, used);
            if (f >= 0.99) { fraction = 0.99; return string.Format("Scanning {0}: {1} found, finishing the last folders...", root, Fmt.Size(found)); }
            fraction = f;
            return string.Format("Scanning {0}: {1} of {2} done ({3:0} %)", root, Fmt.Size(found), Fmt.Size(used), f * 100);
        }

        void UpdateDriveLabel()
        {
            driveLabel.Text = "";
            if (active == null) return;
            if (active.ReadOnly)
            {
                driveLabel.Text = active.Total > 0 ? string.Format("Saved scan of {0:g}: {1} free of {2} then", active.Scanned, Fmt.Size(active.Free), Fmt.Size(active.Total))
                    : string.Format("Saved scan of {0:g}", active.Scanned);
                return;
            }
            try
            {
                var d = new DriveInfo(Path.GetPathRoot(active.Path));
                driveLabel.Text = string.Format("{0}  {1} free of {2} ({3:0}% free)", d.Name, Fmt.Size(d.AvailableFreeSpace),
                    Fmt.Size(d.TotalSize), 100.0 * d.AvailableFreeSpace / Math.Max(1, d.TotalSize));
            }
            catch (Exception) { }
        }

        void Browse()
        {
            using (var dlg = new FolderBrowserDialog { Description = "Choose a folder to analyze", ShowNewFolderButton = false })
            {
                try { dlg.SelectedPath = NormalizePath(pathBox.Text); } catch (Exception) { }
                if (dlg.ShowDialog(this) != DialogResult.OK) return;
                pathBox.Text = dlg.SelectedPath;
            }
            StartScan();
        }

        void RestartAsAdmin()
        {
            string arg = "";
            string p = active != null ? active.Path : pathBox.Text.Trim();
            if (p.Length > 0) arg = "\"" + p.TrimEnd('\\') + "\"";
            try
            {
                Process.Start(new ProcessStartInfo(Application.ExecutablePath, arg) { Verb = "runas", UseShellExecute = true });
                Close();
            }
            catch (Win32Exception) { }
        }

        // ---------------------------------------------------------------- tree and lists

        bool IsAttached(DirNode d)
        {
            return d != null && RootOf(d.Top) != null;
        }

        /// <summary>Shows target again after the scanned trees changed (or the drive it was on, or This PC).</summary>
        void RefreshTree(DirNode target)
        {
            expandedDirs.RemoveWhere(d => !IsAttached(d));
            if (target != null && IsAttached(target)) SelectDir(target);
            else if (thisPc) ShowThisPc();
            else if (active != null && roots.Contains(active)) SelectRoot(active);
            else if (roots.Count > 0) SelectRoot(roots[0]);
            else ShowThisPc();
        }

        void SelectRoot(ScanRoot r)
        {
            if (r.Node != null) SelectDir(r.Node);
            else ShowUnscanned(r);
        }

        void SelectDir(DirNode target)
        {
            if (target == null || !IsAttached(target)) return;
            ShowContents(target);
        }

        // ---------------------------------------------------------------- Contents: tree-list and This PC

        /// <summary>Folders expanded in place in Contents.</summary>
        readonly HashSet<DirNode> expandedDirs = new HashSet<DirNode>();
        /// <summary>Contents lists the drives and scanned folders (the level above every drive).</summary>
        bool thisPc;
        static readonly object ThisPcPart = new object();

        static bool HasContent(DirNode d)
        {
            return d != null && !d.Denied && ((d.Children != null && d.Children.Count > 0) || d.Files > 0);
        }

        /// <summary>Rows of folder d at depth, sorted like the list, each expanded folder followed by its own rows.</summary>
        void AddContentRows(DirNode d, int depth, List<ItemInfo> into)
        {
            var level = new List<ItemInfo>();
            if (d.Children != null) foreach (var c in d.Children) level.Add(ItemInfo.ForDir(c, d.Size));
            var files = Scanner.ListFiles(d);
            files.Sort(FileEntry.BySizeDesc);
            for (int i = 0; i < files.Count && i < MaxFilesShown; i++) level.Add(ItemInfo.ForFile(files[i], d.Size));
            if (files.Count > MaxFilesShown)
            {
                long rest = 0;
                for (int i = MaxFilesShown; i < files.Count; i++) rest += files[i].Size;
                level.Add(new ItemInfo
                {
                    IsSummary = true, Name = string.Format("[{0:N0} smaller files not listed]", files.Count - MaxFilesShown),
                    Size = rest, Files = files.Count - MaxFilesShown, Percent = d.Size > 0 ? 100.0 * rest / d.Size : 0
                });
            }
            SetChanges(d, level);
            level.Sort(contents.Sorter.Compare);
            foreach (var it in level)
            {
                it.TreeRow = true;
                it.Depth = depth;
                if (it.IsDir)
                {
                    it.Expandable = HasContent(it.Dir);
                    it.Expanded = it.Expandable && expandedDirs.Contains(it.Dir);
                }
                into.Add(it);
                if (it.Expanded) AddContentRows(it.Dir, depth + 1, into);
            }
        }

        /// <summary>Replaces the Contents rows; keeps the scroll position and the selected rows (by folder or file).</summary>
        void FillContentsRows(List<ItemInfo> items, bool keepView)
        {
            int top = keepView && contents.TopItem != null ? contents.TopItem.Index : 0;
            var keep = new HashSet<object>();
            if (keepView) foreach (ListViewItem lvi in contents.SelectedItems) { var i = lvi.Tag as ItemInfo; if (i != null) keep.Add(RowKey(i)); }
            contents.BeginUpdate();
            contents.ResetHover();
            contents.Items.Clear();
            string pct = thisPc ? "% used" : "% of parent";
            if (contents.Columns.Count > 2 && contents.Columns[2].Text != pct) contents.Columns[2].Text = pct;
            contents.Items.AddRange(items.Select(it =>
            {
                var known = it.Data is ScanRoot ? null : KnownFor(it);
                if (!(it.Data is ScanRoot)) it.Category = known != null ? known.Short : null;
                var lvi = new ListViewItem(new[]
                {
                    it.Name, Fmt.Size(it.Size), it.Percent.ToString("0.0") + " %", ChangeText(it),
                    it.Data is ScanRoot && it.Dir == null ? "" : it.Files.ToString("N0"), it.IsDir ? it.Dirs.ToString("N0") : "",
                    it.Modified > 0 ? Fmt.Date(it.Modified) : "", it.Category ?? ""
                }) { Tag = it };
                if (it.IsSummary || (it.IsDir && it.Dir.Denied) || (it.Data is ScanRoot && it.Dir == null)) lvi.ForeColor = Theme.MUTED;
                if (keep.Count > 0 && keep.Contains(RowKey(it))) lvi.Selected = true;
                return lvi;
            }).ToArray());
            if (keepView && contents.Items.Count > 0) contents.TopItem = contents.Items[Math.Min(top, contents.Items.Count - 1)];
            contents.EndUpdate();
        }

        static object RowKey(ItemInfo i)
        {
            return i.IsDir ? (object)i.Dir : i.File != null ? (object)i.File.FullPath : i.Data ?? i.Name;
        }

        /// <summary>Rebuilds the Contents rows after a folder was expanded or collapsed, or the sort order changed.</summary>
        void RefillContents()
        {
            if (thisPc) { FillContentsRows(ThisPcRows(), true); }
            else if (current != null && IsAttached(current))
            {
                var items = new List<ItemInfo>();
                AddContentRows(current, 0, items);
                FillContentsRows(items, true);
            }
            else return;
            if (ActivePage == pContents) RefreshChart();
        }

        void ContentsGlyph(ListViewItem lvi, bool check)
        {
            var it = lvi.Tag as ItemInfo;
            if (check || it == null || !it.IsDir || !it.Expandable) return;
            if (!expandedDirs.Remove(it.Dir)) expandedDirs.Add(it.Dir);
            RefillContents();
        }

        /// <summary>Right expands the selected folder (or moves into it), Left collapses it (or selects its parent row).</summary>
        bool ExpandSelected(bool expand)
        {
            if (contents.SelectedItems.Count != 1) return false;
            var lvi = contents.SelectedItems[0];
            var it = lvi.Tag as ItemInfo;
            if (it == null) return false;
            if (expand)
            {
                if (!it.IsDir || !it.Expandable) return true;
                if (!it.Expanded) { expandedDirs.Add(it.Dir); RefillContents(); return true; }
                int next = lvi.Index + 1;
                if (next < contents.Items.Count) SelectRow(contents.Items[next]);
                return true;
            }
            if (it.IsDir && it.Expanded) { expandedDirs.Remove(it.Dir); RefillContents(); return true; }
            for (int i = lvi.Index - 1; i >= 0; i--)
            {
                var up = contents.Items[i].Tag as ItemInfo;
                if (up != null && up.Depth < it.Depth) { SelectRow(contents.Items[i]); break; }
            }
            return true;
        }

        void SelectRow(ListViewItem lvi)
        {
            contents.SelectedItems.Clear();
            lvi.Selected = true;
            lvi.Focused = true;
            lvi.EnsureVisible();
        }

        /// <summary>One row per drive, saved scan and scanned folder; scanned ones expand into their folders.</summary>
        List<ItemInfo> ThisPcRows()
        {
            var items = new List<ItemInfo>();
            foreach (var r in roots)
            {
                var n = r.Node;
                // Only real drives count their used space (and get a chart slice); a scanned folder or a saved scan
                // shows its own size, so nothing is counted twice.
                bool drive = CountsAsDrive(r);
                long used = drive && r.Total > 0 ? r.Total - r.Free : n != null ? n.Size : 0;
                var it = new ItemInfo
                {
                    TreeRow = true, Data = r, FolderIcon = true, IsDir = n != null, Dir = n, Path = r.Path,
                    Name = r.DisplayName + (n == null ? (r.Scanning ? "  (scanning...)" : "  (not scanned)") : r.Scanning ? "  (rescanning...)" : ""),
                    Size = used, Files = n != null ? n.Files : 0, Dirs = n != null ? n.Dirs : 0,
                    Percent = r.Total > 0 ? 100.0 * used / r.Total : 0,
                    Category = r.ReadOnly ? "Saved scan" : !drive ? "Scanned folder"
                        : r.Total > 0 ? string.Format("{0} free of {1}", Fmt.Size(r.Free), Fmt.Size(r.Total)) : "",
                    ChartValue = drive ? -1 : 0
                };
                it.Expandable = HasContent(n);
                it.Expanded = it.Expandable && expandedDirs.Contains(n);
                items.Add(it);
                if (it.Expanded) AddContentRows(n, 1, items);
            }
            return items;
        }

        /// <summary>Contents shows This PC: every drive with its used space; Up from a drive leads here.</summary>
        void ShowThisPc()
        {
            thisPc = true;
            current = null;
            if (unreadBanner != null) unreadBanner.Message = null;
            contents.EmptyText = roots.Count == 0 ? "No drives found." : null;
            UpdateCrumbs(null);
            FillContentsRows(ThisPcRows(), false);
            var drives = roots.Where(CountsAsDrive).ToList();
            long used = drives.Where(r => r.Total > 0).Sum(r => r.Total - r.Free), total = drives.Where(r => r.Total > 0).Sum(r => r.Total);
            pContents.Caption.Text = string.Format("{0:N0} drive{1}{2}", drives.Count, drives.Count == 1 ? "" : "s",
                total > 0 ? string.Format(": {0} used of {1}", Fmt.Size(used), Fmt.Size(total)) : "");
            foreach (var pg in pages) if (pg.FollowsFolder && pg != pContents) pg.Stale = true;
            if (ActivePage == pContents) RefreshChart();
            UpdateButtons();
        }

        /// <summary>This PC chart: the used space of every drive.</summary>
        void UpdateChartThisPc()
        {
            if (scanning) { ShowScanLogo(); return; }
            var drives = roots.Where(r => CountsAsDrive(r) && r.Total > 0).ToList();
            long total = drives.Sum(r => r.Total);
            var slices = BuildSlices(contents, Math.Max(1, drives.Sum(r => r.Total - r.Free)), "of the used space");
            chart.SetData("This PC", total > 0 ? Fmt.Size(total) + " in " + drives.Count + (drives.Count == 1 ? " drive" : " drives") : "", slices);
        }

        static bool CountsAsDrive(ScanRoot r) { return r.IsDrive && !r.ReadOnly; }

        void ShowContents(DirNode d)
        {
            RecordNavigation(current, d);
            bool same = d == current && !thisPc;
            thisPc = false;
            current = d;
            var r = RootOf(d.Top);
            if (r != null && r != active)
            {
                active = r;
                UpdateDriveLabel();
                if (!busy) pathBox.Text = r.Path;
            }
            contents.EmptyText = null;
            UpdateCrumbs(d);
            UpdateUnreadBanner(d);
            var items = new List<ItemInfo>();
            AddContentRows(d, 0, items);
            FillContentsRows(items, same);
            // The path is in the path bar above; the caption gives the totals.
            pContents.Caption.Text = string.Format("{0} in {1:N0} files and {2:N0} folders{3}", Fmt.Size(d.Size), d.Files, d.Dirs, ChangeCaption(d));
            ContentsChanged();
            UpdateButtons();
        }

        List<ItemInfo> GetSelection()
        {
            var list = new List<ItemInfo>();
            {
                var lv = lastView as ListView ?? contents;
                foreach (ListViewItem lvi in lv.SelectedItems)
                {
                    var it = lvi.Tag as ItemInfo;
                    if (it != null && !it.IsSummary && !it.IsGroup && (it.CanDelete || it.FullPath != null)) list.Add(it);
                }
            }
            return list;
        }

        void OpenSelected()
        {
            var sel = GetSelection();
            if (sel.Count != 1 || busy) return;
            var it = sel[0];
            var sr = it.Data as ScanRoot;
            if (sr != null && sr.Node == null) { ScanPath(sr.Path); return; }
            if (it.IsDir) { SelectDir(it.Dir); return; }
            if (it.File == null) { ShowInExplorer(); return; }
            if (lastView != contents && IsAttached(it.File.Dir))
            {
                SelectDir(it.File.Dir);
                viewTabs.SelectedIndex = pages.IndexOf(pContents);
                foreach (ListViewItem lvi in contents.Items)
                {
                    var c = (ItemInfo)lvi.Tag;
                    if (!c.IsDir && string.Equals(c.Name, it.Name, StringComparison.OrdinalIgnoreCase))
                    {
                        contents.SelectedItems.Clear();
                        lvi.Selected = true;
                        lvi.EnsureVisible();
                        contents.Focus();
                        break;
                    }
                }
                return;
            }
            ShowInExplorer();
        }

        void GoUp()
        {
            if (busy || thisPc) return;
            if (current != null && current.Parent != null) { SelectDir(current.Parent); return; }
            // From a drive (or a drive not scanned yet) up to This PC, with that drive selected.
            var from = current != null ? RootOf(current) : active;
            ShowThisPc();
            foreach (ListViewItem lvi in contents.Items)
                if (from != null && ((ItemInfo)lvi.Tag).Data == from) { SelectRow(lvi); break; }
        }

        void ShowInExplorer()
        {
            var sel = GetSelection();
            string path = sel.Count > 0 ? sel[0].FullPath : current != null ? current.FullPath : null;
            if (path == null) return;
            try { Process.Start("explorer.exe", "/select,\"" + path + "\""); } catch (Exception) { }
        }

        void CopyPath()
        {
            var sel = GetSelection();
            if (sel.Count == 0) return;
            try { Clipboard.SetText(string.Join(Environment.NewLine, sel.Select(i => i.FullPath))); } catch (Exception) { }
        }

        // ---------------------------------------------------------------- model updates

        void RemoveNode(DirNode dn)
        {
            var p = dn.Parent;
            if (p == null) return;
            p.Children.Remove(dn);
            p.AddUp(-dn.Bytes, -dn.Alloc, -dn.Files, -(dn.Dirs + 1));
            dn.Parent = null;
        }

        void ReplaceNode(DirNode old, DirNode fresh)
        {
            var p = old.Parent;
            if (p == null) { var r = RootOf(old); if (r != null) r.Node = fresh; return; }
            fresh.Name = old.Name;
            fresh.Modified = old.Modified;
            fresh.Parent = p;
            p.Children[p.Children.IndexOf(old)] = fresh;
            p.AddUp(fresh.Bytes - old.Bytes, fresh.Alloc - old.Alloc, fresh.Files - old.Files, fresh.Dirs - old.Dirs);
            old.Parent = null;
        }

        void RemoveFile(FileEntry f)
        {
            var d = f.Dir;
            if (!IsAttached(d)) return;
            d.RemoveFileRec(f.Name);
        }

        /// <summary>Switches every view between file size and size on disk.</summary>
        void SetMeasure(bool onDisk)
        {
            if (DirNode.OnDisk == onDisk) return;
            DirNode.OnDisk = onDisk;
            foreach (var r in roots)
                if (r.Node != null) r.Node.ResortAll();
            var keep = current;
            current = null;
            if (keep != null && IsAttached(keep)) RefreshTree(keep);
            else if (active != null) { RefreshTree(null); }
            ViewsChanged();
            statusLabel.Text = onDisk
                ? "Showing size on disk: the space files really take (compressed and sparse files less, small files a whole cluster, online-only cloud files nothing)."
                : "Showing file size: the length of each file, as Explorer's Size column shows it.";
        }

        async void RescanSelected()
        {
            if (busy || scanning || root == null) return;
            var sel = GetSelection();
            DirNode dir = sel.Count == 1 && sel[0].IsDir ? sel[0].Dir : current;
            if (dir == null) return;
            var ro = RootOf(dir.Top);
            if (ro != null && ro.ReadOnly) { statusLabel.Text = "This is a saved scan opened from a file: it can be browsed, not rescanned."; return; }
            if (dir.Parent == null) { var rr = RootOf(dir); ScanPath(rr != null ? rr.Path : dir.FullPath); return; }

            string path = dir.FullPath;
            var owner = RootOf(dir.Top);
            var s = new Scanner();
            scanner = s;
            scanRoot = owner;
            SetScanning(true, "Rescanning " + Fmt.Shorten(path, 80) + "...");
            DirNode fresh = null;
            var sw = Stopwatch.StartNew();
            try { await RunThread(() => fresh = s.Run(path)); }
            finally { scanner = null; scanRoot = null; SetScanning(false, null); }

            // Stay where the user is; if they are inside the rescanned folder, follow them into the new copy.
            bool inside = current != null && current.IsUnder(dir);
            string here = inside ? current.FullPath : null;
            DirNode target = current;
            if (!Native.Exists(path)) { if (inside) target = dir.Parent; RemoveNode(dir); }
            else
            {
                ReplaceNode(dir, fresh);
                if (inside) target = FindByPath(fresh, here) ?? fresh;
            }
            if (target == null || !IsAttached(target)) target = dir.Parent;
            current = null;
            RefreshTree(target);
            ViewsChanged();
            UpdateDriveLabel();
            statusLabel.Text = string.Format("Rescanned {0}: {1} in {2:0.00} s", path, Fmt.Size(fresh.Size), sw.Elapsed.TotalSeconds);
        }

        static bool IsWithin(string path, string folder)
        {
            if (string.IsNullOrEmpty(folder)) return false;
            folder = folder.TrimEnd('\\');
            return path.Equals(folder, StringComparison.OrdinalIgnoreCase) ||
                   path.StartsWith(folder + "\\", StringComparison.OrdinalIgnoreCase);
        }
    }
}

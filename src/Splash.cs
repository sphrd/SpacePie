using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Threading;
using System.Windows.Forms;

namespace SpacePie
{
    /// <summary>
    /// Splash shown from the first moment of a normal start until the main window is on screen. It runs on its own thread
    /// with its own message loop, so building the main window is never slowed down by it: the window is created in
    /// parallel and the splash closes the moment the window is shown. 520x300, bg, rounded corners and a drop shadow,
    /// a soft accent glow behind the logo, name, "by sphrd" with a version pill, an accent bar, an accent sweep gliding
    /// along the divider, a one-line description and a short log of what is being loaded right now (finished steps get
    /// a check mark, the current one a spinner).
    /// </summary>
    internal sealed class Splash : Form
    {
        const string AppName = "SpacePie";
        const string Description = "Fast, free and open-source disk space analyzer and cleaner";
        const int LogLines = 4;

        static Splash current;
        static readonly ManualResetEvent ready = new ManualResetEvent(false);
        static volatile bool endRequested;
        internal static bool WasShown;
        internal static double ShownAfterMs = -1;
        static readonly object gate = new object();
        static readonly List<string> log = new List<string> { "Starting..." };

        readonly System.Windows.Forms.Timer anim;
        readonly Font titleFont, byFont, pillFont, descFont, logFont;
        readonly string version;
        bool preview;

        /// <summary>
        /// SpacePie.exe --splash: shows the splash (animated) until it is clicked or Esc is pressed, to look at it
        /// for as long as you like; the main window is not opened.
        /// </summary>
        public static void Preview()
        {
            foreach (var asm in AppDomain.CurrentDomain.GetAssemblies())
            {
                string n = asm.GetName().Name;
                if (n != "mscorlib" && asm != typeof(Splash).Assembly) Status("Loaded " + n + ".dll");
            }
            Status("Preview - click or press Esc to close");
            using (var s = new Splash { preview = true, KeyPreview = true })
            {
                s.Shown += (o, e) => s.anim.Start();
                s.Click += (o, e) => s.Close();
                s.KeyDown += (o, e) => { if (e.KeyCode == Keys.Escape) s.Close(); };
                Application.Run(s);
            }
        }

        /// <summary>Starts the splash on its own thread and returns at once.</summary>
        public static void Begin()
        {
            // The log shows what is being loaded, like the unpack progress of a bundled app: the framework DLLs this
            // process has already loaded, then each one that loads while the window is built.
            AppDomain.CurrentDomain.AssemblyLoad += OnAssemblyLoad;
            foreach (var asm in AppDomain.CurrentDomain.GetAssemblies())
            {
                string n = asm.GetName().Name;
                if (n != "mscorlib" && asm != typeof(Splash).Assembly) Status("Loaded " + n + ".dll");
            }
            var t = new Thread(() =>
            {
                try
                {
                    var s = new Splash();
                    current = s;
                    s.Shown += (o, e) =>
                    {
                        WasShown = true;
                        ShownAfterMs = (DateTime.Now - Process.GetCurrentProcess().StartTime).TotalMilliseconds;
                        ready.Set();
                        if (endRequested) s.Close();
                        else s.anim.Start();
                    };
                    Application.Run(s);
                }
                catch (Exception) { ready.Set(); }
            }) { IsBackground = true, Name = "splash" };
            t.SetApartmentState(ApartmentState.STA);
            t.Start();
        }

        /// <summary>Adds a line to the loading log (any thread; kept until the splash is up if it is not yet).</summary>
        public static void Status(string text)
        {
            lock (gate)
            {
                if (log.Count > 0 && log[log.Count - 1] == text) return;
                log.Add(text);
                while (log.Count > LogLines) log.RemoveAt(0);
            }
            var s = current;
            if (s == null || s.IsDisposed || !s.IsHandleCreated) return;
            try { s.BeginInvoke(new Action(() => { if (!s.IsDisposed) s.Invalidate(); })); } catch (Exception) { }
        }

        static void OnAssemblyLoad(object sender, AssemblyLoadEventArgs e)
        {
            Status("Loading " + e.LoadedAssembly.GetName().Name + ".dll");
        }

        /// <summary>Closes the splash (any thread); the main window comes to the front.</summary>
        public static void End(Form main)
        {
            AppDomain.CurrentDomain.AssemblyLoad -= OnAssemblyLoad;
            endRequested = true;
            var s = current;
            if (s != null && !s.IsDisposed && s.IsHandleCreated)
                try { s.BeginInvoke(new Action(() => { if (!s.IsDisposed) s.Close(); })); } catch (Exception) { }
            if (main != null) main.Activate();
        }

        /// <summary>Screenshot mode: the splash as an image (it is not shown in that mode).</summary>
        internal static void SaveImage(string file)
        {
            using (var s = new Splash())
            using (var bmp = new Bitmap(s.Width, s.Height))
            {
                s.DrawToBitmap(bmp, new Rectangle(0, 0, s.Width, s.Height));
                bmp.Save(file, System.Drawing.Imaging.ImageFormat.Png);
            }
        }

        Splash()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
            // The main window sets the same scale later; the splash is up before it, so it reads the DPI itself (from the
            // screen: CreateGraphics would create the handle now and the window would ignore CenterScreen).
            // The splash is a fixed 520x300 layout at the display scale (never zoomed); its own scale, not Theme.Scale.
            using (var g = Graphics.FromHwnd(IntPtr.Zero)) Px1 = g.DpiX / 96f;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            ShowInTaskbar = false;
            BackColor = Theme.BG;
            AutoScaleMode = AutoScaleMode.None;
            ClientSize = new Size(Theme.S(520), Theme.S(300));
            Text = AppName;
            // Sizes are pixels of the 520x300 layout, not points: points would draw everything a third larger.
            titleFont = Px(30f, FontStyle.Bold);
            byFont = Px(14f, FontStyle.Regular);
            pillFont = Px(12f, FontStyle.Bold);
            descFont = Px(14f, FontStyle.Regular);
            logFont = Px(12f, FontStyle.Regular);
            // Same form as the status line and the releases (v2.0.0, never v2.0).
            version = "v" + Updater.Short(Updater.Current);
            anim = new System.Windows.Forms.Timer { Interval = 30 };
            anim.Tick += (o, e) => Invalidate();
        }

        static Font Px(float size, FontStyle style)
        {
            return new Font("Segoe UI", size * Px1, style, GraphicsUnit.Pixel);
        }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                    if (!preview) cp.ExStyle |= 0x80;   // WS_EX_TOOLWINDOW: no taskbar button, no Alt+Tab entry (the preview keeps them)
                cp.ClassStyle |= 0x20000;    // CS_DROPSHADOW
                return cp;
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            Theme.RoundPopup(Handle);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                anim.Dispose();
                titleFont.Dispose(); byFont.Dispose(); pillFont.Dispose(); descFont.Dispose(); logFont.Dispose();
            }
            base.Dispose(disposing);
        }

        static float Px1 = 1f;
        static int S(int v) { return (int)Math.Round(v * Px1); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            double t = Theme.Now;
            g.Clear(Theme.BG);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;

            // The logo with its small soft glow (Theme.DrawLogoGlow, the same everywhere in the app).
            Theme.DrawLogoGlow(g, new Rectangle(S(36), S(44), S(96), S(96)), 1f, 56, ClientRectangle);
            using (var pen = new Pen(Theme.SURFACE, S(2))) g.DrawRectangle(pen, S(1), S(1), Width - S(2), Height - S(2));

            const TextFormatFlags f = TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis;
            const TextFormatFlags measure = TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding;

            // Name, shrunk only if it would not fit.
            var nameBox = new Rectangle(S(156), S(50), Width - S(192), S(44));
            Font title = titleFont;
            for (float size = 30f; size > 20f && TextRenderer.MeasureText(g, AppName, title, Size.Empty, measure).Width > nameBox.Width; size -= 1f)
            {
                if (title != titleFont) title.Dispose();
                title = Px(size - 1f, FontStyle.Bold);
            }
            TextRenderer.DrawText(g, AppName, title, nameBox, Theme.FG, f);
            if (title != titleFont) title.Dispose();

            // "by sphrd" and the version pill.
            int byW = TextRenderer.MeasureText(g, "by sphrd", byFont, Size.Empty, measure).Width;
            TextRenderer.DrawText(g, "by sphrd", byFont, new Rectangle(S(158), S(97), byW + S(4), S(20)), Theme.MUTED, f);
            int verW = TextRenderer.MeasureText(g, version, pillFont, Size.Empty, measure).Width;
            var pill = new Rectangle(S(158) + byW + S(12), S(96), verW + S(18), S(22));
            Theme.FillRound(g, pill, pill.Height / 2, Theme.SURFACE, Theme.BORDER);
            TextRenderer.DrawText(g, version, pillFont, pill, Theme.ACCENT,
                TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);

            // Accent bar under the name block (as on the social preview).
            Theme.FillRound(g, new Rectangle(S(158), S(130), S(44), S(4)), S(2), Theme.ACCENT, Theme.ACCENT);

            // Divider with an accent sweep gliding along it while the app loads.
            int x0 = S(36), x1 = Width - S(36), y = S(158);
            using (var b = new SolidBrush(Theme.SURFACE)) g.FillRectangle(b, x0, y, x1 - x0, S(2));
            Theme.DrawSweep(g, new RectangleF(x0, y, x1 - x0, S(2)), S(140), 1.6, Theme.ACCENT);

            TextRenderer.DrawText(g, Description, descFont, new Rectangle(S(36), S(172), Width - S(72), S(22)), Theme.FG, f);

            // Loading log: finished steps get a check mark, the newest one a spinner.
            string[] lines;
            lock (gate) lines = log.ToArray();
            for (int i = 0; i < lines.Length; i++)
            {
                int ly = S(206) + i * S(18);
                bool last = i == lines.Length - 1;
                var icon = new Rectangle(S(37), ly + S(2), S(11), S(11));
                if (last)
                    Theme.DrawCometArc(g, RectangleF.Inflate(icon, -S(1), -S(1)), (float)(t * 360 % 360), 270, Math.Max(2f, 2f * Px1), Theme.ACCENT);
                else
                    using (var pen = new Pen(Color.FromArgb(160, Theme.ACCENT), Math.Max(1.5f, 1.6f * Px1)) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
                        g.DrawLines(pen, new[] {
                            new PointF(icon.X + icon.Width * 0.1f, icon.Y + icon.Height * 0.55f),
                            new PointF(icon.X + icon.Width * 0.4f, icon.Y + icon.Height * 0.85f),
                            new PointF(icon.X + icon.Width * 0.95f, icon.Y + icon.Height * 0.15f) });
                TextRenderer.DrawText(g, lines[i], logFont, new Rectangle(S(56), ly, Width - S(92), S(18)), last ? Theme.MUTED : Theme.DISABLED_FG, f);
            }
        }
    }
}

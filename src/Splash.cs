using System;
using System.Drawing;
using System.Threading;
using System.Windows.Forms;

namespace DiskSpaceAnalyzer
{
    /// <summary>
    /// Splash shown from the first moment of a normal start until the main window is on screen. It runs on its own thread
    /// with its own message loop, so building the main window is never slowed down by it: the window is created in
    /// parallel and the splash closes the moment the window is shown. 520x300, bg, 2 px surface frame, the logo, name,
    /// tagline, two lines saying what happens next and a live status line.
    /// </summary>
    internal sealed class Splash : Form
    {
        static Splash current;
        static readonly ManualResetEvent ready = new ManualResetEvent(false);
        static volatile bool endRequested;
        internal static bool WasShown;
        internal static double ShownAfterMs = -1;
        string status = "Starting...";

        /// <summary>Starts the splash on its own thread and returns at once.</summary>
        public static void Begin()
        {
            var t = new Thread(() =>
            {
                try
                {
                    var s = new Splash();
                    current = s;
                    s.Shown += (o, e) =>
                    {
                        WasShown = true;
                        ShownAfterMs = (DateTime.Now - System.Diagnostics.Process.GetCurrentProcess().StartTime).TotalMilliseconds;
                        ready.Set();
                        if (endRequested) s.Close();
                    };
                    Application.Run(s);
                }
                catch (Exception) { ready.Set(); }
            }) { IsBackground = true, Name = "splash" };
            t.SetApartmentState(ApartmentState.STA);
            t.Start();
        }

        /// <summary>Updates the status line (any thread).</summary>
        public static void Status(string text)
        {
            var s = current;
            if (s == null || s.IsDisposed) return;
            try { s.BeginInvoke(new Action(() => { s.status = text; s.Invalidate(); })); } catch (Exception) { }
        }

        /// <summary>Closes the splash (any thread); the main window comes to the front.</summary>
        public static void End(Form main)
        {
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
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            ShowInTaskbar = false;
            BackColor = Theme.BG;
            AutoScaleMode = AutoScaleMode.None;
            ClientSize = new Size(Theme.S(520), Theme.S(300));
            Text = "Disk Space Analyzer";
        }

        protected override CreateParams CreateParams
        {
            get { var cp = base.CreateParams; cp.ExStyle |= 0x80; return cp; }   // WS_EX_TOOLWINDOW: no taskbar button, no Alt+Tab entry
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(Theme.BG);
            using (var pen = new Pen(Theme.SURFACE, Theme.S(2))) g.DrawRectangle(pen, Theme.S(1), Theme.S(1), Width - Theme.S(2), Height - Theme.S(2));
            Theme.DrawLogo(g, new Rectangle(Theme.S(36), Theme.S(48), Theme.S(96), Theme.S(96)), 1f);
            const TextFormatFlags f = TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis;
            // The name at 30 pt, smaller if it would not fit (long names).
            var nameBox = new Rectangle(Theme.S(156), Theme.S(54), Width - Theme.S(176), Theme.S(54));
            for (float pt = 30f; pt >= 16f; pt -= 1f)
                using (var title = new Font("Segoe UI", pt, FontStyle.Bold, GraphicsUnit.Point))
                    if (pt <= 16f || TextRenderer.MeasureText(g, "Disk Space Analyzer", title, Size.Empty, TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding).Width <= nameBox.Width)
                    {
                        TextRenderer.DrawText(g, "Disk Space Analyzer", title, nameBox, Theme.FG, f);
                        break;
                    }
            using (var tag = new Font("Segoe UI", 14f, GraphicsUnit.Point))
                TextRenderer.DrawText(g, "Drives  \u2192  where the space went", tag, new Rectangle(Theme.S(158), Theme.S(110), Width - Theme.S(170), Theme.S(30)), Theme.MUTED, f);
            using (var div = new Pen(Theme.SURFACE, 1)) g.DrawLine(div, Theme.S(36), Theme.S(186), Width - Theme.S(36), Theme.S(186));
            using (var small = new Font("Segoe UI", 12f, GraphicsUnit.Point))
            {
                TextRenderer.DrawText(g, "Opening the window. The system drive is analyzed right away;", small,
                    new Rectangle(Theme.S(36), Theme.S(198), Width - Theme.S(72), Theme.S(24)), Theme.MUTED, f);
                TextRenderer.DrawText(g, "you can browse while it runs.", small,
                    new Rectangle(Theme.S(36), Theme.S(222), Width - Theme.S(72), Theme.S(24)), Theme.MUTED, f);
                TextRenderer.DrawText(g, status, small, new Rectangle(Theme.S(36), Theme.S(262), Width - Theme.S(72), Theme.S(24)), Theme.FG, f);
            }
        }
    }
}

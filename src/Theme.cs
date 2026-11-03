using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace DiskSpaceAnalyzer
{
    /// <summary>Design language: palette, fonts and shared drawing helpers. New UI code uses only these names.</summary>
    internal static class Theme
    {
        public static readonly Color BG = Hex(0x222831);
        public static readonly Color SURFACE = Hex(0x2d333d);
        public static readonly Color BORDER = Hex(0x3a414c);
        public static readonly Color SECONDARY_HOVER = Hex(0x4a525e);
        public static readonly Color DISABLED_BG = Hex(0x333a45);
        public static readonly Color FG = Hex(0xffffff);
        public static readonly Color MUTED = Hex(0xaab4c0);
        public static readonly Color DISABLED_FG = Hex(0x6b7480);
        public static readonly Color ACCENT = Hex(0x4da3ff);
        public static readonly Color ACCENT_ACTIVE = Hex(0x7bbcff);
        public static readonly Color ACCENT_LIGHT = Hex(0xcfe4ff);
        // ---- LOGO COLOURS: edit here. This is the only place; tools/make_icon.ps1 reads these three lines for the
        // exe icon, README logo and social preview, so rebuild (build.ps1) after changing them.
        // Shade runs dark -> light: top left, right half, bottom left (Tailwind CSS blue 800 / 600 / 400).
        public static readonly Color LOGO_TOP_LEFT = Hex(0x3d6bcc);
        public static readonly Color LOGO_RIGHT = Hex(0x5e88e6);
        public static readonly Color LOGO_BOTTOM_LEFT = Hex(0x81a2eb);
        public static readonly Color WARN = Hex(0xe0a030);
        public static readonly Color WARN_FG = Hex(0xffd27a);
        public static readonly Color WARN_BG = Hex(0x3d3522);
        public static readonly Color WARN_BORDER = Hex(0x5a4a2a);
        /// <summary>Destructive actions: permanent deletes, uninstalls, the delete progress strip.</summary>
        public static readonly Color DANGER = Hex(0xe5534b);
        public static readonly Color DANGER_HOVER = Hex(0xf47067);
        public static readonly Color DANGER_BG = Hex(0x3b2427);
        public static readonly Color DANGER_BORDER = Hex(0x6b2e30);
        public static readonly Color DANGER_FG = Hex(0xffb3ad);
        // Suggestions (space that can be freed): the one place that gets its own hue, so the tab stands out.
        public static readonly Color SUGGEST = Hex(0x4cc38a);
        public static readonly Color PILL = Hex(0x5c6470);
        public static readonly Color PILL_HOVER = Hex(0x7a828e);
        // Close button hover in the custom title bar: the Windows convention (not a design-language hue).
        public static readonly Color CLOSE_HOVER = Hex(0xc42b1c);

        // Data visualisation only (pie chart): shades of the accent, alternating light/dark so neighbours separate,
        // plus greys for "free space" and catch-all slices.
        public static readonly Color[] CHART = { Hex(0x4da3ff), Hex(0xa6cfff), Hex(0x2f78cc), Hex(0x7bbcff), Hex(0x1f5aa0), Hex(0xcfe4ff), Hex(0x5b95d6), Hex(0x8fb8e8) };
        public static readonly Color CHART_FREE = Hex(0x4a525e);
        public static readonly Color CHART_OTHER = Hex(0x6b7480);

        public static readonly Font FONT = new Font("Segoe UI", 10f);
        public static readonly Font FONT_11 = new Font("Segoe UI", 11f);
        public static readonly Font FONT_9 = new Font("Segoe UI", 9f);
        public static readonly Font FONT_BOLD = new Font("Segoe UI", 10f, FontStyle.Bold);
        public static readonly Font FONT_HEADLINE = new Font("Segoe UI", 15f, FontStyle.Bold);

        public static float Scale = 1f;

        public static int S(int v) { return (int)Math.Round(v * Scale); }

        static Color Hex(int rgb)
        {
            return Color.FromArgb(255, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
        }

        public static GraphicsPath RoundRect(RectangleF r, float radius)
        {
            var p = new GraphicsPath();
            float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
            if (d < 1f) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        /// <summary>Anti-aliased rounded rectangle with a 1 px outline (pass outline == fill for none).</summary>
        public static void FillRound(Graphics g, Rectangle r, int radius, Color fill, Color outline)
        {
            if (r.Width <= 0 || r.Height <= 0) return;
            var sm = g.SmoothingMode;
            var pm = g.PixelOffsetMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            if (outline != fill)
            {
                using (var p = RoundRect(r, radius))
                using (var b = new SolidBrush(outline)) g.FillPath(b, p);
                r.Inflate(-1, -1);
                radius = Math.Max(0, radius - 1);
            }
            using (var p = RoundRect(r, radius))
            using (var b = new SolidBrush(fill)) g.FillPath(b, p);
            g.SmoothingMode = sm;
            g.PixelOffsetMode = pm;
        }

        /// <summary>Half-angle of the logo's mouth (degrees); the mouth faces left (centred on 180).</summary>
        public const float LogoMouth = 30f;

        /// <summary>
        /// Working state of the logo: the mouth read as a 3D cone (apex at the centre, opening left); a tail runs round its
        /// base circle, seen in perspective as an oval centred on the mouth's chord (half-axes 0.11 R across, 0.36 R high,
        /// so it stays inside the logo's circle). Only the tail is drawn (the path itself is invisible): alpha 0 -> full
        /// over 40 % of the loop, ending in a lighter head dot no wider than the line. The phase turns evenly round the 3D
        /// circle, so on screen the motion follows sin/cos: quick across the front and back, slow at the top and bottom.
        /// </summary>
        public static void DrawMouthLoop(Graphics g, Rectangle circle, double seconds, Color c)
        {
            float R = circle.Width / 2f, cx = circle.X + R, cy = circle.Y + R;
            double xc = cx - 0.8 * R * Math.Cos(LogoMouth * Math.PI / 180);
            double a = 0.09 * R, b = 0.3 * R;
            // Runs down the front (outer) side and up the back: y = cy - b sin(phi).
            Func<double, PointF> at = phi => new PointF((float)(xc - a * Math.Cos(phi)), (float)(cy - b * Math.Sin(phi)));
            float w = Math.Max(2f, R / 15f);
            var sm = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            // Highlight: 40 % of the loop behind the phase, a tail whose alpha rises from 0 to full, ending in the bright head.
            const double period = 1.0, span = 0.4 * 2 * Math.PI;
            const int pieces = 48;
            double head = seconds % period / period * 2 * Math.PI;
            for (int i = 0; i < pieces; i++)
            {
                double t0 = i / (double)pieces, t1 = (i + 1) / (double)pieces;
                float k = (float)((t0 + t1) / 2);                              // 0 at the tail end, 1 at the head
                var p0 = at(head - span + t0 * span);
                var p1 = at(head - span + t1 * span);
                using (var pen = new Pen(Color.FromArgb((int)(255 * k * k), c), w) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                    g.DrawLine(pen, p0, p1);
            }
            var hp = at(head);
            using (var br = new SolidBrush(Blend(c, Color.White, 0.3f))) g.FillEllipse(br, hp.X - w / 2, hp.Y - w / 2, w, w);
            g.SmoothingMode = sm;
        }

        /// <summary>
        /// The brand logo: DrawLogo with the soft accent glow behind it (as on the splash). The glow reaches glowFactor x
        /// the diameter from the centre and fades with alpha; glowAlpha ~46 on BG, ~34 on SURFACE.
        /// </summary>
        public static void DrawLogoGlow(Graphics g, Rectangle circle, float alpha, int glowAlpha, float glowFactor = 1.15f)
        {
            if (alpha <= 0) return;
            var sm = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            DrawGlow(g, new PointF(circle.X + circle.Width / 2f, circle.Y + circle.Height / 2f), circle.Width * glowFactor, ACCENT,
                (int)Math.Round(glowAlpha * Math.Min(1f, alpha)));
            g.SmoothingMode = sm;
            DrawLogo(g, circle, alpha);
        }

        /// <summary>
        /// App logo (no tile) in a circle: LOGO_TOP_LEFT upper-left, LOGO_RIGHT right half, LOGO_BOTTOM_LEFT lower-left,
        /// mouth facing left. Used by the chart pane and the About window; the exe icon uses the same colours.
        /// </summary>
        public static void DrawLogo(Graphics g, Rectangle circle, float alpha)
        {
            if (alpha <= 0) return;
            int a = (int)Math.Round(255 * Math.Min(1f, alpha));
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            const float under = 6;
            float mouth = LogoMouth;
            using (var b = new SolidBrush(Color.FromArgb(a, LOGO_TOP_LEFT))) g.FillPie(b, circle, 180 + mouth, 90 - mouth + under);
            using (var b = new SolidBrush(Color.FromArgb(a, LOGO_BOTTOM_LEFT))) g.FillPie(b, circle, 90 - under, 90 - mouth + under);
            using (var b = new SolidBrush(Color.FromArgb(a, LOGO_RIGHT))) g.FillPie(b, circle, -90, 180);
        }

        // ------------------------------------------------------------------ flair (busy states only)
        // One look for everything that says "working": a comet arc (fading tail, bright head, soft glow) instead of a
        // plain arc, an accent sweep gliding along a line or progress bar, and a soft radial glow behind a logo.

        /// <summary>Animation clock (seconds) shared by spinners, sweeps and the splash, so they move in step.</summary>
        public static double Now { get { return clock.Elapsed.TotalSeconds; } }
        static readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();

        /// <summary>
        /// Trailing arc on a circle (every spinner): the head at headAngle (degrees, GDI+), the tail sweep degrees behind it
        /// fading to transparent, ending in a lighter head dot no wider than the line. No glow (it looks cheap on small
        /// shapes; the only glow in the app is the soft one beneath the logo).
        /// </summary>
        public static void DrawCometArc(Graphics g, RectangleF circle, float headAngle, float sweep, float width, Color c)
        {
            var sm = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            const int steps = 28;
            float step = sweep / steps;
            for (int i = 0; i < steps; i++)
            {
                float k = (i + 1) / (float)steps;               // 0 at the tail end, 1 at the head
                int a = (int)(255 * k * k);
                if (a <= 0) continue;
                using (var pen = new Pen(Color.FromArgb(a, c), width) { StartCap = LineCap.Flat, EndCap = LineCap.Flat })
                    g.DrawArc(pen, circle, headAngle - sweep + i * step, step + 0.6f);
            }
            double rad = headAngle * Math.PI / 180;
            float cx = circle.X + circle.Width / 2 + (float)(Math.Cos(rad) * circle.Width / 2);
            float cy = circle.Y + circle.Height / 2 + (float)(Math.Sin(rad) * circle.Height / 2);
            using (var b = new SolidBrush(Blend(c, Color.White, 0.3f))) g.FillEllipse(b, cx - width / 2, cy - width / 2, width, width);
            g.SmoothingMode = sm;
        }

        /// <summary>Soft radial glow: colour c at alpha in the centre, fading to transparent at radius.</summary>
        public static void DrawGlow(Graphics g, PointF center, float radius, Color c, int alpha)
        {
            if (radius < 1) return;
            using (var path = new GraphicsPath())
            {
                path.AddEllipse(center.X - radius, center.Y - radius, 2 * radius, 2 * radius);
                using (var b = new PathGradientBrush(path))
                {
                    b.CenterColor = Color.FromArgb(Math.Max(0, Math.Min(255, alpha)), c);
                    b.SurroundColors = new[] { Color.FromArgb(0, c) };
                    g.FillPath(b, path);
                }
            }
        }

        /// <summary>
        /// Accent sweep: a seg-wide highlight fading to transparent at both ends glides along track (left to right, one
        /// pass per period seconds), clipped to it. Drawn over a divider line or a progress bar's fill.
        /// </summary>
        public static void DrawSweep(Graphics g, RectangleF track, float seg, double period, Color c)
        {
            if (track.Width <= 0 || track.Height <= 0) return;
            float pos = track.X - seg + (float)((Now % period) / period) * (track.Width + seg);
            var sweep = RectangleF.Intersect(new RectangleF(pos, track.Y, seg, track.Height), track);
            if (sweep.Width <= 0) return;
            using (var b = new LinearGradientBrush(new RectangleF(pos - 1, track.Y, seg + 2, track.Height), Color.Transparent, Color.Transparent, 0f))
            {
                b.InterpolationColors = new ColorBlend
                {
                    Colors = new[] { Color.FromArgb(0, c), c, Color.FromArgb(0, c) },
                    Positions = new[] { 0f, 0.5f, 1f }
                };
                g.FillRectangle(b, sweep);
            }
        }

        public static Color Blend(Color a, Color b, float t)
        {
            return Color.FromArgb((int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
        }

        /// <summary>Warning sign: a rounded triangle in c with a BG exclamation mark (bar and dot).</summary>
        public static void DrawWarningSign(Graphics g, Rectangle r, Color c)
        {
            var sm = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float w = r.Width, h = w * 0.88f, x = r.X, y = r.Y + (r.Height - h) / 2, rad = w * 0.09f;
            var pts = new[] { new PointF(x + w / 2, y), new PointF(x + w, y + h), new PointF(x, y + h) };
            using (var path = new GraphicsPath())
            {
                path.AddPolygon(pts);
                using (var b = new SolidBrush(c)) g.FillPath(b, path);
                using (var pen = new Pen(c, rad * 2) { LineJoin = LineJoin.Round }) g.DrawPath(pen, path);
            }
            float cx = x + w / 2, bw = w * 0.11f;
            using (var pen = new Pen(BG, bw) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                g.DrawLine(pen, cx, y + h * 0.36f, cx, y + h * 0.66f);
            using (var b = new SolidBrush(BG)) g.FillEllipse(b, cx - bw * 0.62f, y + h * 0.78f - bw * 0.62f, bw * 1.24f, bw * 1.24f);
            g.SmoothingMode = sm;
        }

        /// <summary>Circular arrow (refresh / rescan): a ~300° arc open at the top right, with an arrowhead at its end.</summary>
        public static void DrawRefresh(Graphics g, Rectangle r, Color c)
        {
            var sm = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float w = Math.Max(1.6f, 1.8f * Scale);
            var arc = RectangleF.Inflate(r, -w, -w);
            using (var pen = new Pen(c, w) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                g.DrawArc(pen, arc, -60, 300);
            // Arrowhead at the arc's end (11 o'clock), pointing on along the arc (clockwise).
            double a = (-60 + 300) * Math.PI / 180;
            float cx = arc.X + arc.Width / 2, cy = arc.Y + arc.Height / 2, rad = arc.Width / 2;
            float ex = cx + rad * (float)Math.Cos(a), ey = cy + rad * (float)Math.Sin(a);
            float tx = -(float)Math.Sin(a), ty = (float)Math.Cos(a);      // tangent, clockwise
            float nx = (float)Math.Cos(a), ny = (float)Math.Sin(a);       // outward normal
            float s = r.Width * 0.30f;
            using (var b = new SolidBrush(c))
                g.FillPolygon(b, new[]
                {
                    new PointF(ex + tx * s, ey + ty * s),
                    new PointF(ex + nx * s * 0.75f, ey + ny * s * 0.75f),
                    new PointF(ex - nx * s * 0.75f, ey - ny * s * 0.75f)
                });
            g.SmoothingMode = sm;
        }

        public static void DrawFolder(Graphics g, Rectangle r, Color c)
        {
            var sm = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float x = r.X, y = r.Y, w = r.Width, h = r.Height;
            using (var b = new SolidBrush(c))
            using (var tab = RoundRect(new RectangleF(x + w * 0.08f, y + h * 0.16f, w * 0.40f, h * 0.24f), w * 0.07f))
            using (var body = RoundRect(new RectangleF(x + w * 0.08f, y + h * 0.28f, w * 0.84f, h * 0.56f), w * 0.10f))
            {
                g.FillPath(b, tab);
                g.FillPath(b, body);
            }
            g.SmoothingMode = sm;
        }

        public static void DrawFile(Graphics g, Rectangle r, Color c)
        {
            var sm = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float x = r.X, y = r.Y, w = r.Width, h = r.Height;
            using (var pen = new Pen(c, Math.Max(1.2f, w * 0.09f)) { LineJoin = LineJoin.Round })
            {
                g.DrawPolygon(pen, new[]
                {
                    new PointF(x + w * 0.24f, y + h * 0.10f), new PointF(x + w * 0.58f, y + h * 0.10f),
                    new PointF(x + w * 0.78f, y + h * 0.30f), new PointF(x + w * 0.78f, y + h * 0.90f),
                    new PointF(x + w * 0.24f, y + h * 0.90f)
                });
                g.DrawLines(pen, new[]
                {
                    new PointF(x + w * 0.58f, y + h * 0.10f), new PointF(x + w * 0.58f, y + h * 0.30f),
                    new PointF(x + w * 0.78f, y + h * 0.30f)
                });
            }
            g.SmoothingMode = sm;
        }

        /// <summary>Chevron in a size x size box: pointing down when open, right when closed.</summary>
        public static void DrawChevron(Graphics g, Rectangle r, Color c, bool down)
        {
            var sm = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float cx = r.X + r.Width / 2f, cy = r.Y + r.Height / 2f, a = r.Width * 0.22f;
            using (var pen = new Pen(c, Math.Max(1.5f, 2 * Scale)) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
            {
                if (down) g.DrawLines(pen, new[] { new PointF(cx - 1.6f * a, cy - 0.8f * a), new PointF(cx, cy + 0.8f * a), new PointF(cx + 1.6f * a, cy - 0.8f * a) });
                else g.DrawLines(pen, new[] { new PointF(cx - 0.8f * a, cy - 1.6f * a), new PointF(cx + 0.8f * a, cy), new PointF(cx - 0.8f * a, cy + 1.6f * a) });
            }
            g.SmoothingMode = sm;
        }

        /// <summary>Arrow (back / forward): a horizontal shaft with an open head, pointing left or right.</summary>
        public static void DrawArrow(Graphics g, Rectangle r, Color c, bool left)
        {
            var sm = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float cx = r.X + r.Width / 2f, cy = r.Y + r.Height / 2f, a = r.Width * 0.40f, d = left ? -1 : 1;
            using (var pen = new Pen(c, Math.Max(1.6f, 1.8f * Scale)) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
            {
                g.DrawLine(pen, cx - d * a, cy, cx + d * a, cy);
                g.DrawLines(pen, new[] { new PointF(cx + d * a * 0.15f, cy - a * 0.8f), new PointF(cx + d * a, cy), new PointF(cx + d * a * 0.15f, cy + a * 0.8f) });
            }
            g.SmoothingMode = sm;
        }

        // ------------------------------------------------------------------ window manager

        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        public static readonly bool HasDwmCorners = Environment.OSVersion.Version.Major >= 10 && Environment.OSVersion.Version.Build >= 22000;

        public static void DarkTitleBar(IntPtr hwnd)
        {
            try
            {
                int on = 1;
                if (DwmSetWindowAttribute(hwnd, 20, ref on, 4) != 0) DwmSetWindowAttribute(hwnd, 19, ref on, 4);
            }
            catch (Exception) { }
        }

        /// <summary>Windows 11: anti-aliased rounded corners and a BORDER outline on popup windows.</summary>
        public static void RoundPopup(IntPtr hwnd)
        {
            if (!HasDwmCorners) return;
            try
            {
                int round = 2;
                DwmSetWindowAttribute(hwnd, 33, ref round, 4);
                int border = BORDER.R | (BORDER.G << 8) | (BORDER.B << 16);
                DwmSetWindowAttribute(hwnd, 34, ref border, 4);
            }
            catch (Exception) { }
        }

        // ------------------------------------------------------------------ scroll interop

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int L, T, R, B; }

        [StructLayout(LayoutKind.Sequential)]
        public struct ScrollInfo
        {
            public int Size;
            public uint Mask;
            public int Min, Max;
            public uint Page;
            public int Pos, TrackPos;
        }

        [DllImport("user32.dll")]
        static extern bool GetScrollInfo(IntPtr hwnd, int bar, ref ScrollInfo info);

        [DllImport("user32.dll", EntryPoint = "GetWindowLong")]
        public static extern int GetWindowLong(IntPtr hwnd, int index);

        [DllImport("user32.dll")]
        public static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, string lParam);

        public static ScrollInfo GetScroll(IntPtr hwnd, bool vertical)
        {
            var si = new ScrollInfo { Size = Marshal.SizeOf(typeof(ScrollInfo)), Mask = 0x17 };
            GetScrollInfo(hwnd, vertical ? 1 : 0, ref si);
            return si;
        }
    }
}

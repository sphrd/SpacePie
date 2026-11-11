using System;
using System.Drawing;
using System.Drawing.Drawing2D;

namespace SpacePie
{
    /// <summary>
    /// Line icons for the toolbar buttons (drawn in the button's text colour inside a square), in the style of the views
    /// bar icons: round caps and joins, 1.7 px lines at 100 %.
    /// </summary>
    internal static class Icons
    {
        static Pen LinePen(Color c) { return new Pen(c, Math.Max(1.5f, 1.7f * Theme.Scale)) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round }; }

        static void Draw(Graphics g, Action body)
        {
            var sm = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            body();
            g.SmoothingMode = sm;
        }

        static GraphicsPath FolderPath(float x, float y, float s)
        {
            var p = new GraphicsPath();
            p.AddLines(new[]
            {
                new PointF(x + s * 0.08f, y + s * 0.80f), new PointF(x + s * 0.08f, y + s * 0.20f), new PointF(x + s * 0.38f, y + s * 0.20f),
                new PointF(x + s * 0.48f, y + s * 0.32f), new PointF(x + s * 0.92f, y + s * 0.32f), new PointF(x + s * 0.92f, y + s * 0.80f)
            });
            p.CloseFigure();
            return p;
        }

        /// <summary>Choose...: a folder.</summary>
        public static void Folder(Graphics g, Rectangle r, Color c)
        {
            Draw(g, () => { using (var pen = LinePen(c)) using (var p = FolderPath(r.X, r.Y, r.Width)) g.DrawPath(pen, p); });
        }

        /// <summary>Scan: the logo's outline, a circle with its mouth open to the left (as in the logo, Theme.LogoMouth).</summary>
        public static void Scan(Graphics g, Rectangle r, Color c)
        {
            Draw(g, () =>
            {
                float s = r.Width, m = s * 0.10f;
                using (var pen = LinePen(c))
                    g.DrawPie(pen, r.X + m, r.Y + m, s - 2 * m, s - 2 * m, 180 + Theme.LogoMouth, 360 - 2 * Theme.LogoMouth);
            });
        }

        /// <summary>Run as administrator: a shield.</summary>
        public static void Shield(Graphics g, Rectangle r, Color c)
        {
            Draw(g, () =>
            {
                float x = r.X, y = r.Y, s = r.Width;
                using (var pen = LinePen(c))
                using (var p = new GraphicsPath())
                {
                    p.AddLine(x + s * 0.50f, y + s * 0.08f, x + s * 0.86f, y + s * 0.22f);
                    p.AddBezier(x + s * 0.86f, y + s * 0.22f, x + s * 0.86f, y + s * 0.62f, x + s * 0.72f, y + s * 0.80f, x + s * 0.50f, y + s * 0.92f);
                    p.AddBezier(x + s * 0.50f, y + s * 0.92f, x + s * 0.28f, y + s * 0.80f, x + s * 0.14f, y + s * 0.62f, x + s * 0.14f, y + s * 0.22f);
                    p.CloseFigure();
                    g.DrawPath(pen, p);
                    g.DrawLine(pen, x + s * 0.50f, y + s * 0.24f, x + s * 0.50f, y + s * 0.76f);
                }
            });
        }

        /// <summary>Show in Explorer: an open folder (the back with its tab, the front flap tilted open).</summary>
        public static void Reveal(Graphics g, Rectangle r, Color c)
        {
            Draw(g, () =>
            {
                float x = r.X, y = r.Y, s = r.Width;
                using (var pen = LinePen(c))
                {
                    g.DrawLines(pen, new[]
                    {
                        new PointF(x + s * 0.08f, y + s * 0.82f), new PointF(x + s * 0.08f, y + s * 0.18f), new PointF(x + s * 0.36f, y + s * 0.18f),
                        new PointF(x + s * 0.46f, y + s * 0.30f), new PointF(x + s * 0.82f, y + s * 0.30f), new PointF(x + s * 0.82f, y + s * 0.42f)
                    });
                    g.DrawPolygon(pen, new[]
                    {
                        new PointF(x + s * 0.08f, y + s * 0.82f), new PointF(x + s * 0.24f, y + s * 0.42f),
                        new PointF(x + s * 0.96f, y + s * 0.42f), new PointF(x + s * 0.80f, y + s * 0.82f)
                    });
                }
            });
        }

        /// <summary>Delete list: a trash can (also the views bar icon of the delete list).</summary>
        public static void Trash(Graphics g, Rectangle r, Color c)
        {
            Draw(g, () => { using (var pen = LinePen(c)) TrashLines(g, pen, r.X, r.Y, r.Width); });
        }

        static void TrashLines(Graphics g, Pen pen, float x, float y, float s)
        {
            g.DrawLine(pen, x + s * 0.14f, y + s * 0.24f, x + s * 0.86f, y + s * 0.24f);
            g.DrawLine(pen, x + s * 0.40f, y + s * 0.12f, x + s * 0.60f, y + s * 0.12f);
            using (var path = new GraphicsPath())
            {
                path.AddLines(new[] { new PointF(x + s * 0.22f, y + s * 0.24f), new PointF(x + s * 0.28f, y + s * 0.90f),
                    new PointF(x + s * 0.72f, y + s * 0.90f), new PointF(x + s * 0.78f, y + s * 0.24f) });
                g.DrawPath(pen, path);
            }
            g.DrawLine(pen, x + s * 0.42f, y + s * 0.40f, x + s * 0.43f, y + s * 0.74f);
            g.DrawLine(pen, x + s * 0.58f, y + s * 0.40f, x + s * 0.57f, y + s * 0.74f);
        }

        /// <summary>Add to delete list: a smaller trash can with a plus at its top right.</summary>
        public static void TrashAdd(Graphics g, Rectangle r, Color c)
        {
            Draw(g, () =>
            {
                float x = r.X, y = r.Y, s = r.Width;
                using (var pen = LinePen(c))
                {
                    TrashLines(g, pen, x - s * 0.06f, y + s * 0.12f, s * 0.84f);
                    g.DrawLine(pen, x + s * 0.80f, y + s * 0.02f, x + s * 0.80f, y + s * 0.34f);
                    g.DrawLine(pen, x + s * 0.64f, y + s * 0.18f, x + s * 0.96f, y + s * 0.18f);
                }
            });
        }

        /// <summary>Delete permanently: a warning triangle with an exclamation mark (lines, for a coloured button).</summary>
        public static void Danger(Graphics g, Rectangle r, Color c)
        {
            Draw(g, () =>
            {
                float x = r.X, y = r.Y, s = r.Width;
                using (var pen = LinePen(c))
                {
                    g.DrawPolygon(pen, new[] { new PointF(x + s * 0.50f, y + s * 0.10f), new PointF(x + s * 0.94f, y + s * 0.88f), new PointF(x + s * 0.06f, y + s * 0.88f) });
                    g.DrawLine(pen, x + s * 0.50f, y + s * 0.38f, x + s * 0.50f, y + s * 0.62f);
                }
                using (var b = new SolidBrush(c)) g.FillEllipse(b, x + s * 0.43f, y + s * 0.70f, s * 0.14f, s * 0.14f);
            });
        }

        /// <summary>Import...: an arrow coming down into an open tray (the reverse of Export).</summary>
        public static void Import(Graphics g, Rectangle r, Color c)
        {
            Draw(g, () =>
            {
                float x = r.X, y = r.Y, s = r.Width;
                using (var pen = LinePen(c))
                {
                    g.DrawLines(pen, new[] { new PointF(x + s * 0.10f, y + s * 0.56f), new PointF(x + s * 0.10f, y + s * 0.90f), new PointF(x + s * 0.90f, y + s * 0.90f), new PointF(x + s * 0.90f, y + s * 0.56f) });
                    g.DrawLine(pen, x + s * 0.50f, y + s * 0.08f, x + s * 0.50f, y + s * 0.68f);
                    g.DrawLines(pen, new[] { new PointF(x + s * 0.28f, y + s * 0.46f), new PointF(x + s * 0.50f, y + s * 0.68f), new PointF(x + s * 0.72f, y + s * 0.46f) });
                }
            });
        }

        /// <summary>Export...: an open tray with an arrow rising out of it.</summary>
        public static void Export(Graphics g, Rectangle r, Color c)
        {
            Draw(g, () =>
            {
                float x = r.X, y = r.Y, s = r.Width;
                using (var pen = LinePen(c))
                {
                    g.DrawLines(pen, new[] { new PointF(x + s * 0.10f, y + s * 0.56f), new PointF(x + s * 0.10f, y + s * 0.90f), new PointF(x + s * 0.90f, y + s * 0.90f), new PointF(x + s * 0.90f, y + s * 0.56f) });
                    g.DrawLine(pen, x + s * 0.50f, y + s * 0.68f, x + s * 0.50f, y + s * 0.08f);
                    g.DrawLines(pen, new[] { new PointF(x + s * 0.28f, y + s * 0.30f), new PointF(x + s * 0.50f, y + s * 0.08f), new PointF(x + s * 0.72f, y + s * 0.30f) });
                }
            });
        }
    }
}

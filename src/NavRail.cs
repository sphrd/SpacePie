using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace SpacePie
{
    /// <summary>
    /// Vertical bar of views on the left of the window: one row per view, a line icon with its name to the right. The
    /// current view sits on a SURFACE pill with an ACCENT marker on its left edge and ACCENT icon and name; the others are
    /// MUTED (FG on hover). A title ending in " (n)" shows n as a badge at the end of the row. When the window is too low
    /// for every row, the bar scrolls (mouse wheel) and shows a thin scroll pill. Items can be hidden (a view opened from
    /// elsewhere, like the delete list); while such a view is shown no row is highlighted. Indexes are the page indexes.
    /// </summary>
    internal sealed class NavRail : Control
    {
        readonly string[] titles;
        readonly Dictionary<int, Color> colors = new Dictionary<int, Color>();
        readonly HashSet<int> hidden = new HashSet<int>();
        int selected, hover = -1, scroll;
        public event EventHandler SelectedIndexChanged;

        public NavRail(params string[] titles)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            SetStyle(ControlStyles.Selectable, false);
            this.titles = titles;
            Font = Theme.FONT_9;
            BackColor = Theme.BG;
            Width = Theme.S(150);
        }

        public int SelectedIndex
        {
            get { return selected; }
            set
            {
                if (selected == value) return;
                selected = value;
                Reveal(value);
                Invalidate();
                if (SelectedIndexChanged != null) SelectedIndexChanged(this, EventArgs.Empty);
            }
        }

        public void SetTitle(int i, string text) { titles[i] = text; Invalidate(); }

        /// <summary>Gives one view its own colour (icon and label) instead of muted/accent.</summary>
        public void SetColor(int i, Color c) { colors[i] = c; Invalidate(); }

        /// <summary>Leaves view i out of the bar (it is opened from elsewhere).</summary>
        public void Hide(int i) { hidden.Add(i); Invalidate(); }

        int ItemHeight { get { return Theme.S(36); } }
        int Gap { get { return Theme.S(2); } }

        /// <summary>Position of view i among the shown rows (-1 when hidden).</summary>
        int Slot(int i)
        {
            if (hidden.Contains(i)) return -1;
            int n = 0;
            for (int k = 0; k < i; k++) if (!hidden.Contains(k)) n++;
            return n;
        }

        int ContentHeight { get { return (titles.Length - hidden.Count) * (ItemHeight + Gap) - Gap; } }
        int MaxScroll { get { return Math.Max(0, ContentHeight - Height); } }

        Rectangle ItemRect(int i)
        {
            int s = Slot(i);
            return s < 0 ? Rectangle.Empty : new Rectangle(0, s * (ItemHeight + Gap) - scroll, Width - Theme.S(4), ItemHeight);
        }

        void Reveal(int i)
        {
            var r = ItemRect(i);
            if (r.IsEmpty) return;
            if (r.Y < 0) scroll += r.Y;
            else if (r.Bottom > Height) scroll += r.Bottom - Height;
            scroll = Math.Max(0, Math.Min(MaxScroll, scroll));
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            scroll = Math.Max(0, Math.Min(MaxScroll, scroll));
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            base.OnMouseWheel(e);
            int s = Math.Max(0, Math.Min(MaxScroll, scroll - e.Delta * (ItemHeight + Gap) / 120));
            if (s == scroll) return;
            scroll = s;
            hover = HitTest(e.Location);
            Invalidate();
        }

        /// <summary>Label and badge of a title: "Delete list (4)" -> "Delete list" and "4".</summary>
        static void Split(string title, out string label, out string badge)
        {
            label = title; badge = null;
            if (!title.EndsWith(")")) return;
            int i = title.LastIndexOf(" (", StringComparison.Ordinal);
            if (i <= 0) return;
            label = title.Substring(0, i);
            badge = title.Substring(i + 2, title.Length - i - 3);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(BackColor);
            CutText.Begin(this);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            for (int i = 0; i < titles.Length; i++)
            {
                var r = ItemRect(i);
                if (r.IsEmpty || r.Bottom < 0 || r.Y > Height) continue;
                Color own;
                bool hasOwn = colors.TryGetValue(i, out own);
                bool sel = i == selected;
                if (sel)
                {
                    Theme.FillRound(g, r, Theme.S(8), Theme.SURFACE, Theme.SURFACE);
                    Color mark = hasOwn ? own : Theme.ACCENT;
                    Theme.FillRound(g, new Rectangle(r.X, r.Y + Theme.S(9), Theme.S(3), r.Height - Theme.S(18)), Theme.S(2), mark, mark);
                }
                else if (i == hover) Theme.FillRound(g, r, Theme.S(8), Theme.BORDER, Theme.BORDER);
                Color c = sel ? (hasOwn ? own : Theme.ACCENT) : hasOwn ? (i == hover ? Theme.FG : own) : i == hover ? Theme.FG : Theme.MUTED;
                string label, badge;
                Split(titles[i], out label, out badge);
                int ic = Theme.S(18);
                var ir = new Rectangle(r.X + Theme.S(12), r.Y + (r.Height - ic) / 2, ic, ic);
                DrawIcon(g, label, ir, c);
                int textRight = r.Right - Theme.S(6);
                if (badge != null)
                {
                    int bw = Math.Max(Theme.S(20), TextRenderer.MeasureText(badge, Theme.FONT_9, Size.Empty, TextFormatFlags.NoPadding).Width + Theme.S(10));
                    var br = new Rectangle(r.Right - Theme.S(8) - bw, r.Y + (r.Height - Theme.S(18)) / 2, bw, Theme.S(18));
                    Theme.FillRound(g, br, br.Height / 2, Theme.ACCENT, Theme.ACCENT);
                    TextRenderer.DrawText(g, badge, Theme.FONT_9, br, Theme.BG,
                        TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
                    textRight = br.Left - Theme.S(4);
                }
                var tr = new Rectangle(ir.Right + Theme.S(10), r.Y, Math.Max(0, textRight - ir.Right - Theme.S(10)), r.Height);
                CutText.Draw(g, this, label, Font, tr, c, TextFormatFlags.Left | TextFormatFlags.VerticalCenter);
            }
            // Thin scroll pill when not every row fits.
            if (MaxScroll > 0)
            {
                int track = Height, ch = ContentHeight;
                int ph = Math.Max(Theme.S(24), track * track / ch);
                int py = (int)((long)(track - ph) * scroll / MaxScroll);
                var pr = new Rectangle(Width - Theme.S(3), py, Theme.S(3), ph);
                Theme.FillRound(g, pr, Theme.S(1), Theme.BORDER, Theme.BORDER);
            }
        }

        /// <summary>One line icon per view, drawn in c inside r.</summary>
        static void DrawIcon(Graphics g, string label, Rectangle r, Color c)
        {
            float w = Math.Max(1.5f, 1.7f * Theme.Scale);
            float x = r.X, y = r.Y, s = r.Width;
            using (var pen = new Pen(c, w) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
            using (var b = new SolidBrush(c))
            {
                switch (label.ToLowerInvariant())
                {
                    case "contents":
                        Theme.DrawFolder(g, Rectangle.Round(new RectangleF(x, y + s * 0.04f, s, s)), c);
                        break;
                    case "suggestions":
                        Sparkle(g, b, x + s * 0.42f, y + s * 0.52f, s * 0.36f);
                        Sparkle(g, b, x + s * 0.80f, y + s * 0.20f, s * 0.16f);
                        break;
                    case "apps":
                        {
                            float q = s * 0.40f, gap = s * 0.12f, o = (s - 2 * q - gap) / 2;
                            for (int i = 0; i < 4; i++)
                            {
                                var rr = new RectangleF(x + o + (i % 2) * (q + gap), y + o + (i / 2) * (q + gap), q, q);
                                using (var path = Theme.RoundRect(rr, q * 0.28f)) g.DrawPath(pen, path);
                            }
                        }
                        break;
                    case "system":
                        using (var path = Theme.RoundRect(new RectangleF(x + s * 0.08f, y + s * 0.14f, s * 0.84f, s * 0.56f), s * 0.08f)) g.DrawPath(pen, path);
                        g.DrawLine(pen, x + s * 0.5f, y + s * 0.70f, x + s * 0.5f, y + s * 0.84f);
                        g.DrawLine(pen, x + s * 0.32f, y + s * 0.86f, x + s * 0.68f, y + s * 0.86f);
                        break;
                    case "files":
                        g.DrawEllipse(pen, x + s * 0.12f, y + s * 0.12f, s * 0.54f, s * 0.54f);
                        g.DrawLine(pen, x + s * 0.60f, y + s * 0.60f, x + s * 0.88f, y + s * 0.88f);
                        break;
                    case "file types":
                        Document(g, pen, x + s * 0.18f, y + s * 0.08f, s * 0.64f, s * 0.84f);
                        g.DrawLine(pen, x + s * 0.34f, y + s * 0.50f, x + s * 0.66f, y + s * 0.50f);
                        g.DrawLine(pen, x + s * 0.34f, y + s * 0.68f, x + s * 0.58f, y + s * 0.68f);
                        break;
                    case "duplicates":
                        Document(g, pen, x + s * 0.30f, y + s * 0.06f, s * 0.56f, s * 0.70f);
                        using (var path = Theme.RoundRect(new RectangleF(x + s * 0.14f, y + s * 0.24f, s * 0.56f, s * 0.70f), s * 0.08f))
                        {
                            using (var bg = new SolidBrush(Theme.BG)) g.FillPath(bg, path);
                            g.DrawPath(pen, path);
                        }
                        break;
                    case "changes":
                        g.DrawEllipse(pen, x + s * 0.10f, y + s * 0.10f, s * 0.80f, s * 0.80f);
                        g.DrawLine(pen, x + s * 0.5f, y + s * 0.5f, x + s * 0.5f, y + s * 0.26f);
                        g.DrawLine(pen, x + s * 0.5f, y + s * 0.5f, x + s * 0.68f, y + s * 0.60f);
                        break;
                    case "delete list":
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
                        break;
                    default:
                        g.DrawEllipse(pen, x + s * 0.2f, y + s * 0.2f, s * 0.6f, s * 0.6f);
                        break;
                }
            }
        }

        static void Document(Graphics g, Pen pen, float x, float y, float w, float h)
        {
            float f = w * 0.32f;
            using (var path = new GraphicsPath())
            {
                path.AddLines(new[] { new PointF(x, y), new PointF(x + w - f, y), new PointF(x + w, y + f), new PointF(x + w, y + h), new PointF(x, y + h) });
                path.CloseFigure();
                g.DrawPath(pen, path);
            }
            g.DrawLines(pen, new[] { new PointF(x + w - f, y), new PointF(x + w - f, y + f), new PointF(x + w, y + f) });
        }

        /// <summary>Four-pointed star centred at (cx, cy) with radius r.</summary>
        static void Sparkle(Graphics g, Brush b, float cx, float cy, float r)
        {
            float k = r * 0.28f;
            g.FillPolygon(b, new[]
            {
                new PointF(cx, cy - r), new PointF(cx + k, cy - k), new PointF(cx + r, cy), new PointF(cx + k, cy + k),
                new PointF(cx, cy + r), new PointF(cx - k, cy + k), new PointF(cx - r, cy), new PointF(cx - k, cy - k)
            });
        }

        int HitTest(Point p)
        {
            for (int i = 0; i < titles.Length; i++) { var r = ItemRect(i); if (!r.IsEmpty && r.Contains(p)) return i; }
            return -1;
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            int h = HitTest(e.Location);
            Cursor = h >= 0 ? Cursors.Hand : Cursors.Default;
            if (h != hover) { hover = h; Invalidate(); }
        }

        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hover = -1; Invalidate(); }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            int h = HitTest(e.Location);
            if (h >= 0 && e.Button == MouseButtons.Left) SelectedIndex = h;
        }
    }
}

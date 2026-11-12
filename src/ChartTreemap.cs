using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace SpacePie
{
    /// <summary>
    /// Treemap view of the same slices as the pie chart: one rectangle per slice, area in true proportion (squarified so
    /// rectangles stay close to square). Folder slices hold their subfolders, two levels deep (like the outer rings).
    /// Hover, click (open a folder) and the link to the list work as for the rings; the area below the map shows the
    /// hovered item, and "Up" goes to the parent folder.
    /// </summary>
    internal sealed partial class PieChart
    {
        sealed class Tile
        {
            public RectangleF R;
            public int Slice;          // index of the slice it belongs to
            public int Level;          // 0 = the slice itself
            public DirNode Dir;
            public Color Color;
            public string Label;
            public long Size, ParentSize;
            public string ParentName;
        }

        bool treemap;
        bool tilesDirty = true;
        readonly List<Tile> tiles = new List<Tile>();
        int hoverTile = -1;
        bool hoverUp;
        Rectangle mapRect, upRect;

        /// <summary>Rectangles laid out at the last paint (self-test).</summary>
        public int TileCount { get { return tiles.Count; } }

        /// <summary>Right margin of the title lines (room for the Pie / Treemap switch placed over the chart).</summary>
        public int TitleRightMargin;

        /// <summary>Rectangles instead of rings.</summary>
        public bool Treemap
        {
            get { return treemap; }
            set
            {
                if (treemap == value) return;
                treemap = value;
                tilesDirty = true;
                tiles.Clear();
                hover = reported = hoverTile = hoverArc = -1;
                reportedDir = null;
                Invalidate();
            }
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            tilesDirty = true;
        }

        // ---- layout

        /// <summary>Squarified treemap (Bruls et al.): sizes in any order; returns one rectangle per size, same order.</summary>
        internal static RectangleF[] Squarify(IList<double> sizes, RectangleF area)
        {
            var result = new RectangleF[sizes.Count];
            var order = new List<int>();
            double sum = 0;
            for (int i = 0; i < sizes.Count; i++) if (sizes[i] > 0) { order.Add(i); sum += sizes[i]; }
            if (sum <= 0 || area.Width <= 0 || area.Height <= 0) return result;
            order.Sort((a, b) => sizes[b].CompareTo(sizes[a]));
            double scale = area.Width * (double)area.Height / sum;
            var rect = area;
            int start = 0;
            while (start < order.Count)
            {
                double side = Math.Min(rect.Width, rect.Height);
                int end = start;
                double rowSum = 0, worst = double.MaxValue;
                while (end < order.Count)
                {
                    double a = sizes[order[end]] * scale, s = rowSum + a;
                    double maxA = Math.Max(a, end > start ? sizes[order[start]] * scale : a), minA = a;
                    double w = Math.Max(side * side * maxA / (s * s), s * s / (side * side * minA));
                    if (end > start && w > worst) break;
                    worst = w;
                    rowSum = s;
                    end++;
                }
                // Lay out order[start..end) along the shorter side.
                bool horizontal = rect.Width >= rect.Height;   // row stacked vertically in a column on the left
                double thick = rowSum / side;
                float pos = horizontal ? rect.Y : rect.X;
                for (int k = start; k < end; k++)
                {
                    double len = sizes[order[k]] * scale / thick;
                    result[order[k]] = horizontal
                        ? new RectangleF(rect.X, pos, (float)thick, (float)len)
                        : new RectangleF(pos, rect.Y, (float)len, (float)thick);
                    pos += (float)len;
                }
                rect = horizontal
                    ? new RectangleF(rect.X + (float)thick, rect.Y, Math.Max(0, rect.Width - (float)thick), rect.Height)
                    : new RectangleF(rect.X, rect.Y + (float)thick, rect.Width, Math.Max(0, rect.Height - (float)thick));
                start = end;
            }
            return result;
        }

        void LayoutTiles()
        {
            tiles.Clear();
            tilesDirty = false;
            if (total <= 0 || mapRect.Width < 10 || mapRect.Height < 10) return;
            var sizes = new List<double>();
            foreach (var s in slices) sizes.Add(Math.Max(0, s.Size));
            var rects = Squarify(sizes, mapRect);
            for (int i = 0; i < slices.Count; i++)
            {
                if (rects[i].Width <= 0 || rects[i].Height <= 0) continue;
                var s = slices[i];
                tiles.Add(new Tile { R = rects[i], Slice = i, Level = 0, Dir = s.Dir, Color = s.Color, Label = s.Label, Size = s.Size, ParentSize = total });
            }
            int count = tiles.Count;
            for (int i = 0; i < count; i++)
                if (tiles[i].Dir != null && !slices[tiles[i].Slice].Empty) AddChildTiles(tiles[i], 1);
        }

        /// <summary>Subfolders inside a folder's tile (below its name), down to level 2; small ones are left out.</summary>
        void AddChildTiles(Tile parent, int level)
        {
            var dir = parent.Dir;
            if (level > 2 || dir.Children == null || dir.Size <= 0) return;
            var r = parent.R;
            float head = level == 1 && r.Height > Theme.FONT_9.Height * 3 ? Theme.FONT_9.Height + Theme.S(6) : 0;
            float inset = Theme.S(level == 1 ? 3 : 2);
            var inner = new RectangleF(r.X + inset, r.Y + head + inset, r.Width - 2 * inset, r.Height - head - 2 * inset);
            if (inner.Width < Theme.S(12) || inner.Height < Theme.S(12)) return;
            // The folder's own files take their share too (as a gap), so every subfolder keeps its true proportion.
            var kids = new List<DirNode>();
            var sizes = new List<double>();
            foreach (var c in dir.Children) { if (c.Size <= 0) break; kids.Add(c); sizes.Add(c.Size); }
            if (kids.Count == 0) return;
            long kidsSum = 0;
            foreach (var c in kids) kidsSum += c.Size;
            if (dir.Size - kidsSum > 0) sizes.Add(dir.Size - kidsSum);
            var rects = Squarify(sizes, inner);
            int k = 0;
            for (int i = 0; i < kids.Count; i++)
            {
                var cr = rects[i];
                if (cr.Width < Theme.S(4) || cr.Height < Theme.S(4)) continue;
                var color = Blend(slices[parent.Slice].Color, BackColor, (level == 1 ? 0.28f : 0.5f) + (k++ % 2 == 0 ? 0f : 0.12f));
                var t = new Tile { R = cr, Slice = parent.Slice, Level = level, Dir = kids[i], Color = color, Label = kids[i].Name, Size = kids[i].Size, ParentSize = dir.Size, ParentName = dir.Name };
                tiles.Add(t);
                AddChildTiles(t, level + 1);
            }
        }

        // ---- painting

        void PaintTreemap(Graphics g, Rectangle area)
        {
            int infoH = Theme.FONT_9.Height * 2 + Theme.S(10);
            var map = new Rectangle(area.X, area.Y, area.Width, Math.Max(Theme.S(40), area.Height - infoH));
            if (map != mapRect) { mapRect = map; tilesDirty = true; }
            if (tilesDirty) LayoutTiles();
            float alpha = Animating ? Ease(anim) : 1f;
            if (Animating)
            {
                MorphFrames++;
                DrawLogo(g, pieRect, 1 - alpha);
            }
            if (total <= 0)
            {
                using (var b = new SolidBrush(Theme.BORDER)) g.FillRectangle(b, mapRect);
            }
            const TextFormatFlags one = TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding;
            using (var sep = new Pen(BackColor, Math.Max(1f, Theme.Scale)))
                for (int i = 0; i < tiles.Count; i++)
                {
                    var t = tiles[i];
                    var s = slices[t.Slice];
                    bool hot = i == hoverTile || (t.Level == 0 && t.Slice == hover && hoverTile < 0);
                    var rr = Rectangle.Round(t.R);
                    if (s.Empty && t.Level == 0)
                    {
                        // Free space: nothing drawn but an outline (a faint fill while hovered), like the gap in the ring.
                        if (hot) using (var b = new SolidBrush(Fade(Theme.BORDER, alpha))) g.FillRectangle(b, rr);
                        using (var p = new Pen(Fade(Theme.BORDER, alpha))) g.DrawRectangle(p, rr.X, rr.Y, rr.Width - 1, rr.Height - 1);
                    }
                    else
                    {
                        var col = hot ? Blend(t.Color, Theme.HOVER, Theme.HOVER_MIX) : t.Color;
                        using (var b = new SolidBrush(Fade(col, alpha))) g.FillRectangle(b, rr);
                        g.DrawRectangle(sep, rr.X, rr.Y, rr.Width - 1, rr.Height - 1);
                    }
                    // Names where they fit: every slice, and level-1 folders that are large enough.
                    if (alpha < 1 || t.Level > 1) continue;
                    int lh = Theme.FONT_9.Height;
                    if (rr.Width < Theme.S(44) || rr.Height < lh + Theme.S(6)) continue;
                    if (t.Level == 1 && (rr.Width < Theme.S(70) || rr.Height < lh * 2 + Theme.S(6))) continue;
                    var fg = s.Empty ? Theme.MUTED : Readable(t.Color);
                    var tr = new Rectangle(rr.X + Theme.S(5), rr.Y + Theme.S(3), rr.Width - Theme.S(10), lh);
                    TextRenderer.DrawText(g, t.Label ?? "", Theme.FONT_9, tr, fg, one);
                    if (t.Level == 0 && t.Dir == null && rr.Height >= lh * 2 + Theme.S(8))
                        TextRenderer.DrawText(g, Fmt.Size(t.Size), Theme.FONT_9, new Rectangle(tr.X, tr.Y + lh, tr.Width, lh), fg, one);
                }
            // The hovered folder's tile is mostly covered by its subfolders: an outline on top shows where it is.
            if (alpha >= 1 && hoverTile >= 0 && hoverTile < tiles.Count)
                using (var pen = new Pen(Theme.HOVER, Math.Max(2f, 2 * Theme.Scale)) { Alignment = PenAlignment.Inset })
                {
                    var hr = Rectangle.Round(tiles[hoverTile].R);
                    g.DrawRectangle(pen, hr.X, hr.Y, hr.Width - 1, hr.Height - 1);
                }
            DrawTreemapInfo(g, new Rectangle(area.X, mapRect.Bottom + Theme.S(6), area.Width, infoH - Theme.S(6)));
        }

        /// <summary>Dark text on light tiles, white on dark ones.</summary>
        static Color Readable(Color c)
        {
            double lum = (0.299 * c.R + 0.587 * c.G + 0.114 * c.B) / 255;
            return lum > 0.6 ? Theme.BG : Theme.FG;
        }

        /// <summary>Below the map: the hovered item (name; size and share), or the folder shown; "Up" on the right.</summary>
        void DrawTreemapInfo(Graphics g, Rectangle r)
        {
            string l1, l2;
            if (hoverTile >= 0 && hoverTile < tiles.Count && tiles[hoverTile].Level > 0)
            {
                var t = tiles[hoverTile];
                l1 = t.Label;
                l2 = string.Format("{0}  -  {1:0.0} % of {2}", Fmt.Size(t.Size), 100.0 * t.Size / Math.Max(1, t.ParentSize), t.ParentName ?? "parent");
            }
            else if (hover >= 0 && hover < slices.Count) { l1 = slices[hover].Label; l2 = Fmt.Size(slices[hover].Size) + (string.IsNullOrEmpty(slices[hover].Detail) ? "" : "  -  " + slices[hover].Detail); }
            else if (centerName != null && centerFree >= 0) { l1 = centerName; l2 = Fmt.Size(centerFree) + " free of " + Fmt.Size(total); }
            else { l1 = centerName ?? "Total"; l2 = Fmt.Size(total); }
            upRect = Rectangle.Empty;
            int right = r.Right;
            if (canGoUp)
            {
                var sz = TextRenderer.MeasureText("Up", Theme.FONT_9);
                upRect = new Rectangle(r.Right - sz.Width - Theme.S(28), r.Y + (r.Height - sz.Height - Theme.S(8)) / 2, sz.Width + Theme.S(28), sz.Height + Theme.S(8));
                g.SmoothingMode = SmoothingMode.AntiAlias;
                Theme.FillRound(g, upRect, Theme.S(7), hoverUp ? Theme.SECONDARY_HOVER : Theme.BORDER, hoverUp ? Theme.SECONDARY_HOVER : Theme.BORDER);
                g.SmoothingMode = SmoothingMode.Default;
                int a = Theme.S(10);
                using (var m = new Matrix())
                {
                    // An arrow pointing up: the back arrow turned by 90 degrees.
                    var ar = new Rectangle(upRect.X + Theme.S(7), upRect.Y + (upRect.Height - a) / 2, a, a);
                    m.RotateAt(90, new PointF(ar.X + a / 2f, ar.Y + a / 2f));
                    var st = g.Save();
                    g.MultiplyTransform(m);
                    Theme.DrawArrow(g, ar, Theme.FG, true);
                    g.Restore(st);
                }
                TextRenderer.DrawText(g, "Up", Theme.FONT_9, new Rectangle(upRect.X + Theme.S(20), upRect.Y, upRect.Width - Theme.S(22), upRect.Height), Theme.FG,
                    TextFormatFlags.NoPrefix | TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter);
                right = upRect.X - Theme.S(8);
            }
            const TextFormatFlags one = TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding;
            int h = Theme.FONT_9.Height;
            CutText.Draw(g, this, l1 ?? "", Theme.FONT_9, new Rectangle(r.X, r.Y + Theme.S(2), right - r.X, h), Theme.FG, one);
            CutText.Draw(g, this, l2 ?? "", Theme.FONT_9, new Rectangle(r.X, r.Y + Theme.S(2) + h, right - r.X, h), Theme.MUTED, one);
        }

        // ---- mouse

        int HitTile(Point p)
        {
            if (logoMode || Animating) return -1;
            if (tilesDirty && mapRect.Width > 0) LayoutTiles();
            for (int i = tiles.Count - 1; i >= 0; i--)   // children come after their parents: the deepest first
                if (tiles[i].R.Contains(p)) return i;
            return -1;
        }

        void TreemapMouseMove(Point p)
        {
            int t = HitTile(p);
            bool up = canGoUp && upRect.Contains(p);
            int slice = t >= 0 ? tiles[t].Slice : -1;
            int tileShown = t >= 0 && tiles[t].Level > 0 ? t : -1;
            Cursor = up || (t >= 0 && tiles[t].Dir != null) ? Cursors.Hand : Cursors.Default;
            if (slice != hover || tileShown != hoverTile || up != hoverUp) { hover = slice; hoverTile = tileShown; hoverUp = up; Invalidate(); }
            Report(slice, tileShown >= 0 ? tiles[tileShown].Dir : null);
        }

        void TreemapClick(Point p)
        {
            if (canGoUp && upRect.Contains(p)) { if (CenterClicked != null) CenterClicked(); return; }
            int t = HitTile(p);
            if (t < 0 || tiles[t].Dir == null || SliceClicked == null || tiles[t].Slice >= slices.Count) return;
            if (tiles[t].Level == 0) SliceClicked(slices[tiles[t].Slice]);
            else SliceClicked(new ChartSlice { Dir = tiles[t].Dir, Label = tiles[t].Dir.Name });
        }
    }
}

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.CompilerServices;
using System.Windows.Forms;

namespace SpacePie
{
    /// <summary>
    /// Text that does not fit is drawn with "..." and shown in full on hover. Controls draw such text through Draw (or
    /// Note), which records where it was cut; hovering that place raises Hover with the full text, which the main window
    /// shows in its dark tooltip next to the cursor. Call Begin at the start of each paint.
    /// </summary>
    internal static class CutText
    {
        sealed class State
        {
            public readonly List<KeyValuePair<Rectangle, string>> Cuts = new List<KeyValuePair<Rectangle, string>>();
            public string Shown;
        }

        static readonly ConditionalWeakTable<Control, State> states = new ConditionalWeakTable<Control, State>();

        /// <summary>The control and the full text under the cursor (null text = nothing cut there).</summary>
        public static event Action<Control, string> Hover;

        static State Get(Control c)
        {
            State s;
            if (states.TryGetValue(c, out s)) return s;
            s = states.GetValue(c, k => new State());
            c.MouseMove += (o, e) => Update(c, e.Location);
            c.MouseLeave += (o, e) => Raise(c, null);
            c.MouseDown += (o, e) => Raise(c, null);
            return s;
        }

        /// <summary>Forgets what was cut in the last paint of c.</summary>
        public static void Begin(Control c) { Get(c).Cuts.Clear(); }

        /// <summary>Draws one line of text (ellipsis when it does not fit) and remembers it when it was cut.</summary>
        public static void Draw(IDeviceContext g, Control c, string text, Font font, Rectangle r, Color color, TextFormatFlags flags)
        {
            flags |= TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix;
            TextRenderer.DrawText(g, text, font, r, color, flags);
            Note(g, c, text, font, r, flags);
        }

        /// <summary>Remembers text drawn in r when it is wider than r (the caller drew it with an ellipsis).</summary>
        public static void Note(IDeviceContext g, Control c, string text, Font font, Rectangle r, TextFormatFlags flags)
        {
            if (string.IsNullOrEmpty(text) || r.Width <= 0) return;
            var f = (flags & ~(TextFormatFlags.EndEllipsis | TextFormatFlags.PathEllipsis | TextFormatFlags.WordEllipsis)) | TextFormatFlags.SingleLine;
            if (TextRenderer.MeasureText(g, text, font, new Size(int.MaxValue, Math.Max(1, r.Height)), f).Width > r.Width)
                Add(c, r, text);
        }

        /// <summary>Remembers that the text in r was cut (for text measured by the caller, e.g. wrapped lines).</summary>
        public static void Add(Control c, Rectangle r, string text)
        {
            if (!string.IsNullOrEmpty(text)) Get(c).Cuts.Add(new KeyValuePair<Rectangle, string>(r, text));
        }

        /// <summary>The full text of the cut text at p, or null.</summary>
        public static string At(Control c, Point p)
        {
            State s;
            if (!states.TryGetValue(c, out s)) return null;
            for (int i = s.Cuts.Count - 1; i >= 0; i--)
                if (s.Cuts[i].Key.Contains(p)) return s.Cuts[i].Value;
            return null;
        }

        static void Update(Control c, Point p) { Raise(c, At(c, p)); }

        /// <summary>Shows (or with null hides) full text for c, for parts that track the mouse themselves (list headers).</summary>
        public static void Show(Control c, string text) { Get(c); Raise(c, text); }

        static void Raise(Control c, string text)
        {
            State s;
            if (!states.TryGetValue(c, out s) || s.Shown == text) return;
            s.Shown = text;
            var h = Hover;
            if (h != null) h(c, text);
        }
    }

    /// <summary>
    /// Label that draws its text on one line (or up to MaxLines wrapped lines) with an ellipsis when it does not fit, and
    /// shows the full text on hover (CutText). Replaces Label.AutoEllipsis, whose light system tooltip does not match.
    /// </summary>
    internal class EllipsisLabel : Label
    {
        /// <summary>Wrapped lines allowed before the ellipsis.</summary>
        public int MaxLines = 1;

        public EllipsisLabel()
        {
            UseMnemonic = false;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }

        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(BackColor);
            CutText.Begin(this);
            var r = new Rectangle(Padding.Left, Padding.Top, Math.Max(0, ClientSize.Width - Padding.Horizontal), Math.Max(0, ClientSize.Height - Padding.Vertical));
            var h = TextAlign == ContentAlignment.TopRight || TextAlign == ContentAlignment.MiddleRight || TextAlign == ContentAlignment.BottomRight
                ? TextFormatFlags.Right : TextAlign == ContentAlignment.TopCenter || TextAlign == ContentAlignment.MiddleCenter || TextAlign == ContentAlignment.BottomCenter
                ? TextFormatFlags.HorizontalCenter : TextFormatFlags.Left;
            var v = TextAlign == ContentAlignment.TopLeft || TextAlign == ContentAlignment.TopCenter || TextAlign == ContentAlignment.TopRight
                ? TextFormatFlags.Top : TextFormatFlags.VerticalCenter;
            Color fore = Enabled ? ForeColor : Theme.DISABLED_FG;
            if (MaxLines <= 1)
            {
                CutText.Draw(g, this, Text, Font, r, fore, h | v);
                return;
            }
            var flags = h | TextFormatFlags.Top | TextFormatFlags.NoPrefix | TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis | TextFormatFlags.TextBoxControl;
            int lineH = Font.Height, maxH = Math.Min(r.Height, lineH * MaxLines);
            int need = TextRenderer.MeasureText(g, Text, Font, new Size(Math.Max(1, r.Width), int.MaxValue), flags & ~TextFormatFlags.EndEllipsis).Height;
            int textH = Math.Min(need, maxH);
            var tr = new Rectangle(r.X, v == TextFormatFlags.VerticalCenter ? r.Y + (r.Height - textH) / 2 : r.Y, r.Width, maxH);
            TextRenderer.DrawText(g, Text, Font, tr, fore, flags);
            if (need > maxH) CutText.Add(this, ClientRectangle, Text);
        }
    }
}

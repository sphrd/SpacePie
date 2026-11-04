using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows.Forms;

namespace SpacePie
{
    /// <summary>
    /// Zoom of everything in the window (Ctrl+Plus / Ctrl+Minus / Ctrl+0), remembered in %LOCALAPPDATA%\SpacePie\zoom.
    /// Theme.SetZoom makes the fonts again and scales every S() size; controls placed once are scaled with Control.Scale,
    /// lists get new row heights and column widths, then everything is laid out and drawn again.
    /// </summary>
    internal sealed partial class MainForm
    {
        static string ZoomFile { get { return AppData.Path("zoom"); } }

        /// <summary>The zoom saved last time (100 % when there is none).</summary>
        public static float SavedZoom()
        {
            try
            {
                float z;
                if (File.Exists(ZoomFile) && float.TryParse(File.ReadAllText(ZoomFile).Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out z)
                    && Theme.ZoomSteps.Any(s => Math.Abs(s - z) < 0.001f)) return z;
            }
            catch (Exception) { }
            return 1f;
        }

        /// <summary>One step larger (dir > 0) or smaller.</summary>
        void ZoomStep(int dir)
        {
            float z = Theme.Zoom;
            float next = dir > 0 ? Theme.ZoomSteps.Where(s => s > z + 0.001f).DefaultIfEmpty(z).Min()
                                 : Theme.ZoomSteps.Where(s => s < z - 0.001f).DefaultIfEmpty(z).Max();
            SetZoom(next);
        }

        public void SetZoom(float z)
        {
            z = Math.Max(Theme.ZoomSteps[0], Math.Min(Theme.ZoomSteps[Theme.ZoomSteps.Length - 1], z));
            float old = Theme.Zoom;
            if (Math.Abs(z - old) < 0.001f) return;
            float r = z / old;
            Theme.SetZoom(z);
            SuspendLayout();
            foreach (Control c in Controls) c.Scale(new SizeF(r, r));
            ApplyThemeFonts(this);
            var mf = Theme.Current(menu.Font);
            if (mf != null) menu.Font = mf;
            foreach (var lv in AllOf<SizeListView>(this))
            {
                lv.SmallImageList = new ImageList { ImageSize = new Size(1, Theme.S(26)) };
                foreach (ColumnHeader col in lv.Columns) col.Width = Math.Max(1, (int)Math.Round(col.Width * r));
            }
            ResumeLayout(true);
            LayoutToolbar();
            PerformLayout();
            Invalidate(true);
            if (SelfTestDir == null && ShotDir == null)
            {
                try { Directory.CreateDirectory(AppData.Dir); File.WriteAllText(ZoomFile, z.ToString(CultureInfo.InvariantCulture)); }
                catch (Exception) { }
            }
            statusLabel.Text = string.Format("Zoom {0:0} %  (Ctrl+Plus larger, Ctrl+Minus smaller, Ctrl+0 actual size)", z * 100);
        }

        /// <summary>Every control holding a theme font of an earlier zoom gets the same role's font now.</summary>
        static void ApplyThemeFonts(Control c)
        {
            var f = Theme.Current(c.Font);
            if (f != null && !ReferenceEquals(f, c.Font)) c.Font = f;
            foreach (Control k in c.Controls) ApplyThemeFonts(k);
        }

        static IEnumerable<T> AllOf<T>(Control c) where T : Control
        {
            foreach (Control k in c.Controls)
            {
                var t = k as T;
                if (t != null) yield return t;
                foreach (var x in AllOf<T>(k)) yield return x;
            }
        }
    }
}

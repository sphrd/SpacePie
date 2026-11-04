using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace SpacePie
{
    /// <summary>Windows' own Properties dialog, and pictures of files from the shell (thumbnails or icons).</summary>
    internal static class Shell
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        static extern bool SHObjectProperties(IntPtr hwnd, uint type, string name, string page);

        /// <summary>Opens the Properties dialog Explorer shows for the file or folder (Alt+Enter).</summary>
        public static bool ShowProperties(IntPtr owner, string path)
        {
            try { return SHObjectProperties(owner, 2 /* SHOP_FILEPATH */, path, null); } catch (Exception) { return false; }
        }

        [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IShellItemImageFactory
        {
            [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr hbitmap);
        }

        [StructLayout(LayoutKind.Sequential)]
        struct SIZE { public int cx, cy; }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        static extern void SHCreateItemFromParsingName(string path, IntPtr bindCtx, [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
            [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory item);

        [StructLayout(LayoutKind.Sequential)]
        struct BITMAP { public int bmType, bmWidth, bmHeight, bmWidthBytes; public ushort bmPlanes, bmBitsPixel; public IntPtr bmBits; }

        [StructLayout(LayoutKind.Sequential)]
        struct BITMAPINFOHEADER
        {
            public int biSize, biWidth, biHeight;
            public short biPlanes, biBitCount;
            public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
        }

        [DllImport("gdi32.dll")] static extern int GetObject(IntPtr h, int size, out BITMAP bm);
        [DllImport("gdi32.dll")] static extern int GetDIBits(IntPtr hdc, IntPtr hbm, uint start, uint lines, byte[] bits, ref BITMAPINFOHEADER bmi, uint usage);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);

        /// <summary>
        /// The shell's picture of a file: its thumbnail (photo, video frame, document page) or, with iconOnly, its icon. Never
        /// asks for a thumbnail of an online-only cloud file (that would download it). Null when there is none.
        /// </summary>
        public static Bitmap Picture(string path, int size, bool iconOnly)
        {
            IntPtr hbm = IntPtr.Zero;
            try
            {
                IShellItemImageFactory f;
                SHCreateItemFromParsingName(path, IntPtr.Zero, typeof(IShellItemImageFactory).GUID, out f);
                int hr;
                // SIIGBF_BIGGERSIZEOK (1); SIIGBF_ICONONLY (4)
                try { hr = f.GetImage(new SIZE { cx = size, cy = size }, 1 | (iconOnly ? 4 : 0), out hbm); }
                finally { Marshal.ReleaseComObject(f); }
                if (hr != 0 || hbm == IntPtr.Zero) return null;
                BITMAP bm;
                if (GetObject(hbm, Marshal.SizeOf(typeof(BITMAP)), out bm) == 0 || bm.bmWidth <= 0) return null;
                int w = bm.bmWidth, h = Math.Abs(bm.bmHeight);
                // Read it top-down as 32-bit premultiplied ARGB, so transparency and orientation are right.
                var bmi = new BITMAPINFOHEADER { biSize = Marshal.SizeOf(typeof(BITMAPINFOHEADER)), biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32 };
                var bits = new byte[w * h * 4];
                IntPtr dc = GetDC(IntPtr.Zero);
                try { if (GetDIBits(dc, hbm, 0, (uint)h, bits, ref bmi, 0) == 0) return null; }
                finally { ReleaseDC(IntPtr.Zero, dc); }
                bool anyAlpha = false;
                for (int i = 3; i < bits.Length; i += 4) if (bits[i] != 0) { anyAlpha = true; break; }
                if (!anyAlpha) for (int i = 3; i < bits.Length; i += 4) bits[i] = 255;   // a plain RGB picture
                var bmp = new Bitmap(w, h, PixelFormat.Format32bppPArgb);
                var data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppPArgb);
                try { for (int y = 0; y < h; y++) Marshal.Copy(bits, y * w * 4, data.Scan0 + y * data.Stride, w * 4); }
                finally { bmp.UnlockBits(data); }
                return bmp;
            }
            catch (Exception) { return null; }
            finally { if (hbm != IntPtr.Zero) DeleteObject(hbm); }
        }
    }

    /// <summary>
    /// Quick look at a file or folder without leaving the app (Space): its thumbnail or icon, what it is, sizes and dates,
    /// and for text files the first lines. Online-only cloud files are never downloaded for it.
    /// </summary>
    internal sealed class PreviewForm : AppDialog
    {
        static readonly HashSet<string> TextExt = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "txt", "log", "md", "csv", "tsv", "json", "xml", "yml", "yaml", "ini", "cfg", "conf", "toml", "reg", "bat", "cmd", "ps1", "psm1", "sh",
            "c", "h", "cpp", "hpp", "cs", "java", "py", "js", "ts", "tsx", "jsx", "go", "rs", "rb", "php", "swift", "kt", "html", "htm", "css", "scss", "sql", "gitignore"
        };

        Bitmap picture;
        readonly string path;
        Rectangle picBox;

        public PreviewForm(ItemInfo it, KnownItem known) : base("Preview")
        {
            path = it.FullPath;
            bool isDir = it.IsDir;
            bool online = it.File != null && it.File.OnlineOnly;
            ClientSize = new Size(Theme.S(760), Theme.S(isDir ? 360 : 420));
            picBox = new Rectangle(Theme.S(24), Theme.S(24), Theme.S(256), Theme.S(256));
            picture = Shell.Picture(path, Theme.S(256), isDir || online);
            int x = picBox.Right + Theme.S(24), w = ClientSize.Width - x - Theme.S(24), y = Theme.S(24);
            Func<string, Font, Color, int, Label> add = (text, font, color, gap) =>
            {
                var l = new Label { Text = text, Font = font, ForeColor = color, BackColor = Theme.BG, AutoSize = false, UseMnemonic = false };
                int h = TextRenderer.MeasureText(text, font, new Size(w, 0), TextFormatFlags.WordBreak).Height;
                l.Bounds = new Rectangle(x, y, w, h);
                Controls.Add(l);
                y += h + gap;
                return l;
            };
            add(isDir ? it.Dir.Name : it.File != null ? it.File.Name : it.Name, new Font("Segoe UI", 13f, FontStyle.Bold), Theme.FG, Theme.S(4));
            add(Fmt.Shorten(path, 90), Theme.FONT_9, Theme.MUTED, Theme.S(12));
            var facts = new List<string>();
            if (isDir)
            {
                facts.Add(string.Format("Size: {0}   (on disk: {1})", Fmt.Size(it.Dir.Bytes), Fmt.Size(it.Dir.Alloc)));
                facts.Add(string.Format("Contains: {0:N0} files in {1:N0} folders", it.Dir.Files, it.Dir.Dirs));
                if (it.Dir.Modified > 0) facts.Add("Modified: " + Fmt.Date(it.Dir.Modified));
            }
            else if (it.File != null)
            {
                var f = it.File;
                facts.Add(string.Format("Size: {0}   (on disk: {1}{2})", Fmt.Size(f.Bytes), Fmt.Size(f.Alloc), online ? ", online-only" : ""));
                string ext = FileIndex.Extension(f.Name);
                facts.Add("Type: " + (ext.Length > 0 ? "." + ext + "  -  " : "") + FileTypes.CategoryOf(ext));
                if (f.Modified > 0) facts.Add("Modified: " + Fmt.Date(f.Modified));
                if (f.LastUse > 0) facts.Add("Last opened: " + Fmt.Date(f.LastUse));
            }
            add(string.Join("\n", facts), Theme.FONT, Theme.FG, Theme.S(10));
            if (known != null) add(known.Long, Theme.FONT_9, Theme.WARN_FG, Theme.S(10));
            int bottom = Math.Max(picBox.Bottom, y) + Theme.S(12);
            // Text files: the first lines (at most 64 KB read; never for online-only files).
            if (!isDir && it.File != null && !online && TextExt.Contains(FileIndex.Extension(it.File.Name)) && it.File.Bytes > 0)
            {
                var lines = ReadHead(path);
                if (lines.Count > 0)
                {
                    var box = new DetailsBox(lines);
                    int h = Math.Min(box.PreferredHeight(14), Theme.S(260));
                    box.Bounds = new Rectangle(Theme.S(24), bottom, ClientSize.Width - Theme.S(48), h);
                    Controls.Add(box);
                    bottom += h + Theme.S(8);
                }
            }
            ClientSize = new Size(ClientSize.Width, bottom + Theme.S(60));
            SetButtons(Button("Open", () => { try { Process.Start(path); } catch (Exception) { } Close(); }),
                Button("Show in Explorer", () => { try { Process.Start("explorer.exe", "/select,\"" + path + "\""); } catch (Exception) { } Close(); }),
                Button("Close", Close));
            KeyDown += (s, e) => { if (e.KeyCode == Keys.Space) Close(); };
        }

        static List<string> ReadHead(string path)
        {
            var lines = new List<string>();
            try
            {
                using (var fs = new FileStream(Native.LongPath(path), FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    var buf = new byte[Math.Min(65536, fs.Length)];
                    int n = fs.Read(buf, 0, buf.Length);
                    if (buf.Take(n).Any(b => b == 0) && !(n > 1 && (buf[0] == 0xFF || buf[0] == 0xFE))) return lines;   // binary, not text
                    string text;
                    using (var r = new StreamReader(new MemoryStream(buf, 0, n), Encoding.UTF8, true)) text = r.ReadToEnd();
                    foreach (var l in text.Replace("\r\n", "\n").Split('\n').Take(400)) lines.Add(l.Replace("\t", "    "));
                }
            }
            catch (Exception) { }
            return lines;
        }

        protected override void DrawIcon(Graphics g, Rectangle r)
        {
            Theme.FillRound(g, picBox, Theme.S(12), Theme.SURFACE, Theme.BORDER);
            if (picture == null) { Theme.DrawLogo(g, Rectangle.Inflate(picBox, -Theme.S(64), -Theme.S(64)), 1f); return; }
            float k = Math.Min((picBox.Width - Theme.S(16)) / (float)picture.Width, (picBox.Height - Theme.S(16)) / (float)picture.Height);
            k = Math.Min(k, picture.Width < 96 ? 2f : 1f);
            int w = (int)(picture.Width * k), h = (int)(picture.Height * k);
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            g.DrawImage(picture, picBox.X + (picBox.Width - w) / 2, picBox.Y + (picBox.Height - h) / 2, w, h);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && picture != null) { picture.Dispose(); picture = null; }
            base.Dispose(disposing);
        }
    }

    internal sealed partial class MainForm
    {
        /// <summary>Properties dialog of the selected item (Alt+Enter), as in Explorer.</summary>
        void ShowProperties()
        {
            var sel = GetSelection();
            string p = sel.Count > 0 ? sel[0].FullPath : current != null ? current.FullPath : null;
            if (p == null || (sel.Count > 0 && FromReadOnly(sel[0]) && !Native.Exists(p))) return;
            if (!Shell.ShowProperties(Handle, p)) statusLabel.Text = "Windows has no properties for " + p + ".";
        }

        /// <summary>Quick preview of the selected file or folder (Space).</summary>
        void PreviewSelected()
        {
            var sel = GetSelection();
            if (sel.Count != 1 || busy) return;
            var it = sel[0];
            if (!it.IsDir && it.File == null) return;
            if (!Native.Exists(it.FullPath)) { statusLabel.Text = it.FullPath + " is not on this computer (any more)."; return; }
            using (var f = new PreviewForm(it, KnownFor(it))) f.ShowDialog(this);
        }

        /// <summary>Space previews in lists without checkboxes (in Suggestions and Apps it ticks and unticks).</summary>
        bool SpacePreviews()
        {
            return lastView == contents || (pFiles != null && lastView == pFiles.List) ||
                   (pDupes != null && lastView == pDupes.List) || (pBasket != null && lastView == pBasket.List) || (pChanges != null && lastView == pChanges.List);
        }
    }
}

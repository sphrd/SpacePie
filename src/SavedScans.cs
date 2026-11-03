using System;
using System.IO;
using System.Linq;
using System.Windows.Forms;

namespace SpacePie
{
    /// <summary>
    /// Scan files: a whole scan (every folder and file with sizes and dates, compressed) saved as a .spacepie file, to keep
    /// it, compare later or send it to someone. Opened again it shows as a read-only entry in the tree, below the drives:
    /// every view works on it, but nothing is rescanned, watched or deleted.
    /// </summary>
    internal sealed partial class MainForm
    {
        RoundButton btnOpenScan;

        /// <summary>Saves the scan that holds scope (the whole drive or folder, not just the part shown).</summary>
        void SaveScanFile(DirNode scope, string file)
        {
            var top = scope.Top;
            var r = RootOf(top);
            string path = r != null ? r.Path : top.FullPath;
            DateTime when = r != null && r.Scanned != DateTime.MinValue ? r.Scanned : DateTime.Now;
            Snapshot.SaveTo(file, path, top, when, r != null ? r.Total : 0, r != null ? r.Free : 0);
        }

        void OpenScanDialog()
        {
            if (busy) return;
            using (var dlg = new OpenFileDialog
            {
                Title = "Open a saved scan",
                Filter = "SpacePie scan (*" + Snapshot.ScanFileExtension + ")|*" + Snapshot.ScanFileExtension,
                CheckFileExists = true
            })
            {
                if (dlg.ShowDialog(this) != DialogResult.OK) return;
                OpenScanFile(dlg.FileName);
            }
        }

        static bool IsScanFile(string path)
        {
            return path != null && path.EndsWith(Snapshot.ScanFileExtension, StringComparison.OrdinalIgnoreCase) && File.Exists(path);
        }

        async void OpenScanFile(string file)
        {
            if (busy) return;
            var open = roots.FirstOrDefault(x => x.ReadOnly && string.Equals(x.SourceFile, file, StringComparison.OrdinalIgnoreCase));
            if (open != null) { SelectRoot(open); return; }
            statusLabel.Text = "Opening " + file + "...";
            Snapshot.Info info = null;
            var sw = System.Diagnostics.Stopwatch.StartNew();
            try { await RunThread(() => info = Snapshot.LoadFrom(file)); } catch (Exception) { }
            if (info == null || info.Node == null)
            {
                statusLabel.Text = "";
                Alert(AlertIcon.Warn, "This is not a scan file", file + " could not be read as a SpacePie scan (or it is damaged).", null, null, "OK");
                return;
            }
            var r = new ScanRoot
            {
                Path = info.Root, ReadOnly = true, SourceFile = file, Scanned = info.Saved, Total = info.Total, Free = info.Free,
                IsDrive = false, Node = info.Node, Complete = false
            };
            roots.Add(r);
            SortRoots();
            RefreshTree(r.Node);
            ViewsChanged();
            statusLabel.Text = string.Format("Opened the scan of {0} from {1:g}: {2} in {3:N0} files and {4:N0} folders ({5:0.0} s). It can be browsed, searched and exported; nothing in it is changed.",
                info.Root, info.Saved, Fmt.Size(r.Node.Size), r.Node.Files, r.Node.Dirs, sw.Elapsed.TotalSeconds);
        }

        /// <summary>Removes a saved scan from the tree (the file stays where it is).</summary>
        void CloseSavedScan(ScanRoot r)
        {
            if (r == null || !r.ReadOnly || busy) return;
            roots.Remove(r);
            if (active == r) { active = null; current = null; }
            navBack.RemoveAll(e => e.Key != null && e.Key.Top == r.Node);
            navForward.RemoveAll(e => e.Key != null && e.Key.Top == r.Node);
            RefreshTree(null);
            ViewsChanged();
            statusLabel.Text = "Closed the saved scan of " + r.Path + ".";
        }
    }
}

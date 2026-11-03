using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace SpacePie
{
    /// <summary>Fast restart with saved scans and the NTFS change journal (see Snapshot).</summary>
    internal sealed partial class MainForm
    {
        /// <summary>The fast start's note for the status line after a normal scan that had to follow it.</summary>
        string fastStartNote;

        /// <summary>
        /// Shows the drive's saved scan at once. True when it could be brought up to date from the change journal (no scan
        /// needed); false when a normal scan has to follow (the saved scan stays visible while it runs).
        /// </summary>
        async Task<bool> FastStart(ScanRoot r)
        {
            var sw = Stopwatch.StartNew();
            Snapshot.Info info = null;
            SetScanning(true, "Opening the last scan of " + r.Path + "...");
            try { await RunThread(() => info = Snapshot.Load(r.Path)); } catch (Exception) { }
            if (info == null) { SetScanning(false, null); return false; }
            double loaded = sw.Elapsed.TotalSeconds;
            r.Node = info.Node;
            r.Scanned = info.Saved;
            r.Complete = true;
            RefreshCapacity(r);
            StartWatching(r);   // changes from now on come live; the journal covers the time in between
            current = null;
            SelectRoot(r);
            ViewsChanged();
            UpdateDriveLabel();
            statusLabel.Text = string.Format("Showing the scan of {0:g} for {1}; checking what changed since...", info.Saved, r.Path);

            ulong id; long next;
            List<Snapshot.Change> changes = null;
            string why = null;
            if (Snapshot.QueryJournal(r.Path, out id, out next))
                await RunThread(() => changes = Snapshot.ReadSince(r.Path, info.JournalId, info.Usn, 200000, out why));
            else why = "the change journal needs administrator rights";
            SetScanning(false, null);
            if (changes == null)
            {
                fastStartNote = string.Format("The scan of {0:g} was shown at once ({1:0.0} s) while scanning again: {2}.", info.Saved, loaded, why);
                return false;
            }
            foreach (var c in changes)
                fsChanges.Enqueue(new FsChange { Kind = c.Deleted ? WatcherChangeTypes.Deleted : c.Created ? WatcherChangeTypes.Created : WatcherChangeTypes.Changed, Path = c.Path });
            for (int i = 0; i < 100 && !fsChanges.IsEmpty; i++) ApplyChanges();
            RefreshAfterLive();
            r.JournalId = id;
            r.JournalUsn = next;
            r.Scanned = DateTime.Now;
            RememberScan(r, r.Node, true);
            RefreshTree(current ?? r.Node);
            ViewsChanged();
            UpdateDriveLabel();
            statusLabel.Text = string.Format("{0}: {1} in {2:N0} files and {3:N0} folders - ready in {4:0.0} s: the scan of {5:g}, updated with {6:N0} changes from the change journal.",
                r.Node.Name, Fmt.Size(r.Node.Size), r.Node.Files, r.Node.Dirs, sw.Elapsed.TotalSeconds, info.Saved, changes.Count);
            if ((apps == null || appsFromCache) && !appsLoading) FillApps();
            return true;
        }

        /// <summary>When the app closes: saves each whole drive scan with its change-journal position, for a fast restart.</summary>
        void SaveSnapshots()
        {
            if (SelfTestDir != null || ShotDir != null) return;
            foreach (var r in roots.ToList())
            {
                if (r.Node == null || !r.IsDrive || !r.Complete) continue;
                try { Snapshot.Save(r.Path, r.Node, r.JournalId, r.JournalUsn); } catch (Exception) { }
            }
        }
    }
}

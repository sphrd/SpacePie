using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SpacePie
{
    /// <summary>
    /// Live updates: every scanned drive or folder is watched for changes, and the scan is updated in place every two
    /// seconds (a changed folder's own files are read again; new folders are scanned; removed ones dropped). Nothing is
    /// rescanned as a whole. When Windows reports that changes were missed, the status line suggests a rescan.
    /// </summary>
    internal sealed partial class MainForm
    {
        struct FsChange { public WatcherChangeTypes Kind; public string Path, OldPath; }

        readonly Dictionary<ScanRoot, FileSystemWatcher> watchers = new Dictionary<ScanRoot, FileSystemWatcher>();
        readonly ConcurrentQueue<FsChange> fsChanges = new ConcurrentQueue<FsChange>();
        readonly HashSet<ScanRoot> missedChanges = new HashSet<ScanRoot>();
        System.Windows.Forms.Timer liveTimer;
        // Paths the app is deleting itself: their change events are its own echo (the scan is updated directly).
        volatile string[] ownPaths = new string[0];
        DateTime ownUntil = DateTime.MinValue;
        DateTime lastLiveRefresh = DateTime.MinValue;
        bool livePending;
        Label liveLabel;

        void StartWatching(ScanRoot r)
        {
            StopWatching(r);
            missedChanges.Remove(r);
            if (liveTimer == null)
            {
                liveTimer = new System.Windows.Forms.Timer { Interval = 2000 };
                liveTimer.Tick += (s, e) => ApplyChanges();   // never throws (ApplyChangesCore catches)
                liveTimer.Start();
            }
            try
            {
                var w = new FileSystemWatcher(r.Path)
                {
                    IncludeSubdirectories = true, InternalBufferSize = 64 * 1024,
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.Size | NotifyFilters.LastWrite
                };
                FileSystemEventHandler onChange = (s, e) => Enqueue(e.ChangeType, e.FullPath, null);
                w.Created += onChange;
                w.Deleted += onChange;
                w.Changed += onChange;
                w.Renamed += (s, e) => Enqueue(WatcherChangeTypes.Renamed, e.FullPath, e.OldFullPath);
                w.Error += (s, e) => BeginInvoke(new Action(() => { if (!busy && DateTime.UtcNow > ownUntil) { missedChanges.Add(r); UpdateLiveLabel(); } }));
                w.EnableRaisingEvents = true;
                watchers[r] = w;
            }
            catch (Exception) { }
            UpdateLiveLabel();
        }

        void StopWatching(ScanRoot r)
        {
            FileSystemWatcher w;
            if (!watchers.TryGetValue(r, out w)) return;
            watchers.Remove(r);
            try { w.EnableRaisingEvents = false; w.Dispose(); } catch (Exception) { }
        }

        void Enqueue(WatcherChangeTypes kind, string path, string old)
        {
            // Only the echo of our own deletes is skipped; changes anywhere else are never lost, even during a delete.
            if (IsOwnChange(path)) return;
            if (fsChanges.Count > 200000) return;
            fsChanges.Enqueue(new FsChange { Kind = kind, Path = path, OldPath = old });
        }

        bool IsOwnChange(string path)
        {
            if (DateTime.UtcNow > ownUntil) return false;
            foreach (var o in ownPaths)
                if (path.Equals(o, StringComparison.OrdinalIgnoreCase) || path.StartsWith(o + "\\", StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        /// <summary>A delete of these paths starts: their events are ignored until a few seconds after it ends.</summary>
        void BeginOwnChanges(IEnumerable<string> paths)
        {
            ownPaths = paths.Where(p => !string.IsNullOrEmpty(p)).Select(p => p.TrimEnd('\\')).ToArray();
            ownUntil = DateTime.MaxValue;
        }

        void EndOwnChanges()
        {
            ownUntil = DateTime.UtcNow.AddSeconds(3);
            // Drop queued echoes of our own delete; keep everything else.
            var keep = new List<FsChange>();
            FsChange c;
            while (fsChanges.TryDequeue(out c)) if (!IsOwnChange(c.Path)) keep.Add(c);
            foreach (var k in keep) fsChanges.Enqueue(k);
        }

        void UpdateLiveLabel()
        {
            if (liveLabel == null) return;
            foreach (var r in watchers.Keys.ToList()) if (!roots.Contains(r) || r.Node == null) StopWatching(r);
            if (missedChanges.Count > 0)
            {
                liveLabel.Text = "Changes missed - rescan";
                liveLabel.ForeColor = Theme.WARN_FG;
                tips.SetToolTip(liveLabel, "Too many changes happened at once on " + string.Join(", ", missedChanges.Select(r => r.Path)) +
                    "; the scan may be out of date. Rescan (F5) to be sure.");
            }
            else
            {
                liveLabel.Text = watchers.Count > 0 ? "Live" : "";
                liveLabel.ForeColor = Theme.MUTED;
                tips.SetToolTip(liveLabel, "The scanned drives and folders are watched; files that appear, change or go away update the results within seconds.");
            }
        }

        Task liveTask;

        /// <summary>
        /// Applies a batch of changes (at most 20,000). Everything that touches the disk runs in the background (which
        /// paths are folders; a changed folder's files read again; new folders scanned), the trees are only read and
        /// changed here on the window's thread, so the window never stops responding, however many changes arrive (e.g.
        /// the change journal after an instant restart). While a batch runs, callers get the same task.
        /// </summary>
        Task ApplyChanges()
        {
            if (liveTask != null && !liveTask.IsCompleted) return liveTask;
            liveTask = ApplyChangesCore();
            return liveTask;
        }

        async Task ApplyChangesCore()
        {
            try
            {
                RefreshSuggestionsIfDue();
                if (busy || scanning || fsChanges.IsEmpty) { if (livePending && !busy && !scanning) RefreshAfterLive(); return; }
                var batch = new List<FsChange>();
                FsChange c;
                while (batch.Count < 20000 && fsChanges.TryDequeue(out c)) batch.Add(c);
                // 1. Disk, in the background: which changed paths are folders.
                var isDir = await Task.Run(() => batch.Select(bc => bc.Kind != WatcherChangeTypes.Deleted && Native.IsDirectory(bc.Path)).ToArray());
                if (IsDisposed) return;
                if (busy || scanning) { foreach (var again in batch) fsChanges.Enqueue(again); return; }
                // 2. In memory, here: what each change means for the trees (removed folders go at once).
                var files = new HashSet<DirNode>();
                var added = new List<string>();
                bool structure = false;
                for (int i = 0; i < batch.Count; i++)
                {
                    c = batch[i];
                    var parent = FindScanned(Native.ParentDir(c.Path), true);
                    if (c.Kind == WatcherChangeTypes.Renamed && c.OldPath != null)
                    {
                        var oldNode = FindScanned(c.OldPath, true);
                        if (oldNode != null && oldNode.Parent != null)
                        {
                            if (parent == oldNode.Parent) { oldNode.Name = Native.FileName(c.Path); oldNode.Parent.Children.Sort(DirNode.BySizeDesc); structure = true; }
                            else { RemoveNode(oldNode); added.Add(c.Path); structure = true; }
                            continue;
                        }
                        var oldParent = FindScanned(Native.ParentDir(c.OldPath), true);
                        if (oldParent != null) files.Add(oldParent);
                    }
                    if (parent == null) continue;
                    var node = parent.Child(Native.FileName(c.Path));
                    if (c.Kind == WatcherChangeTypes.Deleted)
                    {
                        if (node != null) { RemoveNode(node); structure = true; }
                        else files.Add(parent);
                    }
                    else if (isDir[i])
                    {
                        if (node == null && c.Kind != WatcherChangeTypes.Changed) { added.Add(c.Path); structure = true; }
                    }
                    else files.Add(parent);
                }
                // 3. Disk, in the background: the changed folders' files, the new folders' contents (by path only).
                var dirs = files.Where(IsAttached).ToList();
                var dirPaths = dirs.Select(d => d.FullPath).ToList();
                var newPaths = added.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
                FileRec[][] read = null;
                DirNode[] scannedNew = null;
                await Task.Run(() =>
                {
                    read = dirPaths.Select(dp => Scanner.ReadFiles(dp)).ToArray();
                    scannedNew = newPaths.Select(np => Native.IsDirectory(np) ? new Scanner().Run(np) : null).ToArray();
                });
                if (IsDisposed) return;
                if (busy || scanning) { foreach (var again in batch) fsChanges.Enqueue(again); return; }
                // 4. Here again: apply what is still attached.
                for (int i = 0; i < dirs.Count; i++) if (read[i] != null && IsAttached(dirs[i])) dirs[i].SetFiles(read[i]);
                for (int i = 0; i < newPaths.Count; i++)
                {
                    var fresh = scannedNew[i];
                    if (fresh == null) continue;
                    var into = FindScanned(Native.ParentDir(newPaths[i]), true);
                    if (into == null || into.Child(Native.FileName(newPaths[i])) != null) continue;
                    fresh.Name = Native.FileName(newPaths[i]);
                    fresh.Parent = into;
                    fresh.Modified = DateTime.Now.ToFileTime();
                    if (into.Children == null) into.Children = new List<DirNode>();
                    into.Children.Add(fresh);
                    into.AddUp(fresh.Bytes, fresh.Alloc, fresh.Files, fresh.Dirs + 1);
                }
                if (dirs.Count > 0 || newPaths.Count > 0 || structure)
                {
                    livePending = true;
                    suggestionsDirty = true;
                    foreach (var pg in pages) if (pg != pContents && (structure || pg == pSuggest || pg == pFiles || pg == pTypes)) pg.Stale = true;
                    RefreshSuggestionsIfDue();
                }
                if (livePending && (DateTime.UtcNow - lastLiveRefresh).TotalSeconds >= 4) RefreshAfterLive();
            }
            catch (Exception) { livePending = false; }   // a live update must never take the app down
        }

        /// <summary>Shows live changes without disturbing the user: values update in place, the selection and scroll position stay.</summary>
        void RefreshAfterLive()
        {
            livePending = false;
            lastLiveRefresh = DateTime.UtcNow;
            contents.Invalidate();
            UpdateDriveLabel();
            if (current == null || !IsAttached(current)) return;
            if (ActivePage != pContents) return;
            if (contents.SelectedItems.Count > 0 || contents.Focused && MouseButtons != MouseButtons.None) return;
            var top = contents.TopItem != null ? ((ItemInfo)contents.TopItem.Tag).Name : null;
            ShowContents(current);
            if (top != null)
                foreach (ListViewItem it in contents.Items)
                    if (((ItemInfo)it.Tag).Name == top) { try { contents.TopItem = it; } catch (Exception) { } break; }
        }
    }
}

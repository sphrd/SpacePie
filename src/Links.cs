using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32.SafeHandles;

namespace SpacePie
{
    /// <summary>
    /// Duplicates: replace extra copies with hard links to the copy that is kept. Every path stays and opens the same
    /// content, but the data is stored once. Only on the same NTFS volume; a copy that changed since the search is left
    /// alone. Hard links share one content: editing one edits them all, so the confirmation says so.
    /// </summary>
    internal sealed partial class MainForm
    {
        RoundButton btnLinkDupes;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateHardLinkW(string newLink, string existing, IntPtr security);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool MoveFileExW(string from, string to, int flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetVolumePathNameW(string path, System.Text.StringBuilder volume, int length);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetVolumeInformationW(string root, System.Text.StringBuilder name, int nameLen, out uint serial, out uint maxComp,
            out uint flags, System.Text.StringBuilder fs, int fsLen);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sec, uint disposition, uint flags, IntPtr template);

        [StructLayout(LayoutKind.Sequential, Pack = 4)]   // FILETIMEs are two DWORDs: no 8-byte alignment
        struct FileInfoByHandle
        {
            public uint Attributes;
            public long Created, Accessed, Written;
            public uint VolumeSerial, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandle(SafeFileHandle h, out FileInfoByHandle info);

        /// <summary>Volume serial and file index (equal for hard links of one file), and the number of links; null if unreadable.</summary>
        internal static Tuple<ulong, uint> FileIdentity(string path)
        {
            using (var h = CreateFileW(Native.LongPath(path), 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero))   // no access needed; backup semantics
            {
                FileInfoByHandle i;
                if (h.IsInvalid || !GetFileInformationByHandle(h, out i)) return null;
                return Tuple.Create(((ulong)i.VolumeSerial << 48) ^ ((ulong)i.IndexHigh << 32) ^ i.IndexLow, i.Links);
            }
        }

        /// <summary>.NET Framework 4 file APIs reject \\?\ paths; plain paths work up to ~260 characters.</summary>
        static string NetPath(string p) { return p.Length < 240 ? p : Native.LongPath(p); }

        static string VolumeOf(string path)
        {
            var sb = new System.Text.StringBuilder(1024);
            return GetVolumePathNameW(path, sb, sb.Capacity) ? sb.ToString() : null;
        }

        static string FileSystemOf(string volume)
        {
            var name = new System.Text.StringBuilder(261);
            var fs = new System.Text.StringBuilder(261);
            uint serial, maxComp, flags;
            return GetVolumeInformationW(volume, name, name.Capacity, out serial, out maxComp, out flags, fs, fs.Capacity) ? fs.ToString() : "";
        }

        /// <summary>The selected copies with the copy each will link to (the first unselected one of its group, else the newest).</summary>
        List<KeyValuePair<FileEntry, FileEntry>> SelectedLinkPairs()
        {
            var pairs = new List<KeyValuePair<FileEntry, FileEntry>>();
            if (dupeGroups == null) return pairs;
            var sel = new HashSet<FileEntry>(pDupes.List.SelectedItems.Cast<ListViewItem>().Select(i => ((ItemInfo)i.Tag).File).Where(f => f != null));
            foreach (var g in dupeGroups)
            {
                var picked = g.Where(sel.Contains).ToList();
                if (picked.Count == 0) continue;
                var keep = g.FirstOrDefault(f => !sel.Contains(f)) ?? g[0];
                foreach (var f in picked) if (f != keep) pairs.Add(new KeyValuePair<FileEntry, FileEntry>(f, keep));
            }
            return pairs;
        }

        void UpdateLinkButton()
        {
            if (btnLinkDupes == null) return;
            btnLinkDupes.Enabled = !busy && !scanning && dupeFinder == null && SelectedLinkPairs().Count > 0;
        }

        async void ReplaceSelectedWithLinks() { await ReplaceWithLinks(SelectedLinkPairs(), SelfTestDir == null); }

        /// <summary>Replaces each copy with a hard link to its kept copy. Returns how many were replaced.</summary>
        internal async Task<int> ReplaceWithLinks(List<KeyValuePair<FileEntry, FileEntry>> pairs, bool confirm)
        {
            if (busy || scanning || pairs.Count == 0) return 0;
            long saved = pairs.Sum(p => p.Key.Alloc);
            if (confirm && Alert(AlertIcon.Warn, string.Format("Replace {0:N0} cop{1} with links?", pairs.Count, pairs.Count == 1 ? "y" : "ies"),
                    Fmt.Size(saved) + " is freed. Every file stays where it is and opens the same content, but the data is stored only once.",
                    "Linked files share one content: changing one of them changes all of them. Use this for files you only keep, not edit.",
                    pairs.Select(p => p.Key.FullPath + "\tlinks to " + p.Value.FullPath).ToList(),
                    "Replace with links", "Cancel") != "Replace with links") return 0;

            var errors = new List<string>();
            int done = 0;
            BeginOwnChanges(pairs.Select(p => p.Key.FullPath));
            busy = true;
            UpdateButtons();
            scanBar.Start("Replacing copies with links...");
            scanBar.CancelButton.Enabled = false;
            try
            {
                var work = pairs.Select(p => new { Copy = p.Key.FullPath, Keep = p.Value.FullPath, Bytes = p.Key.Bytes, Mod = p.Key.Modified }).ToList();
                await RunThread(() =>
                {
                    foreach (var w in work)
                    {
                        string why = LinkOne(w.Copy, w.Keep, w.Bytes, w.Mod);
                        if (why == null) done++; else lock (errors) errors.Add(w.Copy + "  -  " + why);
                    }
                });
                scanBar.SetProgress("Updating the scan...", "", -1);
                var dirs = pairs.Select(p => p.Key.Dir.FullPath).Distinct(StringComparer.OrdinalIgnoreCase)
                    .Select(d => new DeleteTarget { Path = d, IsDir = true }).ToList();
                await ApplyDeleted(dirs);
            }
            finally { busy = false; scanBar.Stop(); UpdateButtons(); EndOwnChanges(); }

            // Linked copies are one file now, not duplicates.
            var linked = new HashSet<string>(pairs.Select(p => p.Key.FullPath).Except(errors.Select(e => e.Substring(0, e.IndexOf("  -  ", StringComparison.Ordinal)))),
                StringComparer.OrdinalIgnoreCase);
            if (dupeGroups != null)
            {
                foreach (var g in dupeGroups) g.RemoveAll(f => linked.Contains(f.FullPath));
                dupeGroups.RemoveAll(g => g.Count < 2);
            }
            RefreshTree(current != null && IsAttached(current) ? current : root);
            ViewsChanged();
            FillDuplicates();
            UpdateDriveLabel();
            statusLabel.Text = string.Format("Replaced {0:N0} cop{1} with links, freed about {2}.{3}", done, done == 1 ? "y" : "ies",
                Fmt.Size(pairs.Where(p => linked.Contains(p.Key.FullPath)).Sum(p => p.Key.Alloc)),
                errors.Count > 0 ? string.Format(" {0:N0} could not be replaced.", errors.Count) : "");
            if (errors.Count > 0 && SelfTestDir == null) ShowDeleteErrors(errors, "replaced with links");
            return done;
        }

        /// <summary>Replaces copy with a hard link to keep; null on success, else why not. The copy is never lost: the link is
        /// made under a temporary name first and only then moved over the copy.</summary>
        static string LinkOne(string copy, string keep, long bytes, long modified)
        {
            try
            {
                string vc = VolumeOf(copy), vk = VolumeOf(keep);
                if (vc == null || vk == null || !string.Equals(vc, vk, StringComparison.OrdinalIgnoreCase)) return "on another drive than the copy it would link to";
                if (!string.Equals(FileSystemOf(vc), "NTFS", StringComparison.OrdinalIgnoreCase)) return "the drive does not support hard links (not NTFS)";
                var ic = new FileInfo(NetPath(copy));
                var ik = new FileInfo(NetPath(keep));
                if (!ic.Exists || !ik.Exists) return "no longer exists";
                if (ic.Length != bytes || ic.LastWriteTimeUtc.ToFileTimeUtc() != modified || ik.Length != bytes) return "changed since the search";
                var a = FileIdentity(copy); var b = FileIdentity(keep);
                if (a != null && b != null && a.Item1 == b.Item1) return null;   // already one file
                if (b != null && b.Item2 >= 1023) return "the kept copy has the most links a file can have";
                string tmp = copy + ".dsa-link-" + Guid.NewGuid().ToString("N").Substring(0, 8);
                if (!CreateHardLinkW(Native.LongPath(tmp), Native.LongPath(keep), IntPtr.Zero))
                    return new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()).Message;
                if ((ic.Attributes & FileAttributes.ReadOnly) != 0) ic.Attributes &= ~FileAttributes.ReadOnly;
                if (!MoveFileExW(Native.LongPath(tmp), Native.LongPath(copy), 1))   // MOVEFILE_REPLACE_EXISTING
                {
                    int err = Marshal.GetLastWin32Error();
                    try { File.Delete(NetPath(tmp)); } catch (Exception) { }
                    return new System.ComponentModel.Win32Exception(err).Message;
                }
                return null;
            }
            catch (Exception ex) { return ex.Message; }
        }
    }
}

using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;

namespace DiskSpaceAnalyzer
{
    /// <summary>
    /// Fast restart: the scan of a drive is saved when the app closes (the whole tree with every file, compressed) together
    /// with the position of the drive's NTFS change journal (USN journal) at the moment that scan started. On the next start
    /// the saved scan shows at once; then, as administrator and when the journal still holds everything since that position,
    /// only the files and folders changed since are read again (through the live-update code). Otherwise a normal scan runs
    /// in the background while the saved one is browsed. Kept for the 4 most recent drives in
    /// %LOCALAPPDATA%\DiskSpaceAnalyzer\snapshots.
    /// </summary>
    internal static unsafe class Snapshot
    {
        const int Version = 2;   // 2: last-access times and the drive's capacity
        const int Keep = 4;
        internal static string DirOverride;   // self-test

        static string Dir
        {
            get { return DirOverride ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"DiskSpaceAnalyzer\snapshots"); }
        }

        static string FileFor(string root)
        {
            var sb = new StringBuilder();
            foreach (char c in root.ToUpperInvariant()) sb.Append(char.IsLetterOrDigit(c) ? c : '_');
            return Path.Combine(Dir, sb + ".snap");
        }

        public sealed class Info
        {
            public string Root;
            public DateTime Saved;
            public ulong JournalId;
            public long Usn;           // journal position when the saved scan started (0 = none)
            public long Total, Free;   // capacity of the drive when saved (0 = unknown)
            public DirNode Node;
        }

        public static bool Exists(string root) { return File.Exists(FileFor(root)); }

        public static void Save(string root, DirNode node, ulong journalId, long usn)
        {
            Directory.CreateDirectory(Dir);
            Write(FileFor(root), false, root, node, journalId, usn, DateTime.UtcNow, 0, 0);
            // Keep the most recent drives only.
            foreach (var old in new DirectoryInfo(Dir).GetFiles("*.snap").OrderByDescending(f => f.LastWriteTimeUtc).Skip(Keep))
                try { old.Delete(); } catch (Exception) { }
        }

        /// <summary>A scan file saved by the user (Save scan) starts with this, then the snapshot.</summary>
        static readonly byte[] ScanFileMagic = Encoding.ASCII.GetBytes("DSASCAN1");
        public const string ScanFileExtension = ".dsascan";

        /// <summary>Saves a scan as a file the user can keep, send and open later (read-only).</summary>
        public static void SaveTo(string file, string root, DirNode node, DateTime scanned, long total, long free)
        {
            Write(file, true, root, node, 0, 0, scanned.ToUniversalTime(), total, free);
        }

        /// <summary>Opens a scan file saved with SaveTo; null if it is not one or is damaged.</summary>
        public static Info LoadFrom(string file) { return Read(file, null); }

        static void Write(string file, bool userFile, string root, DirNode node, ulong journalId, long usn, DateTime savedUtc, long total, long free)
        {
            string tmp = file + ".tmp";
            using (var fs = File.Create(tmp))
            {
                if (userFile) fs.Write(ScanFileMagic, 0, ScanFileMagic.Length);
                using (var z = new DeflateStream(fs, CompressionLevel.Fastest))
                using (var w = new BinaryWriter(new BufferedStream(z, 1 << 16), Encoding.UTF8))
                    WriteBody(w, root, node, journalId, usn, savedUtc, total, free);
            }
            if (File.Exists(file)) File.Delete(file);
            File.Move(tmp, file);
        }

        static void WriteBody(BinaryWriter w, string root, DirNode node, ulong journalId, long usn, DateTime savedUtc, long total, long free)
        {
            w.Write(Version);
            w.Write(root);
            w.Write(savedUtc.ToBinary());
            w.Write(journalId);
            w.Write(usn);
            w.Write(total);
            w.Write(free);
            var stack = new Stack<DirNode>();
            stack.Push(node);
            while (stack.Count > 0)
            {
                var d = stack.Pop();
                w.Write(d.Name ?? "");
                w.Write(d.Modified);
                w.Write(d.Denied);
                if (d.FileList == null) w.Write(-1);
                else
                {
                    w.Write(d.FileList.Length);
                    foreach (var f in d.FileList) { w.Write(f.Name); w.Write(f.Bytes); w.Write(f.Alloc); w.Write(f.Modified); w.Write(f.Accessed); w.Write(f.Attr); }
                }
                int n = d.Children == null ? 0 : d.Children.Count;
                w.Write(n);
                for (int i = n - 1; i >= 0; i--) stack.Push(d.Children[i]);
            }
        }

        /// <summary>The saved scan of root (totals recomputed), or null if none or unreadable.</summary>
        public static Info Load(string root)
        {
            string file = FileFor(root);
            if (!File.Exists(file)) return null;
            return Read(file, root);
        }

        /// <summary>Reads a snapshot (root given) or a user's scan file (root null: the file must start with the scan-file header).</summary>
        static Info Read(string file, string root)
        {
            try
            {
                using (var fs = File.OpenRead(file))
                {
                    if (root == null)
                    {
                        var head = new byte[ScanFileMagic.Length];
                        if (fs.Read(head, 0, head.Length) != head.Length || !head.SequenceEqual(ScanFileMagic)) return null;
                    }
                    using (var z = new DeflateStream(fs, CompressionMode.Decompress))
                    using (var r = new BinaryReader(new BufferedStream(z, 1 << 16), Encoding.UTF8))
                        return ReadBody(r, root);
                }
            }
            catch (Exception) { return null; }
        }

        static Info ReadBody(BinaryReader r, string root)
        {
            int version = r.ReadInt32();
            if (version != 1 && version != Version) return null;
            var info = new Info { Root = r.ReadString(), Saved = DateTime.FromBinary(r.ReadInt64()).ToLocalTime(), JournalId = r.ReadUInt64(), Usn = r.ReadInt64() };
            if (version >= 2) { info.Total = r.ReadInt64(); info.Free = r.ReadInt64(); }
            if (root != null && !string.Equals(info.Root, root, StringComparison.OrdinalIgnoreCase)) return null;
            // Pre-order with child counts: rebuild with a stack of (node, children still to read).
            var all = new List<DirNode>();
            var stack = new Stack<KeyValuePair<DirNode, int>>();
            DirNode top = null;
            do
            {
                var d = new DirNode { Name = r.ReadString(), Modified = r.ReadInt64(), Denied = r.ReadBoolean() };
                int nf = r.ReadInt32();
                if (nf >= 0)
                {
                    var list = new FileRec[nf];
                    for (int i = 0; i < nf; i++)
                    {
                        list[i] = new FileRec { Name = r.ReadString(), Bytes = r.ReadInt64(), Alloc = r.ReadInt64(), Modified = r.ReadInt64() };
                        if (version >= 2) list[i].Accessed = r.ReadInt64();
                        list[i].Attr = r.ReadUInt32();
                        d.LocalBytes += list[i].Bytes; d.LocalAlloc += list[i].Alloc;
                    }
                    d.FileList = list;
                    d.LocalFiles = nf;
                }
                int nc = r.ReadInt32();
                if (stack.Count > 0)
                {
                    var p = stack.Pop();
                    d.Parent = p.Key;
                    if (p.Key.Children == null) p.Key.Children = new List<DirNode>(p.Value);
                    p.Key.Children.Add(d);
                    if (p.Value > 1) stack.Push(new KeyValuePair<DirNode, int>(p.Key, p.Value - 1));
                }
                else top = d;
                all.Add(d);
                if (nc > 0) stack.Push(new KeyValuePair<DirNode, int>(d, nc));
            } while (stack.Count > 0);
            for (int i = all.Count - 1; i >= 0; i--) all[i].Aggregate();   // children come after parents
            info.Node = top;
            return info;
        }

        // ---------------------------------------------------------------- USN change journal

        const uint FSCTL_QUERY_USN_JOURNAL = 0x000900f4, FSCTL_READ_USN_JOURNAL = 0x000900bb;
        const uint USN_REASON_FILE_CREATE = 0x100, USN_REASON_FILE_DELETE = 0x200, USN_REASON_RENAME_OLD_NAME = 0x1000, USN_REASON_RENAME_NEW_NAME = 0x2000;

        [StructLayout(LayoutKind.Sequential)]
        struct UsnJournalData { public ulong UsnJournalID; public long FirstUsn, NextUsn, LowestValidUsn, MaxUsn; public ulong MaximumSize, AllocationDelta; }

        [StructLayout(LayoutKind.Sequential)]
        struct ReadUsnJournalData { public long StartUsn; public uint ReasonMask, ReturnOnlyOnClose; public ulong Timeout, BytesToWaitFor, UsnJournalID; }

        [StructLayout(LayoutKind.Sequential)]
        struct FileIdDescriptor { public int Size; public int Type; public long FileId; public long Pad; }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DeviceIoControl(IntPtr h, uint code, void* inBuf, int inSize, void* outBuf, int outSize, out int returned, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenFileById(IntPtr volumeHint, ref FileIdDescriptor id, uint access, uint share, IntPtr security, uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern int GetFinalPathNameByHandleW(IntPtr h, StringBuilder path, int len, int flags);

        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr h);

        static readonly IntPtr Invalid = new IntPtr(-1);

        /// <summary>The journal's id and next position for the drive of root (needs administrator rights); false if none.</summary>
        public static bool QueryJournal(string root, out ulong id, out long next)
        {
            id = 0; next = 0;
            if (root == null || root.Length < 2 || root[1] != ':') return false;
            IntPtr v = CreateFileW(@"\\.\" + root.Substring(0, 2), 0x80000000, 7, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (v == Invalid) return false;
            try
            {
                UsnJournalData d;
                int got;
                if (!DeviceIoControl(v, FSCTL_QUERY_USN_JOURNAL, null, 0, &d, sizeof(UsnJournalData), out got, IntPtr.Zero)) return false;
                id = d.UsnJournalID; next = d.NextUsn;
                return true;
            }
            finally { CloseHandle(v); }
        }

        public struct Change { public string Path; public bool Deleted, Created; }

        /// <summary>
        /// Everything changed on the drive since usn, as full paths in journal order, limited to paths under root. Null when
        /// the journal can't tell (not administrator, another journal now, those records already overwritten, a parent folder
        /// that no longer exists, or too many changes to be worth it).
        /// </summary>
        public static List<Change> ReadSince(string root, ulong journalId, long usn, int maxChanges, out string why)
        {
            why = null;
            if (journalId == 0 || usn <= 0) { why = "no journal position was saved (the scan ran without administrator rights)"; return null; }
            IntPtr v = CreateFileW(@"\\.\" + root.Substring(0, 2), 0x80000000, 7, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (v == Invalid) { why = "the change journal needs administrator rights"; return null; }
            IntPtr hint = CreateFileW(root.Substring(0, 3), 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);   // root folder, backup semantics
            try
            {
                UsnJournalData d;
                int got;
                if (!DeviceIoControl(v, FSCTL_QUERY_USN_JOURNAL, null, 0, &d, sizeof(UsnJournalData), out got, IntPtr.Zero)) { why = "the drive has no change journal"; return null; }
                if (d.UsnJournalID != journalId) { why = "the drive's change journal was recreated"; return null; }
                if (usn < d.FirstUsn) { why = "the changes since then are no longer in the journal"; return null; }
                var changes = new List<Change>();
                var dirPath = new Dictionary<long, string>();
                string rootTrim = root.TrimEnd('\\');
                var rd = new ReadUsnJournalData { StartUsn = usn, ReasonMask = 0xFFFFFFFF, UsnJournalID = journalId };
                var buf = new byte[1 << 16];
                fixed (byte* b = buf)
                {
                    while (rd.StartUsn < d.NextUsn)
                    {
                        if (!DeviceIoControl(v, FSCTL_READ_USN_JOURNAL, &rd, sizeof(ReadUsnJournalData), b, buf.Length, out got, IntPtr.Zero))
                        { why = "the change journal could not be read (error " + Marshal.GetLastWin32Error() + ")"; return null; }
                        long nextStart = *(long*)b;
                        if (got <= 8 || nextStart <= rd.StartUsn) break;
                        int off = 8;
                        while (off < got)
                        {
                            byte* rec = b + off;
                            int len = *(int*)rec;
                            if (len <= 0) break;
                            if (*(ushort*)(rec + 4) == 2)   // USN_RECORD_V2
                            {
                                long parentRef = *(long*)(rec + 16);
                                uint reason = *(uint*)(rec + 40);
                                int nameLen = *(ushort*)(rec + 56), nameOff = *(ushort*)(rec + 58);
                                string name = new string((char*)(rec + nameOff), 0, nameLen / 2);
                                string parent;
                                if (!dirPath.TryGetValue(parentRef, out parent)) { parent = PathOf(hint, parentRef); dirPath[parentRef] = parent; }
                                if (parent == null) { off += len; continue; }   // inside a folder that is gone by now: its own deletion is in the journal too
                                string full = parent.TrimEnd('\\') + "\\" + name;
                                if (full.StartsWith(rootTrim + "\\", StringComparison.OrdinalIgnoreCase) && name.Length > 0 && name[0] != '$')
                                {
                                    var c = new Change
                                    {
                                        Path = full,
                                        Deleted = (reason & (USN_REASON_FILE_DELETE | USN_REASON_RENAME_OLD_NAME)) != 0,
                                        Created = (reason & (USN_REASON_FILE_CREATE | USN_REASON_RENAME_NEW_NAME)) != 0
                                    };
                                    if (changes.Count == 0 || !string.Equals(changes[changes.Count - 1].Path, c.Path, StringComparison.OrdinalIgnoreCase) ||
                                        changes[changes.Count - 1].Deleted != c.Deleted)
                                        changes.Add(c);
                                    if (changes.Count > maxChanges) { why = "too many changes (a full scan is faster)"; return null; }
                                }
                            }
                            off += len;
                        }
                        rd.StartUsn = nextStart;
                    }
                }
                return changes;
            }
            finally { CloseHandle(v); if (hint != Invalid) CloseHandle(hint); }
        }

        /// <summary>Current full path of a folder by its file reference number; null if it no longer exists.</summary>
        static string PathOf(IntPtr hint, long fileRef)
        {
            if (hint == Invalid) return null;
            var id = new FileIdDescriptor { Size = 24, Type = 0, FileId = fileRef };
            IntPtr h = OpenFileById(hint, ref id, 0, 7, IntPtr.Zero, 0x02000000);
            if (h == Invalid) return null;
            try
            {
                var sb = new StringBuilder(1024);
                int n = GetFinalPathNameByHandleW(h, sb, sb.Capacity, 0);
                if (n > sb.Capacity) { sb = new StringBuilder(n + 1); n = GetFinalPathNameByHandleW(h, sb, sb.Capacity, 0); }
                if (n <= 0) return null;
                string p = sb.ToString(0, n);
                if (p.StartsWith(@"\\?\UNC\")) return @"\\" + p.Substring(8);
                return p.StartsWith(@"\\?\") ? p.Substring(4) : p;
            }
            finally { CloseHandle(h); }
        }
    }
}

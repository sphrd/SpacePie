using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace SpacePie
{
    /// <summary>
    /// Remembered content hashes for the duplicate finder, so a repeat search reads only new or changed files. A file is
    /// known by its path, length and modification time (any change makes it unknown); the entry also keeps the file's
    /// identity (volume and file index) to recognise hard links without opening it. Entries not seen for 90 days are dropped,
    /// at most 2 million are kept (most recently seen first). Stored in %LOCALAPPDATA%\SpacePie\hashes.bin.
    /// </summary>
    internal static class HashCache
    {
        sealed class Entry
        {
            public ulong Id;
            public string Head, Full;
            public int Seen;   // days since 2000-01-01
        }

        const int Version = 1;
        const int MaxEntries = 2000000, KeepDays = 90;
        static readonly object gate = new object();
        static Dictionary<string, Entry> map;
        static bool dirty;
        internal static string FileOverride;   // self-test

        static string FilePath
        {
            get { return FileOverride ?? AppData.Path("hashes.bin"); }
        }

        static int Today { get { return (int)(DateTime.UtcNow - new DateTime(2000, 1, 1)).TotalDays; } }

        static string Key(string path, long bytes, long modified) { return path.ToLowerInvariant() + "|" + bytes + "|" + modified; }

        static void EnsureLoaded()
        {
            if (map != null) return;
            map = new Dictionary<string, Entry>();
            try
            {
                if (!File.Exists(FilePath)) return;
                using (var r = new BinaryReader(new BufferedStream(File.OpenRead(FilePath), 1 << 16)))
                {
                    if (r.ReadInt32() != Version) return;
                    int n = r.ReadInt32();
                    for (int i = 0; i < n; i++)
                    {
                        string k = r.ReadString();
                        var e = new Entry { Id = r.ReadUInt64(), Head = r.ReadString(), Full = r.ReadString(), Seen = r.ReadInt32() };
                        if (e.Head.Length == 0) e.Head = null;
                        if (e.Full.Length == 0) e.Full = null;
                        map[k] = e;
                    }
                }
            }
            catch (Exception) { map = new Dictionary<string, Entry>(); }
        }

        /// <summary>Known head hash (and identity) of this exact file version, or false.</summary>
        public static bool TryHead(string path, long bytes, long modified, out string head, out ulong id)
        {
            head = null; id = 0;
            lock (gate)
            {
                EnsureLoaded();
                Entry e;
                if (!map.TryGetValue(Key(path, bytes, modified), out e) || e.Head == null) return false;
                e.Seen = Today;
                head = e.Head; id = e.Id;
                return true;
            }
        }

        public static string TryFull(string path, long bytes, long modified)
        {
            lock (gate)
            {
                EnsureLoaded();
                Entry e;
                return map.TryGetValue(Key(path, bytes, modified), out e) ? e.Full : null;
            }
        }

        public static void Put(string path, long bytes, long modified, ulong id, string head, string full)
        {
            lock (gate)
            {
                EnsureLoaded();
                string k = Key(path, bytes, modified);
                Entry e;
                if (!map.TryGetValue(k, out e)) map[k] = e = new Entry();
                e.Id = id;
                if (head != null) e.Head = head;
                if (full != null) e.Full = full;
                e.Seen = Today;
                dirty = true;
            }
        }

        public static void Save()
        {
            lock (gate)
            {
                if (map == null || !dirty) return;
                try
                {
                    int oldest = Today - KeepDays;
                    var keep = map.Where(kv => kv.Value.Seen >= oldest).OrderByDescending(kv => kv.Value.Seen).Take(MaxEntries).ToList();
                    Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
                    string tmp = FilePath + ".tmp";
                    using (var w = new BinaryWriter(new BufferedStream(File.Create(tmp), 1 << 16)))
                    {
                        w.Write(Version);
                        w.Write(keep.Count);
                        foreach (var kv in keep)
                        {
                            w.Write(kv.Key);
                            w.Write(kv.Value.Id);
                            w.Write(kv.Value.Head ?? "");
                            w.Write(kv.Value.Full ?? "");
                            w.Write(kv.Value.Seen);
                        }
                    }
                    if (File.Exists(FilePath)) File.Delete(FilePath);
                    File.Move(tmp, FilePath);
                    dirty = false;
                }
                catch (Exception) { }
            }
        }

        /// <summary>Self-test: forget what is loaded (the next lookup reads the file again).</summary>
        internal static void Unload() { lock (gate) { map = null; dirty = false; } }
    }
}

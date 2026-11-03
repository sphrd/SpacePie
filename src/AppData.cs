using System;
using System.IO;

namespace SpacePie
{
    /// <summary>
    /// Where the app keeps its data. Versions 1.x were called Disk Space Analyzer and kept everything in
    /// %LOCALAPPDATA%\DiskSpaceAnalyzer; the first start of SpacePie moves that folder (saved scans, history, hash cache,
    /// apps list, registry backups, settings) to %LOCALAPPDATA%\SpacePie. If it cannot be moved (a 1.x copy still running),
    /// the old folder is used for this session and the move is tried again next time.
    /// </summary>
    internal static class AppData
    {
        const string Folder = "SpacePie";
        const string LegacyFolder = "DiskSpaceAnalyzer";
        static readonly object gate = new object();
        static string dir;

        public static string Dir
        {
            get
            {
                lock (gate)
                {
                    if (dir == null) dir = Resolve();
                    return dir;
                }
            }
        }

        public static string Path(string relative) { return System.IO.Path.Combine(Dir, relative); }

        static string Resolve()
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string current = System.IO.Path.Combine(local, Folder), old = System.IO.Path.Combine(local, LegacyFolder);
            if (!Directory.Exists(current) && Directory.Exists(old))
            {
                try { Directory.Move(old, current); }
                catch (Exception) { return old; }
            }
            return current;
        }
    }
}

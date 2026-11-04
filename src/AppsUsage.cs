using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Microsoft.Win32;

namespace SpacePie
{
    /// <summary>
    /// When each installed app was last opened, as Windows recorded it: Explorer's launch records for this user
    /// (UserAssist: programs started from Start, the taskbar or Explorer) and the last-access time of the app's own .exe
    /// files. Nothing recorded = 0 (the Apps view says "Not recorded" and then goes by the install date).
    /// </summary>
    internal static class AppsUsage
    {
        public const int UnusedDays = 182;

        /// <summary>ROT13, the encoding of UserAssist value names.</summary>
        internal static string Rot13(string s)
        {
            var sb = new StringBuilder(s.Length);
            foreach (char c in s)
            {
                if (c >= 'a' && c <= 'z') sb.Append((char)('a' + (c - 'a' + 13) % 26));
                else if (c >= 'A' && c <= 'Z') sb.Append((char)('A' + (c - 'A' + 13) % 26));
                else sb.Append(c);
            }
            return sb.ToString();
        }

        /// <summary>A UserAssist path with its known-folder id replaced by the folder ("{6D80...}\App\app.exe").</summary>
        internal static string ExpandKnownFolder(string p)
        {
            string pf64 = Environment.GetEnvironmentVariable("ProgramW6432") ?? Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "{6D809377-6AF0-444B-8957-A3773F02200E}", pf64 },
                { "{7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E}", Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86) },
                { "{F38BF404-1D43-42F2-9305-67DE0B28FC23}", Environment.GetFolderPath(Environment.SpecialFolder.Windows) },
                { "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}", Environment.GetFolderPath(Environment.SpecialFolder.System) },
                { "{D65231B0-B2F1-4857-A4CE-A8E7C6EA7D27}", Environment.GetFolderPath(Environment.SpecialFolder.SystemX86) },
                { "{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}", Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) },
                { "{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}", Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData) },
            };
            if (p.Length > 38 && p[0] == '{' && p[37] == '}')
            {
                string root;
                if (map.TryGetValue(p.Substring(0, 38), out root) && !string.IsNullOrEmpty(root)) return root.TrimEnd('\\') + p.Substring(38);
            }
            return p;
        }

        /// <summary>Program (or Store app id) -> last run (FILETIME, UTC), from this user's UserAssist records.</summary>
        internal static Dictionary<string, long> ReadUserAssist()
        {
            var runs = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            try
            {
                using (var ua = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist"))
                {
                    if (ua == null) return runs;
                    foreach (var g in ua.GetSubKeyNames())
                        using (var count = ua.OpenSubKey(g + @"\Count"))
                        {
                            if (count == null) continue;
                            foreach (var vn in count.GetValueNames())
                            {
                                var data = count.GetValue(vn) as byte[];
                                if (data == null || data.Length < 68) continue;
                                long ft = BitConverter.ToInt64(data, 60);
                                if (ft <= 0) continue;
                                string path = ExpandKnownFolder(Rot13(vn));
                                long had;
                                if (!runs.TryGetValue(path, out had) || ft > had) runs[path] = ft;
                            }
                        }
                }
            }
            catch (Exception) { }
            return runs;
        }

        /// <summary>Fills LastUsed for each app: its latest UserAssist record inside its folder (or of its Store
        /// package) and the latest last-access time of the .exe files in its folder (two levels).</summary>
        internal static void Fill(List<InstalledApp> apps)
        {
            var runs = ReadUserAssist();
            foreach (var a in apps)
            {
                long best = 0;
                string loc = string.IsNullOrEmpty(a.Location) ? null : a.Location.TrimEnd('\\') + "\\";
                foreach (var kv in runs)
                {
                    bool mine = loc != null && kv.Key.StartsWith(loc, StringComparison.OrdinalIgnoreCase)
                        || !string.IsNullOrEmpty(a.PackageFamilyName) && kv.Key.StartsWith(a.PackageFamilyName + "!", StringComparison.OrdinalIgnoreCase);
                    if (mine && kv.Value > best) best = kv.Value;
                }
                if (loc != null && loc.Length > 4 && Native.IsDirectory(loc))
                {
                    try
                    {
                        var di = new DirectoryInfo(loc);
                        var exes = di.GetFiles("*.exe").ToList();
                        if (exes.Count == 0) foreach (var sub in di.GetDirectories().Take(20)) { try { exes.AddRange(sub.GetFiles("*.exe")); } catch (Exception) { } }
                        foreach (var f in exes)
                        {
                            // Uninstallers and updaters are run by Windows / the app itself, not by the user.
                            string n = f.Name.ToLowerInvariant();
                            if (n.StartsWith("unins") || n.Contains("uninstall") || n.Contains("update") || n.Contains("crash")) continue;
                            long t = f.LastAccessTimeUtc.ToFileTimeUtc();
                            if (t > best && f.LastAccessTimeUtc > f.CreationTimeUtc.AddMinutes(5)) best = t;
                        }
                    }
                    catch (Exception) { }
                }
                a.LastUsed = best;
            }
        }

        /// <summary>When the app was installed (the uninstall entry's InstallDate), or null.</summary>
        internal static DateTime? InstalledOn(InstalledApp a)
        {
            string d = a.InstallDate;
            if (string.IsNullOrEmpty(d)) return null;
            DateTime t;
            if (d.Length == 8 && d.All(char.IsDigit) &&
                DateTime.TryParseExact(d, "yyyyMMdd", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeLocal, out t)) return t;
            return DateTime.TryParse(d, out t) ? t : (DateTime?)null;
        }

        /// <summary>Not opened for about 6 months: opened last before then, or never recorded as opened and installed before then.</summary>
        internal static bool IsUnused(InstalledApp a, DateTime nowUtc)
        {
            if (a.Uninstalled) return false;
            DateTime limit = nowUtc.AddDays(-UnusedDays);
            if (a.LastUsed > 0) return DateTime.FromFileTimeUtc(a.LastUsed) < limit;
            var inst = InstalledOn(a);
            return inst.HasValue && inst.Value.ToUniversalTime() < limit;
        }
    }
}

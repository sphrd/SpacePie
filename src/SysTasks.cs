using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace DiskSpaceAnalyzer
{
    /// <summary>What a row of the System tab can do.</summary>
    internal enum SysAct { None, AnalyzeStore, CleanStore, DeleteOldestShadow, DeleteAllButNewest, HibernateOff, HibernateOn, ShrinkDisk, RemoveRegistry, ShowSuggestions }

    /// <summary>A group of the System tab (Windows update leftovers, restore points, ...).</summary>
    internal sealed class SysGroup
    {
        public string Key, Name, Note;
        public List<SysItem> Items = new List<SysItem>();
        public bool Expanded, Loading, Loaded;
        /// <summary>Actions offered on the group row itself (e.g. Remove checked).</summary>
        public List<SysAct> Actions = new List<SysAct>();
        public bool NeedsAdmin;
    }

    /// <summary>One row in a group: what it is, its size, what can be freed, what it means and what can be done.</summary>
    internal sealed class SysItem
    {
        public string Name = "", Meaning = "", Location = "", SizeText, ActionText;
        public long Size = -1, Reclaim;
        public bool NeedsAdmin, Info, Muted;
        public List<SysAct> Actions = new List<SysAct>();
        /// <summary>Row colour: 0 normal, 1 amber, 2 red.</summary>
        public int Level;
        public object Data;
        public string Path;
    }

    internal sealed class DismInfo
    {
        public long Reported = -1, Actual = -1, Shared = -1, Backups = -1, Cache = -1;
        public int Reclaimable = -1;
        public bool? Recommended;
        public string LastCleanup = "";
        /// <summary>Estimate of what StartComponentCleanup frees.</summary>
        public long Estimate { get { return Recommended == true ? Math.Max(0, Backups) + Math.Max(0, Cache) : Math.Max(0, Cache); } }
    }

    internal sealed class ShadowCopy
    {
        public string Id = "", Volume = "";
        public DateTime Created;
    }

    internal sealed class ShadowStorage
    {
        public string Volume = "", MaxText = "";
        public long Used = -1, Allocated = -1, Max = -1;
    }

    internal sealed class VirtualDisk
    {
        public string Path = "", Owner = "";
        public long Size;
    }

    /// <summary>System tab: reading the system's state and the actions (DISM, vssadmin, powercfg, wsl + diskpart, registry).</summary>
    internal sealed partial class MainForm
    {
        static string Sys32(string exe) { return System.IO.Path.Combine(Environment.SystemDirectory, exe); }

        // ---------------------------------------------------------------- running tools

        static Encoding OemEncoding
        {
            get { try { return Encoding.GetEncoding(CultureInfo.CurrentCulture.TextInfo.OEMCodePage); } catch (Exception) { return Encoding.Default; } }
        }

        /// <summary>
        /// Runs a console tool hidden, passing all output so far to onOutput as it arrives (progress lines end in \r). Kills it
        /// when cancelled() turns true. Returns the exit code (-1 if it could not start).
        /// </summary>
        static int RunTool(string exe, string args, Action<string> onOutput, Func<bool> cancelled, out string output)
        {
            var psi = new ProcessStartInfo(exe, args)
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = OemEncoding, StandardErrorEncoding = OemEncoding
            };
            var sb = new StringBuilder();
            Process p;
            try { p = Process.Start(psi); }
            catch (Exception ex) { output = ex.Message; return -1; }
            using (p)
            {
                var err = p.StandardError.ReadToEndAsync();
                var done = new ManualResetEvent(false);
                if (cancelled != null)
                    ThreadPool.QueueUserWorkItem(_ =>
                    {
                        while (!done.WaitOne(300))
                            if (cancelled()) { try { p.Kill(); } catch (Exception) { } return; }
                    });
                var buf = new char[1024];
                int n;
                while ((n = p.StandardOutput.Read(buf, 0, buf.Length)) > 0)
                {
                    sb.Append(buf, 0, n);
                    if (onOutput != null) onOutput(sb.ToString());
                }
                p.WaitForExit();
                done.Set();
                try { sb.Append(err.Result); } catch (Exception) { }
                output = sb.ToString();
                return p.ExitCode;
            }
        }

        /// <summary>Last progress percentage in a tool's output ("[=== 45.2% ===]", "45 percent completed"); -1 if none.</summary>
        internal static double LastPercent(string text)
        {
            if (string.IsNullOrEmpty(text)) return -1;
            var ms = Regex.Matches(text, @"(\d{1,3}(?:[.,]\d+)?)\s*(?:%|percent)", RegexOptions.IgnoreCase);
            if (ms.Count == 0) return -1;
            double v;
            return double.TryParse(ms[ms.Count - 1].Groups[1].Value.Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out v) ? Math.Min(100, v) : -1;
        }

        /// <summary>Last meaningful line of a tool's output (for error messages).</summary>
        static string LastLine(string text)
        {
            var lines = (text ?? "").Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries).Select(l => l.Trim())
                .Where(l => l.Length > 0 && !l.StartsWith("[")).ToList();
            return lines.Count > 0 ? lines[lines.Count - 1] : "";
        }

        // ---------------------------------------------------------------- parsing

        /// <summary>"8.12 GB", "222.53 MB", "1,024 bytes" -> bytes; -1 when there is no size.</summary>
        internal static long ParseSize(string s)
        {
            var m = Regex.Match(s ?? "", @"([\d][\d.,]*)\s*(bytes|byte|B|KB|MB|GB|TB|PB)\b", RegexOptions.IgnoreCase);
            if (!m.Success) return -1;
            string num = m.Groups[1].Value;
            int dot = num.LastIndexOf('.'), comma = num.LastIndexOf(',');
            if (dot >= 0 && comma >= 0) num = dot > comma ? num.Replace(",", "") : num.Replace(".", "").Replace(',', '.');
            else if (comma >= 0) num = num.Length - comma - 1 == 3 ? num.Replace(",", "") : num.Replace(',', '.');
            double v;
            if (!double.TryParse(num, NumberStyles.Float, CultureInfo.InvariantCulture, out v)) return -1;
            string u = m.Groups[2].Value.ToUpperInvariant();
            int pow = u == "KB" ? 1 : u == "MB" ? 2 : u == "GB" ? 3 : u == "TB" ? 4 : u == "PB" ? 5 : 0;
            return (long)Math.Round(v * Math.Pow(1024, pow));
        }

        static string Field(string text, string label)
        {
            var m = Regex.Match(text ?? "", "^\\s*" + Regex.Escape(label) + "\\s*:\\s*(.*?)\\s*$", RegexOptions.IgnoreCase | RegexOptions.Multiline);
            return m.Success ? m.Groups[1].Value : null;
        }

        /// <summary>Dism /English /Online /Cleanup-Image /AnalyzeComponentStore output.</summary>
        internal static DismInfo ParseDismAnalyze(string text)
        {
            var d = new DismInfo();
            d.Reported = ParseSize(Field(text, "Windows Explorer Reported Size of Component Store"));
            d.Actual = ParseSize(Field(text, "Actual Size of Component Store"));
            d.Shared = ParseSize(Field(text, "Shared with Windows"));
            d.Backups = ParseSize(Field(text, "Backups and Disabled Features"));
            d.Cache = ParseSize(Field(text, "Cache and Temporary Data"));
            d.LastCleanup = Field(text, "Date of Last Cleanup") ?? "";
            int n;
            if (int.TryParse(Field(text, "Number of Reclaimable Packages") ?? "", out n)) d.Reclaimable = n;
            string rec = Field(text, "Component Store Cleanup Recommended");
            if (rec != null) d.Recommended = rec.StartsWith("Yes", StringComparison.OrdinalIgnoreCase);
            return d;
        }

        /// <summary>vssadmin list shadows: every shadow copy with its drive and creation time.</summary>
        internal static List<ShadowCopy> ParseVssShadows(string text)
        {
            var list = new List<ShadowCopy>();
            DateTime created = DateTime.MinValue;
            ShadowCopy cur = null;
            foreach (var raw in (text ?? "").Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
            {
                string line = raw.Trim();
                var m = Regex.Match(line, @"creation time:\s*(.+)$", RegexOptions.IgnoreCase);
                if (m.Success)
                {
                    DateTime t;
                    created = DateTime.TryParse(m.Groups[1].Value.Trim(), CultureInfo.CurrentCulture, DateTimeStyles.None, out t) ||
                              DateTime.TryParse(m.Groups[1].Value.Trim(), CultureInfo.InvariantCulture, DateTimeStyles.None, out t) ? t : DateTime.MinValue;
                    continue;
                }
                m = Regex.Match(line, @"^Shadow Copy ID:\s*(\{[0-9a-fA-F-]+\})", RegexOptions.IgnoreCase);
                if (m.Success) { cur = new ShadowCopy { Id = m.Groups[1].Value, Created = created }; list.Add(cur); continue; }
                m = Regex.Match(line, @"^Original Volume:\s*\(([A-Za-z]:)\)", RegexOptions.IgnoreCase);
                if (m.Success && cur != null) cur.Volume = m.Groups[1].Value.ToUpperInvariant();
            }
            return list;
        }

        /// <summary>vssadmin list shadowstorage: used / allocated / maximum space per drive.</summary>
        internal static List<ShadowStorage> ParseVssStorage(string text)
        {
            var list = new List<ShadowStorage>();
            ShadowStorage cur = null;
            foreach (var raw in (text ?? "").Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
            {
                string line = raw.Trim();
                var m = Regex.Match(line, @"^For volume:\s*\(([A-Za-z]:)\)", RegexOptions.IgnoreCase);
                if (m.Success) { cur = new ShadowStorage { Volume = m.Groups[1].Value.ToUpperInvariant() }; list.Add(cur); continue; }
                if (cur == null) continue;
                m = Regex.Match(line, @"^Used Shadow Copy Storage space:\s*(.+)$", RegexOptions.IgnoreCase);
                if (m.Success) { cur.Used = ParseSize(m.Groups[1].Value); continue; }
                m = Regex.Match(line, @"^Allocated Shadow Copy Storage space:\s*(.+)$", RegexOptions.IgnoreCase);
                if (m.Success) { cur.Allocated = ParseSize(m.Groups[1].Value); continue; }
                m = Regex.Match(line, @"^Maximum Shadow Copy Storage space:\s*(.+)$", RegexOptions.IgnoreCase);
                if (m.Success) { cur.MaxText = m.Groups[1].Value.Trim(); cur.Max = ParseSize(cur.MaxText); }
            }
            return list;
        }

        // ---------------------------------------------------------------- reading the groups (background threads)

        internal static string SystemRoot { get { return System.IO.Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.Windows)); } }

        List<SysItem> ReadStoreGroup(DismInfo info, bool analyzing, double pct)
        {
            var it = new SysItem
            {
                Name = "Component store (WinSxS)", Location = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "WinSxS"),
                NeedsAdmin = true, Actions = { SysAct.AnalyzeStore, SysAct.CleanStore }
            };
            if (analyzing)
            {
                it.SizeText = pct >= 0 ? string.Format("analyzing {0:0} %", pct) : "analyzing...";
                it.Meaning = "Measuring the component store (takes about a minute)...";
            }
            else if (info == null)
            {
                it.SizeText = "";
                it.Meaning = "Older versions of Windows files kept after updates. Press Analyze to measure what a cleanup frees (about a minute).";
            }
            else
            {
                it.Size = info.Actual;
                it.Reclaim = info.Estimate;
                it.Meaning = string.Format("Older versions of Windows files kept after updates. Cleanup recommended: {0}{1}. After a cleanup, installed updates can no longer be uninstalled.",
                    info.Recommended == true ? "yes" : info.Recommended == false ? "no" : "unknown",
                    info.Reclaimable >= 0 ? string.Format(" ({0} reclaimable package{1})", info.Reclaimable, info.Reclaimable == 1 ? "" : "s") : "");
            }
            var list = new List<SysItem> { it };
            if (info != null && !analyzing)
            {
                if (info.Backups >= 0)
                    list.Add(new SysItem { Name = "Backups and disabled features", Size = info.Backups, Info = true, Location = it.Location,
                        Meaning = "Copies kept so updates can be uninstalled, and Windows features that are turned off." });
                if (info.Cache >= 0)
                    list.Add(new SysItem { Name = "Cache and temporary data", Size = info.Cache, Info = true, Location = it.Location,
                        Meaning = "Temporary files of Windows servicing; removed by a cleanup." });
                if (info.Shared >= 0)
                    list.Add(new SysItem { Name = "Shared with Windows", Size = info.Shared, Info = true, Location = it.Location,
                        Meaning = "Windows' own files (also linked from C:\\Windows). Not counted twice on disk; never removed." });
            }
            return list;
        }

        List<SysItem> ReadShadowGroup(bool admin)
        {
            var list = new List<SysItem>();
            if (!admin)
            {
                list.Add(new SysItem
                {
                    Name = "Restore points and shadow copies", NeedsAdmin = true, SizeText = "", Actions = { SysAct.DeleteOldestShadow, SysAct.DeleteAllButNewest },
                    Meaning = "Snapshots Windows keeps to undo system changes (System Restore) and for previous versions of files."
                });
                return list;
            }
            string so, ss;
            RunTool(Sys32("vssadmin.exe"), "list shadowstorage", null, null, out so);
            RunTool(Sys32("vssadmin.exe"), "list shadows", null, null, out ss);
            var storage = ParseVssStorage(so);
            var shadows = ParseVssShadows(ss);
            foreach (var st in storage.OrderBy(x => x.Volume))
            {
                var mine = shadows.Where(s => s.Volume == st.Volume).OrderBy(s => s.Created).ToList();
                var it = new SysItem
                {
                    Name = string.Format("Restore points on {0} ({1:N0})", st.Volume, mine.Count), Size = Math.Max(0, st.Used), Location = st.Volume + "\\",
                    Reclaim = mine.Count > 0 ? Math.Max(0, st.Used) : 0, NeedsAdmin = true, Data = st,
                    Meaning = string.Format("Snapshots to undo system changes{0}. System Restore may use up to {1}.",
                        mine.Count > 0 ? ", oldest " + mine[0].Created.ToString("yyyy-MM-dd") + ", newest " + mine[mine.Count - 1].Created.ToString("yyyy-MM-dd") : "",
                        st.MaxText.Length > 0 ? st.MaxText : "an unknown amount")
                };
                if (mine.Count > 0) it.Actions.Add(SysAct.DeleteOldestShadow);
                if (mine.Count > 1) it.Actions.Add(SysAct.DeleteAllButNewest);
                list.Add(it);
            }
            if (list.Count == 0)
                list.Add(new SysItem { Name = "No restore points or shadow copies", Info = true, Muted = true, SizeText = "", Meaning = "System Restore keeps nothing on this computer right now." });
            return list;
        }

        static long FileSize(string path)
        {
            try { var fi = new FileInfo(path); if (fi.Exists) return fi.Length; } catch (Exception) { }
            try
            {
                var f = new DirectoryInfo(System.IO.Path.GetDirectoryName(path)).GetFiles(System.IO.Path.GetFileName(path));
                if (f.Length > 0) return f[0].Length;
            }
            catch (Exception) { }
            return -1;
        }

        static bool HibernationOn()
        {
            try
            {
                using (var hive = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
                using (var k = hive.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Power"))
                {
                    var v = k != null ? k.GetValue("HibernateEnabled") : null;
                    if (v is int) return (int)v != 0;
                }
            }
            catch (Exception) { }
            return FileSize(System.IO.Path.Combine(SystemRoot, "hiberfil.sys")) > 0;
        }

        List<SysItem> ReadHiberGroup(List<DriveHealth> drives)
        {
            var list = new List<SysItem>();
            string hib = System.IO.Path.Combine(SystemRoot, "hiberfil.sys");
            long hs = FileSize(hib);
            bool on = HibernationOn();
            var h = new SysItem { Name = "Hibernation file (hiberfil.sys)", Location = hib, Path = hs > 0 ? hib : null, NeedsAdmin = true };
            if (on)
            {
                h.Size = Math.Max(0, hs);
                h.Reclaim = Math.Max(0, hs);
                h.Meaning = "Holds the memory while the PC hibernates; also used by Fast Startup. Turning hibernation off deletes it; Hibernate and Fast Startup then stop working.";
                h.Actions.Add(SysAct.HibernateOff);
            }
            else
            {
                h.Size = Math.Max(0, hs);
                h.SizeText = hs > 0 ? null : "off";
                h.Meaning = "Hibernation is off, so there is no hibernation file. Turn it on to use Hibernate and Fast Startup again.";
                h.Actions.Add(SysAct.HibernateOn);
            }
            list.Add(h);
            foreach (var d in drives)
                foreach (var name in new[] { "pagefile.sys", "swapfile.sys" })
                {
                    string f = System.IO.Path.Combine(d.Root, name);
                    long s = FileSize(f);
                    if (s <= 0) continue;
                    list.Add(new SysItem
                    {
                        Name = (name == "pagefile.sys" ? "Page file" : "Swap file") + " on " + d.Letter + " (" + name + ")", Size = s, Location = f, Path = f, Info = true, ActionText = "managed by Windows",
                        Meaning = name == "pagefile.sys"
                            ? "Extra memory on disk. Windows manages its size by itself; leave it as it is."
                            : "Used by Store apps when memory is short. Managed by Windows; leave it as it is."
                    });
                }
            return list;
        }

        /// <summary>WSL distributions and Docker Desktop virtual disks (.vhdx) of this user.</summary>
        internal static List<VirtualDisk> FindVirtualDisks()
        {
            var found = new Dictionary<string, VirtualDisk>(StringComparer.OrdinalIgnoreCase);
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            Action<string, string> add = (f, owner) =>
            {
                try
                {
                    var fi = new FileInfo(f);
                    if (fi.Exists && !found.ContainsKey(fi.FullName)) found[fi.FullName] = new VirtualDisk { Path = fi.FullName, Size = fi.Length, Owner = owner };
                }
                catch (Exception) { }
            };
            try
            {
                string pk = System.IO.Path.Combine(local, "Packages");
                if (Directory.Exists(pk))
                    foreach (var d in Directory.GetDirectories(pk))
                        add(System.IO.Path.Combine(d, @"LocalState\ext4.vhdx"), "WSL: " + DistroName(System.IO.Path.GetFileName(d)));
            }
            catch (Exception) { }
            try
            {
                string wsl = System.IO.Path.Combine(local, "wsl");
                if (Directory.Exists(wsl))
                    foreach (var d in Directory.GetDirectories(wsl)) add(System.IO.Path.Combine(d, "ext4.vhdx"), "WSL distribution");
            }
            catch (Exception) { }
            try
            {
                string docker = System.IO.Path.Combine(local, @"Docker\wsl");
                if (Directory.Exists(docker))
                    foreach (var f in Directory.EnumerateFiles(docker, "*.vhdx", SearchOption.AllDirectories)) add(f, "Docker Desktop");
            }
            catch (Exception) { }
            // Distributions registered elsewhere (wsl --import): the Lxss key lists their folders.
            try
            {
                using (var lxss = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Lxss"))
                    if (lxss != null)
                        foreach (var id in lxss.GetSubKeyNames())
                            using (var k = lxss.OpenSubKey(id))
                            {
                                string bp = k != null ? Convert.ToString(k.GetValue("BasePath")) : null;
                                if (string.IsNullOrEmpty(bp)) continue;
                                if (bp.StartsWith(@"\\?\")) bp = bp.Substring(4);
                                string dn = Convert.ToString(k.GetValue("DistributionName"));
                                add(System.IO.Path.Combine(bp, "ext4.vhdx"), "WSL: " + (string.IsNullOrEmpty(dn) ? "distribution" : dn));
                            }
            }
            catch (Exception) { }
            return found.Values.OrderByDescending(v => v.Size).ToList();
        }

        static string DistroName(string package)
        {
            // CanonicalGroupLimited.Ubuntu22.04LTS_79rhkp1fndgsc -> Ubuntu22.04LTS
            string s = package;
            int u = s.IndexOf('_');
            if (u > 0) s = s.Substring(0, u);
            int dot = s.IndexOf('.');
            return dot > 0 && dot < s.Length - 1 ? s.Substring(dot + 1) : s;
        }

        List<SysItem> ReadDiskGroup()
        {
            var list = new List<SysItem>();
            foreach (var v in FindVirtualDisks())
                list.Add(new SysItem
                {
                    Name = v.Owner + " (" + System.IO.Path.GetFileName(v.Path) + ")", Size = v.Size, Location = v.Path, Path = v.Path, NeedsAdmin = true, Data = v,
                    Meaning = "Linux's disk as one file. It grows but never shrinks by itself: Shrink gives back the space Linux no longer uses.",
                    Actions = { SysAct.ShrinkDisk }
                });
            if (list.Count == 0)
                list.Add(new SysItem { Name = "No WSL or Docker virtual disks found", Info = true, Muted = true, SizeText = "", Meaning = "Nothing to shrink." });
            return list;
        }

        List<SysItem> ReadRegistryGroup(List<RegIssue> issues)
        {
            var list = new List<SysItem>();
            foreach (var r in issues.OrderBy(x => x.Category).ThenBy(x => x.Name, StringComparer.OrdinalIgnoreCase))
                list.Add(new SysItem
                {
                    Name = r.Category + ": " + r.Name, SizeText = "", Meaning = r.Why, Location = r.Display, NeedsAdmin = r.NeedsAdmin, Data = r,
                    Actions = { SysAct.RemoveRegistry }
                });
            if (list.Count == 0)
                list.Add(new SysItem { Name = "Nothing broken found", Info = true, Muted = true, SizeText = "", Meaning = "No uninstall entries, startup entries or file associations point at missing programs." });
            return list;
        }

        List<SysItem> ReadDriveGroup(List<DriveHealth> drives)
        {
            var list = new List<SysItem>();
            foreach (var d in drives.OrderBy(x => x.Root))
            {
                var it = new SysItem
                {
                    Name = d.Letter + (d.Label.Length > 0 ? "  " + d.Label : "") + (d.Model.Length > 0 ? "  (" + d.Model + ")" : ""), Size = d.Total - d.Free, Location = d.Root, Path = d.Root,
                    SizeText = string.Format("{0} free of {1}", Fmt.Size(d.Free), Fmt.Size(d.Total)), Data = d, Info = true,
                    Level = d.IsUnhealthy ? 2 : d.IsWarning || d.LowSpace ? 1 : 0
                };
                string health = char.ToUpperInvariant(d.HealthText[0]) + d.HealthText.Substring(1) + ".";
                if (d.IsUnhealthy) health += " Back up your files now and replace this disk.";
                else if (d.IsWarning) health += " The disk reports a problem: back up your files.";
                if (d.LowSpace)
                {
                    health += string.Format(" Almost full ({0:0} % free): Windows and apps slow down or fail to update.", d.FreePercent);
                    it.Actions.Add(SysAct.ShowSuggestions);
                }
                it.Meaning = health;
                list.Add(it);
            }
            return list;
        }
    }
}

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace DiskSpaceAnalyzer
{
    /// <summary>A broken registry entry: a key (uninstall entry, file association, app path) or a value (startup entry).</summary>
    internal sealed class RegIssue
    {
        public string Category = "", Name = "", Why = "", Target = "";
        public RegistryHive Hive;
        public RegistryView View;
        public string SubKey;                   // path under the hive, in its view
        /// <summary>Startup entries are values of the Run key; null = the whole key.</summary>
        public string ValueName;
        public bool Checked = true;
        public string Note = "";

        public bool NeedsAdmin { get { return Hive == RegistryHive.LocalMachine; } }

        /// <summary>Full key name as regedit shows it (32-bit view of HKLM under WOW6432Node).</summary>
        public string KeyDisplay { get { return MainForm.RegDisplay(Hive, View, SubKey); } }

        public string Display { get { return KeyDisplay + (ValueName != null ? "  [" + (ValueName.Length == 0 ? "(Default)" : ValueName) + "]" : ""); } }
    }

    /// <summary>
    /// Registry check: only safe categories. Uninstall entries whose program folder and uninstaller are both gone,
    /// startup entries (Run / RunOnce) whose program is gone, and file associations / app paths pointing at a missing
    /// program. Everything removed is first saved to a .reg backup.
    /// </summary>
    internal sealed partial class MainForm
    {
        const string RunPath = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";
        const string RunOncePath = @"SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce";
        const string AppPathsPath = @"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths";
        const string ApplicationsPath = @"Software\Classes\Applications";

        internal static string RegDisplay(RegistryHive hive, RegistryView view, string sub)
        {
            string s = sub ?? "";
            if (hive == RegistryHive.LocalMachine && view == RegistryView.Registry32 && Environment.Is64BitOperatingSystem &&
                s.StartsWith("SOFTWARE\\", StringComparison.OrdinalIgnoreCase) && !s.StartsWith("SOFTWARE\\WOW6432Node", StringComparison.OrdinalIgnoreCase))
                s = "SOFTWARE\\WOW6432Node\\" + s.Substring(9);
            return (hive == RegistryHive.CurrentUser ? "HKEY_CURRENT_USER\\" : "HKEY_LOCAL_MACHINE\\") + s;
        }

        static IEnumerable<Tuple<RegistryHive, RegistryView>> RegRoots()
        {
            yield return Tuple.Create(RegistryHive.LocalMachine, RegistryView.Registry64);
            if (Environment.Is64BitOperatingSystem) yield return Tuple.Create(RegistryHive.LocalMachine, RegistryView.Registry32);
            yield return Tuple.Create(RegistryHive.CurrentUser, RegistryView.Registry64);
        }

        /// <summary>Reads the registry (read only) and returns the broken entries of the safe categories.</summary>
        internal static List<RegIssue> FindBrokenRegistry()
        {
            var list = new List<RegIssue>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            Action<RegIssue> add = i => { if (seen.Add(i.Display)) list.Add(i); };
            foreach (var r in RegRoots())
            {
                try
                {
                    using (var hive = RegistryKey.OpenBaseKey(r.Item1, r.Item2))
                    {
                        CheckUninstall(hive, r.Item1, r.Item2, add);
                        CheckRun(hive, r.Item1, r.Item2, RunPath, add);
                        CheckRun(hive, r.Item1, r.Item2, RunOncePath, add);
                        CheckAppPaths(hive, r.Item1, r.Item2, add);
                        if (r.Item1 == RegistryHive.CurrentUser) CheckApplications(hive, r.Item1, r.Item2, add);
                    }
                }
                catch (Exception) { }
            }
            return list;
        }

        static void CheckUninstall(RegistryKey hive, RegistryHive h, RegistryView v, Action<RegIssue> add)
        {
            using (var un = hive.OpenSubKey(UninstallPath))
            {
                if (un == null) return;
                foreach (var name in un.GetSubKeyNames())
                {
                    try
                    {
                        using (var k = un.OpenSubKey(name))
                        {
                            if (k == null) continue;
                            var sys = k.GetValue("SystemComponent");
                            if (sys is int && (int)sys == 1) continue;
                            string unCmd = Str(k, "UninstallString");
                            string exe = CommandTarget(unCmd);
                            if (exe == null || !IsMissing(exe)) continue;            // msiexec, relative or still there
                            string loc = (Str(k, "InstallLocation") ?? "").Trim().Trim('"');
                            try { loc = Environment.ExpandEnvironmentVariables(loc); } catch (Exception) { }
                            string folder = loc.Length > 0 ? loc.TrimEnd('\\') : Native.ParentDir(exe);
                            if (string.IsNullOrEmpty(folder) || !IsCheckablePath(folder) || Directory.Exists(folder)) continue;
                            string disp = Str(k, "DisplayName");
                            add(new RegIssue
                            {
                                Category = "Uninstall entry", Name = disp.Length > 0 ? disp : name, Hive = h, View = v, SubKey = UninstallPath + "\\" + name,
                                Target = exe, Why = "Its program folder and its uninstaller no longer exist (" + folder + ")."
                            });
                        }
                    }
                    catch (Exception) { }
                }
            }
        }

        static void CheckRun(RegistryKey hive, RegistryHive h, RegistryView v, string path, Action<RegIssue> add)
        {
            using (var k = hive.OpenSubKey(path))
            {
                if (k == null) return;
                foreach (var name in k.GetValueNames())
                {
                    try
                    {
                        if (k.GetValueKind(name) != RegistryValueKind.String && k.GetValueKind(name) != RegistryValueKind.ExpandString) continue;
                        string cmd = Convert.ToString(k.GetValue(name));
                        string exe = CommandTarget(cmd);
                        if (exe == null || !IsMissing(exe)) continue;
                        add(new RegIssue
                        {
                            Category = path.EndsWith("RunOnce") ? "Startup entry (run once)" : "Startup entry", Name = name.Length == 0 ? "(Default)" : name,
                            Hive = h, View = v, SubKey = path, ValueName = name, Target = exe,
                            Why = "Starts with Windows, but the program it starts no longer exists (" + exe + ")."
                        });
                    }
                    catch (Exception) { }
                }
            }
        }

        static void CheckAppPaths(RegistryKey hive, RegistryHive h, RegistryView v, Action<RegIssue> add)
        {
            using (var ap = hive.OpenSubKey(AppPathsPath))
            {
                if (ap == null) return;
                foreach (var name in ap.GetSubKeyNames())
                {
                    try
                    {
                        using (var k = ap.OpenSubKey(name))
                        {
                            if (k == null || k.SubKeyCount > 0) continue;
                            string exe = CommandTarget(Convert.ToString(k.GetValue("")));
                            if (exe == null || !IsMissing(exe)) continue;
                            add(new RegIssue
                            {
                                Category = "App path", Name = name, Hive = h, View = v, SubKey = AppPathsPath + "\\" + name, Target = exe,
                                Why = "Lets Windows start \"" + name + "\" by name, but the program no longer exists (" + exe + ")."
                            });
                        }
                    }
                    catch (Exception) { }
                }
            }
        }

        static void CheckApplications(RegistryKey hive, RegistryHive h, RegistryView v, Action<RegIssue> add)
        {
            using (var apps = hive.OpenSubKey(ApplicationsPath))
            {
                if (apps == null) return;
                foreach (var name in apps.GetSubKeyNames())
                {
                    try
                    {
                        using (var c = apps.OpenSubKey(name + @"\shell\open\command"))
                        {
                            if (c == null) continue;
                            string exe = CommandTarget(Convert.ToString(c.GetValue("")));
                            if (exe == null || !IsMissing(exe)) continue;
                            add(new RegIssue
                            {
                                Category = "File association", Name = name, Hive = h, View = v, SubKey = ApplicationsPath + "\\" + name, Target = exe,
                                Why = "\"Open with\" " + name + ", but the program no longer exists (" + exe + ")."
                            });
                        }
                    }
                    catch (Exception) { }
                }
            }
        }

        /// <summary>
        /// The absolute .exe or .dll a command line refers to ("C:\x\a.exe" /s, C:\Program Files\x\a.exe -min,
        /// rundll32.exe C:\x\b.dll,Entry), environment variables expanded; null when it is not an absolute .exe/.dll path.
        /// </summary>
        internal static string CommandTarget(string cmd)
        {
            if (string.IsNullOrWhiteSpace(cmd)) return null;
            try { cmd = Environment.ExpandEnvironmentVariables(cmd.Trim()); } catch (Exception) { cmd = cmd.Trim(); }
            string first, rest;
            if (!SplitCommand(cmd, out first, out rest)) return null;
            string fn = Path.GetFileName(first).ToLowerInvariant();
            if (fn == "rundll32.exe" || fn == "rundll32")
            {
                string arg = rest.Trim(), dll, ignore;
                if (arg.StartsWith("\"")) { if (!SplitCommand(arg, out dll, out ignore)) return null; }
                else { int c = arg.IndexOf(','); dll = (c >= 0 ? arg.Substring(0, c) : arg).Trim(); }
                return IsAbsolute(dll) && dll.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) ? dll : null;
            }
            if (!IsAbsolute(first)) return null;
            return first.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || first.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) ? first : null;
        }

        static bool SplitCommand(string cmd, out string first, out string rest)
        {
            first = rest = "";
            if (cmd.StartsWith("\""))
            {
                int e = cmd.IndexOf('"', 1);
                if (e < 0) return false;
                first = cmd.Substring(1, e - 1).Trim();
                rest = cmd.Substring(e + 1);
                return first.Length > 0;
            }
            var m = Regex.Match(cmd, @"^(.+?\.(exe|dll|com))(?=[\s,]|$)", RegexOptions.IgnoreCase);
            if (m.Success) { first = m.Groups[1].Value.Trim(); rest = cmd.Substring(m.Length); return true; }
            int sp = cmd.IndexOf(' ');
            first = sp > 0 ? cmd.Substring(0, sp) : cmd;
            rest = sp > 0 ? cmd.Substring(sp) : "";
            return true;
        }

        static bool IsAbsolute(string p)
        {
            return p != null && p.Length >= 4 && char.IsLetter(p[0]) && p[1] == ':' && p[2] == '\\' && p.IndexOfAny(Path.GetInvalidPathChars()) < 0;
        }

        /// <summary>Paths we judge at all: on a drive that is present, outside Windows and Store app folders.</summary>
        static bool IsCheckablePath(string p)
        {
            if (!IsAbsolute(p)) return false;
            try { if (!Directory.Exists(Path.GetPathRoot(p))) return false; } catch (Exception) { return false; }   // a removed drive: not "broken"
            string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            if (!string.IsNullOrEmpty(win) && IsWithin(p, win)) return false;
            string low = p.ToLowerInvariant();
            if (low.Contains(@"\windowsapps\")) return false;
            return true;
        }

        /// <summary>The referenced program surely does not exist (and the path is one we judge).</summary>
        static bool IsMissing(string p)
        {
            if (!IsCheckablePath(p)) return false;
            try { return !File.Exists(p) && !Directory.Exists(p); } catch (Exception) { return false; }
        }

        // ---------------------------------------------------------------- removing

        /// <summary>Saves every entry to one .reg file, then deletes it (keys as keys, values as values). Returns the backup.</summary>
        static string RemoveRegIssues(List<RegIssue> items, List<string> errors, Action<RegIssue> progress)
        {
            Directory.CreateDirectory(BackupFolder);
            string backup = Path.Combine(BackupFolder, "Registry check " + DateTime.Now.ToString("yyyy-MM-dd HHmmss") + ".reg");
            foreach (var it in items)
            {
                if (progress != null) progress(it);
                bool saved = it.ValueName == null
                    ? ExportKey(new Leftover { Hive = it.Hive, View = it.View, SubKey = it.SubKey, IsRegistry = true }, backup)
                    : ExportValue(it, backup);
                if (!saved) { errors.Add(it.Display + "  -  could not be backed up, so it was kept"); continue; }
                try
                {
                    using (var hive = RegistryKey.OpenBaseKey(it.Hive, it.View))
                    {
                        if (it.ValueName == null) hive.DeleteSubKeyTree(it.SubKey, false);
                        else
                            using (var k = hive.OpenSubKey(it.SubKey, true))
                                if (k != null) k.DeleteValue(it.ValueName, false);
                    }
                }
                catch (Exception ex)
                {
                    errors.Add(it.Display + "  -  " + (ex is UnauthorizedAccessException || ex is System.Security.SecurityException ? "access denied (needs administrator)" : ex.Message));
                }
            }
            return File.Exists(backup) ? backup : null;
        }

        /// <summary>Appends one value to the .reg backup in regedit's format (Unicode, version 5.00).</summary>
        static bool ExportValue(RegIssue it, string backup)
        {
            try
            {
                object val;
                RegistryValueKind kind;
                using (var hive = RegistryKey.OpenBaseKey(it.Hive, it.View))
                using (var k = hive.OpenSubKey(it.SubKey))
                {
                    if (k == null) return false;
                    val = k.GetValue(it.ValueName, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                    if (val == null) return false;
                    kind = k.GetValueKind(it.ValueName);
                }
                var sb = new StringBuilder();
                if (!File.Exists(backup)) sb.Append("Windows Registry Editor Version 5.00\r\n");
                sb.Append("\r\n[").Append(it.KeyDisplay).Append("]\r\n");
                sb.Append(it.ValueName.Length == 0 ? "@" : "\"" + RegEscape(it.ValueName) + "\"").Append('=').Append(RegData(val, kind)).Append("\r\n");
                File.AppendAllText(backup, sb.ToString(), Encoding.Unicode);
                return true;
            }
            catch (Exception) { return false; }
        }

        static string RegEscape(string s) { return s.Replace("\\", "\\\\").Replace("\"", "\\\""); }

        internal static string RegData(object val, RegistryValueKind kind)
        {
            switch (kind)
            {
                case RegistryValueKind.String: return "\"" + RegEscape(Convert.ToString(val)) + "\"";
                case RegistryValueKind.DWord: return "dword:" + unchecked((uint)Convert.ToInt32(val)).ToString("x8");
                case RegistryValueKind.ExpandString: return "hex(2):" + Hex(Encoding.Unicode.GetBytes(Convert.ToString(val) + "\0"));
                case RegistryValueKind.MultiString: return "hex(7):" + Hex(Encoding.Unicode.GetBytes(string.Join("\0", (string[])val) + "\0\0"));
                case RegistryValueKind.QWord: return "hex(b):" + Hex(BitConverter.GetBytes(Convert.ToInt64(val)));
                case RegistryValueKind.Binary: return "hex:" + Hex((byte[])val);
                default: return "hex(0):";
            }
        }

        static string Hex(byte[] b) { return string.Join(",", b.Select(x => x.ToString("x2"))); }
    }
}

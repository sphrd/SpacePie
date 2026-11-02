using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Principal;
using System.Text;

namespace DiskSpaceAnalyzer
{
    /// <summary>
    /// "Always start as administrator" without a UAC prompt on every start: a scheduled task that runs this exe with the
    /// highest privileges, for the signed-in user, only when started on demand. Creating or removing the task needs one UAC
    /// prompt; after that a normal start runs the task (passing its arguments through a small file) and exits, so the app
    /// opens elevated. A marker file keeps the normal start cheap when the option is off.
    /// </summary>
    internal static class Elevation
    {
        public const string DefaultTaskName = "Disk Space Analyzer (as administrator)";
        internal static string TaskName = DefaultTaskName;

        static string DataDir { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DiskSpaceAnalyzer"); } }
        static string MarkerFile { get { return Path.Combine(DataDir, "always-admin"); } }
        static string ArgsFile { get { return Path.Combine(DataDir, "task-args.txt"); } }

        public static bool IsAdmin
        {
            get { return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator); }
        }

        /// <summary>The option is on (marker present); cheap, no process started.</summary>
        public static bool MarkedOn { get { return File.Exists(MarkerFile); } }

        /// <summary>The exe the task starts, or null when there is no task.</summary>
        public static string TaskTarget()
        {
            string xml;
            if (Schtasks("/query /tn \"" + TaskName + "\" /xml", out xml) != 0) return null;
            return ParseCommand(xml);
        }

        internal static string ParseCommand(string xml)
        {
            int i = xml.IndexOf("<Command>", StringComparison.OrdinalIgnoreCase);
            if (i < 0) return null;
            int e = xml.IndexOf("</Command>", i, StringComparison.OrdinalIgnoreCase);
            if (e < 0) return null;
            return SecurityElement.FromString("<x>" + xml.Substring(i + 9, e - i - 9) + "</x>").Text.Trim().Trim('"');
        }

        /// <summary>The task points at this exe.</summary>
        public static bool IsOnForThisCopy()
        {
            if (!MarkedOn) return false;
            string t = TaskTarget();
            return t != null && string.Equals(Path.GetFullPath(t), Path.GetFullPath(ExePath), StringComparison.OrdinalIgnoreCase);
        }

        static string ExePath { get { return System.Windows.Forms.Application.ExecutablePath; } }

        /// <summary>Task definition: runs the exe on demand only, elevated, for the signed-in user, in their session.</summary>
        internal static string TaskXml(string exe, string userSid)
        {
            Func<string, string> esc = SecurityElement.Escape;
            return "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\r\n" +
                "<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">\r\n" +
                "  <RegistrationInfo><Author>Disk Space Analyzer</Author><Description>Starts Disk Space Analyzer as administrator without a prompt " +
                "(turned on in its About window; turn it off there).</Description></RegistrationInfo>\r\n" +
                "  <Principals><Principal id=\"Author\"><UserId>" + esc(userSid) + "</UserId><LogonType>InteractiveToken</LogonType>" +
                "<RunLevel>HighestAvailable</RunLevel></Principal></Principals>\r\n" +
                "  <Settings><MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>" +
                "<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>false</StartWhenAvailable>" +
                "<AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>false</Hidden><ExecutionTimeLimit>PT0S</ExecutionTimeLimit>" +
                "<Priority>5</Priority></Settings>\r\n" +
                "  <Actions Context=\"Author\"><Exec><Command>\"" + esc(exe) + "\"</Command><Arguments>--from-task</Arguments>" +
                "<WorkingDirectory>" + esc(Path.GetDirectoryName(exe)) + "</WorkingDirectory></Exec></Actions>\r\n" +
                "</Task>\r\n";
        }

        /// <summary>Creates (or replaces) the task for this exe. Needs administrator rights.</summary>
        public static string Enable()
        {
            if (!IsAdmin) return "needs administrator rights";
            string file = Path.Combine(Path.GetTempPath(), "dsa-task-" + Guid.NewGuid().ToString("N") + ".xml");
            try
            {
                File.WriteAllText(file, TaskXml(ExePath, WindowsIdentity.GetCurrent().User.Value), Encoding.Unicode);
                string output;
                if (Schtasks("/create /tn \"" + TaskName + "\" /xml \"" + file + "\" /f", out output) != 0) return FirstLine(output);
                if (TaskName == DefaultTaskName) { Directory.CreateDirectory(DataDir); File.WriteAllText(MarkerFile, ExePath); }
                return null;
            }
            catch (Exception ex) { return ex.Message; }
            finally { try { File.Delete(file); } catch (Exception) { } }
        }

        /// <summary>Removes the task. Needs administrator rights.</summary>
        public static string Disable()
        {
            if (!IsAdmin) return "needs administrator rights";
            string output;
            int code = Schtasks("/delete /tn \"" + TaskName + "\" /f", out output);
            if (TaskName == DefaultTaskName) try { File.Delete(MarkerFile); } catch (Exception) { }
            return code == 0 || TaskTarget() == null ? null : FirstLine(output);
        }

        /// <summary>
        /// Turns the option on or off from a normal (not elevated) window: one UAC prompt for an elevated copy of this exe
        /// that does only that. Returns null on success, else why not.
        /// </summary>
        public static string SetFromUser(bool on)
        {
            if (IsAdmin) return on ? Enable() : Disable();
            try
            {
                var p = Process.Start(new ProcessStartInfo(ExePath, "--admin-task " + (on ? "on" : "off")) { Verb = "runas", UseShellExecute = true });
                p.WaitForExit();
                if (p.ExitCode != 0) return "the change could not be made (code " + p.ExitCode + ")";
                return null;
            }
            catch (System.ComponentModel.Win32Exception) { return "cancelled"; }
        }

        /// <summary>
        /// Normal start with the option on: run the task with these arguments and return true (the caller exits). False when
        /// the option is off, the task is missing or points at another copy of the app, or it could not be started.
        /// </summary>
        public static bool TryStartElevated(string[] args)
        {
            if (IsAdmin || !MarkedOn) return false;
            try
            {
                if (!IsOnForThisCopy()) return false;
                File.WriteAllLines(ArgsFile, args);
                AllowSetForegroundWindow(-1);   // ASFW_ANY: the elevated window may come to the front
                string output;
                if (Schtasks("/run /tn \"" + TaskName + "\"", out output) == 0) return true;
                try { File.Delete(ArgsFile); } catch (Exception) { }
            }
            catch (Exception) { }
            return false;
        }

        /// <summary>Arguments handed over by the normal start (empty if none); the file is used once.</summary>
        public static string[] TakeTaskArgs()
        {
            try
            {
                if (!File.Exists(ArgsFile)) return new string[0];
                var a = File.ReadAllLines(ArgsFile);
                File.Delete(ArgsFile);
                return a;
            }
            catch (Exception) { return new string[0]; }
        }

        internal static int Schtasks(string args, out string output)
        {
            var psi = new ProcessStartInfo("schtasks.exe", args)
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
            };
            using (var p = Process.Start(psi))
            {
                var err = p.StandardError.ReadToEndAsync();
                output = p.StandardOutput.ReadToEnd();
                p.WaitForExit();
                output += err.Result;
                return p.ExitCode;
            }
        }

        static string FirstLine(string s)
        {
            s = (s ?? "").Trim();
            int i = s.IndexOf('\n');
            return i > 0 ? s.Substring(0, i).Trim() : s;
        }

        [DllImport("user32.dll")]
        static extern bool AllowSetForegroundWindow(int processId);
    }
}

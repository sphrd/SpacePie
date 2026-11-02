using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Management;

namespace DiskSpaceAnalyzer
{
    /// <summary>A fixed drive: free and total space, and the health of the physical disk under it when Windows reports it.</summary>
    internal sealed class DriveHealth
    {
        public string Root = "";            // "C:\"
        public string Label = "";
        public long Free, Total;
        /// <summary>Healthy, Warning or Unhealthy; empty when unknown.</summary>
        public string Health = "";
        public string Operational = "", Media = "", Model = "";
        public int Temperature = -1, Wear = -1;
        public long ReadErrors = -1;

        public double FreePercent { get { return Total > 0 ? 100.0 * Free / Total : 100; } }
        /// <summary>Less than 10 % or less than 10 GB free.</summary>
        public bool LowSpace { get { return Total > 0 && (Free < (10L << 30) || FreePercent < 10); } }
        public bool IsWarning { get { return Health == "Warning"; } }
        public bool IsUnhealthy { get { return Health == "Unhealthy"; } }
        public string Letter { get { return Root.TrimEnd('\\'); } }

        /// <summary>One line in plain words: "Healthy SSD, 38 °C, 3 % worn" / "health unknown".</summary>
        public string HealthText
        {
            get
            {
                var parts = new List<string>();
                string head = Health.Length == 0 ? "health unknown" : Health + (Media.Length > 0 ? " " + Media : "");
                parts.Add(head);
                if (Operational.Length > 0 && Operational != "OK") parts.Add(Operational.ToLowerInvariant());
                if (Temperature > 0) parts.Add(Temperature + " \u00b0C");
                if (Wear >= 0) parts.Add(Wear + " % worn");
                if (ReadErrors > 0) parts.Add(ReadErrors.ToString("N0") + " read errors");
                return string.Join(", ", parts);
            }
        }
    }

    /// <summary>Drive space and disk health (Storage WMI: MSFT_PhysicalDisk, MSFT_StorageReliabilityCounter).</summary>
    internal static class Health
    {
        /// <summary>Fixed, ready drives with free/total; with WMI also the health of their disk (no admin needed for most).</summary>
        public static List<DriveHealth> ReadDrives(bool withHealth)
        {
            var list = new List<DriveHealth>();
            foreach (var d in DriveInfo.GetDrives())
            {
                try
                {
                    if (d.DriveType != DriveType.Fixed || !d.IsReady) continue;
                    list.Add(new DriveHealth { Root = d.Name, Label = d.VolumeLabel ?? "", Free = d.AvailableFreeSpace, Total = d.TotalSize });
                }
                catch (Exception) { }
            }
            if (withHealth) try { AddHealth(list); } catch (Exception) { }
            return list;
        }

        static void AddHealth(List<DriveHealth> drives)
        {
            var scope = new ManagementScope(@"\\.\root\Microsoft\Windows\Storage");
            scope.Connect();
            var opts = new EnumerationOptions { Timeout = TimeSpan.FromSeconds(20), ReturnImmediately = false };
            // Drive letter -> disk number (a partition with a letter).
            var diskOf = new Dictionary<char, string>();
            using (var s = new ManagementObjectSearcher(scope, new ObjectQuery("SELECT DriveLetter, DiskNumber FROM MSFT_Partition"), opts))
                foreach (ManagementObject o in s.Get())
                {
                    try
                    {
                        object dl = o["DriveLetter"];
                        if (dl == null) continue;
                        char c = char.ToUpperInvariant(Convert.ToChar(dl));
                        if (c >= 'A' && c <= 'Z') diskOf[c] = Convert.ToString(o["DiskNumber"]);
                    }
                    catch (Exception) { }
                    finally { o.Dispose(); }
                }
            var disks = new Dictionary<string, DriveHealth>();
            using (var s = new ManagementObjectSearcher(scope, new ObjectQuery("SELECT * FROM MSFT_PhysicalDisk"), opts))
                foreach (ManagementObject o in s.Get())
                {
                    try
                    {
                        var h = new DriveHealth
                        {
                            Model = Convert.ToString(o["FriendlyName"]) ?? "",
                            Health = HealthName(o["HealthStatus"]),
                            Media = MediaName(o["MediaType"]),
                            Operational = OperationalName(o["OperationalStatus"])
                        };
                        try
                        {
                            foreach (ManagementObject r in o.GetRelated("MSFT_StorageReliabilityCounter"))
                            {
                                h.Temperature = ToInt(r["Temperature"], -1);
                                h.Wear = ToInt(r["Wear"], -1);
                                object re = r["ReadErrorsTotal"];
                                if (re != null) h.ReadErrors = Convert.ToInt64(re);
                                r.Dispose();
                                break;
                            }
                        }
                        catch (Exception) { }   // the counters often need administrator rights
                        disks[Convert.ToString(o["DeviceId"])] = h;
                    }
                    catch (Exception) { }
                    finally { o.Dispose(); }
                }
            foreach (var d in drives)
            {
                string num;
                DriveHealth h;
                if (d.Root.Length == 0 || !diskOf.TryGetValue(char.ToUpperInvariant(d.Root[0]), out num) || !disks.TryGetValue(num, out h)) continue;
                d.Health = h.Health;
                d.Media = h.Media;
                d.Operational = h.Operational;
                d.Model = h.Model;
                d.Temperature = h.Temperature;
                d.Wear = h.Wear;
                d.ReadErrors = h.ReadErrors;
            }
        }

        static int ToInt(object v, int fallback)
        {
            try { return v == null ? fallback : Convert.ToInt32(v); } catch (Exception) { return fallback; }
        }

        internal static string HealthName(object v)
        {
            switch (ToInt(v, -1))
            {
                case 0: return "Healthy";
                case 1: return "Warning";
                case 2: return "Unhealthy";
                default: return "";
            }
        }

        static string MediaName(object v)
        {
            switch (ToInt(v, -1))
            {
                case 3: return "HDD";
                case 4: return "SSD";
                case 5: return "SCM";
                default: return "";
            }
        }

        static string OperationalName(object v)
        {
            var arr = v as Array;
            int code = arr != null && arr.Length > 0 ? ToInt(arr.GetValue(0), -1) : ToInt(v, -1);
            switch (code)
            {
                case 2: return "OK";
                case 3: return "Degraded";
                case 5: return "Predictive failure";
                case 6: return "Error";
                case 10: return "Stopped";
                case 11: return "In service";
                case 13: return "Lost communication";
                case -1: return "";
                default: return "";
            }
        }

        /// <summary>The fixed drives that are almost full (less than 10 % or 10 GB free).</summary>
        public static List<DriveHealth> LowDrives(IEnumerable<DriveHealth> drives)
        {
            return drives.Where(d => d.LowSpace).ToList();
        }
    }
}

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Microsoft.Win32;

namespace DiskSpaceAnalyzer
{
    /// <summary>
    /// The installed-apps list as last read (names, versions, folders, uninstall keys, sizes, logos), so the Apps tab shows
    /// it at once on the next start while it is read again in the background. %LOCALAPPDATA%\DiskSpaceAnalyzer\apps.bin.
    /// </summary>
    internal static class AppsCache
    {
        const int Version = 1;
        internal static string FileOverride;   // self-test

        static string FilePath
        {
            get { return FileOverride ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"DiskSpaceAnalyzer\apps.bin"); }
        }

        public static void Save(List<InstalledApp> apps)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
                string tmp = FilePath + ".tmp";
                using (var w = new BinaryWriter(File.Create(tmp)))
                {
                    var list = apps.Where(a => !a.Uninstalled).ToList();
                    w.Write(Version);
                    w.Write(list.Count);
                    foreach (var a in list)
                    {
                        foreach (var s in new[] { a.Name, a.Publisher, a.Version, a.InstallDate, a.Location, a.UninstallString, a.QuietUninstallString, a.ProductCode,
                                                  a.KeyName, a.KeyPath, a.PackageFullName, a.PackageFamilyName, a.SharedWith, a.IconSource })
                            w.Write(s ?? "\0");
                        w.Write((int)a.Hive); w.Write((int)a.View);
                        w.Write(a.IsMsi); w.Write(a.IsStore);
                        w.Write(a.Size); w.Write(a.EstimatedSize);
                        byte[] png = null;
                        if (a.Icon != null)
                            using (var ms = new MemoryStream()) { a.Icon.Save(ms, System.Drawing.Imaging.ImageFormat.Png); png = ms.ToArray(); }
                        w.Write(png == null ? 0 : png.Length);
                        if (png != null) w.Write(png);
                    }
                }
                if (File.Exists(FilePath)) File.Delete(FilePath);
                File.Move(tmp, FilePath);
            }
            catch (Exception) { }
        }

        public static List<InstalledApp> Load()
        {
            try
            {
                if (!File.Exists(FilePath)) return null;
                using (var r = new BinaryReader(File.OpenRead(FilePath)))
                {
                    if (r.ReadInt32() != Version) return null;
                    int n = r.ReadInt32();
                    var list = new List<InstalledApp>(n);
                    Func<string> S = () => { string s = r.ReadString(); return s == "\0" ? null : s; };
                    for (int i = 0; i < n; i++)
                    {
                        var a = new InstalledApp
                        {
                            Name = S() ?? "", Publisher = S() ?? "", Version = S() ?? "", InstallDate = S() ?? "", Location = S() ?? "",
                            UninstallString = S(), QuietUninstallString = S(), ProductCode = S(), KeyName = S(), KeyPath = S(),
                            PackageFullName = S(), PackageFamilyName = S(), SharedWith = S(), IconSource = S()
                        };
                        a.Hive = (RegistryHive)r.ReadInt32(); a.View = (RegistryView)r.ReadInt32();
                        a.IsMsi = r.ReadBoolean(); a.IsStore = r.ReadBoolean();
                        a.Size = r.ReadInt64(); a.EstimatedSize = r.ReadInt64();
                        int len = r.ReadInt32();
                        if (len > 0) using (var ms = new MemoryStream(r.ReadBytes(len))) a.Icon = new System.Drawing.Bitmap(System.Drawing.Image.FromStream(ms));
                        list.Add(a);
                    }
                    return list;
                }
            }
            catch (Exception) { return null; }
        }

        /// <summary>The same app in two readings: its uninstall key, or its Store package family.</summary>
        public static string Identity(InstalledApp a)
        {
            return a.IsStore ? "store|" + (a.PackageFamilyName ?? a.Name) : (int)a.Hive + "|" + (int)a.View + "|" + a.KeyPath;
        }
    }
}

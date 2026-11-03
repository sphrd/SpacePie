using System;
using System.IO;

namespace SpacePie
{
    /// <summary>Where the app keeps its data: %LOCALAPPDATA%\SpacePie.</summary>
    internal static class AppData
    {
        public static readonly string Dir =
            System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SpacePie");

        public static string Path(string relative) { return System.IO.Path.Combine(Dir, relative); }
    }
}

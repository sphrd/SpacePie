using System;
using System.Collections.Generic;
using System.Drawing;

namespace SpacePie
{
    /// <summary>
    /// Marks on the chart besides the hover: the selected rows of the list (each drawn like a hovered section, all of them
    /// at once) and what is on the delete list (drawn red). Set from the list with SetMarks after every SetData.
    /// </summary>
    internal sealed partial class PieChart
    {
        readonly HashSet<int> markSlices = new HashSet<int>(), doomSlices = new HashSet<int>();
        // Selected folders inside slices (rows of expanded folders): slice and folder, resolved to the drawn section.
        readonly List<KeyValuePair<int, DirNode>> markDirs = new List<KeyValuePair<int, DirNode>>();
        readonly HashSet<int> markArcs = new HashSet<int>();
        Func<DirNode, bool> doomedDir;
        readonly Dictionary<DirNode, bool> doomCache = new Dictionary<DirNode, bool>();

        /// <summary>
        /// selected: slice and folder of each selected row (folder null = the whole slice); doomed: slices whose rows are all
        /// on the delete list; doomedDir: whether a folder (an outer-ring section or treemap tile) is on it.
        /// </summary>
        public void SetMarks(IEnumerable<KeyValuePair<int, DirNode>> selected, IEnumerable<int> doomed, Func<DirNode, bool> doomedDir)
        {
            markSlices.Clear(); markDirs.Clear(); markArcs.Clear(); doomSlices.Clear(); doomCache.Clear();
            this.doomedDir = doomedDir;
            if (selected != null)
                foreach (var kv in selected)
                {
                    if (kv.Key < 0 || kv.Key >= slices.Count) continue;
                    if (kv.Value == null) markSlices.Add(kv.Key);
                    else markDirs.Add(kv);
                }
            if (doomed != null) foreach (int i in doomed) if (i >= 0 && i < slices.Count) doomSlices.Add(i);
            // A selected folder lights its section in the outer rings, or the nearest parent section drawn, else its slice.
            if (markDirs.Count > 0)
            {
                var byDir = new Dictionary<DirNode, int>();
                for (int i = 0; i < arcs.Count; i++) byDir[arcs[i].Dir] = i;
                foreach (var kv in markDirs)
                {
                    int found = -1;
                    for (var d = kv.Value; d != null && found < 0; d = d.Parent)
                    {
                        int a;
                        if (byDir.TryGetValue(d, out a) && arcs[a].Owner == kv.Key) found = a;
                    }
                    if (found >= 0) markArcs.Add(found);
                    else markSlices.Add(kv.Key);
                }
            }
            Invalidate();
        }

        void ClearMarks()
        {
            markSlices.Clear(); markDirs.Clear(); markArcs.Clear(); doomSlices.Clear(); doomCache.Clear();
            doomedDir = null;
        }

        bool Doomed(DirNode d)
        {
            if (d == null || doomedDir == null) return false;
            bool v;
            if (!doomCache.TryGetValue(d, out v)) doomCache[d] = v = doomedDir(d);
            return v;
        }

        bool SliceLit(int i) { return i == hover && hoverArc < 0 && hoverTile < 0 || markSlices.Contains(i); }

        /// <summary>The level an outer-ring section grows from (0 = its slice is lit; -1 = not lit): the hovered or selected
        /// section highest above it.</summary>
        int ArcLitFrom(int i)
        {
            int from = -1;
            var a = arcs[i];
            if (hover >= 0 && hoverArc < 0 && a.Owner == hover || markSlices.Contains(a.Owner)) return 0;
            for (int j = i; j >= 0; j = arcs[j].Parent)
                if (j == hoverArc || markArcs.Contains(j)) from = arcs[j].Level;
            return from;
        }

        bool ArcDoomed(int i) { return doomSlices.Contains(arcs[i].Owner) || Doomed(arcs[i].Dir); }

        /// <summary>A section's colour: red when on the delete list, lighter when hovered or selected.</summary>
        static Color MarkColor(Color c, bool lit, bool doomed)
        {
            if (doomed) return lit ? Theme.DANGER_HOVER : Theme.DANGER;
            return lit ? Blend(c, Theme.HOVER, Theme.HOVER_MIX) : c;
        }

        /// <summary>Treemap tiles of the selected rows (a folder too deep to have a tile: its nearest parent's, else its slice's).
        /// Worked out at each paint (the tiles are laid out then).</summary>
        HashSet<int> MarkedTiles()
        {
            var set = new HashSet<int>();
            if (markSlices.Count == 0 && markDirs.Count == 0) return set;
            var byDir = new Dictionary<DirNode, int>();
            for (int i = 0; i < tiles.Count; i++)
            {
                var t = tiles[i];
                if (t.Level == 0) { if (markSlices.Contains(t.Slice)) set.Add(i); }
                else if (t.Dir != null) byDir[t.Dir] = i;
            }
            foreach (var kv in markDirs)
            {
                int found = -1;
                for (var d = kv.Value; d != null && found < 0; d = d.Parent)
                {
                    int ti;
                    if (byDir.TryGetValue(d, out ti) && tiles[ti].Slice == kv.Key) found = ti;
                }
                if (found < 0) for (int i = 0; i < tiles.Count; i++) if (tiles[i].Level == 0 && tiles[i].Slice == kv.Key) { found = i; break; }
                if (found >= 0) set.Add(found);
            }
            return set;
        }

        bool TileLit(int i, HashSet<int> marked)
        {
            var t = tiles[i];
            return i == hoverTile || t.Level == 0 && t.Slice == hover && hoverTile < 0 || marked.Contains(i);
        }

        bool TileDoomed(int i)
        {
            var t = tiles[i];
            return doomSlices.Contains(t.Slice) || t.Level > 0 && Doomed(t.Dir);
        }
    }
}

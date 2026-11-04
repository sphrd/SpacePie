# APP_NOTES — SpacePie

Project notes for the App Engineer agent (`app-engineer.agent.md` from `sphrd/Agents`, stack-agnostic version).
This project is C# WinForms on the in-box .NET Framework 4.x; the design language (Part 2) and interaction
patterns (Part 3) are applied through the WinForms mapping below.

## Locations

| What | Where |
|---|---|
| Entry point (GUI + headless `--cli scan <folder>`, alias `--scan <folder>`) | `src/Program.cs` |
| Main window (layout, wiring, all behavior) | `src/MainForm.cs` |
| Theme tokens (palette, fonts), drawing helpers, DWM interop | `src/Theme.cs` |
| Widgets: RoundButton, RoundedPanel, PathInput, PillScrollBar, ScrollHost, BusyOverlay, Spinner, ScanBar, DarkRenderer, Banner, Breadcrumb | `src/Widgets.cs` |
| Views bar on the left (icon + name rows, scrolls) | `src/NavRail.cs` |
| Full text on hover for anything drawn cut off (`CutText`, `EllipsisLabel`) | `src/CutText.cs` |
| List view (rows, bars, header, empty-state hint) + sorting | `src/Controls.cs` |
| Self-update (GitHub latest release, download, verify, swap) and the update flow (`UpdateManager`) | `src/Updater.cs` |
| About window and update window, both on the shared `AppDialog` frame (logo left, content column, buttons bottom right) | `src/About.cs` |
| Pie chart pane (donut linked to the contents list) | `src/Chart.cs` |
| Scanner / deleter / interop (domain, not UI) | `src/Scanner.cs`, `src/Deleter.cs`, `src/Native.cs` |
| Asset generator (icon `.ico`, 256 px `app.png` for the README, 1280x640 `social-preview.png` for GitHub) | `tools/make_icon.ps1` (run by every build) |
| macOS app (Swift + AppKit, one target) | `macos/Sources/SpacePie/*.swift`; `Tokens.swift` is generated from `src/Theme.cs` by `macos/gen_tokens.py` (git-ignored) |
| macOS build | `macos/build.sh` -> universal `SpacePie.app` (arm64 + x86_64), ad-hoc signed, packed into `SpacePie-macOS.dmg` at the repo root; version from `src/Program.cs`, icon from `assets/app-1024.png` |
| Build script | `build.ps1` -> compiles into `bin/`, moves `SpacePie.exe` to the repo root (git-ignored), deletes `bin/` |
| Version | `src/Program.cs` (`AssemblyVersion` / `AssemblyFileVersion`), `src/app.manifest` |
| Data folder | `src/AppData.cs`, `macos/Sources/SpacePie/AppData.swift` |

## App identity

- Name: **SpacePie** (since v2.0.0; 1.x was "Disk Space Analyzer"). Subtitle everywhere: "fast disk space analyzer and
  cleaner". Repo: `sphrd/SpacePie` (renamed from `sphrd/DiskSpaceAnalyzer`; GitHub redirects the old URLs). License: MIT.
- Files: `SpacePie.exe`, `SpacePie-macOS.dmg` with `SpacePie.app` (executable `SpacePie`); scan files `.spacepie`.
- AppUserModelID: `sphrd.SpacePie`. macOS bundle id: `com.sphrd.SpacePie`. Scheduled task: `SpacePie (as administrator)`.
- Data: `%LOCALAPPDATA%\SpacePie`, `~/Library/Application Support/SpacePie`.
- No compatibility with the 1.x names (there were no users): no old asset names, data folder, task or `.dsascan`.
  Internal names stay as they are: the history archive `.dsa`, the scan-file magic "DSASCAN1", self-test fixtures "DSA ...".
- Icon concept: **a pie chart shaped like Pac-Man facing left = disk usage analyzer that frees space.** No tile
  (transparent background) everywhere: exe/window/taskbar icon, README logo, social preview and the in-app logo.
  One circle split by colour, shading dark -> light from top left via the right half to bottom left: upper-left
  `#3d6bcc`, right half `#5e88e6`, lower-left `#81a2eb` (tuned by the user from Tailwind CSS blue 800 / 600 / 400), mouth on the left; the left
  sections run a few degrees under the right half, so there are no seams. Checked at 16 / 24 / 32 / 48 / 256 px on dark
  and light backgrounds.
- **Logo colours are edited in one place: the `LOGO_TOP_LEFT` / `LOGO_RIGHT` / `LOGO_BOTTOM_LEFT` lines in
  `src/Theme.cs`.** `tools/make_icon.ps1` reads them (and all other colours it uses) from `Theme.cs`, so `build.ps1`
  regenerates the exe icon, `assets/app.png` and `assets/social-preview.png` to match the in-app logo.
- Primary action: **Scan**. Destructive action: **Delete permanently** (warn kind, amber).
- Domain status strings: `Scanning: <n> folders, <n> files, <size> so far` (no known total, so no `i/n`),
  `Cancelling... (finishing current folder)`, `Deleting: <n> files removed`, detail line = current path (muted).

## User requirements

- 2026-10-27: "I wanna creat a new free, open source, fast windows disk space analyzer and cleaner. to analyze
  the sizes of dirs and subdirs fastest possible way, and give the option to permenantly delete files to open
  up space." ... "can be a simple small size app with a gui. a new project to be committed to my sphrd github account."
- 2026-10-27: "use the app-engineer.agent.md from my sphrd/Agents github repo. restyle the app's theme without
  changing functionality."
- 2026-10-27: "build script should buildthe exe from src and copy it to repo root folder."
- 2026-10-27: "reread the app design agent form github. the restrictions are changed. the app logo should be changed.
  i prefer something similar to pacman logo here. like a pie chart missing a pice on the right side that symbolizes
  disk space. theres a bug in the app when hovering over the right side window the calculated sizes disappear.
  until i click which then they come back. also in the left side panel add always visible columns to show size and
  percentage on the right side of it, not attached to the names so this way they orm a column for a cleaner read."
- 2026-10-27: "the icon has a cut, why? the pie chart is not cut smoothly. make it smooth. put a half circle (right side),
  then on the left side add two smaller circle sections above and below each with a slightly different shade of blue,
  in a way that looks like pacman, but flipped form current version."
- 2026-10-27: "the circles radius ar enot matching! fix it. it should look like a smooth circle separate only by color.
  remove the gap. wait with commit or releasing until i tell u. why did u put a screenshot of my pc analysis on the github????"
- 2026-10-27: "i need a macos and macos arm (M series) version released as well. whats the effort for that? can we keep it this fast?"

- 2026-10-27: "after hte app is opened, it should automatically start analyzing the entire disk. show the percentage in
  the left pane as a bar as well. show the external drives as well, and for them only scan manually. add a graphical
  pie chart view on the right of app (a new pane) without compromising speed. the chart should show free storage as
  well, and it should show currently selected (the main drive - C - after startup)"
- 2026-10-27: window size question answered: "Open at 1500x880 (shrunk to fit smaller screens)".
- 2026-10-27: "make the screenshot, with fake data, and commit and push and release all. use the Logo for the repo's
  description as well."
- 2026-10-27: "the scan should not block the page. it should run with a bar on the top of app showing the progress and
  scan data."
- 2026-10-28: "the right pane should only have the pie chart and not the list below it. thats redundant. instead when
  hovering on the pie chart sectors the app should highlight the path in the middle pane, and vice versa. the pie chart
  should represent the middle pane exactly by its order. when categorizing them as others (small files) it should
  highlight multiple items that belong there."
- 2026-10-28: "make the free space section fo the chart, empty. align it always in a way that the mid line of the free pie
  section, is aligned with the vertical line and is at the top."
- 2026-10-28: "remove the dashed line. there should be nothing. dont show the chart before scan is done. or show the app
  logo and then transform animation into the chart."
- 2026-10-28: "put the logo wihtout th ebackground, and the circle of the logo should be aligned with the charts position and
  size. put the free space section where it was, on the left of the top vertical line."
- 2026-10-28: "change the colors of the logo's circle. make them darker blue. put the color of thebottom left arc into the
  right hald circle, and the color of the icon background to the two left side arcs. remove the icon backgroun as well
  everywhere (only the reverse pacman)"
- 2026-10-28: "no, make the right one a darker blue, top left one darker than that, and bottom left one, lighter than the
  right one. so like a shade going from top left to bottom left from dark blue to light blue. use mainstream good
  looking shades. point out where i can adjust colors manually"
- 2026-10-28: "when someone has the app downloaded, and a newer release is available, how to add an update manager section?
  to prompt them and take them to the download page. and then download and replace current version."
- 2026-10-28: "also add about, and check for updates menu to the app. about shows version and author as sphrd. after that
  commit and push all, replace the release."
- 2026-10-28: "do the macos dmg. but before that, why did you put the about and update in the help button? make it a menu bar
  item on the top. make two buttons About, Check for updates. Also update the design language and choices into the App
  design agent file on github."
- 2026-10-28 (macOS): user asked for the macOS dmg in the same repository and the same release flow; Mac available for
  final hands-on checks.
- 2026-10-28: "the update prompt, whether its to say you have the latest version, or else should be in the same looking
  window as the about window. fix that, and update app design agent."
- 2026-10-28: "why the menu bar is there? it should be next to the apps logo and name. on that bar. like every other app."
- 2026-10-28: "reduce the default app size. it doesnt fit in my screen." (1920x1080 at 125 %: 1500x880 became
  1875x995 px and `CenterScreen` pushed it below the taskbar.)
- 2026-10-28: "What other functionalities we can add to the app to make it competetive in its area?" Chosen: master file
  table reading (WizTree speed), multi-ring chart, cleanup suggestions, collect-then-delete list with Recycle Bin option,
  largest files view, file-type breakdown, duplicate finder, old files filter, search and filter, compare with the last
  scan, CSV/HTML export, size on disk vs file size (compressed, sparse, hard links, OneDrive online-only), refresh after
  changes (live updates).

- 2026-10-28: "14-check self-test runs on both platforms in CI. what does it mean? do you save every scan? that builds up in
  size, save only last one. in about section mention that running as admin will increase speed. also mention the keyboard
  shortcuts." + crash report: PathTooLongException in ApplyChanges (live updates) when run as administrator.
- 2026-10-28: "in the chart, when not hovering on pies, instead of writing total in the middle right the name of hte current dir.
  also make it clickable so that i can jump one dir above by clicking. (as a way to reverse the click on one of the pies).
  default to Size on disk instead of Size. The pie chart is not animating transforming from the logo now, why?"

- 2026-10-29: "the mac app takes very long on some files, they were logicx files on my icloud ... it shouldnt be downloading
  the files ... in the dmg make the arrow to show u need to drag the app into Applications folder. on first run, prompt the user to
  give full disk access ... as the default make the size of the right pane bigger so that it is a square when opened up.
  (maximum chart radius) on the Readme and github page, re-read the whole doc and redo it. everything that was for earlier
  versions should be deleted. "Why" section is pointless ... some mentions of keyboard shortcuts are just for Windows version."
- 2026-10-29: "after full disk access or run as admin has been done, the button should disappear. I noticed a bug, when i had a
  large folder in the delete list and deleted it but some files were in use so they didnt delete, in the delete list the size was
  shown as the initial size, not the one after partial delete. Also change the shortcuts to cmd+D/ctrl+D for add to delte list, and
  cmd+shift+D/ctrl+shift+D for permanent delete. Also in the suggestion tab, ther is no button to delete all the suggested
  permanently. there should also be a selector for the suggested files that has also the tree browser with select all deselect
  all buttons, so that user can customize seletion and delete direvtly form there. also give a disinguishing color to the
  suggestion tab."

- 2026-10-29: "after deleting files outside the program, in the suggestion tab i see still the old suggestions even after re
  scanning. Also when hovering show full file name an path."

- 2026-10-29: "suggestions tab: only refresh, select all, deselect all, permanent delete buttons. that it. make these buttons
  smaller. for the refresh and the rescan put a circular arrow button. app should open in suggestions, put it in the first tab.
  make the font of the maount that can be freed larger and mke it bold so it pops out more. when hovering on items (both left and
  middle pane) i still dont see the preview that shows full path and name of the file next to the cursor (or bundled paths for
  suggestions in different dirs)"

- 2026-10-29: "make the chart window a bit smaller by default. make the Contents tab the default tab again. then u can commit and
  release" (asked: Contents first and opens there, Suggestions second).

- 2026-10-29: "lets add application uninstaller. with fully removing all dependancies of the app. later we can add a registry file
  checker." Chosen: Apps tab after Suggestions; official uninstaller first, then leftovers; Windows registry leftovers with a .reg
  backup; Microsoft Store apps included; macOS too. Registry checker: later.

- 2026-10-29: "not same as windows, i want it to show the app when u open th etree to show all the files that have been added by that
  app, after official uninnstaller runs, it should recheck the remainder of files and ask to delete them as well." Confirmed: both
  platforms; macOS: one confirmation, app and all its files to the Trash together.

- 2026-10-29: "show the app logos for the apps found." Both platforms.

- 2026-10-29: "there are lots of bugs now when im trying to open the arrow of each app, i dont understand where the app goes. it
  doesnt expand, some apps that show up as folders move around... check it." Causes (Windows): apps with found items were sorted
  to the top, so expanding moved the app away; nothing showed while searching and the arrow vanished when nothing was found;
  apps sharing a folder had no arrow; double-click opened Explorer. Fixed: order is partly-removed first, then size (expanding
  never moves a row); every app has an arrow; `Looking for its files and settings...` / `No files or settings found.` child line;
  double-click on an app row opens/closes it; scroll position kept by row identity.

- 2026-10-29: "for the pie chart what is the current limit to display the file/folders or to put them in others? make a new rule
  that the size limit that makes them appear as others to be 5% of the current total circle, meaning 7.2 degrees of the circle.
  above that should be displayed." Was: 12 largest rows of at least 1.5 %. Confirmed: 2 % (7.2 degrees), no 12-slice cap,
  outer rings unchanged (arcs down to 1.5 degrees).

- 2026-10-29: "ok, as is 2% of the total circle, but put a minimum number of slices. (max is already set) minimum should be 10
  slices before going to others. except when number of files are less obviously. which then all files should get the slice."
  (Files view on C: showed one slice + a huge grey arc: only pagefile was over 2 %.) Rule: own slice for every row of at least 2 %
  AND always the 10 largest rows (all rows when fewer), at most 50.

- 2026-10-29: "then why the charts are not following the rules??????????" (README pictures: the 10-slice minimum gave slices of
  a few KB next to GB ones, invisible; and the "[N not listed]" row took one of the 10 places.) Asked about a minimum slice width:
  "keep proportions intact, but if smaller than 2% group all of them together." Final rule: own slice for every row of at least
  2 % (true proportions, at most 50); ALL smaller rows form ONE grey slice (at the first small row's place), no minimum count.

- 2026-10-30: (after a Suggestions delete listed 5,000+ failures in C:\Program Files\Microsoft VS Code\...\extensions\copilot\node_modules
  and C:\Program Files\WindowsApps\MicrosoftWindows.Client.WebExperience...\node_modules) "why? i have VSCode open but for the rest?
  Also change the deletion page. make it similar to the scanning page, but in a more alerting color (maybe red) and the app should update
  the view live while deletion is happening. whichever tab it is, whether suggestions or else. i should see the files leaving the list as
  theyre being deleted. Also the prompt that this cant be undone when deleting permanently has a windows shell default look, change it into
  apps theme, with an alert sign and the logged detailes in a scrollable box inside." + "all other prompts like the one for apps own
  uninstaller running, should also be changed into apps theme."
  Cause: the "node_modules folders" suggestion took every node_modules in the scan, including those shipped inside installed programs
  (VS Code's built-in Copilot extension lost its node_modules; Windows protected WindowsApps: access denied, nothing removed there).
  Fixed: only a project's node_modules (package.json beside it), never under Windows, Program Files (incl. WindowsApps), ProgramData,
  AppData, hidden dot-folders, "resources" or "extensions" folders. General rule: a cleanup suggestion never points inside installed
  programs or tools.

- 2026-11-02: "the duplicates finder is finding only based on Size and not Size on disk. so the demo files that you added are making
  almost the entire part of that. why is that? how did u create those files? can i delete them now?" Cause: Duplicates showed and
  sorted by file length always. Fixed: matched by content, but sizes, "can be freed", order and chart follow the Size / Size on disk
  switch (extra copies = all but the newest). C:\Demo (sparse files from tools\make_demo.ps1, 681 GB long, 115 MB on disk) had been
  left behind after the README screenshots; removed. Rule: remove the demo tree right after taking screenshots.

- 2026-11-02: "after drive is scanned start scanning apps automatically not to waste time." Both platforms: when a drive scan
  finishes (not cancelled), the installed apps are listed in the background (sizes from that scan) unless already listed; not in
  the self-test. Verified on Windows: the apps lookup started by itself right after the 15 s C: scan.

- 2026-11-02: chose to build: "Always start as administrator", instant rescans from the change journal, hash cache, safe registry check,
  Windows system cleanup, WSL/Docker disk shrink, replace duplicates with links, macOS snapshots/purgeable/iPhone backups,
  low-space warning + drive health. "implement net features, and only after my trial we will release."
  - Always start as administrator (src\Elevation.cs): scheduled task "Disk Space Analyzer (as administrator)", on demand only,
    HighestAvailable, InteractiveToken; toggled in About (one UAC prompt via `--admin-task on|off`); a normal start runs the task
    with the arguments in %LOCALAPPDATA%\DiskSpaceAnalyzer\task-args.txt and exits; marker file `always-admin`.
  - Fast restart (src\Snapshot.cs, FastStart.cs): on close each whole drive scan is saved (Deflate, ~16 MB for 830k files, 1.8 s)
    with the USN journal id + position from when that scan started; next start loads it (1.7 s vs 27 s scan) and, as admin, feeds
    the journal's changed paths to the live-update queue; otherwise a normal scan runs while the saved one is shown.
  - Hash cache (src\HashCache.cs): %LOCALAPPDATA%\DiskSpaceAnalyzer\hashes.bin keyed by path+length+mtime (+file id), 90 days,
    2 M entries; a repeat search read 0 bytes. Gotcha: BY_HANDLE_FILE_INFORMATION needs Pack = 4 (FILETIMEs).
  - Replace with links (src\Links.cs): hard link to the kept copy via a temp name + MoveFileEx replace; same NTFS volume only;
    skips copies changed since the search. Folder-by-folder scans count every link (like Explorer); the MFT scan counts it once.

- 2026-11-02: "the app has no loading screen why? add it. without increasing load time. defined in agent. before the scan is done,
  the chart should not be shown, the logo should be shown and only when scan bar is done logo turns into the chart."
  Why none: the agent said "native WinForms starts instantly, no splash"; measured: window after ~0.45 s warm, 5.6 s cold.
  Splash (src\Splash.cs) on its own STA thread with its own message loop, closed in MainForm.Shown: appears at ~200 ms; window
  median 454 ms with vs 442 ms without (noise). Name shrinks to fit (measure WITHOUT EndEllipsis: with it MeasureText lies).
  Chart: while `scanning`, RefreshChart/UpdateChart show the logo (ShowScanLogo) on every tab; SetScanning(true) refreshes the
  chart; the end-of-scan refresh morphs the logo into the chart.
- 2026-11-02: "the waiting screen doesnt look good. check the style from the schToDBD project. pay more attention to the
  style and update agent if necessary." Root cause: the agent gave the splash sizes as "pt", the reference (SchematicToDBD
  make_assets.py, PIL) draws them in px, so WinForms drew everything a third larger (title touching the frame, status
  jammed at the bottom, status in `fg`). Splash.cs now uses GraphicsUnit.Pixel x Theme.Scale (30/14/12/13 px), 2 px divider,
  notes at y 200/220, status `muted` with its bottom at y 262; Splash.swift aligned (status `muted`, 2 px divider). Agent
  §2.4 Splash now says px and how to check it.
- 2026-11-02: "in the schematicToDBD project, there is the loading of dlls and so on shown at the bottom, above that there
  should be the description of the App: Disk Space Analyzer / by sphrd / Fastest, free, open-source disk utility (or
  something similar)". Splash now: name + "by sphrd" beside the logo, below the divider "Fast, free and open-source disk
  space analyzer and cleaner" (14 px fg), bottom line live `Loading <assembly>.dll` from AppDomain.AssemblyLoad
  (static status text, so loads before the splash handle exists still show). Agent §2.4 Splash updated to this layout.
- 2026-11-02: "add more flare to it. add version number. i still dont see the loading of anything being written down."
  Why nothing showed: the framework DLLs load before Splash.Begin, and one replacing line vanished in the ~250 ms the splash
  is up on a warm start. Now a 4-line log (check mark = done, spinner = current): already-loaded assemblies as
  `Loaded X.dll`, AssemblyLoad as `Loading X.dll`, plus real build steps from the MainForm constructor (Splash.Status).
  Flair: accent glow behind the logo, version pill next to "by sphrd", accent bar, accent sweep along the divider (30 ms
  timer on the splash thread), DWM rounded corners + CS_DROPSHADOW. Gotcha: CreateGraphics() in the splash constructor
  created the handle early and CenterScreen was ignored (splash at the top-left); DPI now from Graphics.FromHwnd(Zero).
  Checked by capturing the screen during a real start. macOS: same look, steps logged from applicationDidFinishLaunching.
- 2026-11-02: "how can i look at the screen for longer? implement this same style inside the app as well. for example the
  scanning animated circle can have this faded glowy line instead of normal line (the arc) tha circles in the arc. write
  down this style and FLARE that you just added in the agent file so other apps follow."
  `DiskSpaceAnalyzer.exe --splash` shows the splash until click/Esc (Splash.Preview). Flair helpers in Theme.cs/.swift:
  DrawCometArc (fading tail, glow, bright head), DrawSweep, DrawGlow, shared clock Theme.Now. Spinner (scan bar, delete
  strip, busy overlay, splash log) = comet arc; scan bar spinner 26 px; progress fill gets a sweep + head glow (bar-only
  repaint, 30 ms); chart logo while scanning gets a glow and an orbiting comet (ShowLogo(..., working)), the logo shrinks
  inside the orbit and the morph starts from that size. Agent §2.4 "Flair" section added. Self-test: the 3 suggestions /
  node_modules FAILs also fail on HEAD without these changes (pre-existing). macOS changes not compiled here.
- 2026-11-02: "also the logo looks different there, so change all the logos into that one." -> scope chosen: in-app +
  README/social images, exe icon plain; "the line bar and the highlighted section that goes from left to right is what
  i said looks very good and to keep it". Theme.DrawLogoGlow (logo + soft accent glow) for title bar (0.9x), About and
  info prompts (0.75x, clear of the text column at x 140), chart placeholder (0.62x on surface), splash; make_icon.ps1
  draws app.png (README) and the social preview with the glow; app.ico / app-1024.png stay plain.
- 2026-11-02: "remove [the orbiting comet]. instead add an orbiting glow ... in the path that covers the missing arc of
  the full circle of the apps logo, and its mirror ... as if the missing arc of logo is a 3d cone, and the orbiter is
  marking the base circumference of that cone." then "no. draw the line that i described, and move the highlighted part
  through that path (same as the line in the loading screen ... the one with a faded highlighted part)".
  Theme.DrawMouthLoop: the cone base = missing arc (front) + its mirror across the mouth chord (back), drawn in BORDER,
  with a 40 % sweep (alpha 0 -> 1 -> 0 along it, accent) going round once per 1.8 s, phase even round the base circle.
  Logo stays full size while scanning (no inset).
  Then: "cut one side of it, one side has the tail, other side is just the dot that is going." -> one-sided: 40 % tail
  behind the head, alpha 0 -> 1, ending in a bright round head dot (2.2 x stroke); nothing ahead of the dot.
  Then: "after the tail, the line should not be visible. the dot should not have larger width than the line." -> the loop
  path is no longer drawn (only the tail), head dot diameter = line width.
- 2026-11-02: "the spinning logo line is outside of the logo's circle a bit, bring it inwards. you can smooth the edges so
  it looks like an Oval. the speed of motion should reflect that this is a 3d circle (sin cos changes in speed). in the
  scanning bar, i like the highlighter pulse, but the glow on the ending dot is nto so good so remove that. in the agent
  file: the glow sometimes can look low quality. by the glow, i meant the subtle glow beneath the logo in the loading
  screen that looked professional. and what i wanted other apps to adopt is the trailing lines, the highlighter lines both
  in loading screen and in scanning."
  DrawMouthLoop is now a true oval centred on the mouth chord, half-axes 0.11 R x 0.36 R (checked inside the circle with
  the stroke), point = (xc - a cos phi, cy + b sin phi) with phi even in time -> sin/cos speed. Scan bar: glow at the
  fill's end removed (sweep kept). Spinners (DrawCometArc): glow layers removed too (trailing line + head dot = line
  width), per the "glow can look low quality" note. Agent Flair section rewritten: trailing/highlighter lines are the
  core, the only glow is the subtle one beneath the logo.
- 2026-11-02: "chanhge the direction of its spin, and make it slightly faster. commit and push all, update readme and every
  other file necessary, and release." Mouth loop reversed (y = cy - b sin phi: down the outer side, up the inner) and
  1.8 s -> 1.4 s per loop. `--splash` added on macOS too. Released as v1.9.0 (includes the dev/features work held back
  for the owner's trial).
- 2026-11-02: the owner tuned the scanning animation by hand in src/Theme.cs (DrawMouthLoop: xc = cx - 0.8 R cos 30°,
  a = 0.09 R, b = 0.3 R, w = max(2, R/15), period 1.0 s) and src/Chart.cs (animTimer and orbitTimer 10 ms): "reflect the
  changes exactly in macos version as well" -> Theme.swift / Chart.swift mirrored value for value. Released as v1.9.1.
  Owner rule: no Co-authored-by or any Copilot/Claude trace in commits; sphrd is the only author.

- 2026-11-02: "the list of apps is reloading everytime why? make it faster." Why: read from scratch at every start, only after
  the scan, with the Store list from a new PowerShell (3.5 s) after the registry. Now (src\AppsCache.cs, Apps.cs): the list is
  saved (apps.bin, logos as PNG) and shown at once; registry + Store (in parallel) + logos are read while the drive is scanned
  (PrefetchApps at Shown); after the scan only sizes from the scan (one pass on the UI thread); the fresh list replaces the
  saved one in place (same uninstall key / package keeps open state and found items). Measured on C: (181 apps): saved list
  56 ms after the scan, refreshed 1.9 s after; before: 8.5 s after the scan on a cold start. Within a session only Refresh
  reads it again; during a scan the tab waits for the scan.

- 2026-11-02: "wherever there is a ... sign, in each column, all of that should be readable while hovering on that row."
  SizeListView.CutCells(row) finds cells wider than their text room (same widths as DrawCell; name column minus glyphs, indent
  and icon); RowHoverText = full name + path, then "Column: full text" for each other cut cell not already shown. Hover
  screenshots pick a visible row (rows above the scroll position put the cursor outside the window: blank capture).

- 2026-11-03: "look at these repos and compare my DiskSpaceAnalyzer tool to them, and find ways to improve mine and make it
  better than theirs" (SpaceSight, quado, OpenDiskLens, Radix, c2flux). Chosen by the owner (v2.0.0, both platforms):
  1 treemap ("doesnt the left pane already show the tree? add it if not" - the tree is a folder tree, the treemap is a chart),
  2 search everything scanned, 3 scan history "without compromising performance or cluttering logs", 4 save/open scans,
  5 back/forward + path bar, 6 last opened, 8 Recycle Bin limits, 9 synced folders, 10 unreadable folders, 11 what is this
  folder, 12 leftover confidence, 15 properties + preview, 17 SHA-256 + PRIVACY.md + SECURITY.md, 19 accuracy test "include
  the result in readme". Not wanted: compare two folders ("its a different app"); winget/Homebrew wait for a possible repo
  rename.
  - Treemap (src\ChartTreemap.cs): PieChart is partial; `Treemap` switches drawing and hit testing; squarified layout of the
    same slices (true proportions, list order kept for colours), folder slices hold subfolders 2 levels deep (level-1 header
    row; the folder's own files are an undrawn gap so children keep their share), free space = outlined empty rectangle,
    info area under the map (hovered item / folder shown) with an "Up" chip (= centre click). Ring / Treemap `Segmented`
    (FONT_9) is a child of the chart at its top right (`TitleRightMargin`); the choice is a marker file `treemap`.
  - Files search: "In the selected folder / In everything scanned" (all roots); a name search also lists folders
    (`FileIndex.Folders`, chart value 0); date filter merged into one box ("Not changed for ..." / "Not opened for ...") so
    the bar stays two rows. Last opened = max(last access, last write) (`FileRec.Accessed`: FindData access time, MFT
    $STANDARD_INFORMATION +24); if `NtfsDisableLastAccessUpdate` has bit 0 set the caption says opens are not recorded.
  - History (History.cs): every full scan appends 56 bytes to `history\<key>.timeline` (max 1,000) and writes a pruned copy
    (folders >= 4 MB, same .dsa format) to `history\<key>\yyyyMMdd-HHmmss.dsa`: one per day (same day replaces), last 12;
    archive folders follow the 10-most-recent rule. Done in RememberScan's background task, no log output. Changes page:
    From / To `ChoiceBox` (SetChoices), `HistoryStrip` (used space for drives, dot per scan, click = compare from that day),
    comparison generalised over `Side` (DirNode or PrevNode). The archive copy of the scan in memory (within 2 min of
    `ScanRoot.Scanned`) is "Now", not listed as earlier.
  - Scan files (SavedScans.cs, Snapshot.cs v2): "DSASCAN1" + the snapshot (v2 adds last-access times and the drive's
    total/free; v1 still read). Export filter 4, **Open scan...** button, drag and drop, command line. Opened = read-only
    `ScanRoot` (after the drives): FindRoot/FindScanned skip it (same paths as the live drive!), FromReadOnly blocks delete /
    add / rescan, Duplicates and Suggestions ignore it, RefreshCapacity keeps the saved capacity; "Close saved scan".
  - Navigation.cs: Back/Forward (node + path, 100 deep; Alt+Left/Right; WM_APPCOMMAND 1/2 = mouse side buttons), `Breadcrumb`
    above the Contents caption (caption no longer repeats the path), unreadable `Banner` (count of Denied folders under the
    shown folder, cached per tree, cleared in ViewsChanged; Show them / Run as administrator).
  - Known.cs: path rules (environment-expanded), one-folder wildcards and anywhere-names -> What / Verdict / Explain / How;
    Contents column "What it is" (sort key cat) and the hover box. Texts point at the app's own tabs and Windows settings.
  - Safety.cs: RecycleLimits (BitBucket\Volume\{GUID} MaxCapacity MB / NukeOnDelete, default 10 % of 40 GB + 5 % above,
    removable/network/optical = no bin; "contents only" targets use their largest child) -> recycle confirmation keeps those
    items ("Move the others"), all of them -> offer Delete permanently. SyncFolders (SyncRootManager, OneDrive env/registry,
    Dropbox info.json, Google Drive label/DriveFS, Syncthing config.xml, iCloudDrive) -> amber note + "synced with X" per line.
  - Leftover tiers (Apps.cs): Exact (program folder, uninstall entry, full name / folder / key / package name), Same
    developer (Publisher\Name), Name only (shortened name, Documents) = never pre-checked; the post-uninstall prompt deletes
    only sure items and lists the rest as "listed, but not deleted".
  - Preview.cs: SHObjectProperties (Alt+Enter, menu Properties); PreviewForm (Space in Contents, Files, Duplicates, Delete
    list, Changes, tree): IShellItemImageFactory picture read with GetDIBits top-down 32 bpp (orientation and alpha right),
    icon only for folders and online-only files (a thumbnail would download them), first 64 KB of text files.
  - Accuracy (README): app vs `robocopy /L /XJ` vs `dir /s`: System32 identical; Program Files same file count, bytes differ
    only by 16 file symbolic links (robocopy counts their targets); dir /s and PowerShell follow folder links/junctions and
    count files twice. CI repeats it (Windows: robocopy, fails on a count mismatch or > 1 %; macOS: du/find, > 10 %).
  - Gotcha: executables in %TEMP% are blocked on the owner's machine (policy); test builds go to a scratch folder instead.
  - macOS (Known/Navigation/SavedScans/Safety/Preview/SelfTestV2.swift): same features; treemap choice in UserDefaults;
    Back/Forward ⌘[ ⌘] + mouse buttons 4/5; Space = Quick Look (QLPreviewPanel, never for dataless iCloud files), ⌘I = Finder
    Get Info via AppleScript (NSAppleEventsUsageDescription in Info.plist, asks once for Automation); File > Open Scan... ⇧⌘O;
    the unreadable banner also counts folders skipped without Full Disk Access; no Recycle Bin limit (the Trash has none) but
    a volume without a Trash keeps its items ("Move the others"). Compiled first time on CI. Gotcha: `display()` does not draw
    on the headless runner, so the self-test lays the treemap out with `layoutTreemapNow()`.
  - CI accuracy: System32 differs on the elevated runner (robocopy lists SYSTEM-only subfolders the app sees as denied), so
    the check uses both Program Files folders; results are in the README.
  - Self-test: SelfTestV2.cs adds 13 checks (last opened, search everywhere, treemap layout and drawing, navigation, known
    folders, unreadable banner, Recycle Bin limit, synced folders, scan file round trip + read-only guards, timeline/archive).

- 2026-11-03: "why when im searching google for "github disk space analyzer sphrd" my app is not showing up?" ... "should i
  consider changing the name?" ... "ok go for SpacePie. the repo had a lot of changes from other sessions so check the current
  latest files (committed but unreleased). will the name change keep repo history?" Why not found: 7-day-old repo, Google had
  not indexed it (traffic: 9 views, github.com and qwant only), and "Disk Space Analyzer" is a generic term shared by 110
  repos and commercial tools. Names checked: DiskLens (Microsoft Store app + GitHub analyzer of that name), DiskPie (two
  GitHub disk visualizers) taken; SpacePie free in this field. Renamed to **SpacePie** in v2.0.0 (repo renamed on GitHub,
  history, tags, releases and stars kept, old URLs redirect). v2.0.0 still carried 1.x compatibility (old asset names, data
  folder move, old admin task, .dsascan) and "formerly" texts.
- 2026-11-03: "why folder name here is still DiskSpaceAnalyzer? change that as well. why the chart is called Ring? it
  should be called Pie, thats the name of the app. then continue with the release and the rest of the tasks for Google.
  remove formerly and updating from, there ar eno users yet." -> local folder renamed to SpacePie; chart switch Pie /
  Treemap; all 1.x compatibility and "formerly" texts removed (v2.0.1); GitHub Pages site with sitemap for Search Console.
  Done: Pages from `main /docs` (https://sphrd.github.io/SpacePie/, sitemap.xml; a project site's robots.txt is ignored, so
  none), repo homepage = the site, public profile repo `sphrd/sphrd` with a README linking SpacePie, winget PR
  microsoft/winget-pkgs#469632 (portable, neutral, manifest 1.12.0; `winget validate` passed; local install test needs admin).
  Owner to do: Search Console verification (HTML tag -> `docs/index.html` head), sitemap + Request indexing; profile
  bio/website (needs `gh auth refresh -s user`); the CLA comment on the winget PR. Gotcha: VS Code (and its browser
  preview of docs/index.html) keeps the project folder open, so the local folder can only be renamed from VS Code's own
  Explorer or with VS Code closed.
- 2026-11-03: "Add some "flare" to the website of the app. give more detail and promote the app correctly. on the app i still
  see issues, in the photo u see, in general wherever there is a text with ... it should be shown in full when hovering on
  it. why isnt it doing that? new version now is hoswing that alarm at the top which is not nice. I have been thinking to
  make changes: merge the left and middle panes, instead add a column bar with appropriate icons on the left for each
  functionality: Contents, Suggestions, Apps, File Search, duplicates, etc... Cause now the left pane is kinda useless."
  Decisions (asked): the unreadable-folders banner becomes a slim closable line pointing to Run as administrator; the
  rail has icon + name per view; Contents becomes a tree-list (folders expand in place, like WinDirStat) and a **This PC**
  level above every drive lists the drives (Up from a drive, or "This PC" in the path bar). Homebrew: own tap
  `sphrd/homebrew-tap` (`brew install --cask sphrd/tap/spacepie`); the official cask needs notability and, since 2025,
  signed + notarized apps.
- 2026-11-03: "the menu column should e scrollable and smaller in size. the text should be on the right of the icons
  instead of below, increasing column width but reducing length. the loading orbit in logo mouth is not necessary for
  hte site. the delete list should be next to delete permanently button and always visible as the main utility place for
  deleting files." -> rail rows 36 px (icon left, name right, 150 px wide), mouse-wheel scrolling with a thin pill;
  Delete list left the rail: a toolbar button "Delete list (n)" right of Delete permanently, accent while open; the site
  logo has no orbit.
- 2026-11-03: "Delete list on the left of delete permanently, delete list with the yellow box color of delte permanently
  and dlete permanently with a red color." ... "dont release. just build. also add the sort by name or other columns
  instead of locking them on size." -> toolbar order Add to delete list | Delete list (n) (warn) | Delete permanently
  (danger; also in the Suggestions and Delete list bars). Every list sorts by every column: `SizeListView.Grouped` lists
  (Suggestions, Apps, System, Duplicates) move whole groups and sort members inside (`KeepMemberOrder` for Duplicates:
  the kept newest copy stays first); `UserSorted` makes `SetRows` keep the chosen order on every refill. "Can free"
  sorts by the chart value (key `free`), System "Action" by `Category`. No release.
- 2026-11-04: "fix all. under Agents there is an agent for app design, that needs to be in sync with style and mode of
  functions added to the app, and vice versa. recheck mac app here as its the macos machine, why the updater doesnt
  automatically install the app in place_ now it asked me to go to github releases and fownload and myself."
  - Updater (macOS) root cause: before downloading it probed only the folder of the *running* bundle. A copy run from
    the disk image, or a downloaded copy macOS runs translocated (a randomised read-only copy when the app was not
    moved with Finder), failed the probe and got `Can't update here` with **Open download page**; no download was ever
    attempted (no hdiutil/dmg trace in the log). Now `Updater.installTarget()`: the original bundle of a translocated
    copy (`SecTranslocateIsTranslocatedURL` / `SecTranslocateCreateOriginalPathForURL` via dlsym), else the running
    bundle when its folder is writable, else `/Applications` (or `~/Applications`); the staged copy loses
    `com.apple.quarantine`; an EPERM move names System Settings > App Management; Restart now opens the copy installed.
    `--cli update-install <dmg>` runs the install step; CI tests the swap on a copy of the built app. Verified here
    (macOS 27): in place from /Applications and from a mounted dmg into /Applications; translocation itself can't be
    created by a test process (EPERM), so that branch is checked only by the API's "not translocated" answer.
  - Docs matched to code: duplicates use MD5 (PRIVACY said SHA-256); instant-restart scans kept: Windows 4 drives,
    macOS 10 drives/folders (README/PRIVACY/site said 4 for both). Chart switch tooltip "pie chart" (was "ring chart").
  - Agent sync (app follows agent): macOS prompts get **Copy list** (bottom left) like Windows; macOS checkboxes 16 px
    (were 14); toolbar tooltips with shortcuts on Choose... (⌘O), Scan (Return), Show in Finder (⇧⌘R), Export (⇧⌘E),
    Open scan (⇧⌘O); Windows: a failed saved-scan load is named in the status line; the CLI error file falls back to
    the data folder when the working folder can't be written. Agent follows app: red Delete permanently, Back/Forward
    and Open scan in the toolbar, current prompt wording, Files/Changes/System/Duplicates details, context menus,
    shortcuts, macOS font mapping (+3 pt), updater install target, self-test list.
  - Gotcha: a self-test scratch folder under a hidden folder (e.g. `~/.x`) fails the node_modules checks by design
    (dot-folders are never suggested); use a normal folder.

## WinForms mapping of the design language

- Tokens and fonts live only in `Theme.cs`; widgets use those names, no inline hex.
- Rounded shapes: GDI+ anti-aliased paths (`Theme.FillRound`; outline = outer fill + 1 px inset fill).
  The icon is drawn at 4x and downscaled (HighQualityBicubic).
- Popups and context menu: `DarkRenderer`; on Windows 11 DWM gives anti-aliased rounded corners with a border
  outline (`DWMWA_WINDOW_CORNER_PREFERENCE` / `DWMWA_BORDER_COLOR`); Windows 10 falls back to square + border line.
- Title bar: DWM immersive dark mode (attribute 20, fallback 19).
- Scrollbars: native ListView/TreeView scrollbars cannot be styled. `ScrollHost` sizes the native control so its
  scrollbars fall outside a clipping panel and shows `PillScrollBar`s (6 px thumb in a 10 px track) that mirror
  `GetScrollInfo` and scroll via `LVM_SCROLL` (list) / `WM_xSCROLL SB_THUMBPOSITION` (tree).
- Tree: name on the left, then right-aligned **Size** and **% of parent** columns that line up on every row, with a
  `TreeHeader` above. `TVS_NOHSCROLL`: long names are ellipsized instead of scrolling the columns away.
- Scans run in the background behind a **scan bar** under the toolbar (spinner, status, counts + current path,
  pill progress bar, Cancel); browsing stays possible, Scan / Rescan / Delete / Browse are disabled until it ends.
  For a whole drive the bar is real progress: bytes found / drive used space (capped at 99 % until done). Folders have
  no known total, so no bar, only counts. The full-window busy overlay (§2.6) is kept for permanent deletes only.
- Tree top level = one node per local drive (system drive first) plus scanned folders (`ScanRoot`). The system drive
  is scanned at startup; other drives show used space from the volume and are scanned on Scan / double-click / Enter.
- Tree `% of parent` column has a 44 px pill bar; for a scanned drive root it is the share of the drive capacity.
- Pie chart pane (right, 330 px, fixed) holds only the title (selection + path, or used/total/free for a drive) and the
  donut; the centre shows the hovered slice (name, size, share) or the total. Slices mirror the folder contents list
  exactly, in its current row order (rebuilt after every fill and re-sort): every row of at least 2 % of the total
  (7.2 degrees) gets its own slice in true proportion (at most 50; accent shades); all smaller rows together form one grey "N smaller items"
  slice. A drive root appends "System / not readable" (used - scanned) and "Free space". Free space is an empty
  gap (nothing drawn; a faint `border` fill only while hovered). Slices start at 12 o'clock and run clockwise, so the
  free gap (last) always ends at 12 o'clock, just left of the top vertical line.
- No chart before a scan: an unscanned or scanning drive shows the app logo (only the Pac-Man pie, `LOGO_*` colours) on exactly the chart's circle, plus a muted note. When the scan finishes, the logo fades out on
  that circle while the chart sweeps in clockwise from 12 o'clock and the hole opens (650 ms, ease-out). Hover is off during the morph. This is the only animation besides the
  spinners (allowed by §2.1 as a one-off transition; recorded here as a project decision). Hover is linked both ways:
  slice -> its row(s) get an accent outline in the list (scrolled into view if none is visible); list row -> its slice
  pops out. Chart colours are data-only tokens in `Theme.CHART*` (accent shades + greys), allowed by §2.1.
- Message boxes and the folder picker stay OS-styled (accepted by §2.1).

## Deviations from the agent file (kept to preserve existing behavior)

- Window opens at 1280x760 (at most 85 % of the screen's working area, centred in it; min 900x520). The app is a
  three-pane explorer, not the single-column form of §2.5. Layout: toolbar (path row + action row), scan bar (while
  scanning), tree | list | chart panels, status line.
- The path box is editable (type a path + Enter), so only its chevron opens the drive list, not the whole box.
- Deletion has no Cancel on the overlay: the deleter never had cancellation; adding it would change behavior.
- Folder/file icons are muted glyphs instead of shell icons (yellow shell folders would add a hue).
- The former toolbar **Stop** button became the overlay's **Cancel** (same action; Stop was only usable while scanning).

## Decisions and gotchas

- **macOS version:** native Swift/AppKit app, same behaviour and look as Windows (three panels, linked chart, scan bar,
  update window, About, logo morph), built and checked only on GitHub's macOS runners (this machine is Windows): the
  `macos` CI job runs `build.sh`, a headless `--cli scan /usr/share` and `--cli screenshot` (views render themselves
  into PNGs, no screen-recording permission needed), and attaches `DiskSpaceAnalyzer-macOS.dmg` to the same release as
  the exe. Scanner: `getattrlistbulk` on 8-32 threads, does not follow symlinks and skips every other mount point
  (`getmntinfo`), so on `/` the data volume under `/System/Volumes/Data` is not counted twice (its content is reached
  through the firmlinks `/Users`, `/Applications`...). Drives: `mountedVolumeURLs` with `skipHiddenVolumes`, local and
  browsable only; refreshed on mount/unmount. Free space uses `volumeAvailableCapacityForImportantUsage`.
  macOS-only differences: "Choose..." instead of "Browse...", "Show in Finder", "Full Disk Access..." instead of "Run
  as administrator" (opens the privacy setting), About and Check for Updates in the app menu of the system menu bar,
  Cmd+R rescan, Cmd+Backspace delete, Cmd+Up up. Unsigned (no Developer ID): first launch needs right-click > Open.
  The updater downloads `DiskSpaceAnalyzer-macOS.dmg`, verifies it, mounts it, copies the app next to the running one
  and swaps the bundles (`.old` removed at next start); if the app runs from the disk image or a read-only place it
  asks to move it to Applications or links to the release page.
- Windows CI first, then macOS (`needs: build`), so a tag produces both artefacts on one release. Branches `dev/**`
  also build (no release), which is how the macOS app is compiled and checked before merging.
- **Updates:** 3 s after start the app asks `api.github.com/repos/sphrd/DiskSpaceAnalyzer/releases/latest` (no token;
  drafts and pre-releases are never offered). If the tag (`vX.Y.Z`) is newer than the exe's `AssemblyVersion`, an
  update window (same frame as About: `AppDialog`) offers Update now / What's new / Later; automatic checks are silent
  otherwise. Every step uses that window: Checking..., You're up to date (Close / What's new), Update available,
  Downloading (progress pill + Cancel), Update installed (Restart now / Later), Update check failed / Update failed /
  Can't update here (Open download page). Replaced the amber banner on the user's request (2026-10-28), in both apps.
  Manual check: Check for updates in the title bar, the About window's button, or the version label at the bottom right.
- Custom title bar (`TitleBar` in `Widgets.cs`) replaces the native caption: app logo, app name, then the menu items
  **About** (F1) and **Check for updates** right next to the name, and drawn minimise / maximise / close buttons (close
  hover `#c42b1c`, the Windows convention). `WM_NCCALCSIZE` removes the caption but keeps the native resize borders,
  shadow and Snap; `WM_NCHITTEST` returns HTCAPTION for empty title-bar space (drag, double-click to maximise, system
  menu) and HTTOP* in the top resize strip. Maximised, the client top is moved below the off-screen frame part. History:
  a Help button in the toolbar, then a separate menu bar row under the caption; the user wanted the items on the title
  bar "like every other app". The logo drawing lives in `Theme.DrawLogo` (chart pane + About). Update now: download `DiskSpaceAnalyzer.exe` to
  `<exe>.download` with progress and Cancel, check its size and the SHA-256 `digest` GitHub reports for the asset,
  rename the running exe to `<exe>.old` (Windows allows renaming a running exe), move the download into place, then
  Restart now. The next start deletes `.old` / `.download`, retrying for ~15 s because the previous process may still
  be closing. If the folder is not writable (probed by creating a file), the update window links to the release page instead.
  .NET 4.x needs TLS 1.2 switched on explicitly for GitHub; GitHub needs a User-Agent header.
- **Releasing for the updater:** the tag must be `v` + the new `AssemblyVersion` (higher than before) and the asset must
  be named exactly `DiskSpaceAnalyzer.exe`; otherwise the update window only links to the release page. Installs older than
  v1.5.0 have no updater: those users must download v1.5.0 once by hand.
- Tested end to end with a local build labelled 1.3.9 against the published v1.4.0: banner shown, download, checksum,
  swap, restart into 1.4.0; installed file identical to the release asset.

- Window placement: `FormStartPosition.CenterScreen` opened the window off-centre with its bottom under the taskbar
  (y 224..1083 on a 1020 px working area). The form now sets `StartPosition = Manual` and centres itself in the working
  area of the screen under the cursor. Check placement with `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)`.

- Mapped network drives are not listed: `DriveInfo.IsReady` on a disconnected share can block for seconds. A network
  path can still be typed and scanned. Drives are re-read on `WM_DEVICECHANGE` (arrival / removal), deferred while a
  scan or delete runs.
- While a scan runs the user can navigate. When it ends, the view stays where the user is: a selection inside the old
  copy of the rescanned tree is mapped onto the new one by path (`FindByPath`); another drive stays selected.
  Model updates (`ReplaceNode` etc.) use the largest-files list of the root that owns the node (`TopOf`), not the
  active one, because the user may have switched drives during a background rescan.
- Chart hover state is two values: `hover` (what is drawn, also set from the list) and `reported` (last slice sent
  through `HoverChanged`). With one shared value, a list hover that set the slice first swallowed the chart's own
  hover event, and the list highlight never appeared.
- Startup: the window shows in ~0.3 s warm. The first start of a freshly built exe takes 2-10 s while Windows
  Defender inspects the new file; that is not app work.
- Full C: scan (~870k files, 203k folders) took 10 s on an idle machine and 20-35 s under load; the old and new
  scanner measured the same under the same load, so the UI changes cost no scan speed.

- **Privacy: screenshots for the repo never show a real scan of the user's machine** (v1.0-v1.2 showed the user's
  C:\Program Files). Build a demo tree of sparse files under a neutral path (e.g. `C:\Demo`: `fsutil sparse setflag`,
  then `SetLength`; no disk space used), capture with `PrintWindow`, blank the drive free-space label, delete the
  demo tree afterwards. Never commit machine-specific details (paths, user names, security policies).
  Since v1.3 the app scans the system drive and lists real drives at startup, so the screenshot is taken in-process:
  scan `C:\Demo` (sparse files), then via reflection rename that root to a made-up `E:\ Data` drive with a made-up
  capacity, add a made-up `F:\ Backup` drive, drop the real drives, and set the status/drive labels before capturing.
  Since v1.7 this is built in: `.\tools\make_demo.ps1 C:\Demo` (sparse files, ~250 MB on disk, a few duplicate pairs),
  `DiskSpaceAnalyzer.exe --cli screenshot <out> C:\Demo --demo` (finds duplicates first, then shows the folder as
  `E:\ Data` with made-up `F:\`/`G:\` drives; skips Suggestions and Changes, which would show this PC), copy
  `1-contents.png` to `assets\screenshot.png` and `7-duplicates.png` to `assets\screenshot-duplicates.png`, then
  `.\tools\make_demo.ps1 C:\Demo -Remove` and delete `%LOCALAPPDATA%\DiskSpaceAnalyzer\history`.
- Repo logo: `assets/app.png` at the top of the README; `assets/social-preview.png` is the GitHub social preview
  (Settings > General > Social preview; GitHub has no API for it, so it is uploaded by hand).

- Icon: do not cut pie slices with thick strokes in the tile colour. v1.2.0 did, and the square line end left a
  ragged notch on the rim. Separate slices by offsetting whole `FillPie` shapes instead.

- **Owner-drawn ListView, details view:** when the cursor moves over a row, the native list repaints it by raising
  `DrawItem` *without* `DrawSubItem`. Painting cells in `OnDrawSubItem` (and the row background in `OnDrawItem`)
  made every hovered row lose its size/percent cells until a click. Fix: paint the whole row (background,
  selection, every cell in display order) in `OnDrawItem`; `OnDrawSubItem` is empty.
- That bug is invisible to `PrintWindow(..., PW_RENDERFULLCONTENT)` (it repaints everything) and to synthetic
  `WM_MOUSEMOVE`/`WM_MOUSEHOVER`. Reproduce it with real cursor movement (`SetCursorPos`, no clicks) and a plain
  screen capture (`CopyFromScreen`).
- The hosted list/tree must not be docked: docking undoes `ScrollHost`'s bounds and causes a
  layout -> paint -> sync loop (window showed "Not Responding").
- `PathInput.OnLayout` runs from the base constructor (setting Padding) before children exist: null-guard it.
- Header area right of the last column is not owner-drawn; `HeaderPainter` fills it after `WM_PAINT`.
- Tree column widths: measure samples without `EndEllipsis` (with it, `MeasureText` returns a too-small width).
  Each sample is the wider of the longest value and the header title.
- Testing: clicks and keys on a shared desktop can land in another app. Post messages to specific window handles
  (`WM_KEYDOWN` to the tree, `WM_LBUTTONDOWN/UP` to a button, `WM_COMMAND IDYES` to the confirm dialog);
  cursor moves without clicks are safe.
- Driving `MainForm` in-process from PowerShell is fine for synchronous checks, but `await` continuations stall
  there (no WinForms message loop); test async flows (scan/cancel/rescan/delete) on the real exe.
- Headless check: `Start-Process DiskSpaceAnalyzer.exe -ArgumentList '--cli','scan','"<dir>"' -Wait -NoNewWindow
  -RedirectStandardOutput <file>`; a plain call does not capture a winexe's stdout. Headless crashes go to
  `DiskSpaceAnalyzer_error.txt` in the working directory.

### Views, index and cleanup (v1.7.0)

- **File index:** every scanned folder keeps a `FileRec[]` (name, size, size on disk, modified, attributes); the
  Files, File types, Duplicates and export work from memory. `DirNode.OnDisk` picks the measure for every view
  (`Size`/`LocalSize` are properties over `Bytes`/`Alloc`); switching re-sorts all child lists.
- **Size on disk (folder walk):** rounded up to clusters; compressed, sparse and reparse-point files (Compact OS/WOF)
  ask `GetCompressedFileSize`; cloud placeholders (OFFLINE / RECALL_ON_OPEN / RECALL_ON_DATA_ACCESS) count 0. Hard links
  are counted per name here (only the master file table can tell them apart).
- **Master file table (`Mft.cs`):** only for a drive root with admin rights; reads `\\.\C:` sequentially in 4 MB chunks
  from the runs of record 0, applies the update sequence fixups, merges extension records by base reference. File size
  = unnamed `$DATA`; size on disk = allocation of all `$DATA` streams (sparse/compressed: compressed size), except for
  NTFS's own records 0-15 (`$BadClus:$Bad` claims the whole volume). Extra hard links are listed in their folders with
  size on disk 0. On the GitHub runner: 1.2 M files in about 10 s (folder walk: over 7 minutes), size on disk within
  0.5 % of the drive's used space. Any failure falls back to the folder walk; `--cli scan C:\ --mft` prints why.
- **Gotcha:** picking the long name of each extra hard link by scanning the whole link list was quadratic (WinSxS has
  100k+ links) and looked like a hang: use a dictionary keyed by (record, parent).
- **View tabs** sit above the list and the chart (Contents, Files, File types, Duplicates, Suggestions, Changes, Delete
  list); each view is a `Page` with a caption line, an optional filter/action bar (wraps; a search box gets its own row
  when it wraps) and a `SizeListView`. `BuildSlices` turns any list into slices (rows of a duplicate group share their
  group's slice via `ItemInfo.GroupOf`).
- **Deletion** goes through `DeleteTarget` (file, folder, folder contents only, Recycle Bin) and `ConfirmAndDelete`;
  afterwards `ApplyDeleted` drops removed nodes and rescans folders that still exist. Contents-only targets skip files in
  use quietly (counted). Recycle uses `SHFileOperation` with ALLOWUNDO + WANTNUKEWARNING.
- **Default layout:** the chart pane is 4/5 as wide as the panes are tall (square in v1.7.2, a bit big), the list keeps at least 380 px.
- **Suggestions tree:** parent rows (chevron + three-state checkbox) and child rows per target (`ItemInfo.Check`,
  `Expandable`, `Data`; children use `GroupOf` so they share the parent's chart slice). Clicks on the chevron/checkbox are
  caught in `WM_LBUTTONDOWN` before the list selects the row. Safe suggestions start ticked, review-first ones unticked.
  The tab title is green (`Theme.SUGGEST`). Shortcuts: Ctrl+D add to delete list, Ctrl+Shift+D (or Del) delete permanently.
- **After every delete** `AfterDeleteRemeasure` measures each attempted target (and the same paths in the delete list and
  suggestions) from the updated scan: gone ones leave, the rest keep the remaining size with `partly deleted -- ...`.
  (v1.7.2 kept the original size after a partial delete.) **Run as administrator** is hidden when elevated.
- **Suggestions refresh:** found once and cached until Look again in v1.7.2. Now `suggestionsDirty` is set by every
  scan, rescan, delete, measure switch and live change; the tab finds them again when shown (live: at most every 20 s,
  temp folders change constantly). Ticks are kept by path, expanded suggestions by name.
- **Gotcha:** live updates ignored every event for 3 s (then 0.5 s) after our own delete, so outside changes in that window
  were lost (the fast CI runner caught it). Now filtered by path: `BeginOwnChanges(targets)` / `EndOwnChanges()`; events at or
  under the paths being deleted are ignored during the delete and 3 s after; all other events are always queued.
- **Hover:** `SetToolTip` on a ListView/TreeView shows once per control entry, not per row, and a TreeView takes over an
  attached tooltip and sizes it to the row (text cut off). Rows and nodes use `Hover()`: a separate owner-drawn ToolTip shown
  on the form 16/20 px from the cursor 450 ms after the row changes, hidden on leave/click/scroll. Suggestions in several places
  list up to 8 paths. Screenshot mode checks it with the real cursor (`*-hover.png`).
- **Suggestions tab** is second (after Contents, which the app opens on; v1.7.3); bar = circular-arrow refresh (icon button), Select all, Deselect all,
  Delete permanently (compact 9 pt buttons); headline `<size> can be freed` 15 pt bold in `SUGGEST`. Clicking a tree folder
  while on Suggestions switches to Contents. **Rescan folder** is a circular-arrow icon button (`RoundButton.Glyph`).
  Shots are numbered in tab order: `1-contents`, `2-suggestions`, ... `5-duplicates`.
- **Apps tab (`Apps.cs`):** uninstall entries from HKLM 64/32 and HKCU (skips SystemComponent, updates with ParentKeyName or
  ReleaseType Update/Hotfix), plus Store apps via `Get-AppxPackage` (SignatureKind Store, not framework/non-removable; name from
  AppxManifest DisplayName). Size = measured program folder (scan index first), else EstimatedSize; apps sharing one folder (Office
  and language packs) count it once (on the entry with the largest EstimatedSize). Uninstall: MSI `msiexec /x {code}`, else the
  UninstallString (shell execute so UAC works), Store `Remove-AppxPackage`; waits for the process, then until the uninstall key is
  gone (NSIS/Inno hand over to a temp copy), overlay button **Continue** to stop waiting. Leftovers: folders in Roaming, Local,
  LocalLow, Local\Programs, ProgramData, Program Files (x86), Documents, Store Packages; Start menu/desktop shortcuts; registry
  Software\<App> and Software\<Publisher>\<App> (HKCU, HKLM 64/32), the uninstall key if left. Names: normalised display name,
  name without version/bitness, folder name, key name (`_is1` stripped); generic words never match; a publisher folder only when
  all it holds is the app. Admin-only items start unchecked without elevation. Registry keys: `reg export` appended to
  `%LOCALAPPDATA%\DiskSpaceAnalyzer\registry-backups\<app> <date>.reg` before `DeleteSubKeyTree`; a key that can't be backed up is kept.
- **System tab (`System.cs`, `SysTasks.cs`, `RegCheck.cs`, `Health.cs`; Windows):** after Apps. Loads in the background after a drive
  scan (and when opened). Groups -> items, each with size / "Can free", "What it means", action; the chart slices by what can be
  freed (rows without it get none). Windows update leftovers: `Dism /English /Online /Cleanup-Image /AnalyzeComponentStore` (lazily:
  on expand or **Analyze**), **Clean up** = `/StartComponentCleanup` (progress from its %). Restore points: `vssadmin list
  shadowstorage` / `list shadows`, **Delete oldest** (`delete shadows /for=X: /oldest /quiet`) / **Delete all but the newest**
  (`/shadow={id}` each). `hiberfil.sys` with `powercfg /h off|on`; page/swap file info only. WSL/Docker `.vhdx` (Packages\*\LocalState,
  %LOCALAPPDATA%\wsl, Docker\wsl, Lxss BasePath): **Shrink** = `wsl --shutdown` + diskpart `attach vdisk readonly` / `compact vdisk`.
  Registry check (only: uninstall entries whose folder and uninstaller are gone, Run/RunOnce values whose absolute .exe/.dll is
  missing, `Classes\Applications\<exe>` and App Paths pointing at a missing exe; never under Windows or WindowsApps, never on an absent
  drive): each key/value exported to `registry-backups\Registry check <date>.reg` first, values deleted as values. Drives: free/total
  plus Storage WMI health (`MSFT_PhysicalDisk`, `MSFT_StorageReliabilityCounter`; needs `/r:System.Management.dll`). Admin-only
  rows are muted with "needs administrator"; their action offers Run as administrator. Long actions use the scan strip (red for
  deletes) with `busy` set. Low space (< 10 % or < 10 GB): amber banner on the tab, and once per drive per session an amber,
  clickable status line after a scan -> Suggestions.
- **Apps flow (v1.8):** every app expands (first time: search in the background) into all its items, program folder first
  (child rows `<Kind>: <name>`, no checkboxes while installed). Uninstall: official uninstaller, then the same search again; if anything
  remains a dialog lists it and asks `Delete them too?` (Yes = delete with registry backup; No = keep as checkable leftovers).
  macOS: one confirmation moves the bundle and all its items to the Trash. `Look for leftovers` menu item removed.
- **App logos:** each app row draws the app's own icon (`ItemInfo.Icon`) instead of the folder, loaded with the list in the
  background at the row icon size. Windows order: `DisplayIcon` (`file,index`, via `SHDefExtractIconW` at the exact size) ->
  MSI `HKCR\Installer\Products\<packed code>\ProductIcon` -> main exe in the program folder (or one level down; named like the
  app, else the largest; skips unins/setup/update/helper) -> folder icon. Store apps: `Square44x44Logo` (or `<Logo>`) from
  AppxManifest.xml, the scaled file closest to the size, unplated preferred, no contrast variants. macOS: `NSWorkspace.icon(forFile:)`.
- **Deleting (v1.8.2):** red delete strip = `ScanBar(danger: true)` docked under the scan bar: DANGER_BG fill, DANGER_BORDER outline,
  DANGER spinner and progress bar (files done / files in the targets from the scan), DANGER_FG detail line (current path), **Stop**
  (`DeleteJob.Stop`: finishes the current file; the rest is untouched and rescanned). No overlay: the window stays browsable, actions
  that change the disk are disabled (`busy`). `DeleteJob.Gone` (every deleted file/folder) and `Finished` (targets) are drained on the
  150 ms UI timer; rows of the open list and of Contents whose path (or a parent folder) is gone, or whose targets are all finished,
  are removed and the chart rebuilt. `RunDelete` is shared by ConfirmAndDelete and RemoveLeftovers.
- **Prompts:** every prompt is `AlertForm` (About frame): warning sign (`Theme.DrawWarningSign`, DANGER for permanent deletes and
  uninstalls, WARN for warnings/errors) or the logo, heading (13 pt bold), body, amber note, `DetailsBox` (rounded SURFACE box, pill
  scrollbars both ways, path then muted size/reason after a tab, Ctrl+C copies, **Copy list** button), buttons bottom right; destructive
  primary is red (`ButtonKind.Danger`), Enter/Escape cancel on destructive prompts. Only the startup-crash box stays a MessageBox.
- **Gotcha:** `RoundButton.MinChars` replaced the text width (long primary labels were cut: "Delete perm..."); it is a minimum now.
- **Gotcha:** `Directory.GetDirectories` on .NET 4 (no 4.6.2 target) rejects `\\?\` paths; the leftover search silently found
  nothing until it used plain paths (these roots are short).
- **Chart centre** shows the shown folder's name and size (not "Total"); in Contents it is clickable and goes up one
  folder (the reverse of clicking a slice). **Size on disk** is the default measure.
- **Gotcha (morph not visible):** the logo-to-chart morph was timed by the wall clock; right after a big scan the UI
  thread is busy (tree rebuild, history save, garbage collection of the index), so the 650 ms passed before the first
  frame and the chart just appeared. The morph now advances per timer tick by at most 50 ms (Windows and macOS), and the
  self-test checks that it drew at least 8 frames.
- **History:** `%LOCALAPPDATA%\DiskSpaceAnalyzer\history\<root>.dsa` (gzip: folder names and sizes, no file names).
  One file per drive/folder, overwritten by each full scan; only the 10 most recently written files are kept.
- **Gotcha (v1.7.0 crash):** `Path.GetDirectoryName`/`GetFileName` throw `PathTooLongException` beyond 260 characters
  (the exe has no 4.6.2+ target framework, so .NET uses legacy path checks). The live-update timer hit it on a real drive.
  Paths from the disk go through `Native.ParentDir` / `Native.FileName` / `Native.IsDirectory`, the timer body is
  guarded, and the self-test now creates and removes a 347-character path while live updates run.
- **Live updates:** `FileSystemWatcher` per scanned root; changes are applied every 2 s on the UI thread (re-read a
  folder's own files, scan new folders, drop removed ones, rename in place); the contents list refreshes at most every
  4 s and not while rows are selected. Our own deletes are ignored for 3 s. Overflow shows "Changes missed - rescan".
- **Layout (v2.1.0):** no folder tree any more. Left: `NavRail` (same index as `pages`; `Hide(i)` keeps a page out of
  the bar, used for the delete list, which opens from `btnBasket` next to Delete permanently). Then the list|chart split.
  Contents is a tree-list: `ItemInfo.TreeRow/Depth` indent column 0 by 18 px per level (chevron space kept for files so
  they align), `expandedDirs` holds the expanded folders, `AddContentRows` sorts each level with the list's sorter and
  recurses, `RefillContents` keeps scroll and selection; the chart uses depth-0 rows only. **This PC** (`thisPc`,
  `current == null`): one row per scan root, "% used" column, chart of used space per drive; the path bar always starts
  with "This PC". `CutText` records every text drawn cut off per control and raises `Hover` with the full text; the main
  window shows it in its dark tooltip (list headers too, via the header's WM_MOUSEMOVE).
- **Gotcha (scripted edits in PowerShell):** `@(@("a","b"))` flattens to `@("a","b")`, so a loop over "pairs" replaced
  single characters (every "r" -> "e" in Views.cs, "A" -> " " in MainForm.cs). Recovered from HEAD + a vocabulary of the
  other sources. Use Python (or `,@(...)`) for replacement lists.
- **Checks:** `--cli selftest <scratch>` (14 checks incl. live updates, Recycle Bin on CI, contents-only delete,
  duplicates, export, history) and `--cli screenshot <out> <folder>` (every view) run the real window; CI runs the
  self-test and the master file table check on the elevated Windows runner.

## Releases

- v1.0.0 (2026-10-27): first release, light WinForms UI, ~66 KB.
- v1.1.0 (2026-10-27): design-language dark theme restyle, ~96 KB. Verified: Program Files scan
  matches pre-restyle counts; cancel, rescan and permanent delete on a sandbox folder work on the real exe.
- v1.2.0 (2026-10-27): pie-chart icon, hover fix in the lists, aligned Size / % of parent columns in the tree,
  `--cli scan` headless mode, build moves the exe to the root. ~100 KB.
- v1.3.0 (2026-10-27): auto-scan of the system drive at startup, background scan with progress bar, all local drives
  in the tree (others scanned on demand), percentage bars in the tree, pie chart pane with free space, 1500x880 window,
  smooth Pac-Man icon. ~117 KB.
- v1.4.0 (2026-10-28): pie chart pane is only the donut, linked by hover to the contents list in both directions and
  ordered like the list (small rows merged); free space is an empty gap ending at 12 o'clock; app logo shown before a
  scan and morphing into the chart; tile-less shaded logo everywhere; default window 1280x760, centred in the working
  area. ~123 KB.
- v1.5.0 (2026-10-28): self-update from GitHub releases (banner, download, checksum, swap, restart), Help menu with
  Check for updates and About (version, author sphrd). ~140 KB.
- v1.6.0 (2026-10-28): About and Check for updates as items in the custom title bar next to the logo; every update
  step shown in the About-style app dialog (no banner); first native macOS version (universal .dmg, Swift/AppKit).
- v1.7.0 (2026-10-28): master file table scanning, file index with size on disk, view tabs (Files with search and
  filters, File types, Duplicates, Suggestions, Changes, Delete list with Recycle Bin), multi-ring chart, export to HTML/CSV,
  live updates, self-test and screenshot modes. macOS has the same views (no master file table; Trash instead of the
  Recycle Bin; FSEvents; iCloud dataless files count 0 on disk; shortcuts ⇧⌘D add to delete list, ⌘F search, ⇧⌘E export).
- v1.7.1 (2026-10-28): fix a crash in live updates on paths longer than 260 characters; About shows the speed tip and
  the keyboard shortcuts; scan history keeps only the last scan of the 10 most recent drives/folders; the chart centre
  names the folder and goes up on click; size on disk is the default; the logo morph is visible again after big scans.
- v1.7.2 (2026-10-29): macOS never downloads iCloud files or folders (dataless items are skipped, materialization off),
  first-run Full Disk Access prompt and no per-folder prompts without it, dmg with a drag-to-Applications arrow; square chart
  pane on both platforms; README rewritten.
- v1.7.3 (2026-10-29): Suggestions as a checkbox tree (Select all / Deselect all / Delete permanently, green tab, big headline);
  hover box with full name and path for every row and folder; circular-arrow Rescan; Ctrl/Cmd+D add to delete list,
  Ctrl/Cmd+Shift+D delete permanently; delete list keeps the real remaining size after a partial delete; suggestions refresh
  after any change; live updates never drop outside changes; permission buttons hide when granted; chart pane 4/5.
- v1.8.0 (2026-10-29): Apps tab (uninstaller): every installed app with its own logo and real size; expand an app to see all
  its files, settings and (Windows) registry keys in place; Windows runs the official uninstaller, checks again and asks to delete
  what is left (registry backed up to .reg); macOS moves the app and all its files to the Trash in one step. Chart: the 10
  largest items always get their own slice, plus every item of at least 2 % (7.2 degrees), at most 50.
- v1.8.1 (2026-10-29): chart: every item of at least 2 % (7.2 degrees) gets its own slice in true proportion; all smaller
  items together form one grey slice (no more invisible hairline slices); README shows Suggestions and Apps.
- v1.8.2 (2026-10-30): safety: node_modules suggestions only for projects (package.json), never inside installed programs or
  tools; deleting shows a red progress strip with Stop and the open list empties live; every prompt is a themed dialog with a
  warning sign and the full list of items in a scrollable box.
- v1.8.3 (2026-11-02): Duplicates: sizes, "can be freed", group order and chart follow the Size / Size on disk switch.
- v1.9.0 (2026-11-02): Always start as administrator; instant restart from saved scans (+ change journal / FSEvents);
  duplicate hash cache; replace duplicates with hard links (Windows) / clones (macOS); System tab; installed apps listed
  during the scan; hover shows cut-off columns in full; start-up screen (logo with glow, version, live loading log,
  `--splash` preview); chart shows the logo with a trailing line running round its mouth while scanning, then turns into
  the chart; trailing-line spinners and a highlighter sweep on progress bars; logo with glow everywhere in the app.
- v1.9.1 (2026-11-02): scanning animation tuned by the owner: the trailing line in the logo's mouth is thicker (R/15),
  sits further inside the mouth (centre 0.8 R cos 30°, oval 0.09 R x 0.3 R) and loops once a second; the loop and the
  logo -> chart morph repaint every 10 ms.
- v2.0.0 (2026-11-03): renamed to SpacePie; treemap; search
  everything scanned; scan history timeline and compare any two scans; save / open scan files; back/forward and path bar;
  last opened; what-it-is labels; unreadable folders banner; Recycle Bin limit and synced-folder warnings; leftover
  confidence tiers; preview and properties; PRIVACY.md / SECURITY.md; SHA-256 in the release notes; accuracy checks in CI.
- v2.0.1 (2026-11-03): chart switch "Pie / Treemap" (was Ring); the old-name compatibility of 2.0.0 removed (no users yet).
- v2.1.0 (2026-11-03): views bar on the left (icon + name, scrolls) instead of tabs and the folder tree; Contents as a tree-list
  with This PC / This Mac above the drives (only drives count their used space); Delete list button next to Delete
  permanently; slim closable unreadable-folders line; full text on hover for everything cut off; website refresh.
- v2.1.1 (2026-11-03): Delete list (amber) left of Delete permanently (red); every list sorts by every column, groups stay together and the order survives refills.

# Privacy

SpacePie runs on your computer and keeps what it learns there. It has no account, no telemetry, no
analytics and no advertising.

## What it reads

- **File and folder names, sizes and dates** of the drives and folders you scan, to show where the space went.
  It never reads the contents of a file, except:
  - **Duplicates:** files of the same size are read to compare their content (SHA-256). Only the hashes are kept.
  - **Preview** (Windows, Space): the first 64 KB of a text file you choose to preview, shown in the window and not
    stored. Pictures come from the operating system's own thumbnails.
- **Installed apps** (Apps tab): the uninstall entries in the Windows registry and the Microsoft Store package list,
  or the apps in `/Applications` on macOS, and the folders and settings that belong to them.
- **System information** (System tab): free space and health of your drives, restore points or Time Machine
  snapshots, the component store, hibernation and page files, and (Windows) a list of broken registry entries.
- **Synced folders:** where OneDrive, Dropbox, Google Drive, iCloud Drive and similar services keep their files, so the
  app can warn you before you delete inside them.

Online-only cloud files (OneDrive "online-only", iCloud files not downloaded) are never opened, previewed or
downloaded.

## What it keeps on your computer

Windows: `%LOCALAPPDATA%\SpacePie`. macOS: `~/Library/Application Support/SpacePie`.

| What | Why | How much |
|---|---|---|
| `history\` | folder names and sizes of the last scan of each drive or folder, a small copy per day (folders of 4 MB or more), and the totals of every scan | the 10 most recently scanned drives/folders; 12 daily copies and 1,000 totals each |
| `snapshots\` | the full scan of each drive when the app closes, for an instant restart | the 4 most recent drives |
| `hashes.bin` | content hashes of files compared for duplicates | 2 million files, 90 days |
| `apps.bin` / `apps.plist` | the list of installed apps, so the Apps tab shows at once | one list |
| `registry-backups\` (Windows) | a `.reg` backup of every registry key the app removes | until you delete them |
| `treemap`, `always-admin`, `task-args.txt` (Windows) | your chart choice and the "Always start as administrator" setting | a few bytes |

Delete the folder to remove all of it. Scan files you save yourself (`.spacepie`) are wherever you saved them.

## What it changes

Nothing, unless you ask: deleting (to the Recycle Bin / Trash or permanently, always after a confirmation that lists
every item), uninstalling an app, the System tab's clean-up actions, replacing duplicates with links, and turning
"Always start as administrator" on or off (a scheduled task named "SpacePie (as administrator)").

## Network

The only network requests go to GitHub, for updates:

- at start (after 3 seconds) and when you press **Check for updates**:
  `https://api.github.com/repos/sphrd/SpacePie/releases/latest`
- when you press **Update now**: the release file from `github.com`.

GitHub sees your IP address and the app's version in the request header, like for any download. Nothing about your
files or your computer is sent.

## Check it yourself

The source is in this repository. Every web address in it:

```powershell
Select-String -Path src\*.cs, macos\Sources\SpacePie\*.swift -Pattern 'https?://'
```

and every place that opens a network connection (`HttpWebRequest` / `WebClient` on Windows, `URLSession` on macOS)
is in `src/Updater.cs` and `macos/Sources/SpacePie/Updater.swift`.

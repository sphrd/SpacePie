# Security

## Reporting a vulnerability

Please report security problems **privately**, not in a public issue: use GitHub's
[private vulnerability reporting](../../security/advisories/new) for this repository. Describe what you found, how to
reproduce it and which version you used (shown in **About**). You will get an answer within a week.

## Supported versions

Only the latest release gets fixes. The app updates itself (**Check for updates**), so please update before
reporting.

## Verify a download

Every release lists the SHA-256 hash of each file in its notes. Compare it before running the file:

```powershell
Get-FileHash .\DiskSpaceAnalyzer.exe
```

```bash
shasum -a 256 DiskSpaceAnalyzer-macOS.dmg
```

The built-in updater checks the same hash (published by GitHub for the release file) before it replaces the app.

The files are built from this repository by GitHub Actions (`.github/workflows/build.yml`); they are not code-signed,
so Windows SmartScreen and macOS Gatekeeper warn the first time. To avoid running a downloaded binary, build it from
source (see the README).

## What the app is careful about

- **Deleting:** always after a confirmation that lists every item. Links (junctions, symbolic links) are deleted as
  links; what they point to is never touched. Moving to the Recycle Bin warns when Windows would delete an item
  permanently instead (too large for the bin, bin turned off, no bin on that drive). Deleting inside a synced folder
  (OneDrive, Dropbox, Google Drive, iCloud Drive...) warns that it also deletes in the cloud.
- **Uninstalling:** the app's own uninstaller runs first. Leftovers that match only by name are never selected for
  you. Registry keys are exported to a `.reg` backup before they are removed.
- **Administrator rights:** asked for only when you press **Run as administrator** or turn on **Always start as
  administrator** (a scheduled task that runs only when you start the app).

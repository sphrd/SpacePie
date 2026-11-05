#!/usr/bin/env python3
"""Demo volume for README / website pictures on macOS: a small APFS disk image mounted as /Volumes/Data, filled with
SPARSE files (they report large sizes but take almost no space), the same layout as tools/make_demo.ps1 on Windows.

    python3 tools/make_demo_mac.py            # create and mount /Volumes/Data
    macos/.build/debug/SpacePie --cli demo-shots <out folder> /Volumes/Data
    python3 tools/make_demo_mac.py --remove   # unmount and delete the image
"""
import os
import random
import subprocess
import sys
import tempfile
import time

IMAGE = os.path.join(tempfile.gettempdir(), "spacepie-demo.sparseimage")
VOLUME = "/Volumes/Data"
GB, MB, KB = 1024 ** 3, 1024 ** 2, 1024


def remove():
    if os.path.isdir(VOLUME):
        subprocess.run(["hdiutil", "detach", VOLUME, "-force", "-quiet"], check=False)
    if os.path.exists(IMAGE):
        os.remove(IMAGE)


def main():
    if "--remove" in sys.argv:
        remove()
        print("Demo volume removed")
        return
    remove()
    subprocess.run(["hdiutil", "create", "-size", "8g", "-type", "SPARSE", "-fs", "APFS", "-volname", "Data", "-quiet", IMAGE], check=True)
    subprocess.run(["hdiutil", "attach", "-nobrowse", "-quiet", IMAGE], check=True)
    if not os.path.isdir(VOLUME):
        sys.exit("the demo volume did not mount at " + VOLUME)

    rnd = random.Random(7)
    seed = [1]
    now = time.time()

    def f(rel, size, months_ago=1, same=0, real=False):
        s = same or seed[0]
        if not same:
            seed[0] += 1
        path = os.path.join(VOLUME, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            if real:
                fh.write(os.urandom(int(size)))   # small real files (deleted in the "deleting" picture)
            else:
                fh.write(s.to_bytes(4, "little"))  # same first bytes = same content (duplicates)
                fh.truncate(int(size))
        t = now - months_ago * 30 * 86400 - rnd.randint(0, 26) * 86400
        os.utime(path, (t, t))

    def many(d, pattern, count, lo, hi, months_ago=6):
        for i in range(1, count + 1):
            f(os.path.join(d, pattern.format(i)), lo + rnd.random() * (hi - lo), months_ago + rnd.randint(0, 11))

    # Videos
    many("Videos/Family 2024", "clip_{:03}.mp4", 18, 900 * MB, 6 * GB, 8)
    many("Videos/Trip to Iceland", "GX01{:04}.MP4", 22, 1 * GB, 4 * GB, 14)
    many("Videos/Projects/Wedding edit/Render", "render_v{}.mov", 6, 8 * GB, 14 * GB, 3)
    f("Videos/Projects/Wedding edit/Wedding.fcpbundle", 180 * MB, 2)
    many("Videos/Screen recordings", "Screen Recording {:02}.mov", 30, 120 * MB, 900 * MB, 4)
    # Games
    f("Games/Steam/steamapps/common/Starfield Odyssey/data/content.pak", 62 * GB, 5)
    f("Games/Steam/steamapps/common/Starfield Odyssey/data/textures.pak", 21 * GB, 5)
    f("Games/Steam/steamapps/common/Kart Racer 3/assets.bin", 38 * GB, 9)
    f("Games/Steam/steamapps/common/Puzzle Isles/game.dat", 6 * GB, 20)
    many("Games/Steam/steamapps/shadercache", "cache_{:03}.bin", 40, 20 * MB, 180 * MB, 2)
    # Virtual machines
    f("Virtual machines/Ubuntu 24.04.utm/Data/disk.qcow2", 64 * GB, 1)
    f("Virtual machines/Windows 11.utm/Data/disk.qcow2", 41 * GB, 7)
    f("Virtual machines/ISO/ubuntu-24.04-desktop-arm64.iso", 6 * GB, 18)
    # Photos
    many("Photos/RAW 2023", "IMG_{:04}.CR3", 220, 24 * MB, 38 * MB, 20)
    many("Photos/RAW 2024", "IMG_{:04}.CR3", 260, 24 * MB, 38 * MB, 8)
    many("Photos/Exports", "export_{:03}.jpg", 300, 3 * MB, 9 * MB, 6)
    # Music
    many("Music/Library/Albums", "track_{:03}.flac", 420, 18 * MB, 60 * MB, 30)
    # Projects: real (small) node_modules folders, deleted in the "deleting" picture
    for i in range(1, 13):
        for k in range(1, 9):
            f("Projects/web-app-{}/node_modules/pkg-{}/index.js".format(i, k), (40 + 8 * i) * KB, 2, real=True)
        f("Projects/web-app-{}/package.json".format(i), 2 * KB, 2, real=True)
    many("Projects/ml-model/data", "part-{:04}.parquet", 60, 180 * MB, 420 * MB, 5)
    f("Projects/ml-model/checkpoints/model-final.pt", 7 * GB, 3)
    f("Projects/ml-model/checkpoints/model-epoch-40.pt", 7 * GB, 3)
    f("Projects/ml-model/checkpoints/model-epoch-30.pt", 7 * GB, 4)
    many("Projects/ios-app/DerivedData/Build/Intermediates", "obj_{:03}.o", 200, 2 * MB, 12 * MB, 1)
    # Downloads: old installers and a few duplicates of files kept elsewhere
    f("Downloads/Docker.dmg", 620 * MB, 26)
    f("Downloads/Office-Installer.pkg", 2.1 * GB, 15)
    f("Downloads/ubuntu-24.04-desktop-arm64.iso", 6 * GB, 18, same=9001)
    f("Virtual machines/ISO/ubuntu-24.04-desktop-arm64 copy.iso", 6 * GB, 18, same=9001)
    f("Downloads/family-trip.zip", 2.4 * GB, 13, same=9002)
    f("Backups/Old MacBook/family-trip.zip", 2.4 * GB, 30, same=9002)
    f("Downloads/Tax 2024.pdf", 3 * MB, 7, same=9003)
    f("Documents/Taxes/Tax 2024.pdf", 3 * MB, 7, same=9003)
    many("Downloads", "driver-pack-{}.zip", 5, 300 * MB, 1.5 * GB, 20)
    # Backups and documents
    f("Backups/Old MacBook/full-image-2022.dmg", 96 * GB, 40)
    f("Backups/iPhone/backup-2024-11.tar", 54 * GB, 11)
    many("Documents/Work", "report_{:02}.docx", 80, 200 * KB, 6 * MB, 10)
    many("Documents/Scans", "scan_{:03}.pdf", 150, 400 * KB, 4 * MB, 24)
    print("Demo volume at " + VOLUME)


if __name__ == "__main__":
    main()

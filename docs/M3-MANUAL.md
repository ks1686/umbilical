# M3 manual test

Run this on a Mac with Xcode, after `scripts/build-aria2.sh` and an app build.
The script is the M3 gate in `docs/PLAN.md`. Idle memory is checked on a
Release build.

Torrent downloads, the Safari extension, video, licensing, and Sparkle are out
of scope. A magnet link must be rejected.

## Build

```bash
scripts/build-aria2.sh
xcodegen generate
xcodebuild \
  -project umbilical.xcodeproj \
  -scheme umbilical \
  -destination 'platform=macOS' \
  -configuration Release \
  build
```

The built app is under DerivedData. `umb-watch` and `aria2c` are inside
`Contents/Helpers`. `aria2c` is copied only when `helpers/bin/aria2c` exists.
The copy script reads `aria2c -v`, keeps the line that starts with
`Enabled Features`, and fails the build if that line contains `WebSocket`.
A good line is `Enabled Features: BitTorrent, GZip, HTTPS, Message Digest, Metalink, XML-RPC`.
It then runs `codesign --force --sign - -o runtime` on the copied binary.
`ARIA2_CODESIGN_IDENTITY` is `-` until M5 passes a Developer ID. Xcode signs
`umbilical.app` after that script. A Debug launch may set `ARIA2C` and
`UMB_WATCH` to executable paths. A Release launch ignores both and uses
`Contents/Helpers` only.

Confirm App Sandbox is off:

```bash
codesign -d --entitlements :- /path/to/umbilical.app
```

The entitlements must not contain `com.apple.security.app-sandbox`.
When aria2c was copied, `codesign -dv /path/to/umbilical.app/Contents/Helpers/aria2c`
reports flags that include `runtime`.

## Checklist

1. Launch umbilical. The main window asks for a download folder. The menu bar
   reads `umb` and its menu says there are no active downloads.
2. Choose a new empty folder, for example `~/Downloads/umbilical-test`.
   Settings shows that path. Quit and relaunch. The same folder is still
   selected.
3. Add `https://example.com/` with no save-as name. Paste can fill the URL
   field from the clipboard, and Command-V works in the field. The row
   appears, then moves through waiting or active to complete. The row shows
   progress while the size is known, plus speed and a remaining time while
   bytes are moving.
4. Add a larger file you are allowed to fetch. Pause it. The row says Paused
   and the menu bar returns to `umb`. Resume it. Speed shows again. Remove it.
   It leaves the list and the file stops growing.
5. While one download is active, the menu bar shows a percent and a speed for
   a single file, or a count and a speed for more than one. Open umbilical
   and Settings from the menu bar. Both windows come forward.
6. In the add sheet, choose a folder outside the download folder. The sheet
   reports that the folder cannot be used, and no download is added. Create a
   subfolder inside the download folder, choose that, and add a file. The file
   is written in the subfolder, not next to it.
7. Reject these inputs in the add sheet: an empty URL, `file:///tmp/x`,
   `https://user:password@example.com/a`, a save-as name of `../x`, and
   `magnet:?xt=urn:btih:0123456789abcdef`. None of them start a download.
8. Allow notifications. A finished download posts "Download finished" with the
   file name, not the full URL. Turn the finish toggle off in Settings, finish
   another download, and confirm no new notification appears. Turn the failure
   toggle on and interrupt a download (drop the network or remove the server)
   and confirm a failure notification can appear.
9. Quit from the menu bar. `pgrep aria2c` prints nothing. Relaunch. The
   finished item is still in the list. The removed active item is not. Show in
   Finder reveals the finished file.
10. On the finished file, `xattr -p com.apple.quarantine <file>` prints a value
    that contains `umbilical`.
11. During a download, inspect the `aria2c` process with `ps eww`. The command
    line and environment do not contain `rpc-secret` or `token:`.
12. Remove `Contents/Helpers/aria2c` from a Release build. That build ignores
    `ARIA2C` and `UMB_WATCH`. The window explains that aria2c is missing and
    does not start a download. Restore the helper and use Try Again. Downloads
    work again.
13. Idle memory: quit other copies, launch the Release build, leave it with no
    active downloads for a minute, and read Memory in Activity Monitor. It
    should stay under 60 MB.

## Package tests

`swift test` covers the view models, folder rules, and engine. It does not
replace this Mac pass.

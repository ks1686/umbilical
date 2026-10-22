# Video manual test

Run this on a Mac after `scripts/fetch-helpers.sh` and a Release app build.
`swift test` covers the argument list, URL policy, output confinement, progress,
and cancel. It does not replace this pass. The checklist item stays in progress
until this list has been run.

ffmpeg is not bundled. A JavaScript runtime is not bundled. The pass is a
direct http(s) media file with Video turned on. A YouTube page that fails is
not a failure of this pass, and it is not a pass either.

## Build

```bash
scripts/fetch-helpers.sh
xcodegen generate
xcodebuild \
  -project umbilical.xcodeproj \
  -scheme umbilical \
  -destination 'platform=macOS' \
  -configuration Release \
  build
```

The fetch script checks the GPG signature on `SHA2-256SUMS` before it trusts
`helpers/yt-dlp.lock`. The check uses a temporary keyring and removes it on
exit. It does not run yt-dlp and it does not pass `-U`.

The built app is under DerivedData. `scripts/copy-bundled-yt-dlp.sh` copies
`helpers/bin/yt-dlp` into `Contents/Helpers`, checks its SHA-256 against the
lock, and signs it. A Release build fails when that binary is missing. A
Debug build warns and continues.

```bash
codesign --force --sign "${YT_DLP_CODESIGN_IDENTITY:--}" -o runtime \
  --entitlements helpers/yt-dlp.entitlements \
  Contents/Helpers/yt-dlp
```

`YT_DLP_CODESIGN_IDENTITY` is `-` for local and pull request builds. The Mac
release script passes the Developer ID and this script then adds `--timestamp`.
Ad hoc signatures cannot use a secure timestamp. See `docs/RELEASE.md`.

Confirm the helper inside the built app:

```bash
APP=/path/to/umbilical.app
test -x "$APP/Contents/Helpers/yt-dlp"
codesign -dv "$APP/Contents/Helpers/yt-dlp"
codesign -d --entitlements :- "$APP/Contents/Helpers/yt-dlp"
"$APP/Contents/Helpers/yt-dlp" --version
```

`codesign -dv` must show flags that include `runtime`. `--version` must print
a version and exit. The entitlements must contain only these three keys:

- `com.apple.security.cs.disable-library-validation`
- `com.apple.security.cs.allow-unsigned-executable-memory`
- `com.apple.security.cs.allow-jit`

They must not contain `com.apple.security.get-task-allow`. The app
entitlements stay empty. These three keys are on the helper only.

Repo Guard: yt-dlp_macos is a PyInstaller binary. It unpacks a Python runtime
at launch, including libffi and a libpython signed by a different team.
Hardened runtime rejects that. `disable-library-validation` alone can hang
in libffi on current arm64 macOS. Unsigned executable memory and JIT are
both required for that unpack to return from `--version`. Do not copy these
keys onto the app. The Mac release script signs this helper with the same file.
See `docs/RELEASE.md`.

A Debug launch may set `YT_DLP` to an executable path. A Release launch
ignores `YT_DLP`, `ARIA2C`, and `UMB_WATCH` and uses `Contents/Helpers` only.

## Checklist

1. Launch the Release app and choose an empty download folder.
2. In the add sheet, paste `https://www.youtube.com/watch?v=abcdefghijk`.
   Video turns on by itself. Turn Video off, then edit the URL. It stays off.
   Turn Video on again. A direct file URL such as
   `https://example.com/video.mp4` leaves Video off until you turn it on.
3. Turn Video on and add
   `https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4`
   with no save-as name. The row shows progress. Pause stays disabled. The
   file lands in the download folder. Its name looks like
   `umb-video-<32 hex>.mp4`. `xattr -p com.apple.quarantine <file>` contains
   `umbilical`. No `umb-video-<32 hex>` directory remains in the folder.
4. Add the same URL again with Video on and save-as `clip.mp4`. The finished
   file is `clip.mp4`. Add it once more with save-as `clip`. The finished
   file is `clip.mp4`. A save-as name of `100%` or `../x` is rejected and
   does not start a download.
5. Start another video download and press Cancel on the row. There is no
   confirmation dialog. `pgrep -x yt-dlp` prints nothing. The row leaves the
   list. The staging directory is gone.
6. Reject these in the add sheet with Video on: an empty URL,
   `file:///tmp/x`, and `https://user:password@example.com/a`. None of them
   start yt-dlp.
7. During a video download, `ps eww` on the yt-dlp process shows
   `--ignore-config`, `--no-config-locations`, `--no-plugin-dirs`,
   `--no-update`, `--no-remote-components`, `--no-js-runtimes`,
   `--no-playlist`, `--downloader`, and `native`. It does not show `--exec`,
   `--cookies`, `--plugin-dirs`, or `-U`. The output template is
   `umb-video.%(ext)s`. The URL is the last argument, after `--`.
8. Quit. `pgrep -x yt-dlp` prints nothing.
9. Remove `Contents/Helpers/yt-dlp` from the Release app and relaunch. Adding
   a URL with Video on explains that yt-dlp is missing and that Release
   builds use `Contents/Helpers` only. An exported `YT_DLP` does not change
   that. Restore the helper. The same URL with Video on works again.
10. Debug build: set `YT_DLP` to another executable yt-dlp and confirm that
    path is the one launched. Release must not do this.
11. ffmpeg gap: a page that only offers separate video and audio streams
    fails with "This site didn't offer a version with sound that umbilical
    can save without extra tools." The app does not download ffmpeg, and it
    does not search `PATH` for ffmpeg. A silent video-only file is a fail.
12. JavaScript gap: the helper is launched with `--no-js-runtimes` and
    `--no-remote-components`. The app does not download deno, node, or
    yt-dlp-ejs. A YouTube page may fail for that reason. The direct media
    URL in step 3 is the pass. A YouTube failure is not a pass.
13. `--no-playlist` is set. A playlist URL saves one video, not the playlist.

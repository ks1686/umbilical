---
name: verify-umbilical
description: "Drive the umbilical macOS download manager through its real window, menu bar, and handoff sheet. Use when launching a built umbilical.app, checking that the isolated instance is worth driving, or proving a download, folder choice, pause, or handoff the way a user does."
---

# Verify umbilical

umbilical is a native macOS app. The user drives the main window titled `umbilical`, the menu bar status item, and the Settings window. There is no `umb` command-line client. The menu bar icon's accessibility description is `umbilical`. Package tests do not prove a journey in the feature map.

The harness is `.cursor/skills/verify-umbilical/scripts/verify-umbilical`. Run it from the repo root. UI commands use System Events against button titles and field labels from the SwiftUI source. They call `osascript .cursor/skills/verify-umbilical/scripts/ui.applescript`. Do not add an XCUITest target to `project.yml` for this skill.

One verification instance per Mac. The app stores its download folder and history with `UserDefaults.standard` for bundle id `me.peapod.umbilical`. `cfprefsd` ignores `HOME`, so launch also sets `CFFIXED_USER_HOME` to the scratch home and `__CFPREFERENCES_AVOID_DAEMON=1`. Before the process starts, the harness snapshots the real account home (from `dscl` or `getent`, not from `$HOME`). Absent stays absent. The snapshot covers `Library/Preferences/me.peapod.umbilical.plist`, `Library/Preferences/ByHost/me.peapod.umbilical*`, `Library/Saved Application State/me.peapod.umbilical.savedState`, `Library/Containers/me.peapod.umbilical`, `Library/Group Containers` entries for that bundle id, `Library/Application Support/me.peapod.umbilical`, `Library/Caches/me.peapod.umbilical`, and `Library/HTTPStorages/me.peapod.umbilical`. A directory that cannot be read fails the snapshot. When the preferences plist names a download folder, the snapshot lists the names in that folder. It skips `.DS_Store` and AppleDouble `._*` names. It does not hash the folder's bytes and it does not record the directory mtime, so a Finder touch of an existing file does not fail the run. A new name does. The harness never writes those paths. A change fails the run. The scratch plist is not required until a download folder has been chosen or the window already shows one. After quit, the harness waits four seconds without `defaults` and without `killall`, then checks the same paths again. A second process shares the menu bar name and the `umbilical://` handler. Launch refuses when any process is already named `umbilical`.

## Launch

Build on a Mac with Xcode 26 or later, after `scripts/build-aria2.sh` when the journey downloads a file:

```bash
xcodegen generate
xcodebuild \
  -project umbilical.xcodeproj \
  -scheme umbilical \
  -destination 'platform=macOS' \
  -configuration Debug \
  build
```

Debug leaves license checks off and shows `Unofficial build. License checks are off.` A Release build with no Polar organization id does the same and adds that the build has no organization id. Pass either built `umbilical.app` to launch.

```bash
.cursor/skills/verify-umbilical/scripts/verify-umbilical launch \
  --app /path/to/umbilical.app
```

Launch reads `Contents/Info.plist` and refuses a bundle whose id is not `me.peapod.umbilical`. It refuses `PolarOrganizationID` when the value is neither empty, nor the unsubstituted `$(POLAR_ORGANIZATION_ID)` placeholder, nor a UUID. It does not print that value. On macOS it reads the signature with `codesign -d --entitlements :-` and parses that output as a plist. Empty output is a refusal: a signed build with no entitlements is refused. It refuses a bundle whose entitlement dictionary contains the key `keychain-access-groups`. A string that merely contains that text is not a refusal. When the organization id is a UUID, launch continues only if `com.apple.security.get-task-allow` is the boolean true, which is the Debug injected entitlement. A Release bundle with a real organization id is not started. That build reads the shared login keychain. This harness does not activate a key, does not edit Polar config, and does not sign anything.

The scratch directory comes from `mktemp -d` under `/tmp/umbilical-verify`, which must be owned by the current user and mode `700`, and must not be a symlink. The scratch path and the payload script path accept both `/tmp` and `/private/tmp`. The harness does not assume which form `mktemp` prints. `payload stop` uses the same prefixes. The child is `Contents/MacOS/umbilical` with `HOME`, `CFFIXED_USER_HOME`, and `TMPDIR` inside that scratch directory, plus `__CFPREFERENCES_AVOID_DAEMON=1`. `ARIA2C`, `UMB_WATCH`, and `YT_DLP` are unset so a Debug build uses `Contents/Helpers`, the same files a Release build is allowed to use. `open` is not used for launch because it does not pass those variables. Launch records the process start time with `TZ=UTC0 LC_ALL=C ps -o lstart= -p PID`. Doctor, quit, and cleanup read it the same way. A host that is not macOS exits before any of these directories are created. The account snapshot is taken before the process is spawned, and a hash failure aborts launch. The `umbilical://` handler is the app path, recorded into `launch/handler-before.txt` before spawn. `absent` is a recorded value. A lookup failure aborts launch and does not start the app.

Ready means the accessibility dump contains `Choose a download folder` or `No downloads`. `Starting the download engine` is not ready. `Engine stopped` or `Missing helper` fails the launch. The app is quit or signaled on that failure, the scratch directory is removed, and the evidence directory is kept.

Relaunch keeps the same `HOME` after the recorded pid has exited:

```bash
.cursor/skills/verify-umbilical/scripts/verify-umbilical relaunch
```

Sparkle may contact GitHub for the appcast when the window opens. Do not choose `Check for Updates`.

## Doctor

Run this before the first drive and again after any failure:

```bash
.cursor/skills/verify-umbilical/scripts/verify-umbilical doctor
```

Exit 0 means the instance is worth driving. The recorded pid is alive. Its executable, `HOME`, `CFFIXED_USER_HOME`, `__CFPREFERENCES_AVOID_DAEMON`, and start time match the state file. The account snapshot still matches every real-home path. The scratch preferences plist is required only after a settings write (`settings_written=1`), and it must not be a symlink. The bundle version matches, no second process is named `umbilical`, and the window is past engine startup. Any other exit means it is not worth driving. A later `doctor` or `cleanup` with no `--evidence` uses the evidence path stored at launch.

Exit 1 means the state file, process, bundle, or window is wrong. Exit 2 means the arguments are wrong. Exit 3 means this host is not macOS. Exit 4 means the process identity matched and the UI was not checked because this host is not macOS.

```bash
.cursor/skills/verify-umbilical/scripts/verify-umbilical inspect-app \
  --app /path/to/umbilical.app
```

`inspect-app` prints `bundle_id`, `executable_name`, `version`, `polar=absent|present|invalid`, and `launch=ok|needs-debug-signature|refused`. It does not print the organization id and it does not start the app.

## Drive

Drive the feature file under `features/` after doctor exits 0. Prefer the accessibility names in that file. The composed HTTP journey is:

```bash
.cursor/skills/verify-umbilical/scripts/verify-umbilical drive add-download
```

That command chooses the scratch download folder when the window asks for one, serves `verify-payload.txt` from `127.0.0.1` only, types that URL into the field labeled `https://example.com/file`, leaves `Video` off, and chooses `Add`. It passes only when the row says `Complete`, the file bytes match the payload, and `xattr -p com.apple.quarantine` on that file contains `umbilical`. It stops if the window does not say license checks are off. It does not type a license key.

Step commands, after doctor would pass:

```bash
.cursor/skills/verify-umbilical/scripts/verify-umbilical ui click --name "Add Download"
.cursor/skills/verify-umbilical/scripts/verify-umbilical ui fill \
  --name "https://example.com/file" \
  --value "http://127.0.0.1:9/verify-payload.txt"
.cursor/skills/verify-umbilical/scripts/verify-umbilical ui checkbox --name "Video"
.cursor/skills/verify-umbilical/scripts/verify-umbilical ui choose-folder \
  --path /tmp/umbilical-verify/scratch-RUN-SUFFIX/umbilical-verify-downloads
.cursor/skills/verify-umbilical/scripts/verify-umbilical ui menu --name "Quit umbilical"
.cursor/skills/verify-umbilical/scripts/verify-umbilical ui open-url \
  --url "umbilical://download?url=http://127.0.0.1:9/verify-payload.txt"
```

`ui choose-folder` uses the open panel's `Choose` button (`NSOpenPanel.prompt`) and Command-Shift-G. The path may contain only letters, digits, and `._/-`, and the path itself must be a real directory. `/tmp` is a symlink on macOS, so pass a directory created for the run, not `/tmp`. `ui open-url` does not call `open`. It compares the app path recorded before spawn with the path after delivery. It sends the URL to the recorded pid with an Apple event and treats a nil reply as failure. It restores a moved handler with `NSWorkspace` `setDefaultApplicationAtURL:toOpenURLsWithScheme:error:`, including when delivery fails. A move from `absent` to an app fails and names both values. It then checks the account paths again. If a second pid named `umbilical` appears, its executable and environment are written under `open-url/` and the command fails. That second pid is signaled only when its executable is the recorded bundle. A pid with a different executable is left alone. `ui quit` and `Quit umbilical` address the recorded pid. Other clicks still use the process name, and doctor refuses a second process of that name.

A download journey needs executable `Contents/Helpers/aria2c` and `Contents/Helpers/umb-watch`. The harness does not fill those in from the environment.

## Evidence

Default evidence directory is `/opt/cursor/artifacts/verify-umbilical` when `/opt/cursor/artifacts` exists, otherwise `/tmp/umbilical-verify-evidence`. `launch` takes `--evidence` or `UMB_VERIFY_EVIDENCE`. The whole path is resolved, including every parent, and must stay under `/tmp`, `/private/tmp`, or `/opt/cursor/artifacts`, outside `/tmp/umbilical-verify`. The leaf must not be a symlink. The directory is mode `700`. Files the harness writes are mode `600`. `ui dump --path` and `ui screenshot --path` must stay inside that directory. `doctor`, `cleanup`, `drive`, and `ui` use the evidence path stored in the state file unless `--evidence` repeats that same path. A payload directory is resolved the same way and must stay under `/tmp` or `/private/tmp`.

A passing drive writes `add-http-download/action.txt` before `Add`, then `ui.txt`, `window.png`, `file.sha256`, and `quarantine.txt`. Launch writes `launch/ready.txt`. Doctor writes `doctor/ui.txt` on macOS. `commands.log` records exits. The dump is the accessibility snapshot. The screenshot is the window rectangle from System Events. Capture the action and the resulting state. A finished row without the file bytes and the quarantine attribute is not proof. File hashes use `sha256sum` when it exists, and `shasum -a 256` otherwise.

State file default is `/tmp/umbilical-verify/state.env` (`--state` or `UMB_VERIFY_STATE`). Fields are `run_id`, `pid`, `app_path`, `executable`, `home`, `scratch`, `downloads`, `evidence`, `version`, `server_pid`, `lstart`, `prefs_sha`, `prefs_mtime`, `settings_written`, and `handler_path`. `handler_path` is `absent`, `skipped`, or the app path recorded before spawn. `scratch` is the `mktemp -d` directory `/tmp/umbilical-verify/scratch-<run-id>-<suffix>` or the same path under `/private/tmp`. `home` is `<scratch>/home`. `downloads` is `<scratch>/umbilical-verify-downloads`. `prefs_sha` is `absent` or the account plist hash. `settings_written` is `0` until a download folder is chosen. The account snapshot is `/tmp/umbilical-verify/account-<run-id>.snap`. The harness does not write the account plist.

## Cleanup

```bash
.cursor/skills/verify-umbilical/scripts/verify-umbilical cleanup
```

Cleanup reads the state file. Before Quit, `TERM`, or `KILL`, and before it signals a descendant, the recorded pid must still have the same executable, `HOME`, and start time. The start time is read with `TZ=UTC0 LC_ALL=C ps -o lstart= -p PID`. A mismatch signals nothing, leaves the scratch directory and the state file in place, and does not print `cleaned`. On macOS, Quit is sent with System Events to that pid, not to every process named `umbilical`. If the pid is still alive after Quit, cleanup signals it, then the children collected while the identity matched. It signals `server_pid` only when that pid is `python` and one argument is exactly the payload script `verify-umbilical-payload.py`, the path is not a symlink, and the file contains the payload marker. It then waits four seconds, restores the `umbilical://` handler when its app path differs from `handler_path`, and checks every real-home path again. A handler that cannot be restored, or an account mismatch, keeps the scratch directory and the state file and does not print `cleaned`. The error names the new path. Move that file aside and run cleanup again. `cleanup --discard` stops the process only when the identity matches, restores the handler, and removes the scratch directory and the state file without claiming the account home matched. It prints `discarded`. `freeze-account` refuses while a state file exists and does not re-baseline a live run. When the paths match, cleanup deletes only the scratch directory, the state file, and the account snapshot. It does not delete the evidence directory. A missing state file prints `nothing to clean` and exits 0. A scratch path outside the `mktemp` pattern, or a symlink, is left in place and cleanup exits 1. Do not kill processes by name.

`payload start` refuses a symlink at the directory, the `www` directory, the body file, or the script path. `payload stop` uses the same exact script identity and does not match a longer file name that merely contains `verify-umbilical-payload.py`.

Payload server, used by `drive add-download` and safe to run on its own:

```bash
.cursor/skills/verify-umbilical/scripts/verify-umbilical payload start \
  --directory /tmp/umbilical-verify/payload-proof \
  --name verify-payload.txt \
  --body umbilical-verify-payload
.cursor/skills/verify-umbilical/scripts/verify-umbilical payload stop --pid PID
```

`payload stop` refuses a pid whose command line is not the payload script.

## Helpers

The executable is `.cursor/skills/verify-umbilical/scripts/verify-umbilical`. It runs on stock macOS bash 3.2. `ui.applescript` is only invoked by that script, on macOS.

The Accessibility grant is for the process that runs `osascript` (Terminal, Cursor, or another host). macOS keeps that grant after cleanup. The harness does not write the TCC database. Turn the grant off in System Settings when you no longer want that host to drive the UI.

```bash
osascript .cursor/skills/verify-umbilical/scripts/ui.applescript read-text
```

Run `verify-umbilical` with no arguments for the command list. Exit 2 is a usage error on every host.

## First Mac run

The first run on a Mac has to keep one evidence file for each of these. The harness writes them. Do not treat the run as proven until each file says what is listed here.

- `launch/account-before.txt`: every real-home path above, each `absent` or a hash, plus the download-folder name lines. `~/Library/Containers/me.peapod.umbilical` and the real download folder were read. Doctor's stderr has no permission error for those paths.
- `launch/handler-before.txt`: the app path for `umbilical://`, or `absent`, written before the process starts.
- `launch/accessibility-host.txt`: parent pids walked until an executable is inside a `.app`, or `app=absent` plus the chain. That host is the process that must hold the Accessibility grant.
- `launch/scratch-path.txt`: `/tmp/umbilical-verify/scratch-<run-id>-<suffix>` or the `/private/tmp` form of that path.
- `launch/environ.txt`: `HOME` and `CFFIXED_USER_HOME` both equal `<scratch>/home`, and `__CFPREFERENCES_AVOID_DAEMON=1`.
- `launch/real-download-folder.txt`: `absent`, or the folder recorded in the account plist.
- `add-http-download/scratch-plist-keys.txt`: the lines `umb.settings` and `umb.history`.
- `add-http-download/account-after.txt`: the same real-home records after the download and a four second settle.
- `open-url/handler-before.txt`, `open-url/handler-after.txt`, and `open-url/handler-restored.txt`: the same app path as `launch/handler-before.txt`. `unchanged` is written only when the path did not move.
- `open-url/second-pid.txt` and `open-url/second-pid-env.txt`: `none`, or the extra pid with `HOME`, `CFFIXED_USER_HOME`, and `__CFPREFERENCES_AVOID_DAEMON`.
- `open-url/account-after.txt`: the real-home records after the URL.
- `cleanup/handler-after.txt`: the app path after quit. On a clean run it matches `launch/handler-before.txt`, and `cleanup/handler-restored.txt` says `unchanged`. When cleanup had to put the handler back, `cleanup/handler-restored.txt` is that original app path.
- `cleanup/account-after.txt`: every real-home path byte-identical to the launch snapshot, or still absent, after quit and the four second settle.
- `cleanup/removed.txt`: only `scratch`, `state`, and `account-snapshot`, each with its path. Nothing under the account home.

Also confirm these on that Mac, next to the evidence:

- The Automation prompt appears, and the handoff sheet shows after `ui open-url`. The URL reached the app.
- Time one `doctor` against the real `~/Downloads`. Record the duration. A `.DS_Store` touch must leave doctor at exit 0. A new file must make it exit nonzero and name that file.

The Accessibility host named in `launch/accessibility-host.txt` is the process that must be granted access. The harness does not write the TCC database.

## Maintenance

When the app's windows or labels change, run `/maintain-verification-skill` so this map stays tied to the running app.

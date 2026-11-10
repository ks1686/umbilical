---
name: verify-umbilical
description: "Drive the umbilical macOS download manager through its real window, menu bar, and handoff sheet. Use when launching a built umbilical.app, checking that the isolated instance is worth driving, or proving a download, folder choice, pause, or handoff the way a user does."
---

# Verify umbilical

umbilical is a native macOS app. The user drives the main window titled `umbilical`, the menu bar status item, and the Settings window. There is no `umb` command-line client. The menu bar icon's accessibility description is `umbilical`. Package tests do not prove a journey in the feature map.

The harness is `.cursor/skills/verify-umbilical/scripts/verify-umbilical`. Run it from the repo root. UI commands use System Events against button titles and field labels from the SwiftUI source. They call `osascript .cursor/skills/verify-umbilical/scripts/ui.applescript`. Do not add an XCUITest target to `project.yml` for this skill.

One verification instance per Mac. The app stores its download folder and history with `UserDefaults.standard` for bundle id `me.peapod.umbilical`, in the account file `~/Library/Preferences/me.peapod.umbilical.plist`. `cfprefsd` ignores `HOME`, so launch also sets `CFFIXED_USER_HOME` to the scratch home and `__CFPREFERENCES_AVOID_DAEMON=1`. Doctor requires that scratch plist to exist, and it compares the account plist hash and mtime with the snapshot taken before launch. A change to the account plist fails the run. The harness never writes that file. A second process shares the menu bar name and the `umbilical://` handler. Launch refuses when any process is already named `umbilical`.

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

Launch reads `Contents/Info.plist` and refuses a bundle whose id is not `me.peapod.umbilical`. It refuses `PolarOrganizationID` when the value is neither empty, nor the unsubstituted `$(POLAR_ORGANIZATION_ID)` placeholder, nor a UUID. It does not print that value. On macOS it reads the signature with `codesign -d --entitlements :-` and refuses any bundle whose entitlements include `keychain-access-groups`. When the organization id is a UUID, launch continues only if `com.apple.security.get-task-allow` is present, which is the Debug injected entitlement. A Release bundle with a real organization id is not started. That build reads the shared login keychain. This harness does not activate a key, does not edit Polar config, and does not sign anything.

The scratch directory comes from `mktemp -d` under `/tmp/umbilical-verify`, which must be owned by the current user and mode `700`, and must not be a symlink. The child is `Contents/MacOS/umbilical` with `HOME`, `CFFIXED_USER_HOME`, and `TMPDIR` inside that scratch directory, plus `__CFPREFERENCES_AVOID_DAEMON=1`. `ARIA2C`, `UMB_WATCH`, and `YT_DLP` are unset so a Debug build uses `Contents/Helpers`, the same files a Release build is allowed to use. `open` is not used for launch because it does not pass those variables. Launch records the process start time with `ps -o lstart=`.

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

Exit 0 means the instance is worth driving. The recorded pid is alive. Its executable, `HOME`, `CFFIXED_USER_HOME`, `__CFPREFERENCES_AVOID_DAEMON`, and start time match the state file. The scratch preferences plist exists and is not a symlink. The account preferences plist is unchanged from the launch snapshot. The bundle version matches, no second process is named `umbilical`, and the window is past engine startup. Any other exit means it is not worth driving. A later `doctor` or `cleanup` with no `--evidence` uses the evidence path stored at launch.

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

`ui choose-folder` uses the open panel's `Choose` button (`NSOpenPanel.prompt`) and Command-Shift-G. The path may contain only letters, digits, and `._/-`, and the path itself must be a real directory. `/tmp` is a symlink on macOS, so pass a directory created for the run, not `/tmp`. `ui open-url` runs `open -a` on the verification bundle. Launch Services can then treat that bundle as the opener for `umbilical://`. Cleanup does not call `lsregister` and does not edit that database. After a run that used `ui open-url`, check which app opens `umbilical://` and point it back at the app you use if the verification build took the handler. If `open` starts a second pid whose executable is the verification bundle, that pid is stopped and the command fails. A pid with a different executable is left alone. `ui quit` and `Quit umbilical` address the recorded pid. Other clicks still use the process name, and doctor refuses a second process of that name.

A download journey needs executable `Contents/Helpers/aria2c` and `Contents/Helpers/umb-watch`. The harness does not fill those in from the environment.

## Evidence

Default evidence directory is `/opt/cursor/artifacts/verify-umbilical` when `/opt/cursor/artifacts` exists, otherwise `/tmp/umbilical-verify-evidence`. `launch` takes `--evidence` or `UMB_VERIFY_EVIDENCE`. The path must be a real directory under `/tmp` or `/opt/cursor/artifacts`, outside `/tmp/umbilical-verify`, and not a symlink. The directory is mode `700`. Files the harness writes are mode `600`. `ui dump --path` and `ui screenshot --path` must stay inside that directory. A symlink in the path is refused. `doctor`, `cleanup`, `drive`, and `ui` use the evidence path stored in the state file unless `--evidence` repeats that same path.

A passing drive writes `add-http-download/action.txt` before `Add`, then `ui.txt`, `window.png`, `file.sha256`, and `quarantine.txt`. Launch writes `launch/ready.txt`. Doctor writes `doctor/ui.txt` on macOS. `commands.log` records exits. The dump is the accessibility snapshot. The screenshot is the window rectangle from System Events. Capture the action and the resulting state. A finished row without the file bytes and the quarantine attribute is not proof. File hashes use `sha256sum` when it exists, and `shasum -a 256` otherwise.

State file default is `/tmp/umbilical-verify/state.env` (`--state` or `UMB_VERIFY_STATE`). Fields are `run_id`, `pid`, `app_path`, `executable`, `home`, `scratch`, `downloads`, `evidence`, `version`, `server_pid`, `lstart`, `prefs_sha`, and `prefs_mtime`. `scratch` is the `mktemp -d` directory `/tmp/umbilical-verify/scratch-<run-id>-<suffix>`. `home` is `<scratch>/home`. `downloads` is `<scratch>/umbilical-verify-downloads`. `prefs_sha` is `absent` or the account plist hash. The harness does not write the account plist.

## Cleanup

```bash
.cursor/skills/verify-umbilical/scripts/verify-umbilical cleanup
```

Cleanup reads the state file. Before Quit, `TERM`, or `KILL`, and before it signals a descendant, the recorded pid must still have the same executable, `HOME`, and start time. A mismatch signals nothing and leaves the scratch directory in place. On macOS, Quit is sent with System Events to that pid, not to every process named `umbilical`. If the pid is still alive after Quit, cleanup signals it, then the children collected while the identity matched. It signals `server_pid` only when that pid is `python` and one argument is exactly the payload script `verify-umbilical-payload.py`, the path is not a symlink, and the file contains the payload marker. It then deletes the scratch directory and the state file. It does not delete the evidence directory. A missing state file prints `nothing to clean` and exits 0. A scratch path outside the `mktemp` pattern, or a symlink, is left in place and cleanup exits 1. Do not kill processes by name.

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

## Maintenance

When the app's windows or labels change, run `/maintain-verification-skill` so this map stays tied to the running app.

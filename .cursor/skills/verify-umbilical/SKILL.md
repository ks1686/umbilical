---
name: verify-umbilical
description: "Drive the umbilical macOS download manager through its real window, menu bar, and handoff sheet. Use when launching a built umbilical.app, checking that the isolated instance is worth driving, or proving a download, folder choice, pause, or handoff the way a user does."
---

# Verify umbilical

umbilical is a native macOS app. The user drives the main window titled `umbilical`, the menu bar status item, and the Settings window. There is no `umb` command-line client. The menu bar icon's accessibility description is `umbilical`. Package tests do not prove a journey in the feature map.

The harness is `.cursor/skills/verify-umbilical/scripts/verify-umbilical`. Run it from the repo root. UI commands use System Events against button titles and field labels from the SwiftUI source. They call `osascript .cursor/skills/verify-umbilical/scripts/ui.applescript`. Do not add an XCUITest target to `project.yml` for this skill.

One verification instance per Mac. The app keeps its download folder and history in `UserDefaults` for bundle id `me.peapod.umbilical`. A second process shares the menu bar name and the `umbilical://` handler. Launch refuses when any process is already named `umbilical`.

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

Launch reads `Contents/Info.plist` and refuses a bundle whose id is not `me.peapod.umbilical`. It refuses `PolarOrganizationID` when the value is neither empty, nor the unsubstituted `$(POLAR_ORGANIZATION_ID)` placeholder, nor a UUID. It does not print that value. When the value is a UUID, launch reads the signature with `codesign -d --entitlements :-` and continues only if `com.apple.security.get-task-allow` is present, which is the Debug injected entitlement. A Release bundle with a real organization id is not started. That build reads the shared login keychain. This harness does not activate a key and does not edit Polar config.

The child is started from `Contents/MacOS/umbilical` with `HOME` and `TMPDIR` under `/tmp/umbilical-verify/scratch-<run-id>/`. `ARIA2C`, `UMB_WATCH`, and `YT_DLP` are unset so a Debug build uses `Contents/Helpers`, the same files a Release build is allowed to use. `open` is not used for launch because it does not pass `HOME`.

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

Exit 0 means the instance is worth driving. The recorded pid is alive, its executable is `Contents/MacOS/umbilical`, its `HOME` is the scratch home, the bundle version matches the state file, no second process is named `umbilical`, and the window is past engine startup. Any other exit means it is not worth driving.

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
  --path /tmp/umbilical-verify/scratch-RUN/umbilical-verify-downloads
.cursor/skills/verify-umbilical/scripts/verify-umbilical ui menu --name "Quit umbilical"
.cursor/skills/verify-umbilical/scripts/verify-umbilical ui open-url \
  --url "umbilical://download?url=http://127.0.0.1:9/verify-payload.txt"
```

`ui choose-folder` uses the open panel's `Choose` button (`NSOpenPanel.prompt`) and Command-Shift-G. The path may contain only letters, digits, and `._/-`. `ui open-url` runs `open -a` on the verification bundle. If that starts a second pid, that new pid is stopped and the command fails.

A download journey needs executable `Contents/Helpers/aria2c` and `Contents/Helpers/umb-watch`. The harness does not fill those in from the environment.

## Evidence

Default evidence directory is `/opt/cursor/artifacts/verify-umbilical` when `/opt/cursor/artifacts` exists, otherwise `/tmp/umbilical-verify-evidence`. Override with `--evidence` or `UMB_VERIFY_EVIDENCE`. Keep it outside the checkout and outside the scratch directory.

A passing drive writes `add-http-download/action.txt` before `Add`, then `ui.txt`, `window.png`, `file.sha256`, and `quarantine.txt`. Launch writes `launch/ready.txt`. Doctor writes `doctor/ui.txt` on macOS. `commands.log` records exits. The dump is the accessibility snapshot. The screenshot is the window rectangle from System Events. Capture the action and the resulting state. A finished row without the file bytes and the quarantine attribute is not proof.

State file default is `/tmp/umbilical-verify/state.env` (`--state` or `UMB_VERIFY_STATE`). Fields are `run_id`, `pid`, `app_path`, `executable`, `home`, `scratch`, `downloads`, `evidence`, `version`, and `server_pid`. `scratch` is `/tmp/umbilical-verify/scratch-<run-id>`. `home` is `<scratch>/home`. `downloads` is `<scratch>/umbilical-verify-downloads`.

## Cleanup

```bash
.cursor/skills/verify-umbilical/scripts/verify-umbilical cleanup
```

Cleanup reads the state file. On macOS it chooses `Quit umbilical` so the app can stop its `aria2c` child. If that pid is still alive, cleanup signals that pid, then any child pids collected before the signal. It signals `server_pid` only when that process command line contains `verify-umbilical-payload.py`. It then deletes the scratch directory and the state file. It does not delete the evidence directory. A missing state file prints `nothing to clean` and exits 0. A scratch path that is not the recorded `/tmp/umbilical-verify/scratch-<run-id>` directory, or a symlink, is left in place and cleanup exits 1. Do not kill processes by name.

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

The executable is `.cursor/skills/verify-umbilical/scripts/verify-umbilical`. `ui.applescript` is only invoked by that script, on macOS:

```bash
osascript .cursor/skills/verify-umbilical/scripts/ui.applescript read-text
```

Run `verify-umbilical` with no arguments for the command list. Exit 2 is a usage error on every host.

## Maintenance

When the app's windows or labels change, run `/maintain-verification-skill` so this map stays tied to the running app.

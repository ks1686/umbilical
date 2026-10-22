# umbilical implementation plan

Status: draft for review (Repo Guard security audit, Machine Keeper stack check).
Short name: `umb` (binary, bundle id suffix, branding).

## 1. Product rules (non-negotiable)

- Lightweight first, feature-full second. Idle memory target under 60 MB, app bundle under 40 MB excluding helpers.
- Download only. It never seeds after a download completes. While a download is in progress, upload is capped at 1 KiB/s. Do not claim zero upload. BitTorrent exchanges pieces during the download.
- Paid app, open source (GPL-3.0). Anyone may build from source and we will not block it.
- Native macOS only: Swift and SwiftUI, macOS 14 Sonoma or later, Apple Silicon and Intel.

## 2. Architecture

```
umbilical.app
├── Swift app (SwiftUI windows + MenuBarExtra)
│   ├── EngineSupervisor   starts, watches, restarts aria2c
│   ├── RPCClient          aria2 JSON-RPC over 127.0.0.1 with per-launch secret
│   ├── DownloadStore      queue, history (SQLite via GRDB or SwiftData)
│   ├── LicenseService     activation + periodic check
│   └── Updater            Sparkle 2 (EdDSA signed appcast)
├── Safari Web Extension (bundled appex)
└── Helpers/ (pinned, checksummed, codesigned)
    ├── aria2c             HTTP(S)/FTP parallel, magnet, torrent
    ├── yt-dlp             v1 video, single-file formats, no self-update
    └── ffmpeg             not bundled (separate streams are a documented gap)
```

The app never links aria2; it launches `aria2c` as a child process and talks JSON-RPC. This keeps the GPL boundary clean and lets us swap helper versions.

## 3. aria2 configuration (enforced, not user editable)

- All options are written to a per-launch config file in a private temp folder (mode 0700 folder, 0600 file) and passed with `--conf-path`. Nothing secret goes on the command line, since `ps` exposes argv. The file is deleted once aria2 is listening.
- `--enable-rpc --rpc-listen-port=<random free port> --rpc-secret=<32 random bytes, per launch>` (inside the config file only)
- `--rpc-listen-all=false --rpc-allow-origin-all=false`
- `--seed-time=0` stops seeding when the download completes. Do not set `--seed-ratio=0.0`. In aria2 that value means seed regardless of share ratio. Leave the ratio at its default of 1.0.
- `--max-upload-limit=1K` (0 means unlimited in aria2, so never 0). This caps upload while a download is in progress. It is not a claim of zero upload.
- `--follow-torrent=false` and `--follow-metalink=false`. An HTTP `addUri` of a `.torrent` or a metalink is saved as that file. Confirmed metalink handoffs use `aria2.addMetalink` with `follow-metalink=true` after the document is checked. Magnet links are added with `aria2.addUri` and do not use this switch.
- `--rpc-save-upload-metadata=false` and `--bt-save-metadata=false` so a torrent does not write extra torrent copies into the download folder.
- `--bt-max-peers` capped, DHT and PEX on by default for magnet resolution, toggle in settings
- `--check-certificate=true` (explicit, so a later change cannot silently disable TLS checks)
- `--check-integrity=true`, `--auto-file-renaming=true`, `--allow-overwrite=false`
- `--dir` limited to the user-chosen folder (security-scoped bookmark)
- The RPC secret lives only in memory in `RPCClient`. It is never logged or shown in the UI, and is only written to the temporary settings file, which is deleted once aria2 is listening.

## 4. Security requirements (from Repo Guard, to be re-audited)

1. RPC lockdown as above. `RPCClient` sends per-download options only from a fixed allowlist (for example `out`, `select-file`, `max-download-limit`, `split`). It rejects every `on-*` hook option and any `dir` outside the user-chosen folder, for `addUri`, `addTorrent`, `addMetalink`, `changeOption` and `changeGlobalOption` alike. Engine killed if the app exits (process group, `PR_SET_PDEATHSIG` equivalent via kqueue watch).
2. Downloaded files get `com.apple.quarantine` set so Gatekeeper checks them.
3. Output paths sanitized: reject `..`, absolute paths and symlink escapes from torrent metadata or server filenames.
4. Safari handoff is the URL and an optional file name. No cookies, headers, referrer, or aria2 options. A video menu item may also set a boolean `video` routing flag, which is not page content. Accepted schemes are `http`, `https`, `ftp`, `sftp`, and `magnet`. `file:`, `data:`, `javascript:`, and every other scheme are rejected. A URL or file name that starts with `-` is rejected so it cannot become an aria2 or yt-dlp option. The file name is checked with the output-name rules and is the only RPC option the handoff may set (`out`). The extension opens `umbilical://download` or `umbilical://video`. The app treats that URL as untrusted: it runs `HTTPURLPolicy` or `MagnetLink.canonical`, then `RPCOptionPolicy`, and waits for the user to confirm before starting the download. Finder may also open a `.torrent`, `.metalink`, `.meta4`, or `magnet:` URL through the same confirm sheet.
5. No helper self-update (`yt-dlp -U` disabled). Helpers update only with an app release, pinned by version and SHA-256.
6. Credentials (HTTP auth, license key) stored in the Keychain only. The license validation record is bound to this Mac: the key, the Polar activation id, and a SHA-256 of IOPlatformUUID. Items are in the data protection keychain (`kSecUseDataProtectionKeychain`), use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and are not synchronizable. The access group is the team id plus `me.peapod.umbilical`.
7. No third-party plugin system.
8. Archive extraction, if ever added, is off by default with size and ratio limits.
9. Hardened runtime, notarization, codesigned helpers. App Sandbox evaluated in M1 (aria2 child process and arbitrary folders make it hard; decision recorded in this doc).
10. Sparkle feed served over HTTPS with EdDSA signatures. The feed URL and the Mac signing steps are documented in docs/RELEASE.md. Pull requests do not sign the feed. The Mac release script signs the appcast with sign_update.
11. CI hardening (M0): GitHub Actions pinned to commit SHAs, least-privilege `permissions:` per workflow, gitleaks, Semgrep and zizmor on every PR.
12. Helper supply chain: aria2c built from source in this repo (static, `--with-appletls`, universal via `lipo`), source tarball SHA-256 recorded next to the binary hash. yt-dlp pinned only after verifying the GPG signature on its `SHA2-256SUMS`.

## 5. Licensing and distribution

- Sold direct (not Mac App Store, GPL conflict). Notarized dmg built with plain `hdiutil` from a repo script.
- License check: Polar public customer-portal license keys. $9.99 once, lifetime updates, 1 Mac per key, 14-day offline grace (`LicensePolicy.offlineGrace`). Polar enforces the Mac limit with 403 NotPermitted. `LicensePolicy.activationLimit` is display and expected-error messaging only. The app sends the organization id and does not use an access token. See `docs/LICENSING.md`.
- Source builds and Debug builds skip the check and say they are unofficial. An empty organization id is that path. There is no hidden flag.
- `THIRD_PARTY_LICENSES` bundled: aria2 (GPLv2+), yt-dlp (Unlicense), ffmpeg (LGPL, with source offer), Sparkle (MIT).

## 6. Milestones

| Milestone | Scope | Done when |
|---|---|---|
| M0 Skeleton | XcodeGen `project.yml` (no checked-in .xcodeproj), aria2c build recipe, SwiftLint, swift-format, CI build on macOS runner, helper fetch script with checksums | CI green on a PR |
| M1 Engine | EngineSupervisor + RPCClient, add/pause/resume/remove HTTP downloads | Unit tests against a real aria2c. Requests with no secret or a wrong secret are rejected, a browser page cannot open the WebSocket, and disallowed options are refused |
| M2 Torrent | Magnet and .torrent, no-seed config, file selection | Packet capture shows seeding stops at completion and upload stays capped (blocking test) |
| M3 UI | Main window list, menu bar progress, notifications | docs/M3-MANUAL.md passes, idle memory under 60 MB |
| M4 Safari | Web extension handoff | docs/M4-MANUAL.md passes |
| Video | yt-dlp, single-file formats, no ffmpeg and no JS runtime | docs/VIDEO-MANUAL.md passes. In progress, not done |
| M5 Ship | License, Sparkle, notarized dmg, landing page | Notarized build installs and updates on a clean Mac |
| Phase 2 | ffmpeg remux, scheduling, speed limits per task | v1 video is section 11 |

## 7. Open questions

1. License provider and price: decided. Polar, $9.99, 14 days, 1 Mac. Still open: create that product in the Polar dashboard and put the organization id in `Config/Licensing.local.xcconfig` on the build machine. Trademark search stays item 4.
2. Minimum macOS (14 proposed).
3. App Sandbox: decided in M1. Off. See section 8.
4. Trademark search for umbilical and umb before M5.
5. CI: GitHub Actions macOS runners for now (consistent with other repos).

## 8. M1 decisions

### App Sandbox

Off for the shipping app.

The engine launches `aria2c` as a child and writes into a folder the user picks at runtime. Sandboxing that child blocks arbitrary download folders, and sandboxing only the SwiftUI process leaves the downloader unconstrained. Revisit this if the helper moves behind a restricted XPC service.

### WebSocket

`rpc-allow-origin-all=false` stops aria2 from sending `Access-Control-Allow-Origin: *`. It does not reject a browser WebSocket handshake. aria2 answers `101 Switching Protocols` when WebSocket support is compiled in. The bundled `aria2c` is built with `--disable-websocket`. The engine still talks JSON-RPC over HTTP on `127.0.0.1`. A browser page cannot complete a WebSocket handshake, and a missing or wrong per-launch secret is rejected for JSON-RPC calls.

## 9. M2 decisions

### Seeding

The engine never seeds after a download completes. While a download is in progress, upload is capped at 1 KiB/s. Do not claim zero upload.

`seed-time=0` stops seeding when a download completes. aria2 does not treat `seed-ratio=0.0` as "do not seed". That value means seed regardless of share ratio, because the ratio check is not installed. The engine does not set `seed-ratio`. The default remains 1.0. Seeding ends when either the time or the ratio condition is met, so the zero seed time wins as soon as the download completes.

`max-upload-limit=1K` stays. In aria2, 0 means unlimited.

Per-download RPC options still cannot set `seed-ratio`, `seed-time`, or `max-upload-limit`.

### Magnets and torrents

`RPCClient.add` accepts `http`, `https`, `ftp`, `sftp`, and `magnet`. The add sheet still accepts only `http` and `https`. A magnet must start with `magnet:?` and carry `xt=urn:btih:` (40 hex characters or 32 base32 characters) or `xt=urn:btmh:` (BitTorrent v2, `1220` plus 64 hex characters). Display names, trackers, and web seeds are checked before the URI is sent. `file`, `javascript`, and every other scheme are rejected.

`RPCClient.addTorrent` reads a `.torrent`, rejects path components that escape the download folder (`..`, absolute paths, empty names, and a name that is a symlink out of the folder), and rejects non-http(s) web seeds. Tracker URLs must be `http`, `https`, or `udp`. `select-file` is 1-based and must name a file in the torrent. The RPC call is `aria2.addTorrent` with the file base64-encoded and no extra web-seed URIs.

Global `follow-metalink=false` stays so an HTTP `addUri` of a `.metalink` is saved as that file. A confirmed Finder `.meta4` or `.metalink`, and a confirmed remote metalink URL, are parsed first: every mirror URL uses the same scheme allowlist as a pasted link, and every output name must be a plain file name inside the download folder. The whole metalink is refused if any entry fails. After that check, `aria2.addMetalink` is called with `follow-metalink=true`. A Safari or Finder `.torrent` is fetched or read without cookies, then added with `aria2.addTorrent` so the never-seed config applies. The original torrent is not copied into the download folder. A magnet is still `aria2.addUri`.

### Running the engine tests

`docs/M2-MANUAL.md` is the Mac pass for this milestone. `swift test` is also how M3 package tests run. If the checkout is under `~/Documents`, `swift test` can fail at codesign with `resource fork, Finder information, or similar detritus not allowed`. Use `swift test --scratch-path /tmp/umb-spm`.

### Packet capture

`SeedCaptureTests` runs whenever the engine tests run against aria2. It is not a skip. The test builds a private torrent, serves it from loopback peers, and records TCP with tcpdump. If capture does not start, the test fails. A skip would not prove the claim.

When capture runs, the pcap must show all of the following:

- Piece payload from the local seeder, so the download is visible on the wire.
- While the download is incomplete, piece payload from the engine stays at or below `1KiB/s`, plus one 16KiB block of scheduler burst and 4KiB of slack. The peer has much more than that available to upload.
- After `tellStatus` reports `complete`, and 1.5 seconds for packets already in flight, the engine sends no further piece payload. The leecher is still requesting during the last 2 seconds before completion. `seed-time=0` then closes the peer connections, so a later request has no open session to land on.
- During the download, the aria2 process has at least one established TCP connection, and every established remote address is loopback.

Linux captures on every interface (`tcpdump -i any`, Linux cooked v2). macOS captures on `lo0`. Off-machine TCP is checked from the process socket table on both systems, not only from the pcap.

If tcpdump cannot capture, the failure says what was not proved: piece payload stopping after completion, and the 1KiB upload cap on the wire. Other tests still check that the config contains `seed-time=0` and `max-upload-limit=1K` and does not contain `seed-ratio`. Those config checks are not a packet capture.

The test tries tcpdump directly, then `sudo -n tcpdump` when the direct capture is refused.

## 10. M4 decisions

### Handoff

The Safari Web Extension is an appex embedded in `umbilical.app`. Context menu items are "Download with umbilical" on links and "Download video with umbilical" on the page and on links. The background script calls `runtime.sendNativeMessage` with `url` and, when it has one, `filename`. The video item also sets `video: true`. The native handler refuses cookies, headers, and any other field. An accepted message opens `umbilical://download?url=...&filename=...` or `umbilical://video?url=...&filename=...`.

The app validates that URL with `HTTPURLPolicy` for `http` and `https` (and `ftp`/`sftp` on the transfer path), `MagnetLink.canonical` for magnets, `DownloadPath.validateOutputName` for the optional file name, and `RPCOptionPolicy` on the resulting options. The only option is `out`. The add sheet still rejects magnets. This path accepts them after confirmation. Video handoffs go to yt-dlp, not aria2.

`umbilical://` can be opened by any local process, so the scheme is not proof that the bundled extension sent it. The sheet says a download was requested and shows the link's host. It does not name a sender. Download is not the default button. For the first second the sheet ignores clicks and Return. The download starts only after the user chooses Download. Cancel, including Return after that second, leaves the queue unchanged.

### Extension sandbox and permissions

App Sandbox stays off for the app (section 8). The extension entitlements enable App Sandbox, which Safari requires. The extension does not get the network, file, cookie, or Apple Events entitlements. Release signatures do not include `com.apple.security.get-task-allow`. Debug may, so the debugger can attach. CI checks the Release app, the appex, and the helpers.

Permissions in `Extension/Resources/manifest.json`:

| Permission | Why |
| --- | --- |
| `activeTab` | Kept so the toolbar button can grant the current tab and so the popup can read the current tab URL for "Download this page with umbilical". WebKit's context-menu path (`WebExtensionContext::addItemsToContextMenu`) still hides extension items unless the page is already granted. |
| `contextMenus` | Adds the link and video items. |
| `nativeMessaging` | Delivers the URL and optional file name to the appex. |
| `storage` | Remembers the capture toggle, default off. |
| `optional_host_permissions` `<all_urls>` | Opt-in website access. Not granted at install. The toolbar popup's Allow website access button, or turning on intercept, calls `permissions.request`. Settings also tells users to allow it in Safari Settings > Extensions > umbilical. The background recreates the menu on `permissions.onAdded`. |

`downloads` is not requested. Safari does not implement `browser.downloads` (Apple Developer Forums thread 660046, 2020, still absent from the Safari compatibility table). Click interception is the replacement.

`optional_host_permissions` is `<all_urls>`. It is not granted at install. Allow website access, or turning on "Intercept download links in Safari", explains the all-websites prompt first, then calls `permissions.request`. Safari has no `browser.downloads` API, so a content script is the only way to see a click before navigation. That script runs only after the grant, and only on `http` and `https` pages. It reads the clicked link's `href`, `download`, and `type`. It does not read page text, form fields, cookies, or headers. Option-click, Command-click, Control-click, and Shift-click skip interception. If the native handoff is not accepted, the original click proceeds. Turning intercept off does not drop website access, so the link menu still appears.

No required host permission, `webRequest`, `cookies`, `tabs`, or `scripting`. If a download needs the user's site session, it can fail in umbilical because cookies are not forwarded; Safari's own download still works, and Option-click bypasses capture.

`docs/M4-MANUAL.md` is the Mac pass. `swift test` covers the handoff parser, capture heuristics, and Finder openers. It does not load Safari.

## 11. Video downloads

v1 launches the pinned yt-dlp binary. It does not download yt-dlp, ffmpeg, or a JavaScript runtime at runtime, and it does not pass `-U` or `--update`.

The add sheet has a Video control. Known hosts turn it on until the user changes it. Any other http(s) URL stays off until the user turns it on. The host check is the exact host or a dot-suffix (`m.youtube.com`), not a substring (`notyoutube.com`).

A video download does not go through aria2. The app launches `umb-watch` with yt-dlp and a fixed argument list built in `VideoDownloadPlan`. The user cannot add flags. The child environment is an allowlist (`PATH`, `HOME`, `LC_ALL`, `LANG`, and `TMPDIR` when it is an absolute path). Config files, cookies, plugins, `--exec`, remote components, and JS runtimes are turned off (`--ignore-config`, `--no-config-locations`, `--no-plugin-dirs`, `--no-exec`, `--no-remote-components`, `--no-js-runtimes`). The downloader is `--downloader native`.

The format selector is `b/bv*/ba`. A `+` merge is not requested. `--fixup never` is set. `--ffmpeg-location` is the private staging directory, so yt-dlp does not search `PATH` for ffmpeg. Separate audio and video streams fail. That gap stays until ffmpeg is bundled on purpose.

`--no-js-runtimes` and `--no-remote-components` mean a system deno or node is not executed and yt-dlp-ejs is not downloaded. YouTube's web client may be skipped. A direct media URL is the v1 pass. A YouTube failure is not a pass.

The output template is the constant `umb-video.%(ext)s` inside a mode `0700` staging directory `umb-video-<32 hex>` under the chosen folder. The save-as name is not placed in the argument list, because `%` is a template metacharacter and is rejected. After success, exactly one regular file matching `umb-video.<ext>` is quarantined, then renamed into the chosen folder. A name that contains a dot is used as-is. A name without a dot gets `.<ext>`. The default name is `umb-video-<32 hex>.<ext>`. Symlinks, extra files, and an existing destination are rejected. Partials (`*.part`, `*.ytdl`, `*.temp`) are unlinked. The staging directory is removed without following a directory symlink.

Only `http` and `https` URLs pass `HTTPURLPolicy`. Finished files get `com.apple.quarantine`, same as other downloads.

Cancel sends `SIGTERM` to `umb-watch`, which kills the yt-dlp process group. The row's button says Cancel and does not ask for confirmation. Pause is not offered.

Release builds ignore `YT_DLP`. Debug builds honor it when the path is executable. The helper is copied and signed by `scripts/copy-bundled-yt-dlp.sh` with `--options runtime`, the same pattern as aria2c. A Release build fails when `helpers/bin/yt-dlp` is missing. Debug warns and continues. The same rule applies to `scripts/copy-bundled-aria2.sh`: Release fails when `helpers/bin/aria2c` is missing, and Debug warns and continues. `YT_DLP_CODESIGN_IDENTITY` and `ARIA2_CODESIGN_IDENTITY` stay `-` for ad hoc builds. The Mac release script sets them to the Developer ID and the copy scripts then pass `--timestamp`. Ad hoc signatures still omit `--timestamp`. Xcode's own sign stays ad hoc. `scripts/release/sign-bundle.sh` applies the Developer ID to the helpers, Sparkle, and the app after the build. That is the signature that ships.

Repo Guard: `helpers/yt-dlp.entitlements` is on the helper only. yt-dlp_macos is a PyInstaller binary that unpacks a Python runtime at launch. Hardened runtime needs all three of these or `--version` does not return on current arm64 macOS:

- `com.apple.security.cs.disable-library-validation` so the extracted libpython, signed by another team, can load
- `com.apple.security.cs.allow-unsigned-executable-memory` for libffi's writable executable mapping
- `com.apple.security.cs.allow-jit` for `MAP_JIT` on arm64

`disable-library-validation` alone can hang in libffi. The app entitlements do not gain these keys. `com.apple.security.get-task-allow` is not set. CI signs the pinned binary with `-o runtime` and runs `<app>/Contents/Helpers/yt-dlp --version` from the Release app. The decision is recorded in `docs/RELEASE.md`.

`docs/VIDEO-MANUAL.md` is the Mac pass. It has not been run. The checklist item is in progress, not done.

# umbilical implementation plan

Status: draft for review (Repo Guard security audit, Machine Keeper stack check).
Short name: `umb` (binary, bundle id suffix, branding).

## 1. Product rules (non-negotiable)

- Lightweight first, feature-full second. Idle memory target under 60 MB, app bundle under 40 MB excluding helpers.
- Download only. No seeding, ever. We never claim "zero upload" because BitTorrent exchanges pieces while downloading; we claim "never seeds".
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
    ├── yt-dlp             phase 2, video
    └── ffmpeg (LGPL, remux only)  phase 2
```

The app never links aria2; it launches `aria2c` as a child process and talks JSON-RPC. This keeps the GPL boundary clean and lets us swap helper versions.

## 3. aria2 configuration (enforced, not user editable)

- All options are written to a per-launch config file in a private temp folder (mode 0700 folder, 0600 file) and passed with `--conf-path`. Nothing secret goes on the command line, since `ps` exposes argv. The file is deleted once aria2 is listening.
- `--enable-rpc --rpc-listen-port=<random free port> --rpc-secret=<32 random bytes, per launch>` (inside the config file only)
- `--rpc-listen-all=false --rpc-allow-origin-all=false`
- `--seed-time=0` (this is what stops seeding; `--seed-ratio=0.0` means ignore ratio and is set only for clarity)
- `--max-upload-limit=1K` (0 means unlimited in aria2, so never 0)
- `--bt-max-peers` capped, DHT and PEX on by default for magnet resolution, toggle in settings
- `--check-certificate=true` (explicit, so a later change cannot silently disable TLS checks)
- `--check-integrity=true`, `--auto-file-renaming=true`, `--allow-overwrite=false`
- `--dir` limited to the user-chosen folder (security-scoped bookmark)
- The RPC secret lives only in memory in `RPCClient`. It is never logged or shown in the UI, and is only written to the temporary settings file, which is deleted once aria2 is listening.

## 4. Security requirements (from Repo Guard, to be re-audited)

1. RPC lockdown as above. `RPCClient` sends per-download options only from a fixed allowlist (for example `out`, `select-file`, `max-download-limit`, `split`). It rejects every `on-*` hook option and any `dir` outside the user-chosen folder, for `addUri`, `addTorrent`, `addMetalink`, `changeOption` and `changeGlobalOption` alike. Engine killed if the app exits (process group, `PR_SET_PDEATHSIG` equivalent via kqueue watch).
2. Downloaded files get `com.apple.quarantine` set so Gatekeeper checks them.
3. Output paths sanitized: reject `..`, absolute paths and symlink escapes from torrent metadata or server filenames.
4. Safari handoff is narrow: URL, suggested filename, referrer only. No cookies or auth headers in MVP. Only `http`, `https` and `magnet` schemes are accepted; `file:`, `javascript:` and everything else is rejected. The app verifies the sender is our own bundled extension.
5. No helper self-update (`yt-dlp -U` disabled). Helpers update only with an app release, pinned by version and SHA-256.
6. Credentials (HTTP auth, license key) stored in the Keychain only.
7. No third-party plugin system.
8. Archive extraction, if ever added, is off by default with size and ratio limits.
9. Hardened runtime, notarization, codesigned helpers. App Sandbox evaluated in M1 (aria2 child process and arbitrary folders make it hard; decision recorded in this doc).
10. Sparkle feed served over HTTPS with EdDSA signatures. The EdDSA private key lives only on Karim's Mac and never enters CI. Release signing runs locally.
11. CI hardening (M0): GitHub Actions pinned to commit SHAs, least-privilege `permissions:` per workflow, gitleaks, Semgrep and zizmor on every PR.
12. Helper supply chain: aria2c built from source in this repo (static, `--with-appletls`, universal via `lipo`), source tarball SHA-256 recorded next to the binary hash. yt-dlp pinned only after verifying the GPG signature on its `SHA2-256SUMS`.

## 5. Licensing and distribution

- Sold direct (not Mac App Store, GPL conflict). Notarized dmg built with plain `hdiutil` from a repo script.
- License check: server-side activation, offline grace period (proposal 14 days), device limit (proposal 3). Provider to pick: Lemon Squeezy, Paddle or Keygen. Open question for Karim.
- Source builds: a `UMB_UNLICENSED` build flag skips the check. Documented, not hidden.
- `THIRD_PARTY_LICENSES` bundled: aria2 (GPLv2+), yt-dlp (Unlicense), ffmpeg (LGPL, with source offer), Sparkle (MIT).

## 6. Milestones

| Milestone | Scope | Done when |
|---|---|---|
| M0 Skeleton | XcodeGen `project.yml` (no checked-in .xcodeproj), aria2c build recipe, SwiftLint, swift-format, CI build on macOS runner, helper fetch script with checksums | CI green on a PR |
| M1 Engine | EngineSupervisor + RPCClient, add/pause/resume/remove HTTP downloads | Unit tests against a real aria2c. Requests with no secret or a wrong secret are rejected, a browser page cannot open the WebSocket, and disallowed options are refused |
| M2 Torrent | Magnet and .torrent, no-seed config, file selection | Packet capture shows seeding stops at completion and upload stays capped (blocking test) |
| M3 UI | Main window list, menu bar progress, notifications | Manual test script passes, idle memory target met |
| M4 Safari | Web extension handoff | Download link in Safari lands in umbilical |
| M5 Ship | License, Sparkle, notarized dmg, landing page | Notarized build installs and updates on a clean Mac |
| Phase 2 | yt-dlp video, ffmpeg remux, scheduling, speed limits per task | |

## 7. Open questions

1. License provider and price.
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

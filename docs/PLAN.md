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

- `--enable-rpc --rpc-listen-port=<random free port> --rpc-secret=<32 random bytes, per launch>`
- `--rpc-listen-all=false --rpc-allow-origin-all=false`
- `--seed-time=0 --seed-ratio=0.0`
- `--max-upload-limit=1K` (0 means unlimited in aria2, so never 0)
- `--bt-max-peers` capped, DHT and PEX on by default for magnet resolution, toggle in settings
- `--check-integrity=true`, `--auto-file-renaming=true`, `--allow-overwrite=false`
- `--dir` limited to the user-chosen folder (security-scoped bookmark)
- The RPC secret lives only in memory in `RPCClient`. It is never logged, written to disk, or shown in the UI.

## 4. Security requirements (from Repo Guard, to be re-audited)

1. RPC lockdown as above. Engine killed if the app exits (process group, `PR_SET_PDEATHSIG` equivalent via kqueue watch).
2. Downloaded files get `com.apple.quarantine` set so Gatekeeper checks them.
3. Output paths sanitized: reject `..`, absolute paths and symlink escapes from torrent metadata or server filenames.
4. Safari handoff is narrow: URL, suggested filename, referrer only. No cookies or auth headers in MVP.
5. No helper self-update (`yt-dlp -U` disabled). Helpers update only with an app release, pinned by version and SHA-256.
6. Credentials (HTTP auth, license key) stored in the Keychain only.
7. No third-party plugin system.
8. Archive extraction, if ever added, is off by default with size and ratio limits.
9. Hardened runtime, notarization, codesigned helpers. App Sandbox evaluated in M1 (aria2 child process and arbitrary folders make it hard; decision recorded in this doc).
10. Sparkle feed served over HTTPS with EdDSA signatures; key kept off CI runners except a release job with protected secret.

## 5. Licensing and distribution

- Sold direct (not Mac App Store, GPL conflict). Notarized dmg.
- License check: server-side activation, offline grace period (proposal 14 days), device limit (proposal 3). Provider to pick: Lemon Squeezy, Paddle or Keygen. Open question for Karim.
- Source builds: a `UMB_UNLICENSED` build flag skips the check. Documented, not hidden.
- `THIRD_PARTY_LICENSES` bundled: aria2 (GPLv2+), yt-dlp (Unlicense), ffmpeg (LGPL, with source offer), Sparkle (MIT).

## 6. Milestones

| Milestone | Scope | Done when |
|---|---|---|
| M0 Skeleton | Xcode project, SwiftLint, swift-format, CI build on macOS runner, helper fetch script with checksums | CI green on a PR |
| M1 Engine | EngineSupervisor + RPCClient, add/pause/resume/remove HTTP downloads | Unit tests against a real aria2c, RPC not reachable from another user or origin |
| M2 Torrent | Magnet and .torrent, no-seed config, file selection | Packet capture shows seeding stops at completion, upload stays capped |
| M3 UI | Main window list, menu bar progress, notifications | Manual test script passes, idle memory target met |
| M4 Safari | Web extension handoff | Download link in Safari lands in umbilical |
| M5 Ship | License, Sparkle, notarized dmg, landing page | Notarized build installs and updates on a clean Mac |
| Phase 2 | yt-dlp video, ffmpeg remux, scheduling, speed limits per task | |

## 7. Open questions

1. License provider and price.
2. Minimum macOS (14 proposed).
3. App Sandbox yes or no (M1 spike).
4. Trademark search for umbilical and umb before M5.
5. CI: GitHub Actions macOS runners for now (consistent with other repos).

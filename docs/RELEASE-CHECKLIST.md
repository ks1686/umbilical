# v1 release checklist

Each item has an owner and a state. An item is marked done only after it has been verified.
Last updated October 15, 2026.

| Item | Owner | State |
| --- | --- | --- |
| M0 skeleton (PR #1, merged `d55d279`) | Code Lead | done |
| M1 engine (PR #2, merged `1e02b8a`) | Code Lead | done |
| Release decisions doc (PR #3, merged `ec0c5ad`) | Code Lead | done |
| M2 torrent and magnet, no seeding, packet-capture test (release blocker) | Code Lead | in progress |
| M2 follow-ups: zizmor online audits, remove `seed-ratio=0.0`, `just test` recipe | Code Lead | in progress |
| M3 UI (Mac checklist in docs/M3-MANUAL.md, not yet run) | Code Lead | in progress |
| M4 Safari extension | Code Lead | planned |
| Video downloads with yt-dlp and ffmpeg | Code Lead | planned |
| M5 ship: dmg, Sparkle update feed | Code Lead | planned |
| Signing prerequisites on the Mac (Developer ID cert in Keychain, notarytool settings, App Store Connect key file at 600), verified Oct 15 | Machine Keeper | done |
| Sparkle key generation on the signing Mac | Machine Keeper | planned |
| Sparkle private key committed to the local genv config repo (backup model: Karim's self-hosted encrypted git remote and DAS Time Machine, returning with the new machine in about a month; Karim treats this as in place) | Machine Keeper | planned |
| App Store Connect API key committed to the local genv config repo (same backup model) | Machine Keeper | planned (pending, not done) |
| Developer ID signing and notarization of the release dmg | Machine Keeper | planned |
| License provider choice | Code Lead | planned |
| Price, offline grace period, device limit | Code Lead | planned |
| Trademark check for umbilical and umb | Code Lead | planned |
| License integration: server decides every activation, no key-minting secret in the app, signed activation replies, minimal device data (release blocker) | Code Lead | planned |
| Homebrew cask in ks1686/homebrew-tap, pinned dmg SHA-256, `auto_updates true` | Code Lead | planned |
| Cask checks on the Mac: `brew audit --cask`, `brew style`, install from tap, brew still sees app current after a Sparkle update | Machine Keeper | planned |
| Final security review (signing, update feed, license check against the license rules above, Homebrew cask, App Sandbox, release tag scan) | Repo Guard | planned |
| Milestone Mac tests with a real aria2c | Machine Keeper | planned for each remaining milestone |

Notes:
- The signing Mac's config lives in `~/.config/genv`, which is local only with no remote. GitHub `ks1686/genv` is the public Go genv CLI, a separate project.
- See `docs/RELEASE.md` for the signing and key handling rules.

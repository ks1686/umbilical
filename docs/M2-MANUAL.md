# M2 manual test

Run this on a Mac with Xcode, after `scripts/build-aria2.sh`.
The engine tests are the M2 gate in `docs/PLAN.md`.

The engine never seeds after a download completes. While a download is in
progress, upload is capped at 1 KiB/s. That cap is not zero upload.

## Package tests

```bash
just test
```

`just test` builds `aria2c` and runs `swift test` with `UMB_REQUIRE_ARIA2=1`.
On macOS the binary comes from `scripts/build-aria2.sh`.

If the checkout is under `~/Documents`, `swift test` can fail at codesign
with `resource fork, Finder information, or similar detritus not allowed`.
Use `swift test --scratch-path /tmp/umb-spm`. Set `ARIA2C` to the built
binary and `UMB_REQUIRE_ARIA2=1` when you call `swift test` directly.

The same codesign failure applies to M3 package tests. Use the same
`--scratch-path /tmp/umb-spm`.

## What a pass shows

- A magnet from the local tracker and seeding aria2 finishes while
  `follow-torrent=false`.
- One local HTTP URL serves a `.torrent` and another serves a `.metalink`.
  Each file is saved as those bytes. aria2 does not start a child download:
  `followedBy` is empty and no extra GID appears.
- `SeedCaptureTests` prints `SeedCapture: ran on lo0, PASS` when the capture
  ran on the loopback interface. That line is the proof the test was not
  skipped. After completion the engine sends no piece payload. While the
  download is in progress, piece upload stays at or below 1 KiB/s, plus one
  16 KiB block of scheduler burst and 4 KiB of slack.

The capture test needs permission to record TCP. It tries tcpdump, then
`sudo -n tcpdump`.

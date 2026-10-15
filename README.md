# umbilical

umbilical is a native macOS download manager for macOS 14 and later, on
Apple Silicon and Intel. It only downloads. It never seeds.

The app is paid. It is also GPL-3.0-or-later, and anyone can build it from
this source tree. Nothing here is meant to stop a source build.

The app does not link aria2. A later milestone launches `aria2c` as a child
process. This skeleton is the Xcode project, the helper recipes, and CI.

## Build the app

Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0, then:

```bash
xcodegen generate
xcodebuild \
  -project umbilical.xcodeproj \
  -scheme umbilical \
  -destination 'platform=macOS' \
  build test
```

The `.xcodeproj` is generated. It is not checked in. CI uses the same
`project.yml` and pins XcodeGen 2.46.0 and SwiftLint 0.65.1 by SHA-256.

SwiftLint and the `swift-format` that ships with Xcode both have configs
in this repo (`.swiftlint.yml` and `.swift-format`).

```bash
swiftlint lint --strict
xcrun swift-format lint --strict --recursive --configuration .swift-format App Tests
```

## Helpers

`scripts/build-aria2.sh` downloads aria2 1.37.0 from the official GitHub
release, checks the SHA-256 in `helpers/aria2.lock`, and builds a universal
`aria2c`. The build is static, uses `--with-appletls`, and does not use
OpenSSL or GnuTLS. It compiles arm64 and x86_64, then combines them with
`lipo`. The compile needs macOS, Xcode, `pkg-config`, and `perl`.
`scripts/build-aria2.sh --verify-tarball` only checks the tarball hash.

The recipe freezes `__DATE__` and `__TIME__` to the 1.37.0 release instant
(2023-11-15 12:07:32 UTC) and links with `-Wl,-reproducible`, so the
universal binary hash in `helpers/aria2.lock` can stay stable.

`scripts/fetch-helpers.sh` downloads the pinned yt-dlp macOS binary. It
checks the GPG signature on that release's `SHA2-256SUMS` with the published
key in `helpers/yt-dlp.asc` before it trusts the SHA-256 in
`helpers/yt-dlp.lock`. It does not run yt-dlp, and it does not pass `-U`.
yt-dlp is phase 2. ffmpeg is phase 2 and is not fetched yet.

Both scripts need `curl`. The yt-dlp script also needs `gpg`.

## License

See `LICENSE` and `THIRD_PARTY_LICENSES`.

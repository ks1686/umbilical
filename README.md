# umbilical

umbilical is a native macOS download manager for macOS 14 and later, on
Apple Silicon and Intel. It only downloads. It never seeds.

The app is paid. It is also GPL-3.0-or-later, and anyone can build it from
this source tree. Nothing here is meant to stop a source build.

The app does not link aria2. The engine launches the bundled `aria2c` as a
child process and talks to it over loopback JSON-RPC. The Xcode project is
the app shell. Engine tests run through Swift Package Manager.

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
`aria2c`. The build is static, uses `--with-appletls` and
`--disable-websocket`, and does not use OpenSSL or GnuTLS. WebSocket is
left out because aria2 would still accept a browser handshake when that
server is compiled in. It compiles arm64 and x86_64, then combines them with
`lipo`. The compile needs macOS, Xcode, `pkg-config`, and `perl`.
`scripts/build-aria2.sh --verify-tarball` only checks the tarball hash.

The recipe freezes `__DATE__` and `__TIME__` to the 1.37.0 release instant
(2023-11-15 12:07:32 UTC), pins object mtimes, and links with
`-Wl,-reproducible`. `CXXFLAGS` include `-include iterator` because Xcode
27's libc++ no longer includes that header through other headers.
`helpers/aria2.lock` keeps one universal-binary SHA-256 per Xcode and
clang. The source tarball SHA-256 is the trust anchor. A toolchain with
no recorded hash stops the script.

`scripts/fetch-helpers.sh` downloads the pinned yt-dlp macOS binary. It
checks the GPG signature on that release's `SHA2-256SUMS` with the published
key in `helpers/yt-dlp.asc` before it trusts the SHA-256 in
`helpers/yt-dlp.lock`. It does not run yt-dlp, and it does not pass `-U`.
yt-dlp is phase 2. ffmpeg is phase 2 and is not fetched yet.

Both scripts need `curl`. The yt-dlp script also needs `gpg`.

## Engine tests

`just test` builds `aria2c`, then runs `swift test` with `UMB_REQUIRE_ARIA2=1`.
On macOS the binary comes from `scripts/build-aria2.sh`. On Linux it comes from
`scripts/build-aria2-linux.sh`. A local run cannot pass by skipping the real
aria2 tests.

The seeding test records TCP with tcpdump. It needs permission to capture.
The test tries tcpdump directly, then `sudo -n tcpdump` when that is refused.

## License

See `LICENSE` and `THIRD_PARTY_LICENSES`.

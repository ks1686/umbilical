# M4 manual test

Run this on a Mac with Xcode and Safari, after `scripts/build-aria2.sh` and an
app build. The script is the M4 gate in `docs/PLAN.md`.

Video downloads, licensing, Sparkle, and notarization are out of scope.
The add sheet still rejects magnets. The Safari handoff accepts `http`,
`https`, and `magnet` after you confirm.

## Build

```bash
scripts/build-aria2.sh
xcodegen generate
xcodebuild \
  -project umbilical.xcodeproj \
  -scheme umbilical \
  -destination 'platform=macOS' \
  -configuration Debug \
  build
```

The built app is under DerivedData. `umbilicalExtension.appex` is inside
`Contents/PlugIns`. Launch that app once so macOS registers the extension.

Confirm App Sandbox is off for the app and on for the extension:

```bash
APP="/path/to/umbilical.app"
codesign -d --entitlements :- "$APP"
codesign -d --entitlements :- "$APP/Contents/PlugIns/umbilicalExtension.appex"
```

The app entitlements must not contain `com.apple.security.app-sandbox`.
The appex entitlements must contain `com.apple.security.app-sandbox` set to
true, and must not add network, file, cookie, or Apple Events exceptions.

## Extension permissions

`Extension/Resources/manifest.json` requests only these:

| Permission | Why |
| --- | --- |
| `contextMenus` | Puts "Download with umbilical" on the link menu. |
| `nativeMessaging` | Sends the URL and optional file name to the appex. |
| `storage` | Stores the optional download-capture toggle. It starts off. |

`downloads` is not requested. Safari does not let an extension see browser
downloads, so the popup leaves that control off and disabled. There is no
host permission and no `cookies`, `webRequest`, `tabs`, or `scripting`
permission. The message may contain `url` and `filename` only.

## Enable the extension

1. Quit other copies of umbilical. Open the Debug build you just made.
2. Choose a download folder, for example `~/Downloads/umbilical-safari`.
3. In Safari, open Settings, then Advanced, and turn on "Show features for web developers".
4. From the Develop menu, choose "Allow Unsigned Extensions" and confirm.
5. Safari Settings, Extensions. Enable umbilical. If Safari asks which app it belongs to, it is this build.
6. Click the umbilical toolbar button. The popup says to right-click a link. The capture checkbox is off and disabled, and it says Safari does not let the extension see downloads.

## Checklist

1. Right-click an `https` link, for example `https://example.com/` on a page you are allowed to fetch. Choose "Download with umbilical". The app comes forward. The sheet shows the URL and says nothing starts until you confirm. No download row exists yet.
2. Click Cancel. The sheet closes. The list is unchanged.
3. Right-click the same link again. Click Download. A row appears and moves through waiting or active. The file lands in the download folder.
4. Repeat with a link whose path ends in a file name, such as a `.zip` or `.txt` you are allowed to fetch. The sheet shows "Save as" with that file name and no directory part. After Download, the saved file uses that name.
5. Magnet. From Terminal, with the app running:

   ```bash
   open 'umbilical://download?url=magnet:?xt=urn:btih:abababababababababababababababababababab'
   ```

   The sheet shows the magnet. Cancel once and confirm the list is unchanged. Open it again and click Download. A row appears. It may later fail to find peers. That still counts: the handoff was accepted. The add sheet still rejects the same magnet.
6. Rejected schemes and fields. None of these add a row. Each one shows "Download rejected" (or the sheet stays closed) and does not start a download:

   ```bash
   open 'umbilical://download?url=file:///tmp/x'
   open 'umbilical://download?url=javascript:alert(1)'
   open 'umbilical://download?url=https://user:secret@example.com/a'
   open 'umbilical://download?url=https://example.com/&cookie=secret'
   open 'umbilical://download?url=https://example.com/a.bin&filename=../x'
   ```

7. Quit from the menu bar. `pgrep aria2c` prints nothing.

## Package tests

`swift test` covers handoff parsing: allowed fields, `HTTPURLPolicy`,
`MagnetLink.canonical`, output names, and `RPCOptionPolicy`. A confirmed
handoff is the only value the session will add, and a poisoned options
dictionary is rebuilt from the URL and file name. Those tests do not replace
this Mac pass.

If the checkout is under `~/Documents`, `swift test` can fail at codesign
with `resource fork, Finder information, or similar detritus not allowed`.
Use `swift test --scratch-path /tmp/umb-spm`.

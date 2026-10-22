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

A Debug build may include `com.apple.security.get-task-allow` so the debugger
can attach. A Release build must not. CI runs
`scripts/check-no-get-task-allow.sh` on the Release app, the appex, and
`Contents/Helpers`.

## Extension permissions

`Extension/Resources/manifest.json` requests only these:

| Permission | Why |
| --- | --- |
| `activeTab` | Kept so choosing the toolbar button can grant the current tab. WebKit still hides extension context menus until the page is already granted. |
| `contextMenus` | Puts "Download with umbilical" on the link menu. |
| `nativeMessaging` | Sends the URL and optional file name to the appex. |
| `optional_host_permissions` `<all_urls>` | Not granted at install. A toolbar popup click calls `permissions.request`, or the user allows Website Access in Safari Settings > Extensions > umbilical. |

`downloads` is not requested. Safari does not implement `browser.downloads`.
There is no required `host_permissions` key and no `cookies`, `webRequest`,
`tabs`, `scripting`, or `storage` permission, and no content scripts. The
native message may contain `url` and `filename` only. Until website access
is allowed, Safari Settings may say the extension does not have permission
to read, alter, or transmit content from any webpages, and the link menu
stays hidden. That is expected.

## Enable the extension

1. Quit other copies of umbilical. Open the Debug build you just made.
2. Choose a download folder, for example `~/Downloads/umbilical-safari`.
3. In Safari, open Settings, then Advanced, and turn on "Show features for web developers".
4. From the Develop menu, choose "Allow Unsigned Extensions" and confirm.
5. Safari Settings, Extensions. Enable umbilical. If Safari asks which app it belongs to, it is this build.
6. Click the umbilical toolbar button. The popup says Safari hides the
   link item until website access is allowed, has Allow website access,
   and says only the URL and an optional file name are sent. There is no
   download-capture checkbox.

## 1.0.1 menu regression (notarized or Debug)

This is the pass for the v1.0.0 bug: the link item never appeared, and
Safari Settings said umbilical does not have permission to read, alter,
or transmit content from any webpages. `activeTab` alone is not enough
on a notarized 1.0.1 build. Website access has to be granted.

1. Install this build (notarized 1.0.1, or this Debug app). Enable
   umbilical in Safari Settings > Extensions. Website Access should be
   listed. Leave it unset for now.
2. Click the umbilical toolbar button. Choose Allow website access.
   Safari must prompt. Grant this website or all websites. You can
   instead set Website Access in Safari Settings > Extensions >
   umbilical.
3. Open a real page over https, for example `https://example.com/`.
4. Right-click a real link on that page. "Download with umbilical" must
   appear. If it does not after access is granted, this build fails.
5. Choose that item. The confirm sheet must open with that link. The
   popup must still say the extension sends only the URL and an optional
   file name.

Then continue with the checklist below.

## Checklist

1. Right-click an `https` link, for example `https://example.com/` on a page you are allowed to fetch. Choose "Download with umbilical". The app comes forward. The sheet shows the host in large type (`example.com` for that link) and the full URL under it. The text says a download was requested. It does not name Safari or any other app. No download row exists yet.
2. Immediately press Return, then click Download. The sheet stays open. The list stays empty. Return is not Download.
3. Wait about a second. Press Return. The sheet closes. The list is still empty.
4. Right-click the same link again. Wait about a second. Click Download. A row appears and moves through waiting or active. The file lands in the download folder.
5. Repeat with a link whose path ends in a file name, such as a `.zip` or `.txt` you are allowed to fetch. The sheet shows "Save as" with that file name and no directory part. After Download, the saved file uses that name.
6. Magnet. From Terminal, with the app running:

   ```bash
   open 'umbilical://download?url=magnet:?xt=urn:btih:abababababababababababababababababababab'
   ```

   The sheet shows `magnet` in large type, not a sender name. Press Return before a second has passed and confirm the list is unchanged. Open it again, wait about a second, and click Download. A row appears. It may later fail to find peers. That still counts: the handoff was accepted. The add sheet still rejects the same magnet.
7. Rejected schemes and fields. None of these add a row. Each one shows "Download rejected" (or the sheet stays closed) and does not start a download:

   ```bash
   open 'umbilical://download?url=file:///tmp/x'
   open 'umbilical://download?url=javascript:alert(1)'
   open 'umbilical://download?url=https://user:secret@example.com/a'
   open 'umbilical://download?url=https://example.com/&cookie=secret'
   open 'umbilical://download?url=https://example.com/a.bin&filename=../x'
   ```

8. Quit from the menu bar. `pgrep aria2c` prints nothing.

## Package tests

`swift test` covers handoff parsing: allowed fields, `HTTPURLPolicy`,
`MagnetLink.canonical`, output names, and `RPCOptionPolicy`. A confirmed
handoff is the only value the session will add, and a poisoned options
dictionary is rebuilt from the URL and file name. It also covers the
confirmation gate: Return and a click in the first second do not confirm.
Those tests do not replace this Mac pass.

If the checkout is under `~/Documents`, `swift test` can fail at codesign
with `resource fork, Finder information, or similar detritus not allowed`.
Use `swift test --scratch-path /tmp/umb-spm`.

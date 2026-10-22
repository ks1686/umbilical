# M4 manual test

Run this on a Mac with Xcode and Safari, after `scripts/build-aria2.sh` and an
app build. The script is the M4 gate in `docs/PLAN.md`.

Video downloads, licensing, Sparkle, and notarization are out of scope except
for the video menu and "Download this page" handoff, which must open the
confirm sheet. The add sheet still rejects magnets. The Safari handoff
accepts `http`, `https`, `ftp`, `sftp`, and `magnet` after you confirm.

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

`Extension/Resources/manifest.json` requests these:

| Permission | Why |
| --- | --- |
| `activeTab` | Kept so choosing the toolbar button can grant the current tab, and so the popup can read the current tab URL. WebKit still hides extension context menus until the page is already granted. |
| `contextMenus` | Puts "Download with umbilical" on the link menu and "Download video with umbilical" on the page and link menus. |
| `nativeMessaging` | Sends the URL and optional file name to the appex. |
| `storage` | Remembers the capture toggle. Default is off. |
| `optional_host_permissions` `<all_urls>` | Not granted at install. A toolbar popup click on Allow website access, or turning on intercept, calls `permissions.request`. You can also allow Website Access in Safari Settings > Extensions > umbilical. |

`downloads` is not requested. Safari does not implement `browser.downloads`.
There is no required `host_permissions` key and no `cookies`, `webRequest`,
`tabs`, or `scripting` permission. The native message may contain `url`,
`filename`, and an optional `video` flag. Until website access is allowed,
Safari Settings may say the extension does not have permission to read,
alter, or transmit content from any webpages, and the link menu stays
hidden. That is expected.

## Enable the extension

1. Quit other copies of umbilical. Open the Debug build you just made.
2. Choose a download folder, for example `~/Downloads/umbilical-safari`.
3. In Safari, open Settings, then Advanced, and turn on "Show features for web developers".
4. From the Develop menu, choose "Allow Unsigned Extensions" and confirm.
5. Safari Settings, Extensions. Enable umbilical. If Safari asks which app it belongs to, it is this build.
6. Click the umbilical toolbar button. The popup says Safari hides the
   link item until website access is allowed, has Allow website access,
   and says only the URL and an optional file name are sent. Intercept is
   off. The copy explains that turning it on asks Safari for access to all
   websites.

## 1.0.1 menu regression (still required on 1.1.0)

This is the pass for the v1.0.0 bug: the link item never appeared, and
Safari Settings said umbilical does not have permission to read, alter,
or transmit content from any webpages. `activeTab` alone is not enough
on a notarized 1.0.1 build. Website access has to be granted.

1. Install this build. Enable umbilical in Safari Settings > Extensions.
   Website Access should be listed. Leave intercept off.
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

## Click interception (Safari has no downloads API)

Safari does not implement `browser.downloads`. Capture is a content script
on the clicked link only, and it stays off until you opt in.

Use a local html file served over http, or any https page you control that
contains the links below. Do not use a page that needs a login.

```html
<!doctype html>
<title>umbilical capture</title>
<p><a href="https://example.com/file.zip">zip</a></p>
<p><a href="https://example.com/file.bin" download="file.bin">download attr</a></p>
<p><a href="https://example.com/payload.torrent">torrent</a></p>
<p><a href="https://example.com/list.meta4">metalink</a></p>
<p><a href="magnet:?xt=urn:btih:abababababababababababababababababababab">magnet</a></p>
<p><a href="https://example.com/">ordinary</a></p>
```

Serve it with `python3 -m http.server 8765` and open `http://127.0.0.1:8765/`.

1. Capture still off. Click `zip`. Safari navigates or downloads on its
   own. umbilical does not come forward. The queue is empty.
2. Open the popup. Read the all-websites warning. Check "Intercept
   download links in Safari". If website access is not already granted,
   Safari must prompt for access to all websites. Allow it. If you deny,
   the checkbox must stay off and clicks must still reach Safari.
3. Click `zip`. The confirm sheet opens with `example.com` and
   `file.zip`. No download row exists yet. Cancel. Safari must not also
   navigate that click.
4. Click `download attr`. The sheet shows "Save as file.bin".
5. Click `torrent`. The sheet shows a `.torrent` name. After you confirm,
   umbilical fetches that URL without cookies and adds it as a torrent.
   If the URL is a placeholder, the fetch can fail after confirm. That is
   still a pass for interception. The failure must not start aria2 with
   cookies or extra options.
6. Click `metalink`. The sheet opens. After confirm, umbilical fetches
   that metalink, checks its mirror URLs and file names, and starts the
   files it names. If the URL is a placeholder, the fetch can fail after
   confirm.
7. Click `magnet`. The sheet shows `magnet`. The add sheet still rejects
   the same magnet.
8. Click `ordinary`. Safari follows the link. umbilical does not open.
9. Option-click `zip`. Safari handles the click. umbilical does not open.
10. Turn intercept off in the popup. Click `zip`. Safari handles it.
    Website access stays so the link menu still works. Remove it in
    Safari Settings > Extensions if you want it gone.
11. If the app is quit, or native messaging fails, a captured click must
    fall through to Safari. Quit umbilical, click `zip` with capture on,
    and confirm Safari navigates or downloads.

The content script must not be able to send cookies, headers, or page
text. The confirm sheet still shows only the URL and file name.

## Video menu and this page

1. Right-click the page background. Choose "Download video with
   umbilical". The sheet opens with the page URL. Confirming uses yt-dlp,
   not aria2. Cancel leaves the queue empty.
2. Right-click a link and choose "Download video with umbilical". The
   sheet uses that link, not the page URL.
3. Click the toolbar button. Choose "Download this page with umbilical".
   The sheet opens with the current tab URL. This uses `activeTab` after
   the toolbar click. Do not add a `tabs` permission.

Do not auto-intercept ordinary page loads as video.

## Finder openers

1. Double-click a `.torrent` file that opens with this build. The confirm
   sheet appears. Cancel leaves the queue empty. Confirm adds it as a
   torrent without copying an extra torrent file into the download folder.
   umbilical never seeds.
2. Double-click a `.metalink` or `.meta4` file. Confirm starts the files
   it names. A metalink that uses a rejected URL scheme or a file name
   with a path is refused.
3. Open a `magnet:` URL with this build. The same confirm sheet appears.

```bash
open -a /path/to/umbilical.app payload.torrent
open 'magnet:?xt=urn:btih:abababababababababababababababababababab'
```

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
7. ftp, sftp, and HTTP metalink. Each of these opens the confirm sheet. Cancel leaves the queue empty:

   ```bash
   open 'umbilical://download?url=ftp://example.com/a.bin'
   open 'umbilical://download?url=sftp://files.example.com/a.bin'
   open 'umbilical://download?url=https://example.com/pack.metalink'
   open 'umbilical://download?url=http://example.com/list.meta4'
   ```

8. Rejected schemes and fields. None of these add a row. Each one shows "Download rejected" (or the sheet stays closed) and does not start a download:

   ```bash
   open 'umbilical://download?url=file:///tmp/x'
   open 'umbilical://download?url=javascript:alert(1)'
   open 'umbilical://download?url=data:text/plain,hi'
   open 'umbilical://download?url=https://user:secret@example.com/a'
   open 'umbilical://download?url=https://example.com/&cookie=secret'
   open 'umbilical://download?url=https://example.com/a.bin&filename=../x'
   open 'umbilical://download?url=--header=Bearer'
   ```

9. Quit from the menu bar. `pgrep aria2c` prints nothing.

## Package tests

`swift test` covers handoff parsing: allowed fields, `HTTPURLPolicy`,
`MagnetLink.canonical`, output names, and `RPCOptionPolicy`. A confirmed
handoff is the only value the session will add, and a poisoned options
dictionary is rebuilt from the URL and file name. Capture heuristics, the
Finder torrent and metalink path, and dash-prefixed URLs are covered too.
It also covers the confirmation gate: Return and a click in the first
second do not confirm. Those tests do not replace this Mac pass.

If the checkout is under `~/Documents`, `swift test` can fail at codesign
with `resource fork, Finder information, or similar detritus not allowed`.
Use `swift test --scratch-path /tmp/umb-spm`.

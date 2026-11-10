# Add an HTTP download

Add download lets a user type an http or https URL, save the file inside the chosen folder, and see the row reach Complete with the file quarantined as umbilical.

## Sub-features

- `add-open` opens the add sheet from the empty state and from the toolbar.
- `add-save` downloads the URL with no save-as name and finishes the file.
- `add-reject-empty` rejects an empty URL.
- `add-reject-scheme` rejects `file:///tmp/x` and a magnet link.
- `add-reject-userinfo` rejects a URL that contains a username or password.
- `add-reject-name` rejects a save-as name of `../x`.
- `add-quarantine` marks the finished file with a quarantine value that contains `umbilical`.

## How to get to it (user POV)

- Choose `Add Download` in the empty state after a folder is selected.
- Choose the toolbar `Add Download` button, or press Shift-Command-N.
- Paste into the URL field with the `Paste` button or Command-V.

## Driving it with verify-umbilical

Preconditions:

- `verify-umbilical doctor` exits 0.
- The window says `Unofficial build. License checks are off.`
- `Contents/Helpers/aria2c` and `Contents/Helpers/umb-watch` are executable.
- The download folder is the scratch `umbilical-verify-downloads` directory and does not already contain `verify-payload.txt`.

- **Composed journey.** Choose the folder if needed, add the loopback payload, and wait until the file matches. Run `verify-umbilical drive add-download`. The command writes the action, the accessibility dump, the screenshot, the file sha256, and the quarantine value under the evidence directory. Exit 0 means the row reached `Complete`, the bytes match `umbilical-verify-payload`, and the quarantine attribute contains `umbilical`.
- **Open the sheet.** Choose `Add Download`. Run `verify-umbilical ui click --name "Add Download"`. A sheet titled `Add Download` shows the field `https://example.com/file`, the field `Save as (optional)`, the `Video` checkbox, and the buttons `Paste`, `Cancel`, and `Add`.
- **Enter the URL.** Leave save-as empty. Run `verify-umbilical ui fill --name "https://example.com/file" --value "http://127.0.0.1:PORT/verify-payload.txt"` and `verify-umbilical ui value --name "https://example.com/file"`. The value is that URL. Run `verify-umbilical ui checkbox --name "Video"`. The result is `0`.
- **Save.** Choose `Add`. Run `verify-umbilical ui click --name "Add"`. The sheet closes. Run `verify-umbilical ui wait-text --text "Complete" --timeout 60`. The row title is `verify-payload.txt` and the state text is `Complete`.
- **Reject empty.** Open the sheet and choose `Add` without typing. The sheet says `Enter an http or https URL.`
- **Reject scheme.** Fill `file:///tmp/x` and choose `Add`. The sheet says `That URL scheme is not allowed (file).` Fill `magnet:?xt=urn:btih:0123456789abcdef` and choose `Add`. The sheet names the magnet scheme. No row appears.
- **Reject userinfo.** Fill `https://user:password@example.com/a` and choose `Add`. The sheet says `URLs that include a username or password are rejected.`
- **Reject save-as.** Fill an http URL, fill `../x` into `Save as (optional)`, and choose `Add`. The sheet says `The file name cannot include a path.`
- **Proof.** The evidence files `add-http-download/action.txt`, `ui.txt`, `window.png`, `file.sha256`, and `quarantine.txt` exist. `ui.txt` contains `Complete` and `verify-payload.txt`. `quarantine.txt` contains `umbilical`. The sha256 matches the served payload.

## Gotchas

- The composed command is the proof for `add-save` and `add-quarantine`. Run the reject bullets as their own UI steps. Do not treat the composed command as proof of rejection.
- `drive add-download` stops when the window does not say license checks are off. Do not type a license key.
- `Video` must stay off. A known video host turns it on and the download uses yt-dlp instead of aria2.
- The URL field's accessibility name is the placeholder `https://example.com/file`.
- A missing `aria2c` or `umb-watch` inside `Contents/Helpers` fails the journey. Do not export `ARIA2C` or `UMB_WATCH` to skip that.
- The payload server listens on `127.0.0.1` only. The finished file is `<downloads>/verify-payload.txt`.
- `Show in Finder` appears on a finished row whose file still exists. Choosing it opens Finder. That is a separate user action from the byte check.

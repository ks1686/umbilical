# Confirm a handoff

Confirm handoff lets a user accept or reject a download that Safari or Finder asked umbilical to open. Nothing starts until the user chooses Download, and that button ignores clicks for the first second.

## Sub-features

- `handoff-sheet` shows the host, the URL, and the sentence that nothing starts until the user confirms.
- `handoff-arm` keeps `Download` disabled for one second. Return cancels.
- `handoff-accept` starts the download only after `Download` is enabled and chosen.
- `handoff-cancel` closes the sheet and adds no row.
- `handoff-needs-folder` tells the user to choose a download folder before `Download` can proceed.

## How to get to it (user POV)

- In Safari, after website access is allowed for the umbilical extension, right-click a link and choose Download with umbilical.
- In Finder, open a `.torrent`, `.metalink`, `.meta4`, or `magnet:` link. The sheet names the file or the magnet scheme.
- The extension opens an `umbilical://download?url=` link that the app turns into the same sheet. The user still has to choose `Download` or `Cancel`.

## Driving it with verify-umbilical

Preconditions:

- `verify-umbilical doctor` exits 0 and the recorded pid is the only process named `umbilical`.
- The window says license checks are off.
- For `handoff-accept`, the scratch download folder is already selected and `aria2c` is in `Contents/Helpers`.
- For `handoff-needs-folder`, no download folder is selected.

- **Open the sheet.** Send the handoff URL to this bundle. Run `verify-umbilical ui open-url --url "umbilical://download?url=http://127.0.0.1:PORT/verify-payload.txt"`. The sheet's large title is the host (`127.0.0.1`). The sheet says `A download was requested. Nothing starts until you confirm.` and shows the URL. It does not name Safari.
- **Wait until armed.** `Download` starts disabled. `Cancel` is the default button. Run `verify-umbilical ui wait-enabled --name "Download" --timeout 5`. Do not press Return while waiting. Return chooses Cancel.
- **Accept.** Choose `Download`. Run `verify-umbilical ui click --name "Download"`. The sheet closes and a row for `verify-payload.txt` appears, then reaches `Complete` with the same byte and quarantine proof as an add-sheet download.
- **Cancel.** Open a second handoff and choose `Cancel` after `Download` is enabled. Run `verify-umbilical ui wait-enabled --name "Download" --timeout 5` and `verify-umbilical ui click --name "Cancel"`. The sheet closes and no new row appears.
- **Needs a folder.** Open a handoff before any download folder is chosen. The sheet says `Choose a download folder first.` and `Download` stays disabled after the one-second wait.
- **Proof.** Dump the sheet before accepting and the list after it finishes. Run `verify-umbilical ui dump --path EVIDENCE/confirm-handoff/sheet.txt` and `verify-umbilical ui screenshot --path EVIDENCE/confirm-handoff/sheet.png`. `sheet.txt` contains the host and `Nothing starts until you confirm.`

## Gotchas

- `ui open-url` sends `umbilical://` to the recorded pid and does not call `open`. It records the current handler and restores it when the handler changes. A second pid is recorded with its environment. That pid is signaled only when its executable is the verification bundle. If the original handler was absent, the harness does not invent one to clear a handler that appeared during the run. Read `open-url/handler-restored.txt` after the run.
- The Safari context menu is a separate entry point. Proving the sheet with `ui open-url` does not prove the Safari click or the extension's website-access switch.
- Finder document handoff is a separate entry point. The sheet copy for a torrent says a torrent file was opened and that umbilical never seeds. Do not substitute the HTTP sheet for that sentence.
- `Download` is ignored for one second (`HandoffConfirmationGate.armDelay`). Clicking earlier is not a failure of the button. Wait until it is enabled.
- `Cancel` is the default button. A Return keypress cancels. The harness must click `Download`.
- A magnet link opened from the add sheet is rejected. A magnet opened as a handoff still waits for this sheet. Those are different journeys.
- Video handoff uses `umbilical://video?url=` and says a video download was requested. This recipe uses the download host, not the video host.

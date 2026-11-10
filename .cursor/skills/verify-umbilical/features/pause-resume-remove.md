# Pause, resume, and remove

Pause, resume, and remove let a user stop an in-progress download, start it again, and take a row off the list. Removing an unfinished download deletes its partial file. Removing a finished download leaves the file in the folder.

## Sub-features

- `control-pause` sets the row to Paused and clears the menu bar speed.
- `control-resume` leaves Paused and shows speed again while bytes move.
- `control-remove-active` asks for confirmation, drops the row, and stops the partial file from growing.
- `control-remove-finished` drops a Complete row and leaves the file on disk.
- `control-cancel-video` cancels a video row immediately, without the confirmation dialog.

## How to get to it (user POV)

- In the download list, choose `Pause` on a row that is moving.
- Choose `Resume` on a paused row.
- Choose `Remove`, then `Remove` in the confirmation `Remove this download?`.
- On a live video row, choose `Cancel`.

## Driving it with verify-umbilical

Preconditions:

- `verify-umbilical doctor` exits 0.
- A non-video row is active and has not reached `Complete`. A tiny file can finish before `Pause` is visible. Use a transfer that stays active long enough to click `Pause`. If the row already says `Complete`, this journey has not started.
- The window says license checks are off, so Resume is allowed.

- **Pause.** Choose `Pause`. Run `verify-umbilical ui click --name "Pause"`. The row state text becomes `Paused`. The status item no longer shows a percent or a speed. The menu still lists the row, with `Paused` in its label. It does not say `No active downloads` while that row remains.
- **Resume.** Choose `Resume`. Run `verify-umbilical ui click --name "Resume"`. The button title returns to `Pause` and the row leaves `Paused`.
- **Remove unfinished.** Choose `Remove`. Run `verify-umbilical ui click --name "Remove"`. A dialog titled `Remove this download?` appears. Choose the destructive `Remove`. Run `verify-umbilical ui click --name "Remove"`. The row is gone. The partial file stops growing and its `.aria2` companion is not left as a finished download.
- **Remove finished.** On a `Complete` row, choose `Remove` and confirm. The row leaves the list. The file named by the row is still in the download folder.
- **Cancel video.** On a row whose button says `Cancel`, choose `Cancel`. Run `verify-umbilical ui click --name "Cancel"`. The row leaves without a confirmation dialog.
- **Proof.** Dump the list after pause and after remove. Run `verify-umbilical ui dump --path EVIDENCE/pause-resume-remove/paused.txt` and `verify-umbilical ui screenshot --path EVIDENCE/pause-resume-remove/paused.png` while the row says `Paused`. After removal, a second dump has no row with that title.

## Gotchas

- `App/DownloadList.swift` sets `.accessibilityElement(children: .combine)` on the row that contains Pause, Resume, and Remove. System Events may see one combined element instead of those buttons. That can only be checked on a Mac. If `ui click --name "Pause"` reports that the button is missing, record that result. Do not change the app, and do not treat a click on the combined row as proof of Pause.
- `Pause` and `Resume` are the same button with a changing title. Read the title before clicking.
- Confirming removal clicks a second button that is also named `Remove`. The first click only opens the dialog. `Cancel` in that dialog keeps the row.
- A video row's button is `Cancel` and does not ask. Do not use that row to prove the confirmation dialog.
- Resume does nothing useful when license checks block new work. This map does not drive that block. The unofficial-build precondition is required.
- Quitting the app stops active downloads. Pause is not proved by quitting.

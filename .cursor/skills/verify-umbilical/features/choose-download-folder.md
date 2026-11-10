# Choose a download folder

Choosing a download folder lets a user pick the only directory umbilical will save into, see that path in Settings, and find the same folder still selected after quitting and opening the app again.

## Sub-features

- `folder-first-launch` shows the empty state until a folder is chosen.
- `folder-settings` shows the same path in Settings.
- `folder-relaunch` keeps the folder after Quit and a new launch of the same scratch home.
- `folder-outside` reports that a folder outside the download folder cannot be used from the add sheet.
- `folder-child` saves a file in a subfolder that was chosen inside the download folder.

## How to get to it (user POV)

- Launch umbilical when no download folder is saved. The window says `Choose a download folder`.
- Choose `Choose Folder…` in the empty state or in the toolbar.
- Open the menu bar item described as `umbilical`, then choose `Settings…`, then the Downloads section.
- In the add sheet, choose `Choose Folder…` to pick a child folder or to try a folder outside the download folder.

## Driving it with verify-umbilical

Preconditions:

- `verify-umbilical doctor` exits 0.
- The accessibility dump contains `Choose a download folder`.
- The scratch downloads directory exists and is empty.

- **Choose the folder.** Choose `Choose Folder…`, go to the scratch downloads directory, and choose `Choose`. Run `verify-umbilical ui choose-folder --path /tmp/umbilical-verify/scratch-RUN/umbilical-verify-downloads`, using the `downloads` path from the state file. The open panel's confirm button is `Choose`. The window then says `No downloads` and shows `umbilical-verify-downloads`.
- **Settings path.** Open the status item and choose `Settings…`. Run `verify-umbilical ui menu --name "Settings…"`. The Downloads section shows Folder with that same path.
- **Relaunch.** Quit, then start the same home again. Run `verify-umbilical ui quit`, wait until doctor reports the pid is not running, then `verify-umbilical relaunch`. The window shows `umbilical-verify-downloads` and does not ask for a folder again.
- **Outside folder.** Create a real directory next to the download folder, for example `<scratch>/outside-the-download-folder`. Do not pass `/tmp`: on macOS `/tmp` is a symlink, and `ui choose-folder` refuses a symlink. Run `verify-umbilical ui click --name "Add Download"` and `verify-umbilical ui choose-folder --path <scratch>/outside-the-download-folder`. The sheet says `That folder cannot be used.` and the download list stays empty.
- **Child folder.** Create `umbilical-verify-downloads/incoming`, choose that directory from the add sheet, and add an HTTP file. The saved file's parent directory is `incoming`.
- **Proof.** Capture the window after the folder is chosen and again after relaunch. Run `verify-umbilical ui dump --path EVIDENCE/choose-download-folder/window.txt` and `verify-umbilical ui screenshot --path EVIDENCE/choose-download-folder/window.png`. Both artifacts show `umbilical` and `umbilical-verify-downloads`.

## Gotchas

- `Choose Folder…` uses an ellipsis, not three periods. `Settings…` does too.
- The open panel confirms with `Choose`, not `Open`.
- The folder path itself must not be a symlink. `/tmp` is a symlink on macOS. Create `<scratch>/outside-the-download-folder` for the outside-folder check.
- Command-Shift-G is how the user types a path. The harness only types a path made of letters, digits, and `._/-`.
- A stuck open panel still has a `Choose` button. Dismiss it before starting another folder choice.
- Relaunch fails while the recorded pid is alive. Quit first. `relaunch` reuses the scratch home. A new `launch` refuses while the state file exists.
- `folder-outside` is a failure report in the sheet, not a second download folder.
- `folder-child` is not proved by the composed `drive add-download` command. That command uses the download folder itself.

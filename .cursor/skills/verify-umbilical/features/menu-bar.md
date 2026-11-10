# Menu bar

The menu bar shows whether umbilical is idle or moving bytes, and it opens the main window, Settings, and Quit.

## Sub-features

- `menu-idle` shows no speed and the menu says there are no active downloads.
- `menu-active` shows a percent and a speed for one moving file, or a count and a speed for more than one.
- `menu-open` brings the main window forward.
- `menu-settings` opens Settings.
- `menu-quit` quits umbilical and stops `aria2c`.

## How to get to it (user POV)

- Click the menu bar status item. Its accessibility description is `umbilical`. While idle, the item has no title text.
- Choose `Open umbilical`.
- Choose `Settings…`.
- Choose `Quit umbilical`.
- Leave `Check for Updates` unused during verification.

## Driving it with verify-umbilical

Preconditions:

- `verify-umbilical doctor` exits 0.
- For `menu-idle`, no row is active, waiting, paused, or failed.
- For `menu-active`, at least one row is active. One file shows a percent and a speed. Two active files show the count and a speed.

- **Idle menu.** Open the status item and read its menu. Run `verify-umbilical ui status`. The output contains `No active downloads`, `Open umbilical`, `Settings…`, `Check for Updates`, and `Quit umbilical`. The command closes the menu after reading it.
- **Active title.** Start a download that stays active, then read the status item. A single file's title looks like `10% 1.0 KB/s`. More than one active file looks like `2 1.0 KB/s`. The menu lists each active, waiting, paused, or failed row as `title state`.
- **Open the window.** Choose `Open umbilical`. Run `verify-umbilical ui menu --name "Open umbilical"`. The window titled `umbilical` is frontmost.
- **Settings.** Choose `Settings…`. Run `verify-umbilical ui menu --name "Settings…"`. The Downloads section is visible.
- **Quit.** Choose `Quit umbilical`. Run `verify-umbilical ui quit`. The recorded pid exits. `aria2c` children of that pid are gone. Do not use `pkill` or `killall`.
- **Proof.** Save an accessibility dump of the open idle menu and a screenshot that shows the status item. Run `verify-umbilical ui dump --path EVIDENCE/menu-bar/idle.txt` and `verify-umbilical ui screenshot --path EVIDENCE/menu-bar/window.png`. `idle.txt` contains `No active downloads` and `Quit umbilical`.

## Gotchas

- The visible menu bar glyph is the template image. The accessibility description is `umbilical`, not `umb`.
- `No active downloads` is absent while a paused or failed row is still listed. Pause does not return the menu to that sentence. It only clears the status title.
- `Settings…` uses an ellipsis. `Check for Updates` does not.
- Choosing `Check for Updates` starts a Sparkle check. Verification does not choose it. Launch itself may already contact the appcast.
- `ui menu` clicks the status item and then the named menu item. A missing description `umbilical` fails the command.
- Quit is also what cleanup tries first. After a successful `ui quit`, the pid is dead and a later cleanup only removes scratch state.

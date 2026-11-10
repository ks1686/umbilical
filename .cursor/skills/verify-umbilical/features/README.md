# umbilical verification map

This directory is the maintained source for verifying the user-facing behavior of umbilical. Read the index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- Build `umbilical.app` with Xcode and launch it through `verify-umbilical launch --app`.
- The scratch `HOME` is `/tmp/umbilical-verify/scratch-<run-id>/home`. Download files go in `umbilical-verify-downloads` under that scratch directory.
- `verify-umbilical doctor` exits 0. The recorded pid, bundle id `me.peapod.umbilical`, version, and scratch `HOME` match.
- The window says `Unofficial build. License checks are off.` A build that enforces Polar is not a verification instance.
- `Contents/Helpers/aria2c` and `Contents/Helpers/umb-watch` are executable before a download journey. `yt-dlp` is required only for a video download.
- Never drive an `umbilical` process this run did not start.

## Driving conventions

- Start every recipe from the baseline state unless its preconditions say otherwise.
- Use the button titles and field labels in the feature file. They are the accessibility names.
- Treat every command as literal, including the ellipsis character in `Choose Folder…` and `Settings…`.
- `verify-umbilical` is `.cursor/skills/verify-umbilical/scripts/verify-umbilical`.
- Run window actions through `verify-umbilical ui`.
- Run the composed HTTP journey through `verify-umbilical drive add-download`.
- Leave proof artifacts in the evidence directory. Cleanup removes the scratch `HOME` and the state file only.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- UI proof includes the accessibility dump and a screenshot of the umbilical window.
- A download proof includes the file bytes and the quarantine attribute containing `umbilical`.
- Record the feature id and the entry point with every artifact.
- Report an unreachable path with the attempted command and the unmet precondition.
- Do not report a skipped entry point as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with verify-umbilical` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

## Features

- [Choose a download folder](./choose-download-folder.md) covers the first-launch folder choice, the Settings path, and the same folder after relaunch.
- [Add an HTTP download](./add-http-download.md) covers the add sheet, a finished file, rejection of unsafe inputs, and quarantine.
- [Pause, resume, and remove](./pause-resume-remove.md) covers the row buttons, the confirmation dialog, and what remains on disk.
- [Menu bar](./menu-bar.md) covers the idle status item, an active summary, Open umbilical, Settings, and Quit.
- [Confirm a handoff](./confirm-handoff.md) covers the sheet Safari and Finder reach, the one-second arming delay, and Cancel.

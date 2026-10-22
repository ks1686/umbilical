# Changelog

## 1.0.1

Safari turned off the umbilical extension after this update. To turn it back on, open Safari Settings, choose Extensions, and tick umbilical. The notice shows when the extension is off until it is dismissed for this version.

- Keep a single main window on launch and `umbilical://` handoff.
- Hide pause and resume on completed, failed, and cancelled download rows.
- Confirmed metalink files start the files they name after every mirror URL and output name is checked.
- Torrents no longer save extra torrent copies in the download folder.
- Removing an unfinished download deletes that download's partial file and matching .aria2 control file after aria2 has finished the remove.
- Video downloads require a version with sound and fail plainly when none exists.
- Video files are named after the title and stay inside the download folder.
- A YouTube or other video-site handoff uses the video download path.
- Removing a download cannot clear a different row if the list changed while waiting.
- An update no longer restores leftover windows from an older multi-window build.
- Rejection alerts appear once for the app, not once in every window.
- A second confirm request waits its turn instead of replacing the first.

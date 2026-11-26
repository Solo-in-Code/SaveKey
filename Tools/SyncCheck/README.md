# Sync check

Runs SaveKey's file-sync code — `Shared/DatabaseSession.swift`, `Shared/DatabaseLibrary.swift` and
`Shared/FileAccess.swift` — outside the app, through a scripted set of situations:

- a file replaced by a sync tool (rclone's iCloud backend deletes the old file and uploads a new one),
  and following the database by name in its folder;
- merging changes made on another device, and merging before saving;
- the warning when a one-way copy keeps overwriting the iPhone's changes;
- conflict copies (rclone bisync, Syncthing) and iCloud conflict versions;
- a new password elsewhere, a half-uploaded file, a change whose date and size look unchanged;
- read-only databases mirroring the file, and editors pausing the merge.

```
Tools/SyncCheck/run.sh
```

It needs Linux with Swift 5.10 or newer, because it replaces SwiftUI, Combine and the Apple-only file
APIs (security-scoped bookmarks, `NSFileCoordinator`, `NSFileVersion`, the trash) with small
stand-ins in `Stubs/` and `Sources/AppLogic/LinuxShims.swift`. On a Mac, use Docker:

```
docker run --rm -v "$PWD":/src -w /src swift:6.0 bash Tools/SyncCheck/run.sh
```

`run.sh` copies the three files from `Shared/` into `Sources/AppLogic/App/` (ignored by git) before
building, so the check always runs the current code. The checks themselves are in
`Sources/AppLogic/Scenario.swift`. The CI workflow runs this on every push.

# NaviUpload for Windows

The Windows x64 edition of NaviUpload: upload music directly to a
Navidrome library from the desktop — drag-and-drop or pick audio
files, or paste a URL and let the NaviUpload companion server fetch
it (direct audio links are saved as-is; page links such as YouTube
are fetched server-side with yt-dlp). It talks to the same companion
server as the iOS app: server address + upload token live in
Settings, with a one-tap connection test against the server's
`/health` endpoint.

## What's new in 1.4.0 (Windows only)

- **Resumable uploads**: files of 4 MB and up upload in chunks the
  server keeps between requests, so an interrupted upload resumes
  from the server's own byte count, even after the app restarts.
  The server verifies the whole file's SHA-256 before saving it.
- **CUE sheet albums**: drop a single-file album with its .cue
  sheet beside it and the server splits it into tracks
  (sample-exact for lossless sources).
- **Playlist upload**: drop an .m3u and, once its songs are in,
  a playlist with the same name is created in Navidrome.
- **Tag fixer**: with "Review tags before uploading" on in
  Settings, each batch pauses in a tag editor (title, artist,
  album, year, track, replacement cover). Edits are applied by
  the server to the copies it saves; your own files are never
  rewritten.
- **System tray**: closing the window parks the app in the tray
  while uploads keep running; the tray tooltip shows progress.
  Optional start with Windows, hidden in the tray.
- **Explorer right-click**: "Send to Navidrome" on audio files,
  folders and .cue/.m3u/.zip files (a Settings toggle). A second
  launch hands its files to the running copy instead of opening
  another window; `--add <path>` and `--url <link>` do the same
  from the command line.
- **Watch folder**: new files in a chosen folder upload
  automatically once they finish copying. Files already in the
  folder when it is first chosen are not uploaded.
- **Notifications and taskbar progress**: a toast when a batch
  finishes, and progress on the taskbar button while uploading.
- Drag and drop now works anywhere on the window, not just on
  the drop zone.

## Design

Built to look like its sibling, Viu for Windows — the user asked for
that UI specifically. Same Material 3 system: `ColorScheme.fromSeed`
with the expressive scheme variant, the enlarged text theme
(headline 27, body 17–18), cards at radius 24 on
`surfaceContainerLow` with no elevation, filled buttons padded
28×16 at radius 28, a navigation rail with a `primaryContainer`
indicator, a near-black dark scaffold (`0xFF0A0A0E`), and a row of
selectable accent colors. The only deliberate difference is the
default accent: **Navi Blue** `0xFF1890EB`, the blue of the
Navidrome record icon, ahead of Viu's Red / Purple / Pink / Orange /
Green / Teal.

## Layout of this folder

Only sources are committed, exactly like the Viu repo:

- `lib/main.dart` — the whole app
- `pubspec.yaml`
- `tool/setup_windows.sh` — assembles the platform scaffold in CI
- `windows_overlay/patch_windows.py` — names the exe `NaviUpload`,
  titles the window "NaviUpload", installs the icon
- `windows_overlay/app_icon.ico` — the Navidrome-record icon
  (generated from the iOS app's 1024 px icon)
- `build-windows.yml` — the CI workflow source; it is routed to
  `.github/workflows/build-windows.yml` in the repo (the file is
  kept here because workflow files cannot be pushed through the
  API)

## Building

CI (the normal route): the **Build Windows x64 (Flutter)** workflow
runs on `windows-latest` with Flutter 3.47.8 — it runs
`tool/setup_windows.sh` (`flutter create` for the Windows scaffold,
then the overlay patch), `flutter pub get`,
`flutter build windows --release`, and uploads
`NaviUpload-Windows-x64.zip` (the whole
`build/windows/x64/runner/Release` folder) as the
**NaviUpload-Windows** artifact.

Locally on a Windows machine with Flutter installed, the same three
commands from this folder do it:

```
bash tool/setup_windows.sh
flutter pub get
flutter build windows --release
```

Copyright (c) 2026 c12n Apps

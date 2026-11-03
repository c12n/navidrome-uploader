# NaviUpload for Windows

The Windows x64 edition of NaviUpload: upload music directly to a
Navidrome library from the desktop — drag-and-drop or pick audio
files, or paste a URL and let the NaviUpload companion server fetch
it (direct audio links are saved as-is; page links such as YouTube
are fetched server-side with yt-dlp). It talks to the same companion
server as the iOS app: server address + upload token live in
Settings, with a one-tap connection test against the server's
`/health` endpoint.

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

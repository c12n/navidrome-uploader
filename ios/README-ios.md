# Navidrome Uploader — iOS

Upload music directly to your Navidrome library, from audio files on the
phone or from a URL the server downloads for you.

Copyright (c) 2026 c12n Apps

## Features

- **Upload tab** — big "Choose audio file" button (Files picker, audio
  types: mp3, m4a, flac, wav, ogg, opus, aac). Sends the file as
  `multipart/form-data` (field `file`) with live upload progress, then
  shows the saved filename, size and whether a library scan was triggered.
- **URL tab** — paste or type a link and tap "Download to Navidrome".
  Direct audio links are fetched by the server as-is; YouTube and other
  page links are handled server-side via yt-dlp.
- **History tab** — completed uploads kept on-device: name, source
  (File / URL), date and scan status. Swipe to delete, or Clear all.
- **Settings tab** — companion-server base URL (default
  `https://upload.07051969.xyz`), upload token, and a "Test connection"
  button that calls `GET /health` and reports status + library file count.
  Server errors are shown verbatim (HTTP status + server message), never
  as a blank failure.

## Server API

The app talks to the companion service in `server/`:

- `GET /health` → `{"status":"ok","library_files":int}`
- `POST /upload` (multipart, field `file`) → `{"saved_as","size","scan_triggered"}`
- `POST /url` (JSON `{"url": ...}`) → same response shape

Requests carry `X-Upload-Token: <token>`. The token is stored in the
Keychain (`Keychain.swift`); only the base URL is kept in UserDefaults.

## Build

- SwiftUI, iOS 17.0 minimum, no third-party dependencies.
- Bundle ID `com.c12n.navidromeuploader`, version 1.0.0 (build 1).
- Project: `ios/NavidromeUploader.xcodeproj`, target/scheme
  `NavidromeUploader`, `SDKROOT = iphoneos`, hand-built `project.pbxproj`
  following the Viu Live TV structure.
- CI: `.github/workflows/build-ipa.yml` at the repo root builds an
  **unsigned** IPA on a `macos-26` GitHub Actions runner
  (`xcodebuild archive` with code signing off), packages it as
  `Payload/NavidromeUploader.app` zipped to `NavidromeUploader.ipa`, and
  uploads it as the `NavidromeUploader-IPA` artifact. Sign it with your
  usual sideloading tool before installing.

# NaviUpload (Navidrome Uploader)

Copyright (c) 2026 c12n Apps

Upload music straight into a Navidrome library from an iPhone — pick an
audio file, or paste a URL and let the server fetch it.

Navidrome has no upload API (it only scans its music folder), so this
project has two halves:

## 1. Companion server (`server/`)

A small FastAPI service that runs on the same box as Navidrome
(a ZimaOS homelab, alongside it):

- `POST /upload` — multipart audio file, saved into the library folder
- `POST /url` — `{"url": ...}`: direct audio links are saved as-is;
  links on a TorBox or Premiumize supported hoster go through that
  account when its API key is configured (ZIPs are unpacked, every
  audio file inside is saved); page/media links (YouTube,
  SoundCloud...) go through yt-dlp → MP3
- After each save it calls Navidrome's Subsonic `startScan` endpoint
  (when admin credentials are configured) so the song appears at once
- Resumable chunked uploads (1.4.0): `POST /upload/init`,
  `PUT /upload/chunk`, `GET /upload/status`, `POST /upload/complete`,
  `DELETE /upload/session`. The server keeps the received chunks per
  session, the client resumes from the server's byte count (even
  across app restarts), and completion verifies a SHA-256 of the
  whole file before the assembled file runs through the same save
  pipeline as `POST /upload`. A completed session keeps its result
  as a receipt, so a lost response never produces a duplicate
- CUE sheet albums (1.4.0): a chunked upload can carry cue text; the
  server splits the single file into its tracks. Lossless sources
  are split sample-exact and re-encoded to FLAC; lossy sources are
  stream-copied
- `POST /playlists` (1.4.0): create a Navidrome playlist from track
  titles/artists (the Windows app calls it after an .m3u's files have
  uploaded). Matching is strict (title, artist, duration), and an
  existing playlist of the same name is refilled, not duplicated
- Tag overrides (1.4.0): both upload routes accept per-file title /
  artist / album / year / track edits and a replacement cover,
  applied to the saved library copy with the same tag writer
  enrichment uses. The apps never rewrite the user's own files
- `GET /health`, `GET /recent`; everything except `/health` needs the
  shared `X-Upload-Token`
- Files land flat in the library root, sanitised, never overwritten
  (duplicates get a " (2)" suffix)

Verified on the homelab 2026-11-03: the library Navidrome scans lives
on the 512GB NVMe at `/media/SSD-Storage/Media/Music/Music/` (25 GB,
3,174 files). A near-identical copy exists on the 256GB SSD at
`/media/ZimaOS-HD/Media/Music/Music/` but is NOT scanned (proven from
Navidrome's own database) — the server mounts the NVMe path. Navidrome
data is `/media/ZimaOS-HD/AppData/navidrome/data/`; this server is
public at https://upload.07051969.xyz (port 8911). Optional env:
`TORBOX_API_KEY`, `PREMIUMIZE_API_KEY` enable the debrid routes;
`NAVIDROME_USER`/`NAVIDROME_PASSWORD` enable the instant scan trigger.

Deploy (ZimaOS Custom App, see `server/docker-compose.yml`):
copy `server/app/` + `server/requirements.txt` to
`/media/ZimaOS-HD/AppData/navidrome-uploader/app/`, create the app from
the compose file with the token / Navidrome admin values substituted,
then add a Cloudflare tunnel route `upload.07051969.xyz ->
http://localhost:8911` on the existing `zimaos-navidrome` tunnel.
Installing the container needs sudo/docker on the box.

Tests: 16 suites under `tests/` (server endpoints, debrid routes,
chunked uploads, playlists, tag overrides, CUE splitting, ZIP
uploads); the debrid and playlist suites run against local stub
APIs. All passing.

### Automatic server updates

`server/autoupdate.sh` keeps the deployed server in step with this
repo's releases, so publishing a release is the whole server deploy.
A one-time `sudo bash autoupdate.sh --install` on the box installs it
as a root cron job (every 30 minutes). Each run reads the latest
GitHub release, and only when a NEWER release exists does it fetch
that release's `server/app/main.py` (pinned to the release tag, never
the branch), verify it (sha256 recorded, Python syntax check), back
up the current file to `app/main.py.bak`, install, recreate the
container, and poll `/health`. A release that fails its health check
is rolled back automatically and not retried. Every check and change
is logged to `data/autoupdate.log`, and the current state is kept in
`data/autoupdate-status.json` (also shown by `GET /health`).

## 2. iOS app (`ios/`)

SwiftUI, iOS 17+, no third-party dependencies, modelled on the Viu and
AlRashid apps: bundle `com.c12n.navidromeuploader`, unsigned IPA built
by GitHub Actions (macos-26) for sideloading, server URL + token in
Settings (token in Keychain). Tabs: Upload (file), URL, History,
Settings with a connection test.

Default server URL in the app: https://upload.07051969.xyz

## 3. Windows app (`windows-app/`)

Flutter (same toolkit and design system as the Viu Windows app:
Material 3 expressive, selectable accent colours, enlarged type,
rounded cards), Windows x64. Drag-and-drop or pick audio files, paste
a URL, view history, Settings with a connection test; the token is
kept in Windows secure storage. Built by GitHub Actions
(windows-latest) into a zip — see `windows-app/README-windows.md`.

Version 1.4.0 is a Windows-only release (the iOS app stays at
0.6.0): resumable chunked uploads, CUE sheet album splitting, .m3u
playlist creation in Navidrome, a pre-upload tag review whose edits
are applied on the server, a system tray mode with optional
start-with-Windows, an Explorer right-click "Send to Navidrome"
verb, a watch folder, toast notifications, taskbar progress, and
drag-and-drop anywhere on the window.

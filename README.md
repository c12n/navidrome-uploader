# NaviUpload (Navidrome Uploader)

Copyright (c) 2026 c12n Apps

Upload music straight into a Navidrome library from an iPhone — pick an
audio file, or paste a URL and let the server fetch it.

Navidrome has no upload API (it only scans its music folder), so this
project has two halves:

## 1. Companion server (`server/`)

A small FastAPI service that runs on the same box as Navidrome
(Youssef's ZimaOS homelab, alongside it):

- `POST /upload` — multipart audio file, saved into the library folder
- `POST /url` — `{"url": ...}`: direct audio links are saved as-is;
  page/media links (YouTube, SoundCloud...) go through yt-dlp → MP3
- After each save it calls Navidrome's Subsonic `startScan` endpoint
  (when admin credentials are configured) so the song appears at once
- `GET /health`, `GET /recent`; everything except `/health` needs the
  shared `X-Upload-Token`
- Files land flat in the library root, sanitised, never overwritten
  (duplicates get a " (2)" suffix)

Verified on the homelab 2026-11-03: the library it writes to is
`/media/ZimaOS-HD/Media/Music/Music/` (25 GB, ~3,180 files), Navidrome
data is `/media/ZimaOS-HD/AppData/navidrome/data/`, server at
https://music.07051969.xyz (port 4533).

Deploy (ZimaOS Custom App, see `server/docker-compose.yml`):
copy `server/app/` + `server/requirements.txt` to
`/media/ZimaOS-HD/AppData/navidrome-uploader/app/`, create the app from
the compose file with the token / Navidrome admin values substituted,
then add a Cloudflare tunnel route `upload.07051969.xyz ->
http://localhost:8911` on the existing `zimaos-navidrome` tunnel.
Installing the container needs sudo/docker on the box.

Tests: `python3 tests/test_server.py` (12 checks, all passing).

## 2. iOS app (`ios/`)

SwiftUI, iOS 17+, no third-party dependencies, modelled on the Viu and
AlRashid apps: bundle `com.c12n.navidromeuploader`, unsigned IPA built
by GitHub Actions (macos-26) for sideloading, server URL + token in
Settings (token in Keychain). Tabs: Upload (file), URL, History,
Settings with a connection test.

Default server URL in the app: https://upload.07051969.xyz

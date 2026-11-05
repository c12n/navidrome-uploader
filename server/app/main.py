"""
Navidrome Uploader — companion service for the Navidrome Uploader iOS app.

Navidrome itself has no upload API: it only scans its music folder. This
service is the missing front door. It runs on the same box as Navidrome
(ZimaOS homelab) and:

  - POST /upload   multipart audio file (field "file") -> saved into the
                   Navidrome library folder
  - POST /url      JSON {"url": "..."} -> the server downloads it:
                     * a direct audio-file link is saved as-is
                     * a link on one of TorBox's supported hosters is
                       fetched through the user's TorBox account when
                       TORBOX_API_KEY is configured (ZIPs are unpacked,
                       every audio file inside is saved)
                     * a Google Drive file link is fetched through
                       Drive's direct-download endpoint
                     * a Spotify track / album / playlist link resolves
                       through Spotify's public embed pages (no account)
                       and every track is fetched with yt-dlp search,
                       tagged with the exact Spotify metadata
                     * any other page/media link (YouTube etc.) is fetched
                       with yt-dlp and extracted to MP3 (needs ffmpeg,
                       installed by the container start command)
                     * if yt-dlp cannot handle a website, a generic
                       website downloader inspects the returned page or
                       download endpoint for public audio, ZIP, video or
                       HLS links and fetches those directly (it does not
                       bypass logins, paywalls or CAPTCHAs)
  - after every save it triggers a Navidrome library scan through the
    Subsonic API (startScan) when NAVIDROME_USER/PASSWORD are configured,
    so new songs appear in Navidrome within seconds
  - GET  /health   liveness + library file count (no auth)
  - GET  /recent   last uploads (auth), also appended to
                   $DATA_DIR/uploads.jsonl

Auth: every endpoint except /health requires the shared token in the
X-Upload-Token header (env UPLOAD_TOKEN). There is deliberately no other
account system — the service is personal, sits behind the Cloudflare
tunnel on its own subdomain, and the token is the gate.

Files land FLAT in LIBRARY_DIR (the library root Navidrome scans), named
from the upload / download, sanitised, and de-duplicated with a " (2)",
" (3)"... suffix instead of overwriting an existing different file.

Copyright (c) 2026 c12n Apps
"""

import asyncio
import difflib
import hashlib
import html
import json
import os
import re
import secrets
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.parse
import zipfile

import httpx
from fastapi import (FastAPI, File, Form, Header, HTTPException, Request,
                     UploadFile)
from fastapi.responses import JSONResponse

AUDIO_EXTS = {
    ".mp3", ".m4a", ".flac", ".wav", ".ogg", ".oga", ".opus",
    ".aac", ".aif", ".aiff", ".wma",
}
VIDEO_EXTS = {".mp4", ".m4v", ".webm", ".mkv", ".mov"}
MAX_BYTES = int(os.environ.get("MAX_UPLOAD_MB", "500")) * 1024 * 1024

LIBRARY_DIR = os.environ.get("LIBRARY_DIR", "/music")
DATA_DIR = os.environ.get("DATA_DIR", "/data")
UPLOAD_TOKEN = os.environ.get("UPLOAD_TOKEN", "")
NAVIDROME_URL = os.environ.get("NAVIDROME_URL", "").rstrip("/")
NAVIDROME_USER = os.environ.get("NAVIDROME_USER", "")
NAVIDROME_PASSWORD = os.environ.get("NAVIDROME_PASSWORD", "")
TORBOX_API_KEY = os.environ.get("TORBOX_API_KEY", "")
TORBOX_API_BASE = os.environ.get(
    "TORBOX_API_BASE", "https://api.torbox.app/v1/api").rstrip("/")
PREMIUMIZE_API_KEY = os.environ.get("PREMIUMIZE_API_KEY", "")
PREMIUMIZE_API_BASE = os.environ.get(
    "PREMIUMIZE_API_BASE", "https://www.premiumize.me/api").rstrip("/")
SPOTIFY_EMBED_BASE = os.environ.get(
    "SPOTIFY_EMBED_BASE", "https://open.spotify.com").rstrip("/")
DRIVE_DOWNLOAD_BASE = os.environ.get(
    "DRIVE_DOWNLOAD_BASE",
    "https://drive.usercontent.google.com").rstrip("/")

app = FastAPI(title="Navidrome Uploader", version="1.0.0")


def require_token(token: str | None) -> None:
    if not UPLOAD_TOKEN:
        raise HTTPException(500, "Server has no UPLOAD_TOKEN configured")
    if not token or not secrets.compare_digest(token, UPLOAD_TOKEN):
        raise HTTPException(401, "Bad or missing upload token")


def sanitize_filename(name: str) -> str:
    # Take only the final path component, whatever the client sent.
    name = os.path.basename(urllib.parse.unquote(name or "")).strip()
    # No leading dots (hidden files / traversal remnants), no control chars.
    name = name.lstrip(".")
    name = re.sub(r"[\x00-\x1f\x7f/\\]", "_", name)
    name = re.sub(r"\s+", " ", name).strip()
    if not name:
        name = "upload"
    stem, dot, ext = name.rpartition(".")
    if not stem:
        stem, ext = name, ""
    stem = stem[:120].strip() or "upload"
    ext = ("." + ext.lower()) if dot else ""
    return stem + ext


def _clean_error(text: str, fallback: str = "unknown error") -> str:
    """Turn a tool's stderr into one short, human line for the app.
    yt-dlp sometimes echoes a whole HTML error page (Google Drive's,
    notably); the app must never be shown page source. Prefer the
    last ERROR line, strip any markup, cap the length."""
    lines = []
    for raw in (text or "").splitlines():
        line = re.sub(r"<[^>]+>", " ", raw)
        line = re.sub(r"\s+", " ", line).strip()
        if line:
            lines.append(line)
    if not lines:
        return fallback
    for line in reversed(lines):
        if "ERROR" in line:
            return line[:240]
    return lines[-1][:240]


def unique_path(filename: str, subdir: str = "") -> str:
    folder = os.path.join(LIBRARY_DIR, subdir) if subdir else LIBRARY_DIR
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, filename)
    if not os.path.exists(path):
        return path
    stem, ext = os.path.splitext(filename)
    n = 2
    while True:
        candidate = os.path.join(folder, f"{stem} ({n}){ext}")
        if not os.path.exists(candidate):
            return candidate
        n += 1


def library_file_count() -> int:
    count = 0
    for _root, _dirs, files in os.walk(LIBRARY_DIR):
        for f in files:
            if os.path.splitext(f)[1].lower() in AUDIO_EXTS:
                count += 1
    return count


async def trigger_scan() -> bool:
    """Ask Navidrome to rescan via the Subsonic startScan endpoint."""
    if not (NAVIDROME_URL and NAVIDROME_USER and NAVIDROME_PASSWORD):
        return False
    salt = secrets.token_hex(8)
    token = hashlib.md5((NAVIDROME_PASSWORD + salt).encode()).hexdigest()
    params = {
        "u": NAVIDROME_USER, "t": token, "s": salt,
        "v": "1.16.1", "c": "NavidromeUploader", "f": "json",
    }
    try:
        async with httpx.AsyncClient(timeout=30, trust_env=False) as client:
            r = await client.get(f"{NAVIDROME_URL}/rest/startScan.view", params=params)
        body = r.json().get("subsonic-response", {})
        return r.status_code == 200 and body.get("status") == "ok"
    except Exception:
        return False


def record(entry: dict) -> None:
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        with open(os.path.join(DATA_DIR, "uploads.jsonl"), "a") as fh:
            fh.write(json.dumps(entry) + "\n")
    except OSError:
        pass


async def finish_save(tmp_path: str, filename: str, source: str,
                      subdir: str = "") -> dict:
    if os.path.splitext(filename)[1].lower() not in AUDIO_EXTS:
        os.unlink(tmp_path)
        raise HTTPException(415, f"Not an audio file we can add: {filename}")
    size = os.path.getsize(tmp_path)
    if size == 0:
        os.unlink(tmp_path)
        raise HTTPException(400, "Downloaded / uploaded file is empty")
    dest = unique_path(sanitize_filename(filename), subdir)
    shutil.move(tmp_path, dest)
    bump_stats(size)
    scan = await trigger_scan()
    entry = {
        "saved_as": os.path.basename(dest), "size": size,
        "source": source, "scan_triggered": scan, "at": int(time.time()),
        "folder": subdir,
    }
    record(entry)
    return entry


@app.get("/health")
async def health() -> dict:
    ok = os.path.isdir(LIBRARY_DIR)
    return {
        "status": "ok" if ok else "library_missing",
        "service": "navidrome-uploader",
        "library_files": library_file_count() if ok else 0,
        "scan_configured": bool(NAVIDROME_URL and NAVIDROME_USER),
        "torbox_configured": bool(TORBOX_API_KEY),
        "premiumize_configured": bool(PREMIUMIZE_API_KEY),
    }


@app.get("/recent")
async def recent(x_upload_token: str | None = Header(default=None)) -> dict:
    require_token(x_upload_token)
    items = []
    try:
        with open(os.path.join(DATA_DIR, "uploads.jsonl")) as fh:
            for line in fh:
                line = line.strip()
                if line:
                    items.append(json.loads(line))
    except OSError:
        pass
    return {"uploads": items[-20:][::-1]}


IMAGE_EXTS = {".jpg", ".jpeg", ".png"}
LYRICS_EXTS = {".lrc", ".txt"}
COVER_NAMES = ("cover", "folder", "front", "album", "albumart", "artwork")


def _unzip_album(zip_path: str, workdir: str) -> list:
    """Unpack an uploaded ZIP album (0.6.0). Returns one dict per
    audio track: {local, fname, cover (bytes|None), lyrics (str|None)}.
    Album art found in a track's own folder (cover.jpg / folder.jpg /
    front.*, else the folder's first image) and a .lrc/.txt sharing
    the track's filename are bundled with that track, so the album's
    own assets tag its songs."""
    zdir = tempfile.mkdtemp(dir=workdir)
    with zipfile.ZipFile(zip_path) as zf:
        total = sum(max(info.file_size, 0) for info in zf.infolist())
        if total > MAX_BYTES:
            raise HTTPException(413, "ZIP contents too large")
        zf.extractall(zdir)
    covers: dict = {}
    lyrics_map: dict = {}
    tracks: list = []
    for root, _dirs, names in os.walk(zdir):
        images, lyr = [], []
        for n in sorted(names):
            ext = os.path.splitext(n)[1].lower()
            p = os.path.join(root, n)
            if ext in IMAGE_EXTS:
                images.append((n, p))
            elif ext in LYRICS_EXTS:
                lyr.append((n, p, ext))
            elif ext in AUDIO_EXTS:
                tracks.append((p, n))
        if images:
            best = next(
                (p for n, p in images
                 if os.path.splitext(n)[0].lower() in COVER_NAMES),
                images[0][1])
            try:
                with open(best, "rb") as fh:
                    data = fh.read(6_000_000)
                if data:
                    covers[root] = data
            except OSError:
                pass
        for n, p, ext in lyr:
            key = (root, os.path.splitext(n)[0].lower())
            if key in lyrics_map and ext != ".lrc":
                continue  # a .lrc already claimed this stem
            try:
                with open(p, encoding="utf-8", errors="ignore") as fh:
                    text = fh.read(262_144).strip()
                if text:
                    lyrics_map[key] = text
            except OSError:
                pass

    def cover_for(directory: str):
        d = directory
        while True:
            if d in covers:
                return covers[d]
            if d == zdir:
                return None
            d = os.path.dirname(d)

    # Album art can also live INSIDE a song file (0.6.0): when a
    # folder has no image file, harvest the embedded art from its
    # tracks and share it with same-album / same-folder tracks that
    # carry none of their own, so the whole album ends up tagged.
    embedded = {}
    for p, _n in tracks:
        data = embedded_cover(p)
        if data:
            embedded[p] = data
    album_art: dict = {}
    dir_art: dict = {}
    for p, _n in tracks:
        if p in embedded:
            dir_art.setdefault(os.path.dirname(p), embedded[p])
            alb = read_tags(p)["album"].strip().lower()
            if alb:
                album_art.setdefault(alb, embedded[p])

    out = []
    for p, n in sorted(tracks):
        d = os.path.dirname(p)
        stem = os.path.splitext(n)[0].lower()
        cov = cover_for(d)
        if cov is None and p not in embedded:
            alb = read_tags(p)["album"].strip().lower()
            cov = album_art.get(alb) or dir_art.get(d)
        out.append({"local": p, "fname": n,
                    "cover": cov,
                    "lyrics": lyrics_map.get((d, stem))})
    return out


async def _read_bundled(cover: UploadFile | None,
                        lyrics_file: UploadFile | None):
    """Read the app's attached album art / lyrics sidecars (0.6.0)."""
    cover_bytes, lyrics_text = None, None
    if cover is not None and (cover.filename or "").strip():
        data = await cover.read(6_000_001)
        if data and len(data) <= 6_000_000:
            cover_bytes = data
    if lyrics_file is not None and (lyrics_file.filename or "").strip():
        raw = await lyrics_file.read(262_145)
        if raw and len(raw) <= 262_144:
            text = raw.decode("utf-8", errors="ignore").strip()
            if text:
                lyrics_text = text
    return cover_bytes, lyrics_text


@app.post("/upload")
async def upload(
    file: UploadFile = File(...),
    enrich: str = Form("false"),
    lyrics: str = Form("false"),
    sort: str = Form("false"),
    cover: UploadFile | None = File(None),
    lyrics_file: UploadFile | None = File(None),
    x_upload_token: str | None = Header(default=None),
) -> dict:
    require_token(x_upload_token)
    suffix = os.path.splitext(file.filename or "")[1]
    fd, tmp = tempfile.mkstemp(dir=DATA_DIR if os.path.isdir(DATA_DIR) else None, suffix=suffix)
    size = 0
    try:
        with os.fdopen(fd, "wb") as out:
            while True:
                chunk = await file.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_BYTES:
                    raise HTTPException(413, "File too large")
                out.write(chunk)
    except HTTPException:
        os.unlink(tmp)
        raise
    if suffix.lower() == ".zip":
        # An uploaded album ZIP (0.6.0): unzip it, take the songs
        # out, and tag each with the album art / lyrics bundled
        # inside. The response is the bundle shape the apps already
        # render for ZIP links (first + also_saved + files).
        workdir = tempfile.mkdtemp(dir=DATA_DIR if os.path.isdir(DATA_DIR) else None)
        try:
            tracks = _unzip_album(tmp, workdir)
            if not tracks:
                raise HTTPException(
                    400, "That ZIP contains no audio files we can add")
            saved = []
            for t in tracks:
                saved.append(await save_processed(
                    t["local"], t["fname"], "file",
                    _flag(enrich), _flag(lyrics), _flag(sort),
                    bundled_cover=t["cover"], bundled_lyrics=t["lyrics"]))
            first = saved[0]
            first["via"] = "zip"
            if len(saved) > 1:
                first["also_saved"] = len(saved) - 1
                first["files"] = [s["saved_as"] for s in saved]
            return first
        finally:
            shutil.rmtree(workdir, ignore_errors=True)
            if os.path.exists(tmp):
                os.unlink(tmp)
    bundled_cover, bundled_lyrics = await _read_bundled(cover, lyrics_file)
    return await save_processed(tmp, file.filename or "upload", "file",
                                _flag(enrich), _flag(lyrics), _flag(sort),
                                bundled_cover=bundled_cover,
                                bundled_lyrics=bundled_lyrics)


# ------------------------------------------- metadata enrichment (0.2.0) --
# After a file arrives (upload or download) the server can identify the
# track — iTunes Search first (keyless, has 600px artwork), MusicBrainz
# + Cover Art Archive as fallback — and embed proper tags + cover art
# into the file with mutagen, Picard-style. Lyrics come from LRCLIB
# (keyless) and are embedded into the file too (ID3 USLT / MP4 ©lyr /
# Vorbis LYRICS). Everything is best-effort: a failed lookup never
# blocks or breaks the save.

ITUNES_API_BASE = os.environ.get(
    "ITUNES_API_BASE", "https://itunes.apple.com").rstrip("/")
MUSICBRAINZ_API_BASE = os.environ.get(
    "MUSICBRAINZ_API_BASE", "https://musicbrainz.org/ws/2").rstrip("/")
COVERART_API_BASE = os.environ.get(
    "COVERART_API_BASE", "https://coverartarchive.org").rstrip("/")
LRCLIB_API_BASE = os.environ.get(
    "LRCLIB_API_BASE", "https://lrclib.net/api").rstrip("/")
META_UA = {"User-Agent":
           "NaviUpload/0.2.0 (https://github.com/c12n/navidrome-uploader)"}

try:
    import mutagen
    from mutagen.flac import FLAC, Picture
    from mutagen.id3 import APIC, ID3, TALB, TDRC, TIT2, TPE1, TRCK, USLT
    from mutagen.mp4 import MP4, MP4Cover
    _HAS_MUTAGEN = True
except Exception:  # pragma: no cover - mutagen ships in requirements
    _HAS_MUTAGEN = False


def _tag_get(audio, *keys) -> str:
    for k in keys:
        try:
            v = audio.get(k)
        except Exception:
            v = None
        if v:
            if isinstance(v, list):
                return str(v[0])
            return str(v)
    return ""


def read_tags(path: str) -> dict:
    out = {"title": "", "artist": "", "album": "", "album_artist": "",
           "duration": 0.0}
    if not _HAS_MUTAGEN:
        return out
    try:
        audio = mutagen.File(path)
    except Exception:
        return out
    if audio is None:
        return out
    try:
        out["duration"] = float(audio.info.length or 0)
    except Exception:
        pass
    out["title"] = _tag_get(audio, "TIT2", "\xa9nam", "title", "TITLE")
    out["artist"] = _tag_get(audio, "TPE1", "\xa9ART", "artist", "ARTIST")
    out["album"] = _tag_get(audio, "TALB", "\xa9alb", "album", "ALBUM")
    out["album_artist"] = _tag_get(audio, "TPE2", "aART", "albumartist",
                                   "ALBUMARTIST")
    return out


_FEAT_RE = re.compile(
    r"[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s+([^\)\]]+)[\)\]]"
    r"|(?:^|[\s,])(?:feat\.?|ft\.?|featuring)\s+(.+)$", re.I)


def extract_features(*texts) -> list:
    """Featured artists named in a title / artist string:
    'Song (feat. A & B)' -> ['A', 'B']."""
    feats: list = []
    for text in texts:
        for m in _FEAT_RE.finditer(text or ""):
            raw = (m.group(1) or m.group(2) or "").strip()
            for part in re.split(r"\s*(?:,|&|\band\b|\bwith\b)\s*", raw):
                p = part.strip(" .")
                if p and p.lower() not in [f.lower() for f in feats]:
                    feats.append(p)
    return feats


def _query_title(title: str) -> str:
    """Title with the featuring segment removed — identification
    and lyrics sources match far better without it."""
    t = re.sub(r"[\(\[]\s*(?:feat\.?|ft\.?|featuring)[^\)\]]*[\)\]]",
               " ", title or "", flags=re.I)
    t = re.sub(r"\s+(?:feat\.?|ft\.?|featuring)\s+.+$", "", t, flags=re.I)
    return re.sub(r"\s+", " ", t).strip(" -")


def embedded_cover(path: str) -> bytes | None:
    """The album art embedded in the audio file itself, if any."""
    if not _HAS_MUTAGEN:
        return None
    ext = os.path.splitext(path)[1].lower()
    try:
        if ext == ".mp3":
            apics = ID3(path).getall("APIC")
            for a in apics:
                if a.type == 3:
                    return a.data
            return apics[0].data if apics else None
        if ext in (".m4a", ".mp4"):
            audio = MP4(path)
            covr = audio.tags.get("covr") if audio and audio.tags else None
            return bytes(covr[0]) if covr else None
        if ext == ".flac":
            audio = FLAC(path)
            return audio.pictures[0].data if audio.pictures else None
        audio = mutagen.File(path)
        if audio is not None and getattr(audio, "pictures", None):
            return audio.pictures[0].data
    except Exception:
        return None
    return None


def extract_file_info(path: str) -> dict:
    """Everything the song file itself knows (0.6.0): title, artist,
    album, album artist, track length, featured artists, and whether
    it already carries album art."""
    tags = read_tags(path)
    return {"title": tags["title"], "artist": tags["artist"],
            "album": tags["album"], "album_artist": tags["album_artist"],
            "duration_seconds": int(round(tags["duration"])),
            "featuring": extract_features(tags["title"], tags["artist"]),
            "has_cover": embedded_cover(path) is not None}


def _cover_mime(data: bytes) -> str:
    return "image/png" if data[:4] == b"\x89PNG" else "image/jpeg"


def write_tags(path: str, meta: dict | None, cover: bytes | None,
               lyrics: str | None) -> bool:
    """Embed tags / cover art / lyrics into the audio file itself."""
    if not _HAS_MUTAGEN:
        return False
    ext = os.path.splitext(path)[1].lower()
    try:
        if ext == ".mp3":
            try:
                tags = ID3(path)
            except Exception:
                tags = ID3()
            if meta:
                for frame, key in (("TIT2", "title"), ("TPE1", "artist"),
                                   ("TALB", "album")):
                    if meta.get(key):
                        tags.delall(frame)
                        tags.add({"TIT2": TIT2, "TPE1": TPE1,
                                  "TALB": TALB}[frame](
                                      encoding=3, text=meta[key]))
                if meta.get("year"):
                    tags.delall("TDRC")
                    tags.add(TDRC(encoding=3, text=str(meta["year"])))
                if meta.get("track"):
                    tags.delall("TRCK")
                    tags.add(TRCK(encoding=3, text=str(meta["track"])))
            if cover:
                tags.delall("APIC")
                tags.add(APIC(encoding=3, mime=_cover_mime(cover), type=3,
                              desc="Cover", data=cover))
            if lyrics:
                tags.delall("USLT")
                tags.add(USLT(encoding=3, lang="eng", text=lyrics))
            tags.save(path)
            return True
        if ext in (".m4a", ".mp4"):
            audio = MP4(path)
            if audio.tags is None:
                audio.add_tags()
            if meta:
                if meta.get("title"):
                    audio["\xa9nam"] = [meta["title"]]
                if meta.get("artist"):
                    audio["\xa9ART"] = [meta["artist"]]
                if meta.get("album"):
                    audio["\xa9alb"] = [meta["album"]]
                if meta.get("year"):
                    audio["\xa9day"] = [str(meta["year"])]
                if meta.get("track"):
                    audio["trkn"] = [(int(meta["track"]), 0)]
            if cover:
                fmt = (MP4Cover.FORMAT_PNG
                       if _cover_mime(cover) == "image/png"
                       else MP4Cover.FORMAT_JPEG)
                audio["covr"] = [MP4Cover(cover, imageformat=fmt)]
            if lyrics:
                audio["\xa9lyr"] = [lyrics]
            audio.save()
            return True
        if ext == ".flac":
            audio = FLAC(path)
            if meta:
                for key, field in (("title", "title"), ("artist", "artist"),
                                   ("album", "album"), ("date", "year"),
                                   ("tracknumber", "track")):
                    if meta.get(field):
                        audio[key] = [str(meta[field])]
            if cover:
                pic = Picture()
                pic.data = cover
                pic.type = 3
                pic.mime = _cover_mime(cover)
                audio.clear_pictures()
                audio.add_picture(pic)
            if lyrics:
                audio["LYRICS"] = [lyrics]
            audio.save()
            return True
        if ext in (".ogg", ".oga", ".opus"):
            audio = mutagen.File(path)
            if audio is not None:
                if meta:
                    for key, field in (("TITLE", "title"),
                                       ("ARTIST", "artist"),
                                       ("ALBUM", "album"),
                                       ("DATE", "year"),
                                       ("TRACKNUMBER", "track")):
                        if meta.get(field):
                            audio[key] = [str(meta[field])]
                if lyrics:
                    audio["LYRICS"] = [lyrics]
                audio.save()
                return True
    except Exception:
        return False
    return False


_JUNK = re.compile(
    r"\[[^\]]*\]|"
    r"\((?:official|lyric|audio|video|hd|hq|mv|visualizer|remaster|explicit|"
    r"dirty|clean)[^)]*\)", re.I)


def clean_title(raw: str) -> str:
    s = _JUNK.sub(" ", raw or "")
    return re.sub(r"\s+", " ", s).strip(" -")


def split_artist_title(stem: str) -> tuple:
    stem = re.sub(r"\s*\[[A-Za-z0-9_-]{11}\]\s*$", "", stem or "")
    if " - " in stem:
        a, t = stem.split(" - ", 1)
        return a.strip(), clean_title(t)
    return "", clean_title(stem)


def _sim(a: str, b: str) -> float:
    def norm(s):
        return re.sub(r"[^a-z0-9 ]", "", (s or "").lower()).strip()
    a, b = norm(a), norm(b)
    if not a or not b:
        return 0.0
    return difflib.SequenceMatcher(None, a, b).ratio()


async def _identify_itunes(title: str, artist: str) -> dict | None:
    query = f"{artist} {title}".strip()
    if not query:
        return None
    try:
        async with httpx.AsyncClient(timeout=20, trust_env=False) as c:
            r = await c.get(f"{ITUNES_API_BASE}/search", headers=META_UA,
                            params={"term": query, "media": "music",
                                    "entity": "song", "limit": 5})
            r.raise_for_status()
            results = r.json().get("results") or []
    except Exception:
        return None
    best, best_score = None, 0.0
    for it in results:
        s = 0.65 * _sim(title, it.get("trackName") or "")
        s += 0.35 * (_sim(artist, it.get("artistName") or "")
                     if artist else 0.7)
        if s > best_score:
            best, best_score = it, s
    if best is None or best_score < 0.72:
        return None
    art = (best.get("artworkUrl100") or "").replace(
        "100x100bb.jpg", "600x600bb.jpg")
    return {"title": best.get("trackName") or title,
            "artist": best.get("artistName") or artist,
            "album": best.get("collectionName") or "",
            "year": (best.get("releaseDate") or "")[:4],
            "track": best.get("trackNumber"),
            "cover_url": art or None, "source": "itunes"}


async def _identify_musicbrainz(title: str, artist: str) -> dict | None:
    if not title:
        return None
    query = f'recording:"{title}"'
    if artist:
        query += f' AND artist:"{artist}"'
    try:
        async with httpx.AsyncClient(timeout=20, trust_env=False) as c:
            r = await c.get(f"{MUSICBRAINZ_API_BASE}/recording/",
                            headers=META_UA,
                            params={"query": query, "fmt": "json",
                                    "limit": 5})
            r.raise_for_status()
            recs = r.json().get("recordings") or []
    except Exception:
        return None
    for rec in recs:
        if (rec.get("score") or 0) < 80:
            continue
        if _sim(title, rec.get("title") or "") < 0.6:
            continue
        credit = rec.get("artist-credit") or []
        artist_name = "".join(
            (c.get("name") or "") + (c.get("joinphrase") or "")
            for c in credit).strip() or artist
        releases = rec.get("releases") or []
        album, release_id = "", None
        if releases:
            album = releases[0].get("title") or ""
            release_id = releases[0].get("id")
        cover = None
        if release_id:
            try:
                async with httpx.AsyncClient(
                        timeout=20, trust_env=False,
                        follow_redirects=True) as c:
                    cr = await c.get(
                        f"{COVERART_API_BASE}/release/{release_id}/front-500",
                        headers=META_UA)
                    if cr.status_code == 200 and len(cr.content) < 3_000_000:
                        cover = cr.content
            except Exception:
                cover = None
        return {"title": rec.get("title") or title,
                "artist": artist_name,
                "album": album,
                "year": (rec.get("first-release-date") or "")[:4],
                "track": None, "cover_bytes": cover,
                "source": "musicbrainz"}
    return None


async def _fetch_lyrics_lrclib(title: str, artist: str,
                               duration: float) -> str | None:
    """Plain lyrics from LRCLIB (no key needed). When only the synced
    version exists, its timestamps are stripped."""
    if not title:
        return None
    try:
        async with httpx.AsyncClient(timeout=20, trust_env=False) as c:
            params = {"track_name": title, "artist_name": artist or ""}
            if duration and duration > 0:
                params["duration"] = int(duration)
            r = await c.get(f"{LRCLIB_API_BASE}/get", params=params,
                            headers=META_UA)
            if r.status_code == 200:
                j = r.json()
                if j.get("plainLyrics"):
                    return j["plainLyrics"]
                if j.get("syncedLyrics"):
                    return re.sub(r"\[\d+:\d+(?:\.\d+)?\]\s?", "",
                                  j["syncedLyrics"]).strip() or None
            r = await c.get(f"{LRCLIB_API_BASE}/search",
                            params={"track_name": title,
                                    "artist_name": artist or ""},
                            headers=META_UA)
            if r.status_code == 200:
                for item in r.json() or []:
                    if item.get("plainLyrics"):
                        return item["plainLyrics"]
    except Exception:
        return None
    return None


def _fetch_lyrics_fallback(title: str, artist: str) -> str | None:
    """Second lyrics source: the syncedlyrics aggregator (Musixmatch,
    then Genius) for songs LRCLIB simply doesn't have. Optional
    dependency — absent or failing means no fallback, never an error.
    Synced timestamps and LRC metadata tags are stripped."""
    try:
        import syncedlyrics
    except Exception:
        return None
    query = f"{artist} - {title}".strip(" -") if artist else title
    try:
        raw = syncedlyrics.search(query,
                                  providers=["musixmatch", "genius"])
    except Exception:
        return None
    if not raw:
        return None
    lines = []
    for line in str(raw).splitlines():
        line = re.sub(r"\[\d+:\d+(?:\.\d+)?\]\s?", "", line).strip()
        if not line or (line.startswith("[") and line.endswith("]")):
            continue
        lines.append(line)
    return "\n".join(lines).strip() or None


async def _fetch_lyrics(title: str, artist: str,
                        duration: float) -> str | None:
    """Lyrics for a track: LRCLIB first (exact and fast), then the
    syncedlyrics fallback for songs LRCLIB doesn't carry."""
    text = await _fetch_lyrics_lrclib(title, artist, duration)
    if text:
        return text
    if not title:
        return None
    try:
        return await asyncio.wait_for(
            asyncio.to_thread(_fetch_lyrics_fallback, title, artist),
            timeout=45)
    except Exception:
        return None


async def enrich_file(path: str, want_meta: bool, want_lyrics: bool,
                      display_name: str = "", known: dict | None = None
                      ) -> dict:
    """Identify the track, then embed proper tags, cover art and
    lyrics into the file. Best-effort: failures leave the file as-is.
    display_name is the name the user knows the file by (uploads sit in
    a random temp file on disk, so their own stem is meaningless).
    known carries authoritative metadata (Spotify links): it wins for
    the identification query, and if no source identifies the track the
    known values are written as the tags directly."""
    report = {"matched": False, "source": None,
              "lyrics_embedded": False, "title": None}
    if not _HAS_MUTAGEN or (not want_meta and not want_lyrics):
        return report
    tags = read_tags(path)
    stem = os.path.splitext(display_name or os.path.basename(path))[0]
    f_artist, f_title = split_artist_title(stem)
    title = clean_title(tags["title"]) or f_title
    artist = tags["artist"] or f_artist
    if known:
        title = known.get("title") or title
        artist = known.get("artist") or artist
    meta, cover = None, None
    if want_meta:
        q_title = _query_title(title) or title
        meta = await _identify_itunes(q_title, artist)
        if meta is None:
            meta = await _identify_musicbrainz(q_title, artist)
        if meta is None and known:
            meta = {"title": known.get("title") or title,
                    "artist": known.get("artist") or artist,
                    "album": known.get("album") or "",
                    "year": known.get("year") or "",
                    "track": known.get("track"),
                    "cover_url": known.get("cover_url"),
                    "source": "spotify"}
        if meta:
            report["matched"] = True
            report["source"] = meta["source"]
            report["title"] = meta["title"]
            cover = meta.pop("cover_bytes", None)
            url = meta.pop("cover_url", None)
            if cover is None and url:
                try:
                    async with httpx.AsyncClient(
                            timeout=20, trust_env=False,
                            follow_redirects=True) as c:
                        cr = await c.get(url, headers=META_UA)
                        if cr.status_code == 200 and len(cr.content) < 3_000_000:
                            cover = cr.content
                except Exception:
                    cover = None
    lyrics = None
    if want_lyrics:
        lyrics = await _fetch_lyrics(
            meta["title"] if meta else _query_title(title) or title,
            meta["artist"] if meta else artist,
            tags["duration"])
    if meta or lyrics:
        if write_tags(path, meta, cover, lyrics) and lyrics:
            report["lyrics_embedded"] = True
    return report


# ------------------------------------------------------ upload statistics --

_stats_lock = threading.Lock()


def _stats_file() -> str:
    return os.path.join(DATA_DIR, "upload_stats.json")


def read_stats() -> dict:
    try:
        with open(_stats_file(), encoding="utf-8") as fh:
            s = json.load(fh)
        return {"uploaded_total": int(s.get("uploaded_total", 0)),
                "uploaded_bytes": int(s.get("uploaded_bytes", 0)),
                "last_upload_at": s.get("last_upload_at")}
    except Exception:
        return {"uploaded_total": 0, "uploaded_bytes": 0,
                "last_upload_at": None}


def bump_stats(size: int) -> None:
    with _stats_lock:
        s = read_stats()
        s["uploaded_total"] += 1
        s["uploaded_bytes"] += int(size)
        s["last_upload_at"] = int(time.time())
        os.makedirs(DATA_DIR, exist_ok=True)
        tmp = _stats_file() + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(s, fh)
        os.replace(tmp, _stats_file())


def library_index() -> tuple:
    """(lowercased audio filenames, audio file sizes) library-wide."""
    names, sizes = set(), set()
    for root, _dirs, files in os.walk(LIBRARY_DIR):
        for f in files:
            if os.path.splitext(f)[1].lower() in AUDIO_EXTS:
                names.add(f.lower())
                try:
                    sizes.add(os.path.getsize(os.path.join(root, f)))
                except OSError:
                    pass
    return names, sizes


def _sort_subdir(path: str) -> str:
    """'Artist/Album' from the file's (possibly enriched) tags."""
    t = read_tags(path)
    artist = sanitize_filename(t["artist"]) if t["artist"] else ""
    album = sanitize_filename(t["album"]) if t["album"] else ""
    if artist and album:
        return f"{artist}/{album}"
    return artist


async def save_processed(local: str, fname: str, source: str,
                         want_meta: bool, want_lyrics: bool,
                         sort: bool, known: dict | None = None,
                         bundled_cover: bytes | None = None,
                         bundled_lyrics: str | None = None) -> dict:
    """Enrich (optional) -> sort into Artist/Album (optional) -> save.

    Bundled cover art / lyrics (0.6.0) come with the upload itself —
    inside a ZIP, or attached by the app from the song's own folder —
    so they are the album's own assets: they are always embedded when
    present (even when the online enrichment toggles are off), and
    they win over anything enrichment fetched."""
    report = {"matched": False, "source": None,
              "lyrics_embedded": False, "title": None}
    if want_meta or want_lyrics:
        report = await enrich_file(local, want_meta, want_lyrics, fname,
                                   known)
    if bundled_cover or bundled_lyrics:
        if write_tags(local, None, bundled_cover, bundled_lyrics):
            if bundled_lyrics:
                report["lyrics_embedded"] = True
    info = extract_file_info(local)
    subdir = _sort_subdir(local) if sort else ""
    entry = await finish_save(local, fname, source, subdir)
    entry["enriched"] = report["matched"]
    entry["metadata_source"] = report["source"]
    entry["lyrics_embedded"] = report["lyrics_embedded"]
    entry["bundled_art"] = bool(bundled_cover)
    entry["duration_seconds"] = info["duration_seconds"]
    if info["featuring"]:
        entry["featuring"] = info["featuring"]
    if info["artist"]:
        entry["artist"] = info["artist"]
    if info["album"]:
        entry["album"] = info["album"]
    if report["title"]:
        entry["matched_title"] = report["title"]
    return entry


def _flag(value) -> bool:
    return str(value).strip().lower() in ("1", "true", "yes", "on")


# ---------------------------------------------------------------- TorBox --
# Optional route for /url: when TORBOX_API_KEY is set and the link's host
# is one of TorBox's supported web-download hosters (the list is fetched
# live from TorBox's public /webdl/hosters endpoint, 162 hosters at last
# check), the file is fetched through the user's own TorBox account:
# createwebdownload -> poll mylist -> requestdl per file -> download here.
# A downloaded ZIP is unpacked and every audio file inside is saved.
# Any TorBox failure falls back to yt-dlp so a link is never worse off
# for TorBox being configured.

_hosters_cache: dict = {"at": 0.0, "domains": set()}


async def torbox_hoster_domains() -> set:
    now = time.time()
    if _hosters_cache["domains"] and now - _hosters_cache["at"] < 3600:
        return _hosters_cache["domains"]
    try:
        async with httpx.AsyncClient(timeout=30, trust_env=False) as client:
            r = await client.get(f"{TORBOX_API_BASE}/webdl/hosters")
        domains = set()
        for hoster in r.json().get("data") or []:
            for d in (hoster or {}).get("domains") or []:
                domains.add(d.lower().lstrip("."))
        if domains:
            _hosters_cache.update(at=now, domains=domains)
    except Exception:
        pass
    return _hosters_cache["domains"]


async def torbox_matches(url: str, key: str) -> bool:
    if not key:
        return False
    host = (urllib.parse.urlparse(url).hostname or "").lower()
    if not host:
        return False
    domains = await torbox_hoster_domains()
    return any(host == d or host.endswith("." + d) for d in domains)


def _collect_audio(local: str, fname: str, workdir: str, results: list) -> None:
    """Append (path, filename) for an audio file; unpack ZIPs recursively."""
    ext = os.path.splitext(fname)[1].lower()
    if ext == ".zip":
        zdir = tempfile.mkdtemp(dir=workdir)
        with zipfile.ZipFile(local) as zf:
            zf.extractall(zdir)
        for root, _dirs, names in os.walk(zdir):
            for n in names:
                if os.path.splitext(n)[1].lower() in AUDIO_EXTS:
                    results.append((os.path.join(root, n), n))
        os.unlink(local)
    elif ext in AUDIO_EXTS:
        results.append((local, fname))


# Accelerated downloads (0.5.0): when a source supports HTTP range
# requests and the file is big enough to matter, pull it down over
# several parallel connections with per-segment resume - the trick
# download managers use - and fall back to the plain single stream
# whenever the source doesn't cooperate. Every direct route funnels
# through _download_to_file (direct audio / ZIP links incl. TorBox
# CDN bundles, and the TorBox / Premiumize fetchers), so they all
# get it. yt-dlp routes already parallelise internally; Drive keeps
# its own fetch.
ACCEL_CONNECTIONS = 4
ACCEL_MIN_BYTES = 8 * 1024 * 1024
ACCEL_ATTEMPTS = 3


async def _stream_body(resp, dest: str) -> int:
    size = 0
    with open(dest, "wb") as out:
        async for chunk in resp.aiter_bytes(1024 * 1024):
            size += len(chunk)
            if size > MAX_BYTES:
                raise HTTPException(413, "Downloaded file too large")
            out.write(chunk)
    return size


async def _download_segment(client, url: str, part: str, start: int,
                            end: int, headers) -> bool:
    """One byte range into its part file, resuming across attempts."""
    want = end - start + 1
    for _attempt in range(ACCEL_ATTEMPTS):
        have = os.path.getsize(part) if os.path.exists(part) else 0
        if have >= want:
            return have == want
        try:
            async with client.stream(
                    "GET", url,
                    headers={**(headers or {}),
                             "Range": f"bytes={start + have}-{end}"}) as resp:
                if resp.status_code != 206:
                    return False  # range support vanished: caller falls back
                with open(part, "ab") as out:
                    async for chunk in resp.aiter_bytes(1024 * 1024):
                        out.write(chunk)
        except HTTPException:
            raise
        except Exception:
            continue  # dropped mid-segment: resume from the part size
    return os.path.exists(part) and os.path.getsize(part) == want


async def _download_ranged(client, url: str, dest: str, total: int,
                           headers) -> bool:
    seg = -(-total // ACCEL_CONNECTIONS)
    ranges = [(s, min(s + seg, total) - 1)
              for s in range(0, total, seg)]
    parts = [f"{dest}.part{i}" for i in range(len(ranges))]
    try:
        ok = all(await asyncio.gather(*(
            _download_segment(client, url, part, s, e, headers)
            for part, (s, e) in zip(parts, ranges))))
        if not ok:
            return False
        with open(dest, "wb") as out:
            for part in parts:
                with open(part, "rb") as fh:
                    shutil.copyfileobj(fh, out)
        return os.path.getsize(dest) == total
    except Exception:
        return False
    finally:
        for part in parts:
            if os.path.exists(part):
                os.unlink(part)


async def _download_to_file(url: str, dest: str, headers=None) -> dict:
    """Download url to dest; returns {accelerated, connections, bytes,
    seconds} describing how it actually came down."""
    started = time.monotonic()
    info = {"accelerated": False, "connections": 1, "bytes": 0}
    async with httpx.AsyncClient(timeout=900, follow_redirects=True,
                                 trust_env=False) as client:
        total = None
        try:
            async with client.stream(
                    "GET", url,
                    headers={**(headers or {}),
                             "Range": "bytes=0-0"}) as resp:
                if resp.status_code == 206:
                    m = re.match(r"bytes 0-0/(\d+)$",
                                 resp.headers.get("content-range", ""))
                    if m:
                        total = int(m.group(1))
                elif resp.status_code == 200:
                    # The source ignored the range probe: this
                    # response IS the whole file, stream it as-is.
                    info["bytes"] = await _stream_body(resp, dest)
                    info["seconds"] = round(time.monotonic() - started, 2)
                    return info
                else:
                    raise HTTPException(
                        502, f"Download source returned HTTP "
                             f"{resp.status_code}")
        except HTTPException:
            raise
        except Exception:
            total = None  # probe failed: try the plain path below
        if total is not None:
            if total > MAX_BYTES:
                raise HTTPException(413, "Downloaded file too large")
            if total >= ACCEL_MIN_BYTES and await _download_ranged(
                    client, url, dest, total, headers):
                info.update(accelerated=True,
                            connections=ACCEL_CONNECTIONS, bytes=total)
                info["seconds"] = round(time.monotonic() - started, 2)
                return info
        async with client.stream("GET", url, headers=headers) as resp:
            if resp.status_code != 200:
                raise HTTPException(
                    502, f"Download source returned HTTP {resp.status_code}")
            info["bytes"] = await _stream_body(resp, dest)
    info["seconds"] = round(time.monotonic() - started, 2)
    return info


async def fetch_with_torbox(url: str, workdir: str, key: str = "") -> list:
    """Returns [(local_path, filename), ...] for audio (ZIPs unpacked)."""
    key = key or TORBOX_API_KEY
    headers = {"Authorization": f"Bearer {key}"}
    async with httpx.AsyncClient(timeout=60, trust_env=False) as client:
        r = await client.post(f"{TORBOX_API_BASE}/webdl/createwebdownload",
                              headers=headers, json={"link": url})
        try:
            payload = r.json()
        except Exception:
            payload = {}
        if r.status_code != 200 or not payload.get("success", True):
            detail = payload.get("detail") or payload.get("error") or f"HTTP {r.status_code}"
            raise HTTPException(502, f"TorBox rejected the link: {detail}")
        data = payload.get("data") or {}
        web_id = data.get("webdownload_id") or data.get("id") or data.get("web_download_id")
        if web_id is None:
            raise HTTPException(502, "TorBox did not return a download id")

        files = []
        deadline = time.time() + 8 * 60
        while time.time() < deadline:
            r = await client.get(f"{TORBOX_API_BASE}/webdl/mylist",
                                 headers=headers, params={"id": web_id})
            item = r.json().get("data") or {}
            if isinstance(item, list):
                item = item[0] if item else {}
            state = str(item.get("download_state") or item.get("state") or "").lower()
            if "error" in state or "fail" in state:
                raise HTTPException(502, f"TorBox download failed ({state})")
            files = item.get("files") or []
            done = state in ("completed", "downloaded", "finished", "cached") \
                or item.get("download_finished") is True \
                or float(item.get("progress") or 0) >= 1
            if files and done:
                break
            await asyncio.sleep(5)
        if not files:
            raise HTTPException(504, "TorBox did not finish the download in time")

        results = []
        for f in files:
            fname = sanitize_filename(
                f.get("name") or f.get("filename") or f.get("file_name") or "")
            ext = os.path.splitext(fname)[1].lower()
            if ext not in AUDIO_EXTS and ext != ".zip":
                continue
            r = await client.get(
                f"{TORBOX_API_BASE}/webdl/requestdl",
                params={"token": key, "web_id": web_id,
                        "file_id": f.get("id")})
            dl = r.json().get("data")
            if not isinstance(dl, str) or not dl.startswith("http"):
                raise HTTPException(502, "TorBox did not return a download link")
            local = os.path.join(workdir, f"torbox-{fname}")
            await _download_to_file(dl, local)
            _collect_audio(local, fname, workdir, results)
    if not results:
        raise HTTPException(422, "TorBox download contained no audio files")
    return results


# ------------------------------------------------------------- Premiumize --
# Second debrid route, same contract as TorBox: when PREMIUMIZE_API_KEY
# is set and the link's host is on Premiumize's supported-hoster list
# (GET /services/list), resolve it with POST /transfer/directdl. If the
# file is not yet in Premiumize's cache, a transfer is created, polled
# until finished, and directdl is asked again. Failures fall back.

_pm_hosters_cache: dict = {"at": 0.0, "domains": set(), "known": False}


async def premiumize_hoster_domains(key: str) -> set:
    now = time.time()
    if _pm_hosters_cache["known"] and now - _pm_hosters_cache["at"] < 3600:
        return _pm_hosters_cache["domains"]
    try:
        async with httpx.AsyncClient(timeout=30, trust_env=False) as client:
            r = await client.get(
                f"{PREMIUMIZE_API_BASE}/services/list",
                headers={"Authorization": f"Bearer {key}"})
        payload = r.json()
        domains = set()
        hosterlist = payload.get("hosterlist") or payload.get("hosters") or {}
        if isinstance(hosterlist, dict):
            for key, val in hosterlist.items():
                domains.add(str(key).lower().lstrip("."))
                if isinstance(val, dict):
                    for d in val.get("domains") or []:
                        domains.add(str(d).lower().lstrip("."))
        elif isinstance(hosterlist, list):
            for h in hosterlist:
                if isinstance(h, str):
                    domains.add(h.lower().lstrip("."))
                elif isinstance(h, dict):
                    for d in h.get("domains") or []:
                        domains.add(str(d).lower().lstrip("."))
        _pm_hosters_cache.update(at=now, domains=domains, known=True)
    except Exception:
        pass
    return _pm_hosters_cache["domains"]


async def premiumize_matches(url: str, key: str) -> bool:
    if not key:
        return False
    host = (urllib.parse.urlparse(url).hostname or "").lower()
    if not host:
        return False
    domains = await premiumize_hoster_domains(key)
    if not domains:
        return False  # list unavailable: don't guess, other routes decide
    return any(host == d or host.endswith("." + d) for d in domains)


async def _pm_post(client: httpx.AsyncClient, path: str, data: dict, key: str) -> dict:
    r = await client.post(f"{PREMIUMIZE_API_BASE}{path}",
                          headers={"Authorization": f"Bearer {key}"},
                          data=data)
    try:
        return r.json()
    except Exception:
        return {}


async def fetch_with_premiumize(url: str, workdir: str, key: str = "") -> list:
    """Returns [(local_path, filename), ...] for audio (ZIPs unpacked)."""
    key = key or PREMIUMIZE_API_KEY
    async with httpx.AsyncClient(timeout=120, trust_env=False) as client:
        payload = await _pm_post(client, "/transfer/directdl", {"src": url}, key)
        content = payload.get("content") or []
        if payload.get("status") != "success" or not content:
            created = await _pm_post(client, "/transfer/create", {"src": url}, key)
            transfer_id = (created.get("id")
                           if created.get("status") == "success" else None)
            if transfer_id is None:
                msg = payload.get("message") or created.get("message") \
                    or "link not supported"
                raise HTTPException(502, f"Premiumize could not take the link: {msg}")
            deadline = time.time() + 8 * 60
            finished = False
            while time.time() < deadline:
                listing = await _pm_post(client, "/transfer/list", {}, key)
                for item in listing.get("transfers") or []:
                    if str(item.get("id")) == str(transfer_id):
                        status = str(item.get("status") or "").lower()
                        if status == "finished":
                            finished = True
                        elif status == "error":
                            raise HTTPException(
                                502, "Premiumize transfer failed: "
                                + str(item.get("message") or "error"))
                        break
                if finished:
                    break
                await asyncio.sleep(5)
            if not finished:
                raise HTTPException(504, "Premiumize did not finish in time")
            payload = await _pm_post(client, "/transfer/directdl", {"src": url}, key)
            content = payload.get("content") or []
            if payload.get("status") != "success" or not content:
                raise HTTPException(502, "Premiumize finished but returned no files")

        results = []
        for entry in content:
            link = entry.get("link") or entry.get("stream_link")
            path = entry.get("path") or entry.get("name") or ""
            fname = sanitize_filename(os.path.basename(path.rstrip("/")))
            ext = os.path.splitext(fname)[1].lower()
            if not link or (ext not in AUDIO_EXTS and ext != ".zip"):
                continue
            local = os.path.join(workdir, f"premiumize-{fname}")
            await _download_to_file(link, local)
            _collect_audio(local, fname, workdir, results)
    if not results:
        raise HTTPException(422, "Premiumize download contained no audio files")
    return results


def fetch_with_ytdlp(url: str, workdir: str) -> list:
    """Download with yt-dlp -> MP3. Playlist URLs expand to every entry
    (first 50), each its own file, in playlist order."""
    if not shutil.which("yt-dlp"):
        raise HTTPException(
            501, "This link needs yt-dlp, which is not installed on the server")
    is_playlist = "list=" in url or "/playlist" in url
    if is_playlist:
        extra = ["--playlist-end", "50", "-o",
                 os.path.join(workdir, "%(playlist_index)03d - %(title)s.%(ext)s")]
    else:
        extra = ["--no-playlist", "-o",
                 os.path.join(workdir, "%(title)s.%(ext)s")]
    proc = subprocess.run(
        ["yt-dlp", "-x", "--audio-format", "mp3", "--audio-quality", "0",
         *extra, url],
        capture_output=True, text=True, timeout=1800,
    )
    produced = sorted(os.path.join(workdir, f) for f in os.listdir(workdir)
                      if f.lower().endswith(".mp3"))
    if proc.returncode != 0 or not produced:
        raise HTTPException(502, "yt-dlp could not fetch that link: "
                            + _clean_error(proc.stderr or proc.stdout))
    return produced


# ------------------------------------------------------- Website fallback --
# Some public websites are not supported by yt-dlp and are not direct
# files: a download endpoint may hide its filename in response headers,
# or an ordinary page may expose the actual media in an <audio>/<source>
# tag, an Open Graph tag, JSON-LD, a normal download link, page scripts,
# or an HLS playlist. This last-resort downloader fetches the page like a
# regular client, extracts those public candidates, and downloads them
# through the same accelerated direct downloader. It does not log in,
# solve CAPTCHAs, or bypass paywalls / access controls.
WEBSITE_PAGE_MAX_BYTES = 8 * 1024 * 1024
WEBSITE_MAX_FILES = 50
WEBSITE_EXTS = AUDIO_EXTS | VIDEO_EXTS | {".zip", ".m3u8"}

_CONTENT_TYPE_EXTS = {
    "audio/mpeg": ".mp3",
    "audio/mp3": ".mp3",
    "audio/flac": ".flac",
    "audio/x-flac": ".flac",
    "audio/wav": ".wav",
    "audio/x-wav": ".wav",
    "audio/ogg": ".ogg",
    "audio/opus": ".opus",
    "audio/mp4": ".m4a",
    "audio/aac": ".aac",
    "application/zip": ".zip",
    "application/x-zip-compressed": ".zip",
    "video/mp4": ".mp4",
    "video/webm": ".webm",
    "video/x-matroska": ".mkv",
    "application/vnd.apple.mpegurl": ".m3u8",
    "application/x-mpegurl": ".m3u8",
}


def _website_url_ext(url: str) -> str:
    parsed = urllib.parse.urlparse(url or "")
    ext = os.path.splitext(parsed.path)[1].lower()
    if ext:
        return ext
    qname = (urllib.parse.parse_qs(parsed.query).get("filename")
             or [""])[0]
    return os.path.splitext(qname)[1].lower() if qname else ""


def _website_filename(url: str, headers=None, fallback: str = "Website Download") -> str:
    headers = headers or {}
    cd = headers.get("content-disposition") or ""
    name = ""
    m = re.search(r"filename\*=UTF-8''([^;]+)", cd)
    if m:
        name = urllib.parse.unquote(m.group(1).strip('"'))
    if not name:
        m = re.search(r'filename="([^"]+)"', cd)
        if m:
            name = m.group(1)
    if not name:
        parsed = urllib.parse.urlparse(url or "")
        name = (urllib.parse.parse_qs(parsed.query).get("filename")
                or [""])[0]
        if not name:
            name = os.path.basename(parsed.path)
    name = sanitize_filename(urllib.parse.unquote(name or ""))
    return name or sanitize_filename(fallback)


def _website_rank(url: str) -> int:
    ext = _website_url_ext(url)
    if ext == ".zip":
        return 0
    if ext in AUDIO_EXTS:
        return 1
    if ext == ".m3u8":
        return 2
    if ext in VIDEO_EXTS:
        return 3
    return 99


def _extract_website_candidates(page_url: str, page_text: str) -> list:
    """Public media URLs exposed by a page, best candidates first."""
    text = (page_text or "").replace("\\/", "/")
    raw_values = []
    raw_values.extend(re.findall(
        r"(?:href|src|content|data-src|data-url)\s*=\s*[\"']([^\"']+)[\"']",
        text, flags=re.IGNORECASE))
    raw_values.extend(re.findall(r"https?://[^\s\"'<>\\]+", text))
    found = {}
    for order, raw in enumerate(raw_values):
        value = html.unescape(str(raw)).strip().strip(".,);]}\"'")
        if not value:
            continue
        absolute = urllib.parse.urljoin(page_url, value)
        parsed = urllib.parse.urlparse(absolute)
        if parsed.scheme not in ("http", "https"):
            continue
        absolute = urllib.parse.urldefrag(absolute)[0]
        if absolute.rstrip("/") == (page_url or "").rstrip("/"):
            continue
        if _website_url_ext(absolute) not in WEBSITE_EXTS:
            continue
        found.setdefault(absolute, (_website_rank(absolute), order))
    ranked = sorted(found.items(), key=lambda item: item[1])
    return [url for url, _rank in ranked[:WEBSITE_MAX_FILES]]


def _convert_video_to_mp3(local: str, workdir: str, index: int) -> str:
    if not shutil.which("ffmpeg"):
        raise HTTPException(
            501, "This website returned video, but ffmpeg is not installed "
                 "on the server to extract its audio")
    out = os.path.join(workdir, f"website-audio-{index}.mp3")
    proc = subprocess.run(
        ["ffmpeg", "-y", "-i", local, "-vn", "-codec:a", "libmp3lame",
         "-q:a", "0", out],
        capture_output=True, text=True, timeout=1800)
    if proc.returncode != 0 or not os.path.exists(out):
        raise HTTPException(502, "The website video could not be converted "
                            "to audio: " + _clean_error(proc.stderr))
    return out


def _fetch_hls_sync(url: str, workdir: str, index: int, referer: str) -> str:
    if not shutil.which("ffmpeg"):
        raise HTTPException(
            501, "This website uses an HLS stream, but ffmpeg is not "
                 "installed on the server")
    out = os.path.join(workdir, f"website-stream-{index}.mp3")
    ua = META_UA.get("User-Agent", "Mozilla/5.0")
    proc = subprocess.run(
        ["ffmpeg", "-y", "-user_agent", ua,
         "-headers", f"Referer: {referer}\r\n",
         "-i", url, "-vn", "-codec:a", "libmp3lame", "-q:a", "0", out],
        capture_output=True, text=True, timeout=1800)
    if proc.returncode != 0 or not os.path.exists(out):
        raise HTTPException(502, "The website stream could not be "
                            "downloaded: " + _clean_error(proc.stderr))
    return out


async def _append_website_payload(local: str, fname: str, workdir: str,
                                  results: list, index: int) -> None:
    ext = os.path.splitext(fname)[1].lower()
    if ext in AUDIO_EXTS or ext == ".zip":
        _collect_audio(local, fname, workdir, results)
    elif ext in VIDEO_EXTS:
        converted = await asyncio.to_thread(
            _convert_video_to_mp3, local, workdir, index)
        stem = os.path.splitext(fname)[0] or f"Website Download {index + 1}"
        results.append((converted, sanitize_filename(stem + ".mp3")))


async def fetch_from_website(url: str, workdir: str) -> list:
    """Last-resort public website downloader.

    Returns [(local_path, filename), ...] containing audio only. A URL
    may itself be a header-described download endpoint, an HLS playlist,
    or an HTML page with exposed media/download links. Network-level
    failures become a clean 502, never a server crash - this runs as a
    fallback, so the original route's error must stay in charge.
    """
    try:
        return await _fetch_from_website(url, workdir)
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(502, "That website could not be fetched: "
                            + _clean_error(str(exc)))


async def _fetch_from_website(url: str, workdir: str) -> list:
    if _website_url_ext(url) == ".m3u8":
        local = await asyncio.to_thread(_fetch_hls_sync, url, workdir, 0, url)
        return [(local, "Website Stream.mp3")]

    headers = {**META_UA, "Accept": "*/*"}
    results: list = []
    page_text = ""
    final_url = url
    async with httpx.AsyncClient(timeout=900, follow_redirects=True,
                                 trust_env=False) as client:
        async with client.stream("GET", url, headers=headers) as resp:
            if resp.status_code != 200:
                raise HTTPException(
                    502, f"Website returned HTTP {resp.status_code}")
            final_url = str(resp.url)
            ctype = (resp.headers.get("content-type") or "")
            ctype = ctype.split(";")[0].strip().lower()
            fname = _website_filename(final_url, resp.headers)
            ext = os.path.splitext(fname)[1].lower()
            if ext not in WEBSITE_EXTS:
                ext = _CONTENT_TYPE_EXTS.get(ctype, "")
                if ext:
                    fname = sanitize_filename(
                        os.path.splitext(fname)[0] + ext)
            if ext in AUDIO_EXTS or ext == ".zip" or ext in VIDEO_EXTS:
                local = os.path.join(workdir, f"website-0-{fname}")
                await _stream_body(resp, local)
                await _append_website_payload(
                    local, fname, workdir, results, 0)
                if results:
                    return results
                raise HTTPException(
                    422, "That website download contained no usable audio")
            if ext == ".m3u8":
                local = await asyncio.to_thread(
                    _fetch_hls_sync, final_url, workdir, 0, url)
                return [(local, "Website Stream.mp3")]
            if ctype not in ("text/html", "application/xhtml+xml", ""):
                raise HTTPException(
                    422, "That website did not return a page or a "
                         "download NaviUpload can use")
            body = bytearray()
            async for chunk in resp.aiter_bytes(1024 * 256):
                body.extend(chunk)
                if len(body) >= WEBSITE_PAGE_MAX_BYTES:
                    del body[WEBSITE_PAGE_MAX_BYTES:]
                    break
            encoding = resp.encoding or "utf-8"
            page_text = body.decode(encoding, errors="ignore")

    candidates = _extract_website_candidates(final_url, page_text)
    if not candidates:
        raise HTTPException(
            422, "That website did not expose a downloadable audio file, "
                 "ZIP, video or stream. Login-only and CAPTCHA-protected "
                 "pages cannot be fetched this way")
    download_headers = {**META_UA, "Referer": final_url}
    errors = []
    for i, candidate in enumerate(candidates):
        ext = _website_url_ext(candidate)
        fname = _website_filename(candidate)
        if ext and os.path.splitext(fname)[1].lower() != ext:
            fname = sanitize_filename(fname + ext)
        try:
            if ext == ".m3u8":
                local = await asyncio.to_thread(
                    _fetch_hls_sync, candidate, workdir, i, final_url)
                stem = os.path.splitext(fname)[0] or f"Website Stream {i + 1}"
                results.append((local, sanitize_filename(stem + ".mp3")))
                continue
            local = os.path.join(workdir, f"website-{i}-{fname}")
            await _download_to_file(candidate, local,
                                    headers=download_headers)
            await _append_website_payload(
                local, fname, workdir, results, i)
        except HTTPException as exc:
            errors.append(str(exc.detail))
        except Exception as exc:  # one bad candidate must not sink the rest
            errors.append(_clean_error(str(exc)))
    if not results:
        detail = f": {errors[0]}" if errors else ""
        raise HTTPException(
            502, "The website exposed media links, but none could be "
                 f"downloaded{detail}")
    return results[:WEBSITE_MAX_FILES]


# ---------------------------------------------------------------- Spotify --
# Spotify track / album / playlist links resolve through Spotify's
# public embed pages: the __NEXT_DATA__ JSON in the embed names every
# track (playlists expose their first 50, the same cap as yt-dlp
# playlist expansion). No Spotify account or token is involved. Audio
# itself comes from yt-dlp search, and the exact Spotify metadata
# rides along as `known` so tags and lyrics land right even when the
# video's own title is a mess.

_SPOTIFY_RE = re.compile(
    r"open\.spotify\.com/(?:intl-[a-z]{2}/)?(track|album|playlist)/"
    r"([A-Za-z0-9]+)")
_SPOTIFY_OTHER_RE = re.compile(
    r"open\.spotify\.com/(?:intl-[a-z]{2}/)?(episode|show|artist|user)/")
SPOTIFY_MAX_TRACKS = 50


def spotify_parse(url: str) -> tuple | None:
    m = _SPOTIFY_RE.search(url or "")
    if not m:
        return None
    return m.group(1), m.group(2)


def _find_entity(obj, uri: str, depth: int = 0):
    """Locate the embed entity dict for `uri` in the page JSON."""
    if depth > 10:
        return None
    if isinstance(obj, dict):
        if obj.get("uri") == uri and ("title" in obj or "name" in obj):
            return obj
        for v in obj.values():
            found = _find_entity(v, uri, depth + 1)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for v in obj:
            found = _find_entity(v, uri, depth + 1)
            if found is not None:
                return found
    return None


def _spotify_cover(entity: dict) -> str | None:
    images = ((entity.get("visualIdentity") or {}).get("image")) or []
    best, best_w = None, -1
    for img in images:
        w = img.get("maxWidth") or 0
        if img.get("url") and w > best_w:
            best, best_w = img["url"], w
    return best


def _spotify_year(entity: dict) -> str:
    iso = (entity.get("releaseDate") or {}).get("isoString") or ""
    return iso[:4] if iso[:4].isdigit() else ""


async def fetch_spotify_tracks(kind: str, sid: str) -> tuple:
    """(entity title, [track, ...]) from the public embed page. Each
    track: title / artist / album / year / track / cover_url."""
    embed_url = f"{SPOTIFY_EMBED_BASE}/embed/{kind}/{sid}"
    try:
        async with httpx.AsyncClient(timeout=30, trust_env=False,
                                     follow_redirects=True) as c:
            r = await c.get(embed_url, headers=META_UA)
            r.raise_for_status()
            html = r.text
    except Exception:
        raise HTTPException(502, "Spotify could not be reached")
    m = re.search(
        r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>',
        html, re.S)
    entity = None
    if m:
        try:
            entity = _find_entity(json.loads(m.group(1)),
                                  f"spotify:{kind}:{sid}")
        except Exception:
            entity = None
    if entity is None:
        raise HTTPException(502, "That Spotify link could not be read "
                                 "(it may be private or removed)")
    name = entity.get("title") or entity.get("name") or "Spotify"
    cover = _spotify_cover(entity)
    year = _spotify_year(entity)
    tracks = []
    if kind == "track":
        artist = ", ".join(a.get("name", "") for a in
                           entity.get("artists") or [] if a.get("name"))
        tracks.append({"title": entity.get("title") or name,
                       "artist": artist, "album": "", "year": year,
                       "track": None, "cover_url": cover})
    else:
        for i, t in enumerate(entity.get("trackList") or []):
            if not t.get("title"):
                continue
            tracks.append({
                "title": t["title"],
                "artist": t.get("subtitle") or "",
                "album": name if kind == "album" else "",
                "year": year if kind == "album" else "",
                "track": (i + 1) if kind == "album" else None,
                # A playlist's cover is a mosaic, not the song's art;
                # leave it to the metadata sources.
                "cover_url": cover if kind == "album" else None})
    return name, tracks[:SPOTIFY_MAX_TRACKS]


def fetch_spotify_audio(track: dict, workdir: str, index: int) -> str:
    """One track's audio via yt-dlp search -> MP3 (same flags as the
    page-link route). Raises HTTPException when nothing comes back."""
    if not shutil.which("yt-dlp"):
        raise HTTPException(
            501, "Spotify downloads need yt-dlp, which is not installed "
                 "on the server")
    query = f"{track.get('artist', '')} - {track.get('title', '')}".strip(" -")
    subdir = os.path.join(workdir, f"spotify{index:03d}")
    os.makedirs(subdir, exist_ok=True)
    proc = subprocess.run(
        ["yt-dlp", "-x", "--audio-format", "mp3", "--audio-quality", "0",
         "--no-playlist", "-o",
         os.path.join(subdir, "%(title)s.%(ext)s"),
         f"ytsearch1:{query}"],
        capture_output=True, text=True, timeout=900)
    produced = sorted(os.path.join(subdir, f) for f in os.listdir(subdir)
                      if f.lower().endswith(".mp3"))
    if proc.returncode != 0 or not produced:
        raise HTTPException(502, "yt-dlp found no audio for "
                            f"'{query}': "
                            + _clean_error(proc.stderr or proc.stdout))
    return produced[0]


# ------------------------------------------------------------ Google Drive --
# Drive file links (drive.google.com/file/d/<id>, /open?id=, /uc?id= and
# drive.usercontent.google.com/download?id=) fetch through Drive's own
# direct-download endpoint; yt-dlp chokes on Drive's interstitial pages
# and answers with a blob of HTML. The real filename (and the proof it
# is audio at all) comes from the Content-Disposition header. The file
# must be shared "anyone with the link" — Drive serves a sign-in page
# otherwise, which is detected and reported plainly.

_DRIVE_PATH_RE = re.compile(r"drive\.google\.com/file/d/([A-Za-z0-9_-]+)")


def drive_file_id(url: str) -> str | None:
    m = _DRIVE_PATH_RE.search(url or "")
    if m:
        return m.group(1)
    try:
        parsed = urllib.parse.urlparse(url or "")
    except Exception:
        return None
    host = (parsed.netloc or "").lower()
    if host in ("drive.google.com", "drive.usercontent.google.com"):
        fid = (urllib.parse.parse_qs(parsed.query).get("id") or [""])[0]
        if re.fullmatch(r"[A-Za-z0-9_-]+", fid or ""):
            return fid
    return None


async def fetch_drive_file(file_id: str, workdir: str) -> tuple:
    """(local path, filename) for a shared Drive file."""
    dl = (f"{DRIVE_DOWNLOAD_BASE}/download?"
          f"id={file_id}&export=download&confirm=t")
    async with httpx.AsyncClient(timeout=900, follow_redirects=True,
                                 trust_env=False) as client:
        async with client.stream("GET", dl, headers=META_UA) as resp:
            if resp.status_code != 200:
                raise HTTPException(
                    502, f"Google Drive returned HTTP {resp.status_code}")
            ctype = (resp.headers.get("content-type") or "").lower()
            cd = resp.headers.get("content-disposition") or ""
            name = ""
            m = re.search(r"filename\*=UTF-8''([^;]+)", cd)
            if m:
                name = urllib.parse.unquote(m.group(1).strip('"'))
            if not name:
                m = re.search(r'filename="([^"]+)"', cd)
                if m:
                    name = m.group(1)
            name = sanitize_filename(name)
            if (os.path.splitext(name)[1].lower() not in AUDIO_EXTS
                    or "text/html" in ctype):
                raise HTTPException(
                    400, "That Drive link did not deliver an audio file. "
                         "Make sure it is a single audio file shared "
                         "with 'Anyone with the link'.")
            dest = os.path.join(workdir, name)
            size = 0
            with open(dest, "wb") as out:
                async for chunk in resp.aiter_bytes(1024 * 1024):
                    size += len(chunk)
                    if size > MAX_BYTES:
                        raise HTTPException(
                            413, "Downloaded file too large")
                    out.write(chunk)
    return dest, name


@app.post("/url")
async def upload_url(
    request: Request,
    x_upload_token: str | None = Header(default=None),
    x_torbox_key: str | None = Header(default=None),
    x_premiumize_key: str | None = Header(default=None),
) -> dict:
    require_token(x_upload_token)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "Body must be JSON: {\"url\": \"...\"}")
    url = (body or {}).get("url", "").strip()
    if not url or not re.match(r"^https?://", url):
        raise HTTPException(400, "Give a valid http(s) URL")
    # Optional processing flags (JSON booleans): identify + tag the
    # downloads (default on), embed lyrics (default on), file them
    # under Artist/Album folders (default off).
    want_meta = _flag(body.get("enrich", True))
    want_lyrics = _flag(body.get("lyrics", True))
    want_sort = _flag(body.get("sort", False))

    os.makedirs(DATA_DIR, exist_ok=True)
    workdir = tempfile.mkdtemp(dir=DATA_DIR)
    try:
        parsed_url = urllib.parse.urlparse(url)
        direct_name = sanitize_filename(os.path.basename(parsed_url.path))
        if os.path.splitext(direct_name)[1].lower() not in AUDIO_EXTS | {".zip"}:
            # Some direct-download services (TorBox's CDN among them)
            # keep the real filename in the query string instead of
            # the path: .../zip/<uuid>?token=...&filename=songs.zip
            qname = (urllib.parse.parse_qs(parsed_url.query)
                     .get("filename") or [""])[0]
            if qname:
                direct_name = sanitize_filename(qname)
        if os.path.splitext(direct_name)[1].lower() in AUDIO_EXTS:
            tmp = os.path.join(workdir, direct_name)
            dl_info = await _download_to_file(url, tmp)
            result = await save_processed(tmp, direct_name, "url",
                                          want_meta, want_lyrics, want_sort)
            result["download"] = dl_info
            return result
        if os.path.splitext(direct_name)[1].lower() == ".zip":
            # A direct ZIP (an album bundle, a TorBox CDN zip link):
            # download it and save every audio file inside, exactly
            # like a debrid bundle.
            tmp = os.path.join(workdir, direct_name)
            dl_info = await _download_to_file(url, tmp)
            collected: list = []
            try:
                _collect_audio(tmp, direct_name, workdir, collected)
            except Exception:
                raise HTTPException(400, "That ZIP file could not be opened")
            if not collected:
                raise HTTPException(
                    400, "That ZIP contains no audio files we can add")
            saved = []
            for local, fname in collected:
                saved.append(await save_processed(
                    local, fname, "url", want_meta, want_lyrics,
                    want_sort))
            first = saved[0]
            first["download"] = dl_info
            if len(saved) > 1:
                first["also_saved"] = len(saved) - 1
                first["files"] = [dict(e) for e in saved]
            return first

        # Spotify track / album / playlist: resolve the track list
        # from the public embed page, fetch each song's audio through
        # yt-dlp search, and tag with the exact Spotify metadata. A
        # track that fails to download never sinks the rest of the
        # album / playlist; it is reported in "failed_tracks".
        if _SPOTIFY_OTHER_RE.search(url):
            raise HTTPException(
                400, "Only Spotify track, album and playlist links "
                     "are supported")
        sp = spotify_parse(url)
        if sp:
            _name, tracks = await fetch_spotify_tracks(*sp)
            if not tracks:
                raise HTTPException(
                    502, "Spotify returned no tracks for that link")
            saved, failed = [], []
            for i, track in enumerate(tracks):
                try:
                    # to_thread: a track search can take minutes, and
                    # the sync subprocess must not freeze the server's
                    # event loop (stats/uploads) while it runs.
                    local = await asyncio.to_thread(
                        fetch_spotify_audio, track, workdir, i)
                except HTTPException:
                    failed.append(
                        f"{track['artist']} - {track['title']}".strip(" -"))
                    continue
                fname = sanitize_filename(
                    f"{track['artist']} - {track['title']}.mp3")
                saved.append(await save_processed(
                    local, fname, "url", want_meta, want_lyrics,
                    want_sort, known=track))
            if not saved:
                raise HTTPException(
                    502, "None of the tracks from that Spotify link "
                         "could be downloaded")
            first = saved[0]
            first["via"] = "spotify"
            if len(saved) > 1:
                first["also_saved"] = len(saved) - 1
                first["files"] = [dict(e) for e in saved]
            if failed:
                first["failed_tracks"] = failed
            return first

        # Google Drive file links go through Drive's direct-download
        # endpoint (yt-dlp only gets Drive's HTML interstitial).
        drive_id = drive_file_id(url)
        if drive_id:
            local, fname = await fetch_drive_file(drive_id, workdir)
            return await save_processed(local, fname, "url",
                                        want_meta, want_lyrics, want_sort)

        # Debrid routes first when the link is on a provider's hoster
        # list and that provider's key is available: TorBox, then
        # Premiumize. Keys come from the app per request (X-TorBox-Key /
        # X-Premiumize-Key headers) when present, else the server's own
        # environment. A provider failure never blocks the next route.
        tb_key = (x_torbox_key or "").strip() or TORBOX_API_KEY
        pm_key = (x_premiumize_key or "").strip() or PREMIUMIZE_API_KEY
        provider_error = None
        for key, matches, fetch, label in (
            (tb_key, torbox_matches, fetch_with_torbox, "torbox"),
            (pm_key, premiumize_matches, fetch_with_premiumize, "premiumize"),
        ):
            if not await matches(url, key):
                continue
            try:
                saved = []
                for local, fname in await fetch(url, workdir, key):
                    saved.append(await save_processed(
                        local, fname, "url",
                        want_meta, want_lyrics, want_sort))
                first = saved[0]
                first["via"] = label
                if len(saved) > 1:
                    first["also_saved"] = len(saved) - 1
                    first["files"] = [dict(e) for e in saved]
                return first
            except HTTPException as exc:
                provider_error = provider_error or exc

        # Anything else (YouTube, SoundCloud, a page link): yt-dlp -> MP3.
        # to_thread for the same reason as the Spotify route: a long
        # download must not freeze every other request. If yt-dlp does
        # not support the website, make one last attempt with the
        # generic website downloader before giving up.
        try:
            produced_files = await asyncio.to_thread(
                fetch_with_ytdlp, url, workdir)
            website_files = [(path, os.path.basename(path))
                             for path in produced_files]
            via = None
        except HTTPException as ytdlp_error:
            try:
                website_files = await fetch_from_website(url, workdir)
                via = "website"
            except HTTPException:
                if provider_error is not None:
                    raise provider_error
                raise ytdlp_error
        saved = []
        for produced, fname in website_files:
            saved.append(await save_processed(
                produced, fname, "url",
                want_meta, want_lyrics, want_sort))
        first = saved[0]
        if via:
            first["via"] = via
        if len(saved) > 1:
            first["also_saved"] = len(saved) - 1
            first["files"] = [dict(e) for e in saved]
        return first
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


@app.post("/scan")
async def scan(x_upload_token: str | None = Header(default=None)) -> dict:
    """Manual library refresh: ask Navidrome to rescan now."""
    require_token(x_upload_token)
    configured = bool(NAVIDROME_URL and NAVIDROME_USER and NAVIDROME_PASSWORD)
    triggered = await trigger_scan() if configured else False
    return {"scan_configured": configured, "scan_triggered": triggered}


@app.get("/stats")
async def stats(x_upload_token: str | None = Header(default=None)) -> dict:
    """Library size right now + everything NaviUpload has ever added."""
    require_token(x_upload_token)
    out = read_stats()
    out["library_files"] = library_file_count()
    return out


@app.post("/check")
async def check(request: Request,
                x_upload_token: str | None = Header(default=None)) -> dict:
    """Duplicate check: for each {name, size}, is a file with that name
    (or that exact size) already in the library?"""
    require_token(x_upload_token)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "Body must be JSON: {\"items\": [...]}")
    items = (body or {}).get("items") or []
    names, sizes = library_index()
    results = []
    for it in items[:200]:
        name = str((it or {}).get("name") or "")
        try:
            size = int((it or {}).get("size") or 0)
        except (TypeError, ValueError):
            size = 0
        results.append({
            "name": name,
            "exists": os.path.basename(name).lower() in names,
            "same_size": bool(size) and size in sizes,
        })
    return {"results": results}


@app.get("/in-library")
async def in_library(title: str = "", artist: str = "",
                     scan_first: int = 0,
                     x_upload_token: str | None = Header(default=None)) -> dict:
    """Has this track actually landed in Navidrome yet? Uses the
    Subsonic search3 API when Navidrome credentials are configured."""
    require_token(x_upload_token)
    configured = bool(NAVIDROME_URL and NAVIDROME_USER and NAVIDROME_PASSWORD)
    if not configured or not title:
        return {"configured": configured, "found": False,
                "matched_title": None}
    if scan_first:
        await trigger_scan()
        await asyncio.sleep(3)
    salt = secrets.token_hex(8)
    token = hashlib.md5((NAVIDROME_PASSWORD + salt).encode()).hexdigest()
    params = {
        "u": NAVIDROME_USER, "t": token, "s": salt, "v": "1.16.1",
        "c": "NavidromeUploader", "f": "json",
        "query": f"{artist} {title}".strip(), "songCount": 10,
    }
    try:
        async with httpx.AsyncClient(timeout=30, trust_env=False) as client:
            r = await client.get(f"{NAVIDROME_URL}/rest/search3.view",
                                 params=params)
        songs = (r.json().get("subsonic-response", {})
                 .get("searchResult3", {}).get("song") or [])
    except Exception:
        return {"configured": True, "found": False, "matched_title": None}
    for s in songs:
        if _sim(title, s.get("title") or "") >= 0.8 and (
                not artist or _sim(artist, s.get("artist") or "") >= 0.45):
            return {"configured": True, "found": True,
                    "matched_title": s.get("title")}
    return {"configured": True, "found": False, "matched_title": None}


@app.post("/tracks")
async def upload_tracks(
    request: Request,
    x_upload_token: str | None = Header(default=None),
) -> dict:
    """Fetch specific tracks ({title, artist}, or "Artist - Title"
    strings) via yt-dlp search. The apps use this to retry just the
    failed tracks of a Spotify / playlist batch instead of
    re-downloading the whole link."""
    require_token(x_upload_token)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "Body must be JSON: {\"tracks\": [...]}")
    raw = (body or {}).get("tracks") or []
    want_meta = _flag(body.get("enrich", True))
    want_lyrics = _flag(body.get("lyrics", True))
    want_sort = _flag(body.get("sort", False))
    tracks = []
    for item in raw[:50]:
        if isinstance(item, str):
            artist, sep, title = item.partition(" - ")
            if not sep:
                artist, title = "", item
            tracks.append({"title": title.strip(),
                           "artist": artist.strip()})
        elif isinstance(item, dict):
            tracks.append({
                "title": str(item.get("title") or "").strip(),
                "artist": str(item.get("artist") or "").strip()})
    tracks = [t for t in tracks if t["title"]]
    if not tracks:
        raise HTTPException(400, "Give at least one track to fetch")
    os.makedirs(DATA_DIR, exist_ok=True)
    workdir = tempfile.mkdtemp(dir=DATA_DIR)
    try:
        saved, failed = [], []
        for i, track in enumerate(tracks):
            try:
                local = await asyncio.to_thread(
                    fetch_spotify_audio, track, workdir, i)
            except HTTPException:
                failed.append(
                    f"{track['artist']} - {track['title']}".strip(" -"))
                continue
            fname = sanitize_filename(
                f"{track['artist']} - {track['title']}.mp3")
            saved.append(await save_processed(
                local, fname, "url", want_meta, want_lyrics, want_sort,
                known=track))
        if not saved:
            raise HTTPException(
                502, "None of the tracks could be downloaded")
        first = saved[0]
        first["via"] = "retry"
        if len(saved) > 1:
            first["also_saved"] = len(saved) - 1
            first["files"] = [dict(e) for e in saved]
        if failed:
            first["failed_tracks"] = failed
        return first
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def _dup_key_part(text: str) -> str:
    """Normalise a title/artist for duplicate matching: lowercase,
    drop bracketed extras ((feat. ...), [Remaster] ...), keep only
    letters and digits."""
    text = re.sub(r"\([^)]*\)|\[[^\]]*\]", " ", (text or "").lower())
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return " ".join(text.split())


def find_duplicates() -> dict:
    """Group library files that are the same song (same normalised
    artist + title tags; untagged files match on filename)."""
    groups: dict[str, list] = {}
    scanned = 0
    for root, _dirs, files in os.walk(LIBRARY_DIR):
        for name in files:
            if os.path.splitext(name)[1].lower() not in AUDIO_EXTS:
                continue
            path = os.path.join(root, name)
            try:
                size = os.path.getsize(path)
            except OSError:
                continue
            scanned += 1
            tags = read_tags(path)
            title = tags["title"] or os.path.splitext(name)[0]
            key = (_dup_key_part(tags["artist"]) + "|"
                   + _dup_key_part(title))
            if key == "|":
                continue
            groups.setdefault(key, []).append({
                "file": os.path.relpath(path, LIBRARY_DIR),
                "size": size,
                "title": title,
                "artist": tags["artist"],
                "album": tags["album"],
                "duration": round(tags["duration"], 1),
            })
    dupes, wasted = [], 0
    for items in groups.values():
        if len(items) < 2:
            continue
        # Biggest copy first: that's the one to keep.
        items.sort(key=lambda i: i["size"], reverse=True)
        extra = sum(i["size"] for i in items[1:])
        wasted += extra
        dupes.append({"title": items[0]["title"],
                      "artist": items[0]["artist"],
                      "files": items,
                      "wasted_bytes": extra})
    dupes.sort(key=lambda d: d["wasted_bytes"], reverse=True)
    return {"groups": dupes,
            "group_count": len(dupes),
            "file_count": sum(len(d["files"]) for d in dupes),
            "wasted_bytes": wasted,
            "scanned": scanned}


@app.get("/duplicates")
async def duplicates(
        x_upload_token: str | None = Header(default=None)) -> dict:
    """Every song that exists more than once in the library, with the
    copies (biggest first) and the space the extra copies waste."""
    require_token(x_upload_token)
    # Tag-reading thousands of files is slow, sync work: thread it.
    return await asyncio.to_thread(find_duplicates)


@app.post("/delete")
async def delete_files(
        request: Request,
        x_upload_token: str | None = Header(default=None)) -> dict:
    """Delete library files by library-relative path (the duplicate
    finder's cleanup). Paths are pinned inside the library and must
    be audio files; anything else is reported, never touched."""
    require_token(x_upload_token)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "Body must be JSON: {\"files\": [...]}")
    wanted = (body or {}).get("files") or []
    base = os.path.realpath(LIBRARY_DIR)
    deleted, errors = [], []
    for rel in wanted[:200]:
        rel = str(rel or "")
        path = os.path.realpath(os.path.join(base, rel))
        if (not path.startswith(base + os.sep)
                or os.path.splitext(path)[1].lower() not in AUDIO_EXTS):
            errors.append({"file": rel,
                           "error": "not a library audio file"})
            continue
        try:
            os.unlink(path)
            deleted.append(rel)
        except OSError as exc:
            errors.append({"file": rel, "error": str(exc)})
    scan_triggered = False
    if deleted and NAVIDROME_URL and NAVIDROME_USER and NAVIDROME_PASSWORD:
        scan_triggered = await trigger_scan()
    return {"deleted": deleted, "errors": errors,
            "scan_triggered": scan_triggered}


@app.exception_handler(HTTPException)
async def http_error(_request: Request, exc: HTTPException) -> JSONResponse:
    return JSONResponse(status_code=exc.status_code, content={"error": str(exc.detail)})

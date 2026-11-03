"""
Navidrome Uploader — companion service for the Navidrome Uploader iOS app.

Navidrome itself has no upload API: it only scans its music folder. This
service is the missing front door. It runs on the same box as Navidrome
(ZimaOS homelab) and:

  - POST /upload   multipart audio file (field "file") -> saved into the
                   Navidrome library folder
  - POST /url      JSON {"url": "..."} -> the server downloads it:
                     * a direct audio-file link is saved as-is
                     * any other page/media link (YouTube etc.) is fetched
                       with yt-dlp and extracted to MP3 (needs ffmpeg,
                       installed by the container start command)
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

import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import tempfile
import time
import urllib.parse

import httpx
from fastapi import FastAPI, File, Header, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse

AUDIO_EXTS = {
    ".mp3", ".m4a", ".flac", ".wav", ".ogg", ".oga", ".opus",
    ".aac", ".aif", ".aiff", ".wma",
}
MAX_BYTES = int(os.environ.get("MAX_UPLOAD_MB", "500")) * 1024 * 1024

LIBRARY_DIR = os.environ.get("LIBRARY_DIR", "/music")
DATA_DIR = os.environ.get("DATA_DIR", "/data")
UPLOAD_TOKEN = os.environ.get("UPLOAD_TOKEN", "")
NAVIDROME_URL = os.environ.get("NAVIDROME_URL", "").rstrip("/")
NAVIDROME_USER = os.environ.get("NAVIDROME_USER", "")
NAVIDROME_PASSWORD = os.environ.get("NAVIDROME_PASSWORD", "")

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


def unique_path(filename: str) -> str:
    path = os.path.join(LIBRARY_DIR, filename)
    if not os.path.exists(path):
        return path
    stem, ext = os.path.splitext(filename)
    n = 2
    while True:
        candidate = os.path.join(LIBRARY_DIR, f"{stem} ({n}){ext}")
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


async def finish_save(tmp_path: str, filename: str, source: str) -> dict:
    if os.path.splitext(filename)[1].lower() not in AUDIO_EXTS:
        os.unlink(tmp_path)
        raise HTTPException(415, f"Not an audio file we can add: {filename}")
    size = os.path.getsize(tmp_path)
    if size == 0:
        os.unlink(tmp_path)
        raise HTTPException(400, "Downloaded / uploaded file is empty")
    dest = unique_path(sanitize_filename(filename))
    shutil.move(tmp_path, dest)
    scan = await trigger_scan()
    entry = {
        "saved_as": os.path.basename(dest), "size": size,
        "source": source, "scan_triggered": scan, "at": int(time.time()),
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


@app.post("/upload")
async def upload(
    file: UploadFile = File(...),
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
    return await finish_save(tmp, file.filename or "upload", "file")


@app.post("/url")
async def upload_url(
    request: Request,
    x_upload_token: str | None = Header(default=None),
) -> dict:
    require_token(x_upload_token)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "Body must be JSON: {\"url\": \"...\"}")
    url = (body or {}).get("url", "").strip()
    if not url or not re.match(r"^https?://", url):
        raise HTTPException(400, "Give a valid http(s) URL")

    os.makedirs(DATA_DIR, exist_ok=True)
    workdir = tempfile.mkdtemp(dir=DATA_DIR)
    try:
        direct_name = sanitize_filename(os.path.basename(urllib.parse.urlparse(url).path))
        if os.path.splitext(direct_name)[1].lower() in AUDIO_EXTS:
            tmp = os.path.join(workdir, direct_name)
            async with httpx.AsyncClient(timeout=600, follow_redirects=True, trust_env=False) as client:
                async with client.stream("GET", url) as resp:
                    if resp.status_code != 200:
                        raise HTTPException(502, f"Source returned HTTP {resp.status_code}")
                    size = 0
                    with open(tmp, "wb") as out:
                        async for chunk in resp.aiter_bytes(1024 * 1024):
                            size += len(chunk)
                            if size > MAX_BYTES:
                                raise HTTPException(413, "Downloaded file too large")
                            out.write(chunk)
            return await finish_save(tmp, direct_name, "url")

        # Anything else (YouTube, SoundCloud, a page link): yt-dlp -> MP3.
        if not shutil.which("yt-dlp"):
            raise HTTPException(
                501, "This link needs yt-dlp, which is not installed on the server")
        proc = subprocess.run(
            ["yt-dlp", "-x", "--audio-format", "mp3", "--audio-quality", "0",
             "--no-playlist", "-o", os.path.join(workdir, "%(title)s.%(ext)s"), url],
            capture_output=True, text=True, timeout=1200,
        )
        produced = [os.path.join(workdir, f) for f in os.listdir(workdir)
                    if f.lower().endswith(".mp3")]
        if proc.returncode != 0 or not produced:
            tail = (proc.stderr or proc.stdout or "").strip().splitlines()
            raise HTTPException(502, "yt-dlp could not fetch that link: "
                                + (tail[-1] if tail else "unknown error"))
        return await finish_save(produced[0], os.path.basename(produced[0]), "url")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


@app.exception_handler(HTTPException)
async def http_error(_request: Request, exc: HTTPException) -> JSONResponse:
    return JSONResponse(status_code=exc.status_code, content={"error": str(exc.detail)})

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

import asyncio
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
import zipfile

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
TORBOX_API_KEY = os.environ.get("TORBOX_API_KEY", "")
TORBOX_API_BASE = os.environ.get(
    "TORBOX_API_BASE", "https://api.torbox.app/v1/api").rstrip("/")
PREMIUMIZE_API_KEY = os.environ.get("PREMIUMIZE_API_KEY", "")
PREMIUMIZE_API_BASE = os.environ.get(
    "PREMIUMIZE_API_BASE", "https://www.premiumize.me/api").rstrip("/")

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


async def torbox_matches(url: str) -> bool:
    if not TORBOX_API_KEY:
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


async def _download_to_file(url: str, dest: str) -> None:
    async with httpx.AsyncClient(timeout=900, follow_redirects=True, trust_env=False) as client:
        async with client.stream("GET", url) as resp:
            if resp.status_code != 200:
                raise HTTPException(502, f"Download source returned HTTP {resp.status_code}")
            size = 0
            with open(dest, "wb") as out:
                async for chunk in resp.aiter_bytes(1024 * 1024):
                    size += len(chunk)
                    if size > MAX_BYTES:
                        raise HTTPException(413, "Downloaded file too large")
                    out.write(chunk)


async def fetch_with_torbox(url: str, workdir: str) -> list:
    """Returns [(local_path, filename), ...] for audio (ZIPs unpacked)."""
    headers = {"Authorization": f"Bearer {TORBOX_API_KEY}"}
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
                params={"token": TORBOX_API_KEY, "web_id": web_id,
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


async def premiumize_hoster_domains() -> set:
    now = time.time()
    if _pm_hosters_cache["known"] and now - _pm_hosters_cache["at"] < 3600:
        return _pm_hosters_cache["domains"]
    try:
        async with httpx.AsyncClient(timeout=30, trust_env=False) as client:
            r = await client.get(
                f"{PREMIUMIZE_API_BASE}/services/list",
                headers={"Authorization": f"Bearer {PREMIUMIZE_API_KEY}"})
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


async def premiumize_matches(url: str) -> bool:
    if not PREMIUMIZE_API_KEY:
        return False
    host = (urllib.parse.urlparse(url).hostname or "").lower()
    if not host:
        return False
    domains = await premiumize_hoster_domains()
    if not domains:
        return False  # list unavailable: don't guess, other routes decide
    return any(host == d or host.endswith("." + d) for d in domains)


async def _pm_post(client: httpx.AsyncClient, path: str, data: dict) -> dict:
    r = await client.post(f"{PREMIUMIZE_API_BASE}{path}",
                          headers={"Authorization": f"Bearer {PREMIUMIZE_API_KEY}"},
                          data=data)
    try:
        return r.json()
    except Exception:
        return {}


async def fetch_with_premiumize(url: str, workdir: str) -> list:
    """Returns [(local_path, filename), ...] for audio (ZIPs unpacked)."""
    async with httpx.AsyncClient(timeout=120, trust_env=False) as client:
        payload = await _pm_post(client, "/transfer/directdl", {"src": url})
        content = payload.get("content") or []
        if payload.get("status") != "success" or not content:
            created = await _pm_post(client, "/transfer/create", {"src": url})
            transfer_id = (created.get("id")
                           if created.get("status") == "success" else None)
            if transfer_id is None:
                msg = payload.get("message") or created.get("message") \
                    or "link not supported"
                raise HTTPException(502, f"Premiumize could not take the link: {msg}")
            deadline = time.time() + 8 * 60
            finished = False
            while time.time() < deadline:
                listing = await _pm_post(client, "/transfer/list", {})
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
            payload = await _pm_post(client, "/transfer/directdl", {"src": url})
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


def fetch_with_ytdlp(url: str, workdir: str) -> str:
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
    return produced[0]


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
            await _download_to_file(url, tmp)
            return await finish_save(tmp, direct_name, "url")

        # Debrid routes first when the link is on a provider's hoster
        # list and that provider's key is configured: TorBox, then
        # Premiumize. A provider failure never blocks the next route.
        provider_error = None
        for matches, fetch, label in (
            (torbox_matches, fetch_with_torbox, "torbox"),
            (premiumize_matches, fetch_with_premiumize, "premiumize"),
        ):
            if not await matches(url):
                continue
            try:
                saved = []
                for local, fname in await fetch(url, workdir):
                    saved.append(await finish_save(local, fname, "url"))
                first = saved[0]
                first["via"] = label
                if len(saved) > 1:
                    first["also_saved"] = len(saved) - 1
                return first
            except HTTPException as exc:
                provider_error = provider_error or exc

        # Anything else (YouTube, SoundCloud, a page link): yt-dlp -> MP3.
        try:
            produced = fetch_with_ytdlp(url, workdir)
        except HTTPException:
            if provider_error is not None:
                raise provider_error
            raise
        return await finish_save(produced, os.path.basename(produced), "url")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


@app.exception_handler(HTTPException)
async def http_error(_request: Request, exc: HTTPException) -> JSONResponse:
    return JSONResponse(status_code=exc.status_code, content={"error": str(exc.detail)})

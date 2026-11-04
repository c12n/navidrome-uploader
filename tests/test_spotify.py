"""Spotify links: track / album / playlist resolve through the public
embed pages (stubbed), each track's audio comes from a patched
fetch_spotify_audio (no yt-dlp in tests), tags land from the known
Spotify metadata when iTunes / MusicBrainz (also stubbed) find nothing,
and LRCLIB (stubbed) supplies the lyrics.
"""
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////"
    "////////////////////////////////////////2wBDAf////////////////////////"
    "////////////////////////////////////////////////////////wAARCAABAAED"
    "ASIAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAA"
    "AAD/xAAUAQEAAAAAAAAAAAAAAAAAAAAA/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwD"
    "AQACEQMRAD8AvwH/2Q==")


def embed_html(entity):
    data = {"props": {"pageProps": {"state": {"data": {"entity": entity}}}}}
    return ("<html><head></head><body>"
            '<script id="__NEXT_DATA__" type="application/json">'
            + json.dumps(data) + "</script></body></html>")


def entity_base(kind, sid, title):
    return {"uri": f"spotify:{kind}:{sid}", "type": kind, "title": title,
            "name": title,
            "releaseDate": {"isoString": "2020-01-01T00:00:00Z"},
            "visualIdentity": {"image": [
                {"url": f"http://127.0.0.1:{PORT}/cover.jpg",
                 "maxWidth": 300, "maxHeight": 300}]}}


class Stub(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, body, ctype="application/json", code=200):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/embed/track/AAA111":
            e = entity_base("track", "AAA111", "Test Song")
            e["artists"] = [{"name": "Test Artist"}]
            e["releaseDate"] = {"isoString": "2021-04-02T00:00:00Z"}
            return self._send(embed_html(e), "text/html")
        if u.path == "/embed/album/BBB222":
            e = entity_base("album", "BBB222", "Test Album")
            e["trackList"] = [
                {"title": "Alpha Song", "subtitle": "Test Artist",
                 "uri": "spotify:track:a1"},
                {"title": "Beta Song", "subtitle": "Test Artist",
                 "uri": "spotify:track:a2"}]
            return self._send(embed_html(e), "text/html")
        if u.path == "/embed/playlist/CCC333":
            e = entity_base("playlist", "CCC333", "Test Mix")
            e["trackList"] = [
                {"title": "Gamma Song", "subtitle": "Other Artist",
                 "uri": "spotify:track:p1"},
                {"title": "Delta Song", "subtitle": "Other Artist",
                 "uri": "spotify:track:p2"}]
            return self._send(embed_html(e), "text/html")
        if u.path == "/cover.jpg":
            return self._send(JPEG, "image/jpeg")
        if u.path == "/search":  # iTunes: no matches -> known meta wins
            return self._send(json.dumps({"results": []}))
        if u.path == "/recording/":  # MusicBrainz: no matches either
            return self._send(json.dumps({"recordings": []}))
        if u.path == "/get":  # LRCLIB
            return self._send(json.dumps(
                {"plainLyrics": "la la test lyrics"}))
        self.send_response(404)
        self.end_headers()


stub = HTTPServer(("127.0.0.1", 0), Stub)
PORT = stub.server_port
threading.Thread(target=stub.serve_forever, daemon=True).start()

TMP = tempfile.mkdtemp(prefix="naviupload-spotify-")
LIB = os.path.join(TMP, "music")
DATA = os.path.join(TMP, "data")
os.makedirs(LIB)
os.makedirs(DATA)
BASE = f"http://127.0.0.1:{PORT}"
os.environ.update(
    LIBRARY_DIR=LIB, DATA_DIR=DATA, UPLOAD_TOKEN="test-token-123",
    SPOTIFY_EMBED_BASE=BASE, ITUNES_API_BASE=BASE,
    MUSICBRAINZ_API_BASE=BASE, LRCLIB_API_BASE=BASE,
    NAVIDROME_URL="", NAVIDROME_USER="", NAVIDROME_PASSWORD="",
    TORBOX_API_KEY="", PREMIUMIZE_API_KEY="")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "server", "app"))

FIXTURE = os.path.join(TMP, "fixture.mp3")
subprocess.run(["ffmpeg", "-y", "-f", "lavfi", "-i",
                "sine=frequency=440:duration=2", "-codec:a", "libmp3lame",
                FIXTURE], capture_output=True, check=True)

from fastapi.testclient import TestClient  # noqa: E402
import main  # noqa: E402
from mutagen.id3 import ID3  # noqa: E402

FAIL_TITLES = set()


def fake_audio(track, workdir, index):
    if track["title"] in FAIL_TITLES:
        raise main.HTTPException(502, "stub download failure")
    subdir = os.path.join(workdir, f"spotify{index:03d}")
    os.makedirs(subdir, exist_ok=True)
    dest = os.path.join(subdir, "audio.mp3")
    shutil.copy(FIXTURE, dest)
    return dest


main.fetch_spotify_audio = fake_audio

client = TestClient(main.app, raise_server_exceptions=False)
H = {"X-Upload-Token": "test-token-123"}
failures = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name
          + (f" — {extra}" if extra and not cond else ""))
    if not cond:
        failures.append(name)


def tags_of(fname):
    t = ID3(os.path.join(LIB, fname))
    get = lambda f: str(t[f].text[0]) if f in t else ""
    return {"title": get("TIT2"), "artist": get("TPE1"),
            "album": get("TALB"), "year": get("TDRC"),
            "track": get("TRCK"),
            "lyrics": any(k.startswith("USLT") for k in t.keys()),
            "cover": any(k.startswith("APIC") for k in t.keys())}


# parse helpers
check("parse track", main.spotify_parse(
    "https://open.spotify.com/track/AAA111?si=x") == ("track", "AAA111"))
check("parse intl album", main.spotify_parse(
    "https://open.spotify.com/intl-de/album/BBB222") == ("album", "BBB222"))
check("parse non-spotify", main.spotify_parse(
    "https://www.youtube.com/watch?v=x") is None)

# single track
r = client.post("/url", headers=H, json={
    "url": "https://open.spotify.com/track/AAA111?si=abc"})
j = r.json()
check("track: 200 + via spotify", r.status_code == 200
      and j.get("via") == "spotify", r.text)
check("track: saved name", j.get("saved_as") == "Test Artist - Test Song.mp3",
      str(j))
check("track: enriched from spotify", j.get("enriched") is True
      and j.get("metadata_source") == "spotify", str(j))
check("track: lyrics flagged", j.get("lyrics_embedded") is True, str(j))
t = tags_of("Test Artist - Test Song.mp3")
check("track: tags written", t["title"] == "Test Song"
      and t["artist"] == "Test Artist" and t["year"] == "2021", str(t))
check("track: lyrics + cover embedded", t["lyrics"] and t["cover"], str(t))

# album: both tracks, album tags + track numbers
r = client.post("/url", headers=H, json={
    "url": "https://open.spotify.com/album/BBB222"})
j = r.json()
check("album: 200 + also_saved 1", r.status_code == 200
      and j.get("also_saved") == 1 and len(j.get("files") or []) == 2, r.text)
t2 = tags_of("Test Artist - Beta Song.mp3")
check("album: track 2 tags", t2["album"] == "Test Album"
      and t2["track"] == "2" and t2["year"] == "2020", str(t2))

# playlist: one track fails, the other still saves
FAIL_TITLES.add("Delta Song")
r = client.post("/url", headers=H, json={
    "url": "https://open.spotify.com/playlist/CCC333"})
j = r.json()
check("playlist: survivor saved", r.status_code == 200
      and j.get("saved_as") == "Other Artist - Gamma Song.mp3", r.text)
check("playlist: failure reported", (j.get("failed_tracks") or [])
      == ["Other Artist - Delta Song"], str(j))

# all tracks fail -> 502
FAIL_TITLES.add("Gamma Song")
r = client.post("/url", headers=H, json={
    "url": "https://open.spotify.com/playlist/CCC333"})
check("playlist: all fail -> 502", r.status_code == 502, str(r.status_code))
FAIL_TITLES.clear()

# unsupported spotify kinds -> 400
r = client.post("/url", headers=H, json={
    "url": "https://open.spotify.com/episode/XYZ999"})
check("episode -> 400", r.status_code == 400, str(r.status_code))

# token still required
r = client.post("/url", json={"url": "https://open.spotify.com/track/AAA111"})
check("no token -> 401", r.status_code == 401, str(r.status_code))

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)

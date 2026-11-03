"""Metadata enrichment: identify via iTunes (artwork) or MusicBrainz +
Cover Art Archive, embed tags + cover + LRCLIB lyrics into the file.

One stub plays every metadata source:
  /search (iTunes) · /art600x600bb.jpg · /ws/2/recording/ (MusicBrainz)
  /release/<id>/front-500 (Cover Art) · /api/get + /api/search (LRCLIB)
"""
import base64
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////"
    "////////////////////////////////////////2wBDAf////////////////////////"
    "////////////////////////////////////////////////////////wAARCAABAAED"
    "ASIAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAA"
    "AAD/xAAUAQEAAAAAAAAAAAAAAAAAAAAA/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwD"
    "AQACEQMRAD8AvwH/2Q==")


class Stub(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/search":  # iTunes
            term = (q.get("term") or [""])[0]
            if "Test Song" in term:
                return self._json({"results": [{
                    "trackName": "Test Song", "artistName": "Test Artist",
                    "collectionName": "Test Album",
                    "releaseDate": "2020-05-01T07:00:00Z", "trackNumber": 3,
                    "artworkUrl100": f"http://127.0.0.1:{PORT}/art100x100bb.jpg"}]})
            return self._json({"results": []})
        if u.path == "/art600x600bb.jpg":
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(JPEG)))
            self.end_headers()
            return self.wfile.write(JPEG)
        if u.path == "/ws/2/recording/":  # MusicBrainz
            query = (q.get("query") or [""])[0]
            if "Obscure" in query:
                return self._json({"recordings": [{
                    "score": 100, "title": "Obscure Tune",
                    "artist-credit": [{"name": "Obscure Artist",
                                       "joinphrase": ""}],
                    "first-release-date": "1999-01-01",
                    "releases": [{"title": "Obscure Album", "id": "rel-1"}]}]})
            return self._json({"recordings": []})
        if u.path == "/release/rel-1/front-500":  # Cover Art Archive
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(JPEG)))
            self.end_headers()
            return self.wfile.write(JPEG)
        if u.path == "/api/get":  # LRCLIB
            if (q.get("track_name") or [""])[0] == "Test Song":
                return self._json({"plainLyrics": "line one\nline two",
                                   "syncedLyrics": ""})
            return self._json({"message": "not found"}, 404)
        if u.path == "/api/search":
            return self._json([])
        self.send_response(404)
        self.end_headers()


stub = HTTPServer(("127.0.0.1", 0), Stub)
PORT = stub.server_port
threading.Thread(target=stub.serve_forever, daemon=True).start()

TMP = tempfile.mkdtemp(prefix="naviupload-enrich-")
LIB = os.path.join(TMP, "music")
DATA = os.path.join(TMP, "data")
os.makedirs(LIB)
os.makedirs(DATA)
BASE = f"http://127.0.0.1:{PORT}"
os.environ.update(
    LIBRARY_DIR=LIB, DATA_DIR=DATA, UPLOAD_TOKEN="test-token-123",
    NAVIDROME_URL="", NAVIDROME_USER="", NAVIDROME_PASSWORD="",
    TORBOX_API_KEY="", PREMIUMIZE_API_KEY="",
    ITUNES_API_BASE=BASE, MUSICBRAINZ_API_BASE=BASE + "/ws/2",
    COVERART_API_BASE=BASE, LRCLIB_API_BASE=BASE + "/api",
)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "server", "app"))

# A real untagged MP3 to enrich.
FIXTURE = os.path.join(TMP, "fixture.mp3")
subprocess.run(["ffmpeg", "-y", "-f", "lavfi", "-i",
                "sine=frequency=440:duration=2", "-codec:a", "libmp3lame",
                FIXTURE], capture_output=True, check=True)

from fastapi.testclient import TestClient  # noqa: E402
from mutagen.id3 import ID3  # noqa: E402
import main  # noqa: E402

client = TestClient(main.app, raise_server_exceptions=False)
H = {"X-Upload-Token": "test-token-123"}
failures = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name + (f" — {extra}" if extra and not cond else ""))
    if not cond:
        failures.append(name)


def upload(name, data):
    with open(FIXTURE, "rb") as fh:
        return client.post("/upload", headers=H,
                           files={"file": (name, fh, "audio/mpeg")}, data=data)


# A: iTunes match -> tags + cover + lyrics embedded
r = upload("Test Artist - Test Song.mp3", {"enrich": "true", "lyrics": "true"})
check("itunes upload ok", r.status_code == 200, f"{r.status_code} {r.text}")
j = r.json()
check("itunes identified", j.get("enriched") is True and j.get("metadata_source") == "itunes", str(j))
check("lyrics flagged", j.get("lyrics_embedded") is True, str(j))
tags = ID3(os.path.join(LIB, j["saved_as"]))
check("TIT2 written", str(tags.get("TIT2")) == "Test Song")
check("TPE1 written", str(tags.get("TPE1")) == "Test Artist")
check("TALB written", str(tags.get("TALB")) == "Test Album")
check("TRCK written", str(tags.get("TRCK")) == "3")
check("APIC embedded", tags.getall("APIC") != [])
uslt = tags.getall("USLT")
check("USLT embedded", bool(uslt) and "line one" in str(uslt[0]))

# B: MusicBrainz fallback + Artist/Album sorting, no lyrics found
r = upload("Someone - Obscure Tune.mp3",
           {"enrich": "true", "lyrics": "true", "sort": "true"})
j = r.json()
check("musicbrainz identified", j.get("metadata_source") == "musicbrainz", str(j))
check("sorted folder reported", j.get("folder") == "Obscure Artist/Obscure Album", str(j))
dest = os.path.join(LIB, "Obscure Artist", "Obscure Album", j["saved_as"])
check("file sorted on disk", os.path.isfile(dest), dest)
check("no lyrics for obscure", j.get("lyrics_embedded") is False, str(j))
tags = ID3(dest)
check("MB TIT2 written", str(tags.get("TIT2")) == "Obscure Tune")
check("MB APIC embedded", tags.getall("APIC") != [])

# C: no match anywhere -> saved anyway, untouched
r = upload("Nobody - Zzz Unknown Track.mp3", {"enrich": "true"})
j = r.json()
check("unmatched still saved", r.status_code == 200 and j.get("enriched") is False, str(j))

# D: flags off -> no enrichment attempted
r = upload("Test Artist - Test Song.mp3", {})
j = r.json()
check("flags off: no enrichment", j.get("enriched") is False
      and j.get("metadata_source") is None, str(j))

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)

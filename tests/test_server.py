"""Smoke tests for the Navidrome Uploader companion service.

Runs the FastAPI app in-process with a temp library dir. Covers:
health, auth rejection, file upload landing in the library, dedupe
suffixing, non-audio rejection, direct-URL download (served by a local
one-shot HTTP server), and /recent.
"""
import os
import sys
import tempfile
import threading
from http.server import HTTPServer, SimpleHTTPRequestHandler

TMP = tempfile.mkdtemp(prefix="naviupload-test-")
LIB = os.path.join(TMP, "music")
DATA = os.path.join(TMP, "data")
os.makedirs(LIB)
os.makedirs(DATA)
os.environ.update(
    LIBRARY_DIR=LIB, DATA_DIR=DATA, UPLOAD_TOKEN="test-token-123",
    NAVIDROME_URL="", NAVIDROME_USER="", NAVIDROME_PASSWORD="",
)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "server", "app"))

from fastapi.testclient import TestClient  # noqa: E402
import main  # noqa: E402

client = TestClient(main.app)
H = {"X-Upload-Token": "test-token-123"}
FAKE_MP3 = b"ID3" + b"\x00" * 2048  # content is never parsed, only stored

failures = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name + (f" — {extra}" if extra and not cond else ""))
    if not cond:
        failures.append(name)


r = client.get("/health")
check("health ok + empty library", r.status_code == 200 and r.json()["library_files"] == 0, r.text)

r = client.post("/upload", files={"file": ("song.mp3", FAKE_MP3)})
check("upload without token rejected 401", r.status_code == 401, r.text)

r = client.post("/upload", headers=H, files={"file": ("My Song.mp3", FAKE_MP3)})
check("file upload saved", r.status_code == 200 and r.json()["saved_as"] == "My Song.mp3", r.text)
check("file is in library", os.path.exists(os.path.join(LIB, "My Song.mp3")))

r = client.post("/upload", headers=H, files={"file": ("My Song.mp3", FAKE_MP3)})
check("duplicate gets (2) suffix", r.status_code == 200 and r.json()["saved_as"] == "My Song (2).mp3", r.text)

r = client.post("/upload", headers=H, files={"file": ("notes.txt", b"hello")})
check("non-audio rejected 415", r.status_code == 415, r.text)

r = client.post("/upload", headers=H, files={"file": ("../../evil.mp3", FAKE_MP3)})
check("path traversal stripped to basename", r.status_code == 200 and r.json()["saved_as"] == "evil.mp3"
      and not os.path.exists(os.path.join(TMP, "evil.mp3")), r.text)

# Direct audio URL: serve FAKE_MP3 from a local server.
serve_dir = os.path.join(TMP, "serve")
os.makedirs(serve_dir)
with open(os.path.join(serve_dir, "track.flac"), "wb") as fh:
    fh.write(FAKE_MP3)
handler = lambda *a, **kw: SimpleHTTPRequestHandler(*a, directory=serve_dir, **kw)  # noqa: E731
httpd = HTTPServer(("127.0.0.1", 0), handler)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{httpd.server_port}/track.flac"
r = client.post("/url", headers=H, json={"url": url})
check("direct URL download saved", r.status_code == 200 and r.json()["saved_as"] == "track.flac", r.text)
check("url file is in library", os.path.exists(os.path.join(LIB, "track.flac")))
httpd.shutdown()

r = client.post("/url", headers=H, json={"url": "not a url"})
check("bad URL rejected 400", r.status_code == 400, r.text)

r = client.get("/recent", headers=H)
names = [u["saved_as"] for u in r.json()["uploads"]]
check("recent lists uploads newest-first", names[:1] == ["track.flac"] and "My Song.mp3" in names, str(names))

r = client.get("/health")
check("health now counts 4 audio files", r.json()["library_files"] == 4, r.text)

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)

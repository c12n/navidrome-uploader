"""TorBox route tests for the Navidrome Uploader companion service.

Stands up a stub TorBox API (hosters / createwebdownload / mylist /
requestdl) plus a file host on 127.0.0.1, points the app at it via
TORBOX_API_BASE, and checks:
  - a link on a stub-listed hoster domain is fetched through TorBox and
    saved into the library with via=torbox
  - a ZIP from TorBox is unpacked and its audio files saved
  - a link NOT on a listed domain never calls TorBox create
"""
import io
import os
import sys
import tempfile
import threading
import zipfile
from http.server import BaseHTTPRequestHandler, HTTPServer

FAKE_MP3 = b"ID3" + b"\x00" * 1024
CALLS = {"create": 0}

zip_buf = io.BytesIO()
with zipfile.ZipFile(zip_buf, "w") as zf:
    zf.writestr("Disc 1/One.mp3", FAKE_MP3)
    zf.writestr("Two.flac", FAKE_MP3)
    zf.writestr("cover.jpg", b"not audio")
ZIP_BYTES = zip_buf.getvalue()


class Stub(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj):
        import json
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/v1/api/webdl/hosters"):
            return self._json({"success": True, "data": [
                {"name": "StubHost", "domains": ["stubhost.example"], "status": True}]})
        if self.path.startswith("/v1/api/webdl/mylist"):
            kind = "zip" if "id=43" in self.path else "mp3"
            files = ([{"id": 7, "name": "Album.zip"}] if kind == "zip"
                     else [{"id": 7, "name": "TorBox Song.mp3"}])
            return self._json({"success": True, "data": {
                "download_state": "completed", "files": files}})
        if self.path.startswith("/v1/api/webdl/requestdl"):
            kind = "zip" if "web_id=43" in self.path else "mp3"
            return self._json({"success": True,
                               "data": f"http://127.0.0.1:{PORT}/file.{kind}"})
        if self.path == "/file.mp3" or self.path == "/file.zip":
            body = ZIP_BYTES if self.path.endswith("zip") else FAKE_MP3
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if self.path.startswith("/v1/api/webdl/createwebdownload"):
            CALLS["create"] += 1
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length).decode()
            web_id = 43 if "album" in body else 42
            return self._json({"success": True, "data": {"webdownload_id": web_id}})
        self.send_response(404)
        self.end_headers()


stub = HTTPServer(("127.0.0.1", 0), Stub)
PORT = stub.server_port
threading.Thread(target=stub.serve_forever, daemon=True).start()

TMP = tempfile.mkdtemp(prefix="naviupload-torbox-")
LIB = os.path.join(TMP, "music")
DATA = os.path.join(TMP, "data")
os.makedirs(LIB)
os.makedirs(DATA)
os.environ.update(
    LIBRARY_DIR=LIB, DATA_DIR=DATA, UPLOAD_TOKEN="test-token-123",
    TORBOX_API_KEY="stub-key", TORBOX_API_BASE=f"http://127.0.0.1:{PORT}/v1/api",
    NAVIDROME_URL="", NAVIDROME_USER="", NAVIDROME_PASSWORD="",
)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "server", "app"))

from fastapi.testclient import TestClient  # noqa: E402
import main  # noqa: E402

client = TestClient(main.app, raise_server_exceptions=False)
H = {"X-Upload-Token": "test-token-123"}
failures = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name + (f" — {extra}" if extra and not cond else ""))
    if not cond:
        failures.append(name)


r = client.get("/health")
check("health shows torbox_configured", r.json().get("torbox_configured") is True, r.text)

r = client.post("/url", headers=H, json={"url": "https://stubhost.example/get/song123"})
check("hoster link saved via TorBox", r.status_code == 200
      and r.json()["saved_as"] == "TorBox Song.mp3" and r.json().get("via") == "torbox", r.text)
check("torbox file in library", os.path.exists(os.path.join(LIB, "TorBox Song.mp3")))
check("create called once", CALLS["create"] == 1, str(CALLS))

r = client.post("/url", headers=H, json={"url": "https://stubhost.example/get/album-pack"})
names = sorted(os.listdir(LIB))
check("ZIP unpacked: One.mp3 + Two.flac saved",
      "One.mp3" in names and "Two.flac" in names and "cover.jpg" not in names, str(names))
check("zip response reports also_saved", r.status_code == 200 and r.json().get("also_saved") == 1, r.text)

before = CALLS["create"]
r = client.post("/url", headers=H, json={"url": "https://www.youtube.com/watch?v=abc"})
check("non-hoster link never calls TorBox create", CALLS["create"] == before, str(CALLS))
check("non-hoster falls back to yt-dlp path (501 without yt-dlp here)",
      r.status_code in (501, 502), f"{r.status_code} {r.text}")

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)

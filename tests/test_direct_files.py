"""Direct file links whose filename rides in the query string
(TorBox CDN shape: /zip/<uuid>?token=...&filename=album.zip) and
direct ZIP bundles: the ZIP is downloaded and every audio file
inside is saved; a plain audio file saves under its real name.
"""
import io
import os
import subprocess
import sys
import tempfile
import threading
import zipfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse


class Stub(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path.startswith("/zip/"):
            buf = io.BytesIO()
            with zipfile.ZipFile(buf, "w") as zf:
                zf.write(FIXTURE, "Song One.mp3")
                zf.write(FIXTURE, "Song Two.mp3")
                zf.writestr("notes.txt", "not audio")
            return self._send(buf.getvalue(), "application/zip")
        if u.path.startswith("/dl/"):
            return self._send(open(FIXTURE, "rb").read(), "audio/mpeg")
        if u.path.startswith("/badzip"):
            return self._send(b"this is not a zip at all",
                              "application/zip")
        self.send_response(404)
        self.end_headers()


stub = HTTPServer(("127.0.0.1", 0), Stub)
PORT = stub.server_port
threading.Thread(target=stub.serve_forever, daemon=True).start()

TMP = tempfile.mkdtemp(prefix="naviupload-direct-")
LIB = os.path.join(TMP, "music")
DATA = os.path.join(TMP, "data")
os.makedirs(LIB)
os.makedirs(DATA)
os.environ.update(
    LIBRARY_DIR=LIB, DATA_DIR=DATA, UPLOAD_TOKEN="test-token-123",
    NAVIDROME_URL="", NAVIDROME_USER="", NAVIDROME_PASSWORD="",
    TORBOX_API_KEY="", PREMIUMIZE_API_KEY="")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "server", "app"))

FIXTURE = os.path.join(TMP, "fixture.mp3")
subprocess.run(["ffmpeg", "-y", "-f", "lavfi", "-i",
                "sine=frequency=440:duration=2", "-codec:a", "libmp3lame",
                FIXTURE], capture_output=True, check=True)

from fastapi.testclient import TestClient  # noqa: E402
import main  # noqa: E402

client = TestClient(main.app, raise_server_exceptions=False)
H = {"X-Upload-Token": "test-token-123"}
B = f"http://127.0.0.1:{PORT}"
failures = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name
          + (f" — {extra}" if extra and not cond else ""))
    if not cond:
        failures.append(name)


# TorBox-CDN-shaped ZIP link: uuid path, filename in the query.
r = client.post("/url", headers=H, json={
    "url": f"{B}/zip/d36317a4-c0d8-4449-b344-615bb74d6654"
           "?token=abc&filename=nokn.rar.zip",
    "enrich": False, "lyrics": False})
j = r.json()
names = set()
if r.status_code == 200:
    names.add(j.get("saved_as"))
    names.update(f.get("saved_as") for f in j.get("files") or [])
check("zip bundle: both songs saved", r.status_code == 200
      and j.get("also_saved") == 1
      and names == {"Song One.mp3", "Song Two.mp3"}, r.text[:300])
check("zip bundle: files in library, junk left out",
      os.path.exists(os.path.join(LIB, "Song One.mp3"))
      and os.path.exists(os.path.join(LIB, "Song Two.mp3"))
      and not os.path.exists(os.path.join(LIB, "notes.txt")))

# Audio file whose name only exists in the query string.
r = client.post("/url", headers=H, json={
    "url": f"{B}/dl/xyz789?token=abc&filename=My%20Tune.mp3",
    "enrich": False, "lyrics": False})
check("query-named audio saved under its name",
      r.status_code == 200
      and r.json().get("saved_as") == "My Tune.mp3", r.text[:300])

# A ZIP that is not a ZIP -> clean 400.
r = client.post("/url", headers=H, json={
    "url": f"{B}/badzip?filename=broken.zip",
    "enrich": False, "lyrics": False})
check("broken zip -> 400", r.status_code == 400, str(r.status_code))

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)

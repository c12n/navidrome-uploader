"""Premiumize route tests for the Navidrome Uploader companion service.

Stub Premiumize API on 127.0.0.1:
  - GET  /api/services/list        -> hosterlist with pmhost.example
  - POST /api/transfer/directdl    -> cached link: content immediately;
                                      uncached link: error until a transfer
                                      exists and is finished, then content
  - POST /api/transfer/create      -> creates transfer id t1 (running)
  - POST /api/transfer/list        -> t1 reports finished
Checks both the instant (cached) path and the transfer path, and that a
non-hoster link never touches Premiumize.
"""
import os
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

FAKE_MP3 = b"ID3" + b"\x00" * 2048
STATE = {"transfer": None, "ddl_calls": 0, "create_calls": 0}


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
        if self.path.startswith("/api/services/list"):
            return self._json({"status": "success", "hosterlist": {
                "pmhost.example": {"domains": ["pmhost.example"]}}})
        if self.path == "/dl/song.mp3":
            self.send_response(200)
            self.send_header("Content-Length", str(len(FAKE_MP3)))
            self.end_headers()
            return self.wfile.write(FAKE_MP3)
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode()
        if self.path.startswith("/api/transfer/directdl"):
            STATE["ddl_calls"] += 1
            if "cached" in body or STATE["transfer"] == "finished":
                return self._json({"status": "success", "content": [{
                    "path": "Music/PM Song.mp3",
                    "link": f"http://127.0.0.1:{PORT}/dl/song.mp3",
                    "size": len(FAKE_MP3)}]})
            return self._json({"status": "error", "message": "not cached"})
        if self.path.startswith("/api/transfer/create"):
            STATE["create_calls"] += 1
            STATE["transfer"] = "finished"  # stub finishes instantly
            return self._json({"status": "success", "id": "t1", "name": "x"})
        if self.path.startswith("/api/transfer/list"):
            transfers = ([{"id": "t1", "status": "finished"}]
                         if STATE["transfer"] else [])
            return self._json({"status": "success", "transfers": transfers})
        self.send_response(404)
        self.end_headers()


stub = HTTPServer(("127.0.0.1", 0), Stub)
PORT = stub.server_port
threading.Thread(target=stub.serve_forever, daemon=True).start()

TMP = tempfile.mkdtemp(prefix="naviupload-pm-")
LIB = os.path.join(TMP, "music")
DATA = os.path.join(TMP, "data")
os.makedirs(LIB)
os.makedirs(DATA)
os.environ.update(
    LIBRARY_DIR=LIB, DATA_DIR=DATA, UPLOAD_TOKEN="test-token-123",
    PREMIUMIZE_API_KEY="stub-pm-key",
    PREMIUMIZE_API_BASE=f"http://127.0.0.1:{PORT}/api",
    TORBOX_API_KEY="",  # keep TorBox out of this file's way
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
check("health shows premiumize_configured",
      r.json().get("premiumize_configured") is True, r.text)

r = client.post("/url", headers=H, json={"url": "https://pmhost.example/file/cached-song"})
check("cached hoster link saved via Premiumize", r.status_code == 200
      and r.json()["saved_as"] == "PM Song.mp3" and r.json().get("via") == "premiumize", r.text)
check("no transfer needed for cached", STATE["create_calls"] == 0, str(STATE))

r = client.post("/url", headers=H, json={"url": "https://pmhost.example/file/fresh-song"})
check("uncached link goes through transfer then saves",
      r.status_code == 200 and r.json().get("via") == "premiumize"
      and STATE["create_calls"] == 1, f"{r.status_code} {r.text} {STATE}")
check("file landed in library", os.path.exists(os.path.join(LIB, "PM Song.mp3")))

ddl_before = STATE["ddl_calls"]
r = client.post("/url", headers=H, json={"url": "https://www.youtube.com/watch?v=abc"})
check("non-hoster link never calls Premiumize", STATE["ddl_calls"] == ddl_before, str(STATE))
check("non-hoster falls back (501/502 without yt-dlp)", r.status_code in (501, 502),
      f"{r.status_code}")

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)

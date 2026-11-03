"""Per-request debrid keys: apps send X-TorBox-Key / X-Premiumize-Key
headers; the server must use them when its own env keys are empty, and
must NOT use a provider when neither header nor env provides a key.

One stub plays both providers:
  TorBox     /v1/api/webdl/...     (hoster: tbhost.example)
  Premiumize /api/...              (hoster: pmhost.example)
"""
import os
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

FAKE_MP3 = b"ID3" + b"\x00" * 512
CALLS = {"tb_create": 0, "pm_ddl": 0}


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
                {"name": "TB", "domains": ["tbhost.example"], "status": True}]})
        if self.path.startswith("/v1/api/webdl/mylist"):
            return self._json({"success": True, "data": {
                "download_state": "completed",
                "files": [{"id": 1, "name": "Header Song.mp3"}]}})
        if self.path.startswith("/v1/api/webdl/requestdl"):
            return self._json({"success": True,
                               "data": f"http://127.0.0.1:{PORT}/f.mp3"})
        if self.path.startswith("/api/services/list"):
            return self._json({"status": "success", "hosterlist": {
                "pmhost.example": {"domains": ["pmhost.example"]}}})
        if self.path == "/f.mp3":
            self.send_response(200)
            self.send_header("Content-Length", str(len(FAKE_MP3)))
            self.end_headers()
            return self.wfile.write(FAKE_MP3)
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        if self.path.startswith("/v1/api/webdl/createwebdownload"):
            CALLS["tb_create"] += 1
            if "good-tb-key" not in (self.headers.get("Authorization") or ""):
                return self._json({"success": False, "detail": "bad key"})
            return self._json({"success": True, "data": {"webdownload_id": 9}})
        if self.path.startswith("/api/transfer/directdl"):
            CALLS["pm_ddl"] += 1
            if "good-pm-key" not in (self.headers.get("Authorization") or ""):
                return self._json({"status": "error", "message": "bad key"})
            return self._json({"status": "success", "content": [{
                "path": "PM Header Song.mp3",
                "link": f"http://127.0.0.1:{PORT}/f.mp3", "size": len(FAKE_MP3)}]})
        self.send_response(404)
        self.end_headers()


stub = HTTPServer(("127.0.0.1", 0), Stub)
PORT = stub.server_port
threading.Thread(target=stub.serve_forever, daemon=True).start()

TMP = tempfile.mkdtemp(prefix="naviupload-hdr-")
LIB = os.path.join(TMP, "music")
DATA = os.path.join(TMP, "data")
os.makedirs(LIB)
os.makedirs(DATA)
os.environ.update(
    LIBRARY_DIR=LIB, DATA_DIR=DATA, UPLOAD_TOKEN="test-token-123",
    TORBOX_API_KEY="", PREMIUMIZE_API_KEY="",  # server has NO keys of its own
    TORBOX_API_BASE=f"http://127.0.0.1:{PORT}/v1/api",
    PREMIUMIZE_API_BASE=f"http://127.0.0.1:{PORT}/api",
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


r = client.post("/url", headers=H, json={"url": "https://tbhost.example/x"})
check("no key anywhere: TorBox not attempted", CALLS["tb_create"] == 0
      and r.status_code in (501, 502), f"{r.status_code} {CALLS}")

r = client.post("/url", headers={**H, "X-TorBox-Key": "good-tb-key"},
                json={"url": "https://tbhost.example/x"})
check("header key drives TorBox", r.status_code == 200
      and r.json().get("via") == "torbox" and r.json()["saved_as"] == "Header Song.mp3",
      f"{r.status_code} {r.text}")

r = client.post("/url", headers={**H, "X-Premiumize-Key": "good-pm-key"},
                json={"url": "https://pmhost.example/y"})
check("header key drives Premiumize", r.status_code == 200
      and r.json().get("via") == "premiumize" and r.json()["saved_as"] == "PM Header Song.mp3",
      f"{r.status_code} {r.text}")

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)

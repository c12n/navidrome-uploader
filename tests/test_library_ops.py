"""Library operations: POST /scan, GET /stats, POST /check, GET /in-library.

The stub plays Navidrome's Subsonic API (startScan + search3).
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer


class ND(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/rest/startScan.view"):
            return self._json({"subsonic-response": {"status": "ok"}})
        if self.path.startswith("/rest/search3.view"):
            if "Test" in self.path:
                return self._json({"subsonic-response": {
                    "status": "ok", "searchResult3": {"song": [
                        {"title": "Test Song", "artist": "Test Artist"}]}}})
            return self._json({"subsonic-response": {
                "status": "ok", "searchResult3": {"song": []}}})
        self.send_response(404)
        self.end_headers()


stub = HTTPServer(("127.0.0.1", 0), ND)
PORT = stub.server_port
threading.Thread(target=stub.serve_forever, daemon=True).start()

TMP = tempfile.mkdtemp(prefix="naviupload-ops-")
LIB = os.path.join(TMP, "music")
DATA = os.path.join(TMP, "data")
os.makedirs(LIB)
os.makedirs(DATA)
os.environ.update(
    LIBRARY_DIR=LIB, DATA_DIR=DATA, UPLOAD_TOKEN="test-token-123",
    NAVIDROME_URL=f"http://127.0.0.1:{PORT}",
    NAVIDROME_USER="soup", NAVIDROME_PASSWORD="pw",
    TORBOX_API_KEY="", PREMIUMIZE_API_KEY="",
)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "server", "app"))

FIXTURE = os.path.join(TMP, "fixture.mp3")
subprocess.run(["ffmpeg", "-y", "-f", "lavfi", "-i",
                "sine=frequency=440:duration=2", "-codec:a", "libmp3lame",
                FIXTURE], capture_output=True, check=True)
FSIZE = os.path.getsize(FIXTURE)

from fastapi.testclient import TestClient  # noqa: E402
import main  # noqa: E402

client = TestClient(main.app, raise_server_exceptions=False)
H = {"X-Upload-Token": "test-token-123"}
failures = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name + (f" — {extra}" if extra and not cond else ""))
    if not cond:
        failures.append(name)


r = client.get("/stats", headers=H)
check("stats starts at zero", r.json()["uploaded_total"] == 0
      and r.json()["library_files"] == 0, r.text)

with open(FIXTURE, "rb") as fh:
    r = client.post("/upload", headers=H,
                    files={"file": ("My Song.mp3", fh, "audio/mpeg")})
check("upload ok", r.status_code == 200, r.text)

r = client.get("/stats", headers=H)
j = r.json()
check("stats counted the upload", j["uploaded_total"] == 1
      and j["library_files"] == 1 and j["uploaded_bytes"] == FSIZE
      and j["last_upload_at"], str(j))

r = client.post("/scan", headers=H)
check("manual scan triggers", r.json() == {"scan_configured": True,
                                           "scan_triggered": True}, r.text)

r = client.post("/check", headers=H, json={"items": [
    {"name": "My Song.mp3", "size": FSIZE},
    {"name": "Not There.mp3", "size": 12345},
    {"name": "Other Name.mp3", "size": FSIZE},
]})
res = r.json()["results"]
check("check: exact name exists", res[0]["exists"] is True
      and res[0]["same_size"] is True, str(res))
check("check: missing file", res[1]["exists"] is False
      and res[1]["same_size"] is False, str(res))
check("check: size-only match", res[2]["exists"] is False
      and res[2]["same_size"] is True, str(res))

r = client.get("/in-library", headers=H,
               params={"title": "Test Song", "artist": "Test Artist"})
check("in-library found", r.json()["found"] is True
      and r.json()["matched_title"] == "Test Song", r.text)
r = client.get("/in-library", headers=H, params={"title": "Nothin"})
check("in-library not found", r.json()["found"] is False, r.text)

r = client.get("/stats")
check("stats needs token", r.status_code == 401, str(r.status_code))
r = client.post("/scan")
check("scan needs token", r.status_code == 401, str(r.status_code))

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)

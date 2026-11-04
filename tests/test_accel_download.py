"""Accelerated downloads (0.5.0): parallel ranged fetching with
per-segment resume when the source supports HTTP ranges, and a
plain single-stream fallback when it does not (or the file is
small). The engine lives in _download_to_file, so direct links,
ZIP bundles and the debrid fetchers all share it.
"""
import asyncio
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

PAYLOAD = bytes(range(256)) * 1024  # 256 KB, deterministic
SEG = len(PAYLOAD) // 4


class Stub(BaseHTTPRequestHandler):
    flaky_tripped = False

    def log_message(self, *a):
        pass

    def _range(self):
        h = self.headers.get("Range") or ""
        if not h.startswith("bytes="):
            return None
        a, _, b = h[6:].partition("-")
        return int(a), int(b)

    def _full(self, body):
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _slice(self, body, a, b):
        part = body[a:b + 1]
        self.send_response(206)
        self.send_header("Content-Range", f"bytes {a}-{b}/{len(body)}")
        self.send_header("Content-Length", str(len(part)))
        self.end_headers()
        self.wfile.write(part)

    def do_GET(self):
        u = urlparse(self.path)
        rng = self._range()
        if u.path in ("/big.bin", "/flaky.bin", "/song.mp3"):
            body = SONG if u.path == "/song.mp3" else PAYLOAD
            if rng is None:
                return self._full(body)
            a, b = rng
            if (u.path == "/flaky.bin" and a == SEG
                    and not Stub.flaky_tripped):
                Stub.flaky_tripped = True
                part = body[a:b + 1]
                self.send_response(206)
                self.send_header("Content-Range",
                                 f"bytes {a}-{b}/{len(body)}")
                self.send_header("Content-Length", str(len(part)))
                self.end_headers()
                self.wfile.write(part[:100])  # then drop the line
                self.close_connection = True
                return
            return self._slice(body, a, b)
        if u.path == "/norng.bin":
            return self._full(PAYLOAD)
        self.send_response(404)
        self.end_headers()


stub = HTTPServer(("127.0.0.1", 0), Stub)
PORT = stub.server_port
threading.Thread(target=stub.serve_forever, daemon=True).start()

TMP = tempfile.mkdtemp(prefix="naviupload-accel-")
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
SONG = open(FIXTURE, "rb").read()

from fastapi import HTTPException  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
import main  # noqa: E402

client = TestClient(main.app, raise_server_exceptions=False)
H = {"X-Upload-Token": "test-token-123"}
B = f"http://127.0.0.1:{PORT}"
failures = []

# Test-scale knobs: accelerate anything over 1 KB, 4 connections.
main.ACCEL_MIN_BYTES = 1024
main.ACCEL_CONNECTIONS = 4


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name
          + (f" — {extra}" if extra and not cond else ""))
    if not cond:
        failures.append(name)


def fetch(url, name):
    dest = os.path.join(TMP, name)
    info = asyncio.run(main._download_to_file(url, dest))
    return info, open(dest, "rb").read()


info, data = fetch(f"{B}/big.bin", "big.bin")
check("ranged source: accelerated over 4 connections",
      info["accelerated"] is True and info["connections"] == 4, str(info))
check("ranged source: bytes exact",
      data == PAYLOAD and info["bytes"] == len(PAYLOAD))

info, data = fetch(f"{B}/norng.bin", "norng.bin")
check("range-ignoring source: single-stream fallback, bytes exact",
      info["accelerated"] is False and data == PAYLOAD, str(info))

info, data = fetch(f"{B}/flaky.bin", "flaky.bin")
check("dropped segment: resumed and completed byte-exact",
      info["accelerated"] is True and data == PAYLOAD, str(info))

main.ACCEL_MIN_BYTES = 10 * 1024 * 1024
info, data = fetch(f"{B}/big.bin", "small.bin")
check("below the size floor: no acceleration, bytes exact",
      info["accelerated"] is False and data == PAYLOAD, str(info))
main.ACCEL_MIN_BYTES = 1024

old_max = main.MAX_BYTES
main.MAX_BYTES = 1000
try:
    asyncio.run(main._download_to_file(f"{B}/big.bin",
                                       os.path.join(TMP, "huge.bin")))
    check("oversize ranged file -> 413", False, "no exception raised")
except HTTPException as e:
    check("oversize ranged file -> 413", e.status_code == 413,
          str(e.status_code))
finally:
    main.MAX_BYTES = old_max

r = client.post("/url", headers=H, json={
    "url": f"{B}/song.mp3", "enrich": False, "lyrics": False})
j = r.json()
check("end to end: /url response reports the accelerated download",
      r.status_code == 200 and (j.get("download") or {}).get("accelerated")
      is True, r.text[:300])

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)

"""Google Drive links + error hygiene.

The stub plays Drive's direct-download endpoint: a good file id
returns the fixture MP3 with a Content-Disposition filename, a bad
one returns Drive's HTML sign-in page (which must become a clean
400, never page source in the error). Also unit-checks _clean_error,
the helper that keeps yt-dlp's HTML dumps out of app error messages.
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse


class Stub(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/download":
            fid = (q.get("id") or [""])[0]
            if fid == "GOOD1":
                body = open(FIXTURE, "rb").read()
                self.send_response(200)
                self.send_header("Content-Type", "audio/mpeg")
                self.send_header(
                    "Content-Disposition",
                    'attachment; filename="Drive Song.mp3"')
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            body = (b"<!DOCTYPE html><html><head><title>Sign in</title>"
                    b"</head><body>Google Drive sign-in page</body></html>")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()


stub = HTTPServer(("127.0.0.1", 0), Stub)
PORT = stub.server_port
threading.Thread(target=stub.serve_forever, daemon=True).start()

TMP = tempfile.mkdtemp(prefix="naviupload-drive-")
LIB = os.path.join(TMP, "music")
DATA = os.path.join(TMP, "data")
os.makedirs(LIB)
os.makedirs(DATA)
BASE = f"http://127.0.0.1:{PORT}"
os.environ.update(
    LIBRARY_DIR=LIB, DATA_DIR=DATA, UPLOAD_TOKEN="test-token-123",
    DRIVE_DOWNLOAD_BASE=BASE, SPOTIFY_EMBED_BASE=BASE,
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
failures = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name
          + (f" — {extra}" if extra and not cond else ""))
    if not cond:
        failures.append(name)


# id extraction across Drive's link shapes
check("id from /file/d/", main.drive_file_id(
    "https://drive.google.com/file/d/GOOD1/view?usp=sharing") == "GOOD1")
check("id from usercontent (the shape that failed on-device)",
      main.drive_file_id(
          "https://drive.usercontent.google.com/download?id=GOOD1"
          "&export=download&authuser=0") == "GOOD1")
check("id from /uc", main.drive_file_id(
    "https://drive.google.com/uc?id=GOOD1&export=download") == "GOOD1")
check("no id on other hosts", main.drive_file_id(
    "https://www.youtube.com/watch?v=GOOD1") is None)

# the good file lands under its real name
r = client.post("/url", headers=H, json={
    "url": "https://drive.google.com/file/d/GOOD1/view?usp=sharing",
    "enrich": False, "lyrics": False})
j = r.json()
check("drive file saved", r.status_code == 200
      and j.get("saved_as") == "Drive Song.mp3", r.text)
check("drive file in library", os.path.exists(
    os.path.join(LIB, "Drive Song.mp3")))

# the usercontent shape works too (deduped, never overwritten)
r = client.post("/url", headers=H, json={
    "url": "https://drive.usercontent.google.com/download?id=GOOD1"
           "&export=download&authuser=0",
    "enrich": False, "lyrics": False})
check("usercontent shape saved (2)", r.status_code == 200
      and r.json().get("saved_as") == "Drive Song (2).mp3", r.text)

# an HTML answer becomes a clean 400, no page source anywhere
r = client.post("/url", headers=H, json={
    "url": "https://drive.google.com/file/d/BAD1/view",
    "enrich": False, "lyrics": False})
check("html answer -> 400", r.status_code == 400, str(r.status_code))
check("error has no markup", "<!doctype" not in r.text.lower()
      and "<html" not in r.text.lower(), r.text[:200])

# error hygiene for yt-dlp stderr
messy = ("<!DOCTYPE html>\n<!--[if lt IE 7]> <html class=\"no-js ie6 "
         "oldie\" lang=\"en-US\"> <![endif]-->\n"
         "some warning line\n"
         "ERROR: [GoogleDrive] abc123: Requested entity was not found\n")
clean = main._clean_error(messy)
check("clean_error picks the ERROR line",
      clean.startswith("ERROR: [GoogleDrive]"), clean)
only_html = "<!DOCTYPE html>\n<html><body>Everything is broken</body></html>"
clean2 = main._clean_error(only_html)
check("clean_error strips markup", "<" not in clean2
      and "Everything is broken" in clean2, clean2)
check("clean_error fallback", main._clean_error("") == "unknown error")
check("clean_error caps length", len(main._clean_error("x" * 900)) <= 240)

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)

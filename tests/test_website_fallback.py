"""Generic website fallback: used only after yt-dlp rejects a site.

Covers a normal page exposing audio links, a header-described
download endpoint with no file extension in its URL, a page exposing
a video whose audio is extracted, a page exposing an HLS stream, and
a page with no usable media (the original yt-dlp error must surface).
"""
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse


class Stub(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, body, ctype, filename=None):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if filename:
            self.send_header("Content-Disposition",
                             f'attachment; filename="{filename}"')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/page":
            body = f"""<!doctype html><html><head>
              <meta property="og:title" content="Songs">
              </head><body>
              <a href="/media/Song One.mp3">Download song</a>
              <audio controls src="/media/Tune Two.flac"></audio>
              </body></html>""".encode()
            return self._send(body, "text/html")
        if u.path == "/video-page":
            body = f"""<!doctype html><html><head>
              <meta property="og:video" content="/media/clip.mp4">
              </head><body>Watch</body></html>""".encode()
            return self._send(body, "text/html")
        if u.path == "/stream-page":
            body = f"""<!doctype html><html><body>
              <script>const stream = "{B}/media/live.m3u8";</script>
              </body></html>""".encode()
            return self._send(body, "text/html")
        if u.path == "/plain":
            return self._send(b"<html><body>No media here</body></html>",
                              "text/html")
        if u.path == "/download":
            return self._send(open(FIXTURE, "rb").read(), "audio/mpeg",
                              "Endpoint Song.mp3")
        if u.path == "/media/live.m3u8":
            body = (b"#EXTM3U\n#EXT-X-VERSION:3\n"
                    b"#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n"
                    b"#EXTINF:2.0,\nseg.ts\n#EXT-X-ENDLIST\n")
            return self._send(body, "application/vnd.apple.mpegurl")
        if u.path == "/media/seg.ts":
            return self._send(open(SEGMENT, "rb").read(), "video/mp2t")
        if u.path.startswith("/media/"):
            return self._send(open(FIXTURE, "rb").read(), "audio/mpeg")
        self.send_response(404)
        self.end_headers()


stub = HTTPServer(("127.0.0.1", 0), Stub)
PORT = stub.server_port
B = f"http://127.0.0.1:{PORT}"
threading.Thread(target=stub.serve_forever, daemon=True).start()

TMP = tempfile.mkdtemp(prefix="naviupload-website-")
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
SEGMENT = os.path.join(TMP, "seg.ts")
subprocess.run(["ffmpeg", "-y", "-f", "lavfi", "-i",
                "sine=frequency=440:duration=2", "-codec:a", "aac",
                "-f", "mpegts", SEGMENT], capture_output=True, check=True)

from fastapi import HTTPException  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
import main  # noqa: E402


def unsupported(url, workdir):
    raise HTTPException(502, "yt-dlp could not fetch that link: "
                             "unsupported site")


main.fetch_with_ytdlp = unsupported
client = TestClient(main.app, raise_server_exceptions=False)
H = {"X-Upload-Token": "test-token-123"}
failures = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name
          + (f" — {extra}" if extra and not cond else ""))
    if not cond:
        failures.append(name)


def post(path):
    return client.post("/url", headers=H, json={
        "url": f"{B}{path}", "enrich": False, "lyrics": False})


r = post("/page")
j = r.json()
names = set()
if r.status_code == 200:
    names.add(j.get("saved_as"))
    names.update(f.get("saved_as") for f in j.get("files") or [])
check("page: linked audio files saved via website",
      r.status_code == 200 and j.get("via") == "website"
      and names == {"Song One.mp3", "Tune Two.flac"}, r.text[:300])
check("page: files landed in library",
      os.path.exists(os.path.join(LIB, "Song One.mp3"))
      and os.path.exists(os.path.join(LIB, "Tune Two.flac")))

r = post("/download?id=7")
check("endpoint: header-named file saved via website",
      r.status_code == 200 and r.json().get("via") == "website"
      and r.json().get("saved_as") == "Endpoint Song.mp3", r.text[:300])

r = post("/video-page")
check("video page: audio extracted and saved via website",
      r.status_code == 200 and r.json().get("via") == "website"
      and r.json().get("saved_as") == "clip.mp3"
      and os.path.getsize(os.path.join(LIB, "clip.mp3")) > 0,
      r.text[:300])

r = post("/stream-page")
check("stream page: HLS saved as mp3 via website",
      r.status_code == 200 and r.json().get("via") == "website"
      and r.json().get("saved_as") == "live.mp3"
      and os.path.getsize(os.path.join(LIB, "live.mp3")) > 0,
      r.text[:300])

r = post("/plain")
check("no-media page: original yt-dlp error surfaces",
      r.status_code == 502 and "unsupported site" in r.text, r.text[:300])

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)

"""POST /playlists (1.4.0): resolve [{title, artist}] to Navidrome
song ids via search3 and create the playlist with createPlaylist.
The stub plays Navidrome; it records what createPlaylist received so
the test can prove order and ids, not just the app's own reply."""
import json
import os
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

CAPTURED = {}
EXISTING = {"enabled": False}

SONGS = {
    "Song One": {"id": "id-one", "title": "Song One",
                 "artist": "The Testers", "duration": 201},
    "Song Two": {"id": "id-two", "title": "Song Two",
                 "artist": "The Testers", "duration": 187},
}

TWINS = [
    {"id": "id-twin-a", "title": "Twin Song", "artist": "The Testers",
     "duration": 100},
    {"id": "id-twin-b", "title": "Twin Song", "artist": "The Testers",
     "duration": 203},
]


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
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        if parsed.path.startswith("/rest/search3.view"):
            query = (qs.get("query") or [""])[0]
            hits = [s for name, s in SONGS.items() if name in query]
            if "Twin" in query:
                hits = TWINS
            return self._json({"subsonic-response": {
                "status": "ok", "searchResult3": {"song": hits}}})
        if parsed.path.startswith("/rest/getScanStatus.view"):
            return self._json({"subsonic-response": {
                "status": "ok",
                "scanStatus": {"scanning": False, "count": 3}}})
        if parsed.path.startswith("/rest/getPlaylists.view"):
            entries = ([{"id": "pl-9", "name": "Road Mix"}]
                       if EXISTING["enabled"] else [])
            return self._json({"subsonic-response": {
                "status": "ok", "playlists": {"playlist": entries}}})
        if parsed.path.startswith("/rest/createPlaylist.view"):
            CAPTURED["name"] = (qs.get("playlistName") or [""])[0]
            CAPTURED["playlist_id"] = (qs.get("playlistId") or [""])[0]
            CAPTURED["song_ids"] = qs.get("songId") or []
            pid = CAPTURED["playlist_id"] or "pl-1"
            return self._json({"subsonic-response": {
                "status": "ok", "playlist": {
                    "id": pid, "name": CAPTURED["name"] or "Road Mix",
                    "songCount": len(CAPTURED["song_ids"])}}})
        if parsed.path.startswith("/rest/startScan.view"):
            return self._json({"subsonic-response": {"status": "ok"}})
        self.send_response(404)
        self.end_headers()


stub = HTTPServer(("127.0.0.1", 0), ND)
PORT = stub.server_port
threading.Thread(target=stub.serve_forever, daemon=True).start()

TMP = tempfile.mkdtemp(prefix="navi-playlists-")
LIB = os.path.join(TMP, "library")
DATA = os.path.join(TMP, "data")
os.makedirs(LIB)
os.makedirs(DATA)
TOK = "test" + "-token-" + "123"
os.environ.update(
    LIBRARY_DIR=LIB, DATA_DIR=DATA, UPLOAD_TOKEN=TOK,
    NAVIDROME_URL=f"http://127.0.0.1:{PORT}",
    NAVIDROME_USER="soup", NAVIDROME_PASSWORD="pw",
    TORBOX_API_KEY="", PREMIUMIZE_API_KEY="")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "server", "app"))

from fastapi.testclient import TestClient  # noqa: E402
import main  # noqa: E402

client = TestClient(main.app, raise_server_exceptions=False)
H = {"X-Upload-Token": TOK}
failures = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name
          + (f" — {extra}" if extra and not cond else ""))
    if not cond:
        failures.append(name)


def create(payload, headers=H):
    return client.post("/playlists", headers=headers, json=payload)


check("health says playlists on",
      client.get("/health").json()["features"]["playlists"] is True)
check("playlists need token",
      create({"name": "X", "songs": []}, headers={}).status_code == 401)
check("name required",
      create({"name": " ", "songs": [{"title": "Song One"}]}).status_code
      == 400)
check("songs required",
      create({"name": "Mix", "songs": []}).status_code == 400)

r = create({"name": "Road Mix", "songs": [
    {"title": "Song One", "artist": "The Testers"},
    {"title": "Song Two", "artist": "The Testers"},
    {"title": "Ghost Track", "artist": "Nobody"},
]})
check("create ok", r.status_code == 200, r.text)
body = r.json()
check("created fields", body["created"] is True
      and body["playlist_id"] == "pl-1"
      and body["matched"] == 2
      and body["song_count"] == 2, str(body))
check("missing reported",
      body["missing"] == [{"title": "Ghost Track", "artist": "Nobody"}],
      str(body))
check("ids reached Navidrome in order",
      CAPTURED.get("song_ids") == ["id-one", "id-two"]
      and CAPTURED.get("name") == "Road Mix", str(CAPTURED))

r = create({"name": "Empty", "songs": [{"title": "Nope", "artist": "X"}]})
check("nothing found is 422", r.status_code == 422, r.text)

# Re-running an existing playlist replaces it in place.
EXISTING["enabled"] = True
CAPTURED.clear()
r = create({"name": "Road Mix", "songs": [
    {"title": "Song One", "artist": "The Testers"}]})
check("existing playlist updated", r.status_code == 200
      and r.json()["updated"] is True
      and r.json()["playlist_id"] == "pl-9", r.text)
check("replace went by id", CAPTURED.get("playlist_id") == "pl-9",
      str(CAPTURED))
EXISTING["enabled"] = False

# Duration disambiguates identical titles; without it, a tie is a
# miss, not a coin flip.
CAPTURED.clear()
r = create({"name": "Twins", "songs": [
    {"title": "Twin Song", "artist": "The Testers", "duration": 200}]})
check("duration picks the right twin", r.status_code == 200
      and CAPTURED.get("song_ids") == ["id-twin-b"], str(CAPTURED))
r = create({"name": "Twins", "songs": [
    {"title": "Twin Song", "artist": "The Testers"}]})
check("ambiguous twin is missing, not guessed",
      r.status_code == 422, r.text)

print()
if failures:
    print(f"{len(failures)} FAILURES: {failures}")
    sys.exit(1)
print("ALL PLAYLIST CHECKS PASSED")

"""0.4.0 server tools: GET /duplicates (same song twice, incl. in
subfolders), POST /delete (pinned inside the library), POST /tracks
(retry specific tracks), and the lyrics fallback behind LRCLIB.
"""
import asyncio
import os
import shutil
import subprocess
import sys
import tempfile
import types

TMP = tempfile.mkdtemp(prefix="naviupload-tools-")
LIB = os.path.join(TMP, "music")
DATA = os.path.join(TMP, "data")
os.makedirs(os.path.join(LIB, "Sorted"))
os.makedirs(DATA)
os.environ.update(
    LIBRARY_DIR=LIB, DATA_DIR=DATA, UPLOAD_TOKEN="test-token-123",
    NAVIDROME_URL="", NAVIDROME_USER="", NAVIDROME_PASSWORD="",
    TORBOX_API_KEY="", PREMIUMIZE_API_KEY="")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "server", "app"))


def make_mp3(path, seconds, title=None, artist=None):
    subprocess.run(["ffmpeg", "-y", "-f", "lavfi", "-i",
                    f"sine=frequency=440:duration={seconds}",
                    "-codec:a", "libmp3lame", path],
                   capture_output=True, check=True)
    if title or artist:
        from mutagen.id3 import ID3, TIT2, TPE1
        tags = ID3()
        if title:
            tags.add(TIT2(encoding=3, text=title))
        if artist:
            tags.add(TPE1(encoding=3, text=artist))
        tags.save(path)


BIG = os.path.join(LIB, "Song A.mp3")
SMALL = os.path.join(LIB, "Sorted", "Song A copy.mp3")
UNIQUE = os.path.join(LIB, "Song B.mp3")
make_mp3(BIG, 4, "Test Song", "Test Artist")
make_mp3(SMALL, 2, "Test Song", "Test Artist")
make_mp3(UNIQUE, 3, "Other Song", "Other Artist")
FIXTURE = os.path.join(TMP, "fixture.mp3")
make_mp3(FIXTURE, 2)

from fastapi.testclient import TestClient  # noqa: E402
from fastapi import HTTPException  # noqa: E402
import main  # noqa: E402

client = TestClient(main.app, raise_server_exceptions=False)
H = {"X-Upload-Token": "test-token-123"}
failures = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name
          + (f" — {extra}" if extra and not cond else ""))
    if not cond:
        failures.append(name)


small_size = os.path.getsize(SMALL)

# --- /duplicates ---------------------------------------------------
r = client.get("/duplicates")
check("duplicates: token required", r.status_code == 401,
      str(r.status_code))
r = client.get("/duplicates", headers=H)
j = r.json()
check("duplicates: one group found", r.status_code == 200
      and j.get("group_count") == 1, r.text[:300])
if j.get("groups"):
    g = j["groups"][0]
    rels = {f["file"] for f in g["files"]}
    check("duplicates: both copies incl. subfolder",
          rels == {"Song A.mp3",
                   os.path.join("Sorted", "Song A copy.mp3")},
          str(rels))
    check("duplicates: biggest first, wasted = smaller copy",
          g["files"][0]["file"] == "Song A.mp3"
          and j["wasted_bytes"] == small_size,
          str(g)[:200])

# --- /delete --------------------------------------------------------
r = client.post("/delete", headers=H, json={"files": ["../secret.mp3"]})
j = r.json()
check("delete: traversal refused, nothing deleted",
      r.status_code == 200 and j["deleted"] == []
      and len(j["errors"]) == 1, r.text[:200])
r = client.post("/delete", headers=H,
                json={"files": [os.path.join("Sorted", "Song A copy.mp3")]})
j = r.json()
check("delete: copy removed", j["deleted"] != [] and not os.path.exists(SMALL),
      r.text[:200])
r = client.get("/duplicates", headers=H)
check("duplicates: clean after delete",
      r.json().get("group_count") == 0, r.text[:200])

# --- /tracks --------------------------------------------------------
def fake_fetch(track, workdir, index):
    if track["title"] == "Bad Song":
        raise HTTPException(502, "no audio found")
    dest = os.path.join(workdir, f"track{index}.mp3")
    shutil.copy(FIXTURE, dest)
    return dest


main.fetch_spotify_audio = fake_fetch
r = client.post("/tracks", headers=H, json={
    "tracks": [{"title": "Good Song", "artist": "Good Artist"},
               "Other Artist - String Song",
               {"title": "Bad Song", "artist": "Bad"}],
    "enrich": False, "lyrics": False})
j = r.json()
names = set()
if r.status_code == 200:
    names.add(j.get("saved_as"))
    names.update(f.get("saved_as") for f in j.get("files") or [])
check("tracks: good ones saved, bad one named",
      r.status_code == 200 and j.get("also_saved") == 1
      and names == {"Good Artist - Good Song.mp3",
                    "Other Artist - String Song.mp3"}
      and j.get("failed_tracks") == ["Bad - Bad Song"], r.text[:300])
r = client.post("/tracks", headers=H, json={"tracks": []})
check("tracks: empty list -> 400", r.status_code == 400,
      str(r.status_code))

# --- lyrics fallback --------------------------------------------------
fake_synced = types.ModuleType("syncedlyrics")
fake_synced.search = lambda q, providers=None: (
    "[ar:Someone]\n[ti:Whatever]\n[00:12.30] first line\n"
    "[00:15.00] second line\nplain third")
sys.modules["syncedlyrics"] = fake_synced
out = main._fetch_lyrics_fallback("Whatever", "Someone")
check("lyrics fallback: timestamps + LRC tags stripped",
      out == "first line\nsecond line\nplain third", repr(out))


async def no_lrclib(title, artist, duration):
    return None


main._fetch_lyrics_lrclib = no_lrclib
main._fetch_lyrics_fallback = lambda t, a: "fallback words"
out = asyncio.run(main._fetch_lyrics("T", "A", 0))
check("lyrics: fallback used when LRCLIB misses",
      out == "fallback words", repr(out))

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)

"""ZIP uploads (0.6.0): uploading a ZIP album unpacks it on the
server — every song inside is saved, and the album art / lyrics
bundled in the archive (or attached by the app from the song's own
folder) are embedded into the songs. Bundled assets apply even
with the online enrichment toggles off: they came WITH the music.
"""
import io
import os
import subprocess
import sys
import tempfile
import zipfile

TMP = tempfile.mkdtemp(prefix="navi-zip-")
LIB = os.path.join(TMP, "library")
DATA = os.path.join(TMP, "data")
os.makedirs(LIB)
os.makedirs(DATA)
TOK = "test" + "-token-" + "123"
os.environ.update(
    LIBRARY_DIR=LIB, DATA_DIR=DATA, UPLOAD_TOKEN=TOK,
    NAVIDROME_URL="", NAVIDROME_USER="", NAVIDROME_PASSWORD="",
    TORBOX_API_KEY="", PREMIUMIZE_API_KEY="")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "server", "app"))

FIXTURE = os.path.join(TMP, "fixture.mp3")
subprocess.run(["ffmpeg", "-y", "-f", "lavfi", "-i",
                "sine=frequency=440:duration=2", "-codec:a", "libmp3lame",
                FIXTURE], capture_output=True, check=True)
SONG = open(FIXTURE, "rb").read()

COVER_ROOT = b"\xff\xd8\xff\xe0" + b"ROOT-COVER-BYTES" * 8
COVER_DISC = b"\xff\xd8\xff\xe0" + b"DISC-COVER-BYTES" * 8
LRC_ONE = "[00:01.00]hello one line\n[00:02.00]second line\n"

from fastapi.testclient import TestClient  # noqa: E402
from mutagen.id3 import ID3  # noqa: E402
import main  # noqa: E402

client = TestClient(main.app, raise_server_exceptions=False)
H = {"X-Upload-Token": TOK}
failures = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name
          + (f" — {extra}" if extra and not cond else ""))
    if not cond:
        failures.append(name)


def make_zip() -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("Album/01 One.mp3", SONG)
        zf.writestr("Album/02 Two.mp3", SONG)
        zf.writestr("Album/cover.jpg", COVER_ROOT)
        zf.writestr("Album/01 One.lrc", LRC_ONE)
        zf.writestr("Album/Disc 2/03 Three.mp3", SONG)
        zf.writestr("Album/Disc 2/folder.jpg", COVER_DISC)
    return buf.getvalue()


def apic(path):
    tags = ID3(path)
    frames = tags.getall("APIC")
    return frames[0].data if frames else None


def uslt(path):
    tags = ID3(path)
    frames = tags.getall("USLT")
    return str(frames[0].text) if frames else ""


# 1 — the album ZIP, enrichment toggles OFF: bundled assets still tag.
r = client.post("/upload", headers=H,
                files={"file": ("album.zip", make_zip(), "application/zip")},
                data={"enrich": "false", "lyrics": "false", "sort": "false"})
check("zip upload accepted", r.status_code == 200, r.text[:200])
body = r.json() if r.status_code == 200 else {}
check("zip response is a bundle (via + also_saved + files)",
      body.get("via") == "zip" and body.get("also_saved") == 2
      and len(body.get("files") or []) == 3, str(body)[:200])
check("zip response flags the bundled art", body.get("bundled_art") is True)

names = sorted(os.listdir(LIB))
check("all three songs landed in the library",
      names == ["01 One.mp3", "02 Two.mp3", "03 Three.mp3"], str(names))
if names == ["01 One.mp3", "02 Two.mp3", "03 Three.mp3"]:
    check("root cover art embedded in track 1",
          apic(os.path.join(LIB, "01 One.mp3")) == COVER_ROOT)
    check("matching .lrc embedded in track 1",
          "hello one line" in uslt(os.path.join(LIB, "01 One.mp3")))
    check("root cover art embedded in track 2 (same folder)",
          apic(os.path.join(LIB, "02 Two.mp3")) == COVER_ROOT)
    check("track 2 has no lyrics (no matching .lrc)",
          uslt(os.path.join(LIB, "02 Two.mp3")) == "")
    check("disc subfolder uses its OWN folder.jpg",
          apic(os.path.join(LIB, "03 Three.mp3")) == COVER_DISC)

# 2 — plain upload with app-attached sidecars (folder art / lyrics).
r = client.post("/upload", headers=H,
                files={"file": ("Plain Song.mp3", SONG, "audio/mpeg"),
                       "cover": ("cover.jpg", COVER_ROOT, "image/jpeg"),
                       "lyrics_file": ("Plain Song.lrc",
                                       b"[00:02.00]plain words",
                                       "text/plain")},
                data={"enrich": "false", "lyrics": "false", "sort": "false"})
check("plain upload with sidecars accepted", r.status_code == 200,
      r.text[:200])
body = r.json() if r.status_code == 200 else {}
plain = os.path.join(LIB, "Plain Song.mp3")
check("attached cover embedded + flagged",
      body.get("bundled_art") is True and os.path.exists(plain)
      and apic(plain) == COVER_ROOT)
check("attached lyrics embedded + flagged",
      body.get("lyrics_embedded") is True and os.path.exists(plain)
      and "plain words" in uslt(plain))

# 3 — metadata extraction from the song files themselves: art
# embedded in ONE track is shared with its same-album sibling, and
# the response reports artist / album / duration / features read
# from the file's own tags.
EMBED_ART = b"\xff\xd8\xff\xe0" + b"EMBEDDED-ART-BYTES" * 8
four = os.path.join(TMP, "04 Four.mp3")
five = os.path.join(TMP, "05 Five.mp3")
with open(four, "wb") as fh:
    fh.write(SONG)
with open(five, "wb") as fh:
    fh.write(SONG)
main.write_tags(four, {"title": "Four (feat. Guest Star)",
                       "artist": "The Extractors",
                       "album": "Extracted Album",
                       "year": "2020", "track": 4}, EMBED_ART, None)
main.write_tags(five, {"title": "Five", "artist": "The Extractors",
                       "album": "Extracted Album",
                       "year": "2020", "track": 5}, None, None)
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
    zf.write(four, "Singles/04 Four.mp3")
    zf.write(five, "Singles/05 Five.mp3")
r = client.post("/upload", headers=H,
                files={"file": ("singles.zip", buf.getvalue(),
                                "application/zip")},
                data={"enrich": "false", "lyrics": "false", "sort": "false"})
check("singles zip accepted", r.status_code == 200, r.text[:200])
body = r.json() if r.status_code == 200 else {}
check("extracted artist + album in the response",
      body.get("artist") == "The Extractors"
      and body.get("album") == "Extracted Album", str(body)[:220])
check("extracted track length in the response (2 s fixture)",
      body.get("duration_seconds") == 2, str(body.get("duration_seconds")))
check("extracted featured artist in the response",
      body.get("featuring") == ["Guest Star"], str(body.get("featuring")))
five_saved = os.path.join(LIB, "05 Five.mp3")
four_saved = os.path.join(LIB, "04 Four.mp3")
check("sibling track received the art embedded in its album-mate",
      os.path.exists(five_saved) and apic(five_saved) == EMBED_ART)
check("the art-carrying track kept its own art",
      os.path.exists(four_saved) and apic(four_saved) == EMBED_ART)

# 4 — a ZIP with no audio is a clean 400, never a crash.
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w") as zf:
    zf.writestr("notes.txt", "no music here")
r = client.post("/upload", headers=H,
                files={"file": ("empty.zip", buf.getvalue(),
                                "application/zip")},
                data={"enrich": "false", "lyrics": "false", "sort": "false"})
check("audio-less zip rejected with 400", r.status_code == 400,
      f"{r.status_code} {r.text[:120]}")

print()
if failures:
    print(f"{len(failures)} FAILURE(S): {failures}")
    sys.exit(1)
print("ALL ZIP-UPLOAD CHECKS PASSED")

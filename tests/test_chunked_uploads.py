"""Chunked resumable uploads (1.4.0): init / chunk / status /
complete / cancel, the ZIP branch, and CUE sheet splitting — the
Windows app's answer to uploads that must survive a closed laptop
lid or a dropped connection. Completing a session runs the same
save pipeline as POST /upload, so the landed files must be
indistinguishable from classic uploads (0644 included).
"""
import hashlib
import io
import os
import stat
import subprocess
import sys
import tempfile
import zipfile

TMP = tempfile.mkdtemp(prefix="navi-chunk-")
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
SONG_SHA = hashlib.sha256(SONG).hexdigest()

LONG = os.path.join(TMP, "long.mp3")
subprocess.run(["ffmpeg", "-y", "-f", "lavfi", "-i",
                "sine=frequency=440:duration=6", "-codec:a", "libmp3lame",
                LONG], capture_output=True, check=True)
LONG_BYTES = open(LONG, "rb").read()

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


def init(name, size, headers=H):
    return client.post("/upload/init", headers=headers,
                       json={"filename": name, "size": size})


def put_chunk(uid, offset, data, headers=H):
    return client.put(f"/upload/chunk?upload_id={uid}&offset={offset}",
                      headers=headers, content=data)


def status(uid, headers=H):
    return client.get(f"/upload/status?upload_id={uid}", headers=headers)


def complete(uid, headers=H, **kw):
    body = {"upload_id": uid}
    body.update(kw)
    return client.post("/upload/complete", headers=headers, json=body)


# --- health advertises the feature -----------------------------------
r = client.get("/health")
check("health features", r.json()["features"]["chunked_uploads"] is True
      and r.json()["features"]["cue_split"] is True
      and r.json()["chunk_size"] == main.CHUNK_SIZE, r.text)

# --- auth + validation -------------------------------------------------
check("init needs token", init("a.mp3", 10, headers={}).status_code == 401)
check("init rejects non-audio", init("a.txt", 10).status_code == 415)
check("init rejects empty", init("a.mp3", 0).status_code == 400)

# --- the full flow, with a wrong offset and a resume -------------------
r = init("song.mp3", len(SONG))
check("init ok", r.status_code == 200, r.text)
uid = r.json()["upload_id"]
half = len(SONG) // 2
r = put_chunk(uid, 999, SONG[:half])
check("wrong offset is 409", r.status_code == 409, r.text)
check("nothing held after 409", status(uid).json()["received"] == 0)
r = put_chunk(uid, 0, SONG[:half])
check("chunk 1 lands", r.status_code == 200
      and r.json()["received"] == half, r.text)
r = complete(uid)
check("early complete is 409", r.status_code == 409, r.text)
# "Restart": the client keeps only the id and asks where it stands.
r = status(uid)
check("status survives", r.status_code == 200
      and r.json()["received"] == half
      and r.json()["filename"] == "song.mp3", r.text)
r = put_chunk(uid, half, SONG[half:])
check("chunk 2 lands", r.status_code == 200
      and r.json()["received"] == len(SONG), r.text)
r = complete(uid)
check("complete ok", r.status_code == 200, r.text)
body = r.json()
saved = os.path.join(LIB, body["saved_as"])
check("saved under library", os.path.exists(saved), str(body))
check("bytes identical", hashlib.sha256(open(saved, "rb").read()).hexdigest()
      == SONG_SHA)
check("mode is 0644", stat.S_IMODE(os.stat(saved).st_mode) == 0o644,
      oct(stat.S_IMODE(os.stat(saved).st_mode)))
# A completed session leaves a receipt: status reports it done and
# a repeated complete returns the same result instead of saving a
# second copy (the lost-response case).
r = status(uid)
check("receipt kept", r.status_code == 200
      and r.json()["state"] == "done"
      and r.json()["result"]["saved_as"] == body["saved_as"], r.text)
r = complete(uid)
check("complete is idempotent", r.status_code == 200
      and r.json()["saved_as"] == body["saved_as"], r.text)

# --- checksum verification ----------------------------------------------
uid = init("song.mp3", len(SONG)).json()["upload_id"]
put_chunk(uid, 0, SONG)
r = complete(uid, sha256="0" * 64)
check("bad checksum is 422", r.status_code == 422, r.text)
check("bad checksum discards session", status(uid).status_code == 404)
uid = init("song.mp3", len(SONG)).json()["upload_id"]
put_chunk(uid, 0, SONG)
r = complete(uid, sha256=SONG_SHA)
check("good checksum completes", r.status_code == 200, r.text)

# --- an oversize chunk is rolled back, not half-kept -------------------
r = init("over.mp3", 100)
uid = r.json()["upload_id"]
r = put_chunk(uid, 0, b"x" * 200)
check("oversize chunk is 413", r.status_code == 413, r.text)
check("oversize rolled back", status(uid).json()["received"] == 0)
r = client.delete(f"/upload/session?upload_id={uid}", headers=H)
check("cancel ok", r.status_code == 200
      and status(uid).status_code == 404, r.text)

# --- a ZIP rides the chunked path too ----------------------------------
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w") as zf:
    zf.writestr("Album/01 - Song.mp3", SONG)
ZIP = buf.getvalue()
uid = init("album.zip", len(ZIP)).json()["upload_id"]
put_chunk(uid, 0, ZIP)
r = complete(uid)
check("zip complete", r.status_code == 200
      and r.json()["via"] == "zip", r.text)
check("zip song in library",
      os.path.exists(os.path.join(LIB, "01 - Song.mp3")))

# --- CUE splitting ------------------------------------------------------
cue = (
    'PERFORMER "The Testers"\n'
    'TITLE "Cue Album"\n'
    'FILE "long.mp3" MP3\n'
    '  TRACK 01 AUDIO\n'
    '    TITLE "First Cut"\n'
    '    INDEX 01 00:00:00\n'
    '  TRACK 02 AUDIO\n'
    '    TITLE "Second Cut"\n'
    '    INDEX 01 00:02:00\n'
    '  TRACK 03 AUDIO\n'
    '    TITLE "Third Cut"\n'
    '    INDEX 01 00:04:00\n'
)
uid = init("long.mp3", len(LONG_BYTES)).json()["upload_id"]
mid = len(LONG_BYTES) // 2
put_chunk(uid, 0, LONG_BYTES[:mid])
put_chunk(uid, mid, LONG_BYTES[mid:])
r = complete(uid, cue=cue)
check("cue complete", r.status_code == 200, r.text)
body = r.json()
check("cue shape", body["via"] == "cue" and body["also_saved"] == 2
      and len(body["files"]) == 3, str(body))
from mutagen import File as MFile  # noqa: E402
from mutagen.id3 import ID3  # noqa: E402
durations = []
titles = []
track_numbers = []
for saved_as in body["files"]:
    path = os.path.join(LIB, saved_as)
    durations.append(MFile(path).info.length)
    tags = ID3(path)
    titles.append(str(tags["TIT2"]) if "TIT2" in tags else "")
    track_numbers.append(str(tags["TRCK"]) if "TRCK" in tags else "")
check("cue durations ~2s each",
      all(1.4 < d < 2.8 for d in durations), str(durations))
check("cue titles embedded",
      titles == ["First Cut", "Second Cut", "Third Cut"], str(titles))
check("cue track numbers embedded",
      track_numbers == ["1/3", "2/3", "3/3"], str(track_numbers))

# --- CUE over FLAC: lossless splits are sample-exact ---------------------
FLAC = os.path.join(TMP, "album.flac")
subprocess.run(["ffmpeg", "-y", "-f", "lavfi", "-i",
                "sine=frequency=440:duration=6", "-codec:a", "flac",
                FLAC], capture_output=True, check=True)
FLAC_BYTES = open(FLAC, "rb").read()
flac_cue = cue.replace('FILE "long.mp3" MP3', 'FILE "album.flac" WAVE')
uid = init("album.flac", len(FLAC_BYTES)).json()["upload_id"]
put_chunk(uid, 0, FLAC_BYTES)
r = complete(uid, cue=flac_cue)
check("flac cue complete", r.status_code == 200, r.text)
body = r.json()
check("flac cue outputs are flac",
      all(f.endswith(".flac") for f in body["files"]), str(body["files"]))
flac_durations = [MFile(os.path.join(LIB, f)).info.length
                  for f in body["files"]]
check("flac splits are sample-exact (~2.00s)",
      all(1.95 < d < 2.05 for d in flac_durations), str(flac_durations))
check("album file not saved whole",
      not os.path.exists(os.path.join(LIB, "long.mp3")))

# --- a one-track cue is refused ----------------------------------------
uid = init("long.mp3", len(LONG_BYTES)).json()["upload_id"]
put_chunk(uid, 0, LONG_BYTES)
r = complete(uid, cue='FILE "long.mp3" MP3\n  TRACK 01 AUDIO\n'
                      '    INDEX 01 00:00:00\n')
check("one-track cue refused", r.status_code == 400, r.text)

print()
if failures:
    print(f"{len(failures)} FAILURES: {failures}")
    sys.exit(1)
print("ALL CHUNKED-UPLOAD CHECKS PASSED")

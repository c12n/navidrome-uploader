"""Tag overrides (1.4.0): the Windows app's tag editor never
touches the user's files — it describes changes, and the server
applies them to the library copy with write_tags after enrichment.
Covers the classic /upload form field and the chunked /complete
JSON fields, including a replacement cover image."""
import base64
import io
import json
import os
import subprocess
import sys
import tempfile

TMP = tempfile.mkdtemp(prefix="navi-tags-")
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

COVER_JPG = os.path.join(TMP, "cover.jpg")
subprocess.run(["ffmpeg", "-y", "-f", "lavfi", "-i",
                "color=c=red:size=64x64", "-frames:v", "1",
                COVER_JPG], capture_output=True, check=True)
COVER = open(COVER_JPG, "rb").read()

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


# --- classic /upload -----------------------------------------------------
r = client.post(
    "/upload", headers=H,
    files={"file": ("messy name.mp3", io.BytesIO(SONG), "audio/mpeg")},
    data={"enrich": "false", "lyrics": "false", "sort": "false",
          "tag_overrides": json.dumps(
              {"title": "Fixed Title", "artist": "Fixed Artist",
               "album": "Fixed Album", "year": "1999", "track": "3"})})
check("classic upload ok", r.status_code == 200, r.text)
body = r.json()
check("response reflects overrides",
      body.get("tag_overrides") is True
      and body.get("artist") == "Fixed Artist"
      and body.get("album") == "Fixed Album"
      and body.get("matched_title") == "Fixed Title", str(body))
tags = ID3(os.path.join(LIB, body["saved_as"]))
check("tags written to the library copy",
      str(tags["TIT2"]) == "Fixed Title"
      and str(tags["TPE1"]) == "Fixed Artist"
      and str(tags["TALB"]) == "Fixed Album"
      and str(tags["TRCK"]) == "3", str(tags))

# --- chunked /complete, with a replacement cover --------------------------
r = client.post("/upload/init", headers=H,
                json={"filename": "chunked.mp3", "size": len(SONG)})
uid = r.json()["upload_id"]
client.put(f"/upload/chunk?upload_id={uid}&offset=0",
           headers=H, content=SONG)
r = client.post("/upload/complete", headers=H, json={
    "upload_id": uid,
    "tag_overrides": {"title": "Chunked Title", "artist": "Chunked Artist"},
    "cover_b64": base64.b64encode(COVER).decode(),
    "lyrics_b64": base64.b64encode(b"[00:01.00]hello line\n").decode(),
})
check("chunked complete ok", r.status_code == 200, r.text)
body = r.json()
tags = ID3(os.path.join(LIB, body["saved_as"]))
check("chunked tags written",
      str(tags["TIT2"]) == "Chunked Title"
      and str(tags["TPE1"]) == "Chunked Artist", str(tags))
check("replacement cover embedded", "APIC:" in tags
      or any(k.startswith("APIC") for k in tags.keys()), str(tags.keys()))
check("bundled lyrics embedded",
      any(k.startswith("USLT") for k in tags.keys()), str(tags.keys()))

# --- no overrides: nothing changes ---------------------------------------
r = client.post(
    "/upload", headers=H,
    files={"file": ("plain.mp3", io.BytesIO(SONG), "audio/mpeg")},
    data={"enrich": "false", "lyrics": "false", "sort": "false"})
check("plain upload unaffected", r.status_code == 200
      and "tag_overrides" not in r.json(), r.text)

print()
if failures:
    print(f"{len(failures)} FAILURES: {failures}")
    sys.exit(1)
print("ALL TAG-OVERRIDE CHECKS PASSED")

#!/usr/bin/env bash
# NaviUpload server auto-updater — Copyright (c) 2026 c12n Apps
#
# Keeps the companion server's app/main.py in step with the latest
# GitHub RELEASE of c12n/navidrome-uploader. It never tracks the main
# branch: the candidate file is always fetched pinned to the release
# tag (branch URLs can serve stale cached copies).
#
# Safety chain for every update:
#   download to a temp dir -> sha256 recorded -> python syntax check
#   -> current file backed up to app/main.py.bak -> new file installed
#   -> container recreated -> /health polled until 200.
# If health never comes back, the backup is restored and the server
# restarted again; the bad release is remembered and not retried.
# Updates only ever move FORWARD to a newer release tag, never back
# to an older release's file.
#
# Modes:
#   autoupdate.sh              one check/update run (what cron calls)
#   autoupdate.sh --install    one-time setup (root): installs this
#                              script next to the server, seeds the
#                              baseline release, adds the cron job
#   autoupdate.sh --dry-run    report what a run would do, change
#                              nothing (no root needed)
#
# State + audit log live in the server's data dir:
#   data/autoupdate-status.json   (also surfaced by GET /health)
#   data/autoupdate.log

set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

REPO="c12n/navidrome-uploader"
APP_HOME="${NAVI_APP_HOME:-/media/ZimaOS-HD/AppData/navidrome-uploader}"
MAIN_PY="$APP_HOME/app/main.py"
BACKUP="$APP_HOME/app/main.py.bak"
DATA_DIR="$APP_HOME/data"
LOG_FILE="$DATA_DIR/autoupdate.log"
STATUS_FILE="$DATA_DIR/autoupdate-status.json"
INSTALLED_SCRIPT="$APP_HOME/autoupdate.sh"
CRON_FILE="/etc/cron.d/navi-autoupdate"
API_URL="${NAVI_API_URL:-https://api.github.com/repos/$REPO/releases/latest}"
RAW_BASE="${NAVI_RAW_BASE:-https://raw.githubusercontent.com/$REPO}"
HEALTH_URL="${NAVI_HEALTH_URL:-http://127.0.0.1:8911/health}"
HEALTH_TRIES="${NAVI_HEALTH_TRIES:-36}"      # 36 x 10s = up to 6 min
HEALTH_SLEEP="${NAVI_HEALTH_SLEEP:-10}"
UA="navi-autoupdate/1.0"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

WORKDIR=""
cleanup() { [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"; }

ts() { date '+%Y-%m-%d %H:%M:%S %Z'; }

log() {
    local line="[$(ts)] $*"
    if [ "$DRY_RUN" = "1" ]; then
        echo "$line"
    else
        echo "$line" >> "$LOG_FILE" 2>/dev/null || echo "$line"
    fi
}

# --- status file helpers (python3 does the JSON so quoting is safe) ---

status_get() {  # $1 = field name; prints value or empty
    python3 - "$STATUS_FILE" "$1" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as fh:
        print(json.load(fh).get(sys.argv[2], ""))
except Exception:
    print("")
PYEOF
}

status_set() {  # key=value pairs as args; merges into the status file
    [ "$DRY_RUN" = "1" ] && return 0
    python3 - "$STATUS_FILE" "$@" <<'PYEOF' 2>/dev/null || true
import json, os, sys, tempfile
path, pairs = sys.argv[1], sys.argv[2:]
try:
    with open(path) as fh:
        data = json.load(fh)
except Exception:
    data = {}
for pair in pairs:
    key, _, value = pair.partition("=")
    data[key] = value
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w") as fh:
    json.dump(data, fh, indent=1, sort_keys=True)
os.chmod(tmp, 0o644)  # mkstemp makes it 0600; the status should stay readable
os.replace(tmp, path)
PYEOF
}

sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

fetch_latest_tag() {  # prints tag like v0.6.0, or nothing on failure
    local work="$1"
    curl -fsSL --max-time 30 -A "$UA" "$API_URL" -o "$work/latest.json" 2>/dev/null || return 1
    python3 - "$work/latest.json" <<'PYEOF' 2>/dev/null
import json, re, sys
try:
    with open(sys.argv[1]) as fh:
        tag = json.load(fh).get("tag_name", "")
    print(tag if re.fullmatch(r"v[0-9][A-Za-z0-9.\-]*", tag or "") else "")
except Exception:
    print("")
PYEOF
}

DOCKER_BIN="${NAVI_DOCKER:-docker}"

restart_server() {
    log "restarting server (docker compose up -d --force-recreate)"
    if (cd "$APP_HOME" && "$DOCKER_BIN" compose up -d --force-recreate) >> "$LOG_FILE" 2>&1; then
        return 0
    fi
    log "compose recreate failed; falling back to docker restart"
    "$DOCKER_BIN" restart navidrome-uploader >> "$LOG_FILE" 2>&1
}

wait_health() {  # $1 = tries
    local tries="$1" i code
    for ((i = 1; i <= tries; i++)); do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$HEALTH_URL" 2>/dev/null || echo 000)
        [ "$code" = "200" ] && return 0
        sleep "$HEALTH_SLEEP"
    done
    return 1
}

# ------------------------------- install -------------------------------

do_install() {
    if [ "$(id -u)" != "0" ]; then
        echo "ERROR: --install must run as root (use sudo)." >&2
        return 1
    fi
    local work tag current_sha
    work=$(mktemp -d)
    echo "Fetching the current latest release to seed the baseline..."
    tag=$(fetch_latest_tag "$work")
    if [ -z "$tag" ]; then
        echo "ERROR: could not reach the GitHub API to learn the latest release." >&2
        echo "Install aborted (nothing changed) — seeding the baseline correctly" >&2
        echo "is what stops the updater from ever rolling the server backwards." >&2
        rm -rf "$work"
        return 1
    fi
    current_sha=$(sha_of "$MAIN_PY")
    cp "$0" "$INSTALLED_SCRIPT"
    chmod 755 "$INSTALLED_SCRIPT"
    if [ ! -f "$STATUS_FILE" ]; then
        status_set \
            "installed_tag=$tag" \
            "installed_sha=$current_sha" \
            "failed_tag=" \
            "last_result=baseline seeded at install" \
            "last_check=$(ts)" \
            "last_change="
        echo "Baseline: the running server counts as release $tag (sha ${current_sha:0:12}...)."
    else
        echo "Existing status file kept ($(status_get installed_tag) already recorded)."
    fi
    if [ -d /etc/cron.d ]; then
        printf '*/30 * * * * root %s >/dev/null 2>&1\n' "$INSTALLED_SCRIPT" > "$CRON_FILE"
        chmod 644 "$CRON_FILE"
        echo "Cron job installed: $CRON_FILE (every 30 minutes, as root)."
    elif command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/navi-autoupdate.service <<EOF
[Unit]
Description=NaviUpload server auto-updater
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=$INSTALLED_SCRIPT
EOF
        cat > /etc/systemd/system/navi-autoupdate.timer <<'EOF'
[Unit]
Description=Run the NaviUpload auto-updater every 30 minutes

[Timer]
OnCalendar=*:0/30
Persistent=true

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable --now navi-autoupdate.timer
        echo "systemd timer installed (cron.d unavailable): navi-autoupdate.timer."
    else
        echo "ERROR: no /etc/cron.d and no systemctl — could not install a schedule." >&2
        return 1
    fi
    touch "$LOG_FILE" 2>/dev/null || true
    log "auto-updater installed; baseline release $tag"
    echo "Done. Log: $LOG_FILE"
    echo "Status: $STATUS_FILE (also shown by the server's /health)."
    rm -rf "$work"
    return 0
}

# --------------------------------- run ---------------------------------

do_run() {
    if [ "$(id -u)" != "0" ] && [ "$DRY_RUN" != "1" ] && [ "${NAVI_ALLOW_NONROOT:-0}" != "1" ]; then
        echo "ERROR: the updater must run as root (it replaces a root-owned file and restarts the container)." >&2
        return 1
    fi
    if [ "$DRY_RUN" != "1" ]; then
        exec 9>"$DATA_DIR/.autoupdate.lock"
        if ! flock -n 9; then
            log "another run is in progress; skipping"
            return 0
        fi
    fi

    local work tag current_sha seen_tag failed_tag
    work=$(mktemp -d)
    WORKDIR="$work"
    trap cleanup EXIT

    if [ ! -f "$MAIN_PY" ]; then
        log "ERROR: server file not found at $MAIN_PY"
        return 1
    fi
    current_sha=$(sha_of "$MAIN_PY")

    tag=$(fetch_latest_tag "$work")
    if [ -z "$tag" ]; then
        log "check failed: could not read the latest release from GitHub"
        status_set "last_check=$(ts)" "last_result=check failed (GitHub unreachable)"
        return 0
    fi

    seen_tag=$(status_get installed_tag)
    failed_tag=$(status_get failed_tag)
    if [ "$DRY_RUN" = "1" ] && [ ! -f "$STATUS_FILE" ]; then
        seen_tag="$tag"
        log "dry-run: no status file yet — after --install the baseline would be $tag"
    fi

    if [ "$tag" = "$seen_tag" ]; then
        log "up to date: latest release $tag is what the server baseline records (server sha ${current_sha:0:12}...)"
        status_set "last_check=$(ts)" "last_result=up to date ($tag)"
        return 0
    fi
    if [ "$tag" = "$failed_tag" ]; then
        log "release $tag previously failed its health check and was rolled back; waiting for a newer release"
        status_set "last_check=$(ts)" "last_result=$tag known-bad (rolled back), skipped"
        return 0
    fi

    log "new release $tag (baseline was ${seen_tag:-none}); fetching its server file"
    if ! curl -fsSL --max-time 60 -A "$UA" "$RAW_BASE/$tag/server/app/main.py" -o "$work/main.py" 2>/dev/null; then
        log "download of $tag's server file failed; will retry next run"
        status_set "last_check=$(ts)" "last_result=download failed for $tag"
        return 0
    fi
    local cand_sha
    cand_sha=$(sha_of "$work/main.py")
    if [ "$cand_sha" = "$current_sha" ]; then
        log "$tag's server file is identical to the running one; baseline advanced, no restart"
        status_set "last_check=$(ts)" "installed_tag=$tag" "installed_sha=$cand_sha" \
            "last_result=$tag server file identical; baseline advanced"
        return 0
    fi
    if ! python3 -m py_compile "$work/main.py" 2>"$work/pyerr"; then
        log "release $tag REJECTED: server file fails a Python syntax check ($(head -c 200 "$work/pyerr" | tr '\n' ' '))"
        status_set "last_check=$(ts)" "failed_tag=$tag" \
            "last_result=$tag rejected (syntax check failed)"
        return 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
        log "dry-run: would install $tag (sha ${cand_sha:0:12}...), restart, and health-check (backup + rollback armed)"
        return 0
    fi

    cp "$MAIN_PY" "$BACKUP"
    cp "$work/main.py" "$MAIN_PY"
    log "installed $tag server file (sha ${cand_sha:0:12}...); previous file backed up to main.py.bak"
    restart_server
    if wait_health "$HEALTH_TRIES"; then
        log "update OK: server healthy on $tag"
        status_set "last_check=$(ts)" "installed_tag=$tag" "installed_sha=$cand_sha" \
            "failed_tag=" "last_change=$(ts)" "last_result=updated to $tag"
        return 0
    fi

    log "release $tag FAILED its health check; rolling back to the backup"
    cp "$BACKUP" "$MAIN_PY"
    restart_server
    if wait_health 24; then
        log "rollback OK: previous server is healthy again"
    else
        log "CRITICAL: rollback installed but health is still not 200 — server needs manual attention"
    fi
    status_set "last_check=$(ts)" "failed_tag=$tag" \
        "last_result=$tag failed health check; rolled back"
    return 0
}

case "${1:-}" in
    --install) do_install ;;
    --dry-run) do_run ;;
    "")        do_run ;;
    *) echo "usage: $0 [--install|--dry-run]" >&2; exit 2 ;;
esac

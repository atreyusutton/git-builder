#!/usr/bin/env bash
#
# git-builder — nightly autonomous project generator.
#
#   1. Scout   : search for what shipped in AI recently, pick an unbuilt idea
#   2. Build   : hand the spec to claude -p in a fresh repo, unattended
#   3. Verify  : run the smoke test; a failing build is never pushed
#   4. Publish : commit, create the GitHub repo, push
#   5. Report  : write reports/YYYY-MM-DD.md for you to read in the morning
#
# Run manually with:  bin/nightly.sh
# Dry run (no push):  NO_PUSH=1 bin/nightly.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ---------------------------------------------------------------- config ----

# shellcheck disable=SC1091
source "$ROOT/config.env"

: "${BUILD_ROOT:="$ROOT/builds"}"
: "${REPO_VISIBILITY:=public}"
: "${NO_PUSH:=0}"
: "${SCOUT_MODEL:=sonnet}"
: "${BUILD_MODEL:=opus}"
: "${SCOUT_BUDGET_USD:=1.00}"
: "${BUILD_BUDGET_USD:=8.00}"
: "${SCOUT_TIMEOUT:=600}"
: "${BUILD_TIMEOUT:=3600}"
: "${NOTIFY:=1}"
: "${REPO_PREFIX:=}"

DATE="$(date +%Y-%m-%d)"
STAMP="$(date +%Y-%m-%dT%H:%M:%S%z)"
HISTORY="$ROOT/state/history.json"
REPORT="$ROOT/reports/$DATE.md"
LOG="$ROOT/logs/$DATE.log"
LOCK="$ROOT/state/.lock"

mkdir -p "$BUILD_ROOT" "$ROOT/state" "$ROOT/reports" "$ROOT/logs"

# launchd gives us a threadbare PATH; put the usual suspects back.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# ------------------------------------------------------------- utilities ----

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG" >&2; }
die() { log "FATAL: $*"; exit 1; }

# macOS has no coreutils `timeout`. Use gtimeout if present, else a watchdog.
run_limited() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null || true ) &
    local watchdog=$!
    local rc=0
    wait "$pid" || rc=$?
    kill -TERM "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    return "$rc"
  fi
}

notify() {
  [ "$NOTIFY" = "1" ] || return 0
  command -v osascript >/dev/null 2>&1 || return 0
  local title="$1" msg="$2"
  osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\"" \
    >/dev/null 2>&1 || true
}

# Ask claude, unattended, and print the assistant's final text to stdout.
ask_claude() {
  local model="$1" budget="$2" secs="$3" workdir="$4" prompt_file="$5"
  local raw
  raw="$(
    cd "$workdir" && run_limited "$secs" claude -p "$(cat "$prompt_file")" \
      --model "$model" \
      --output-format json \
      --dangerously-skip-permissions \
      --max-budget-usd "$budget" \
      --no-session-persistence \
      2>>"$LOG"
  )" || return 1
  printf '%s' "$raw" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    env = json.loads(raw)
except json.JSONDecodeError:
    sys.stdout.write(raw); sys.exit(0)
if isinstance(env, dict) and env.get("is_error"):
    sys.stderr.write("claude reported an error: %s\n" % str(env.get("result", ""))[:500])
    sys.exit(1)
if isinstance(env, dict) and "result" in env:
    sys.stdout.write(env["result"] if isinstance(env["result"], str) else json.dumps(env["result"]))
else:
    sys.stdout.write(raw)
'
}

cleanup() { rmdir "$LOCK" 2>/dev/null || true; }

# ------------------------------------------------------------------ lock ----

if ! mkdir "$LOCK" 2>/dev/null; then
  die "another run is in progress ($LOCK exists). Remove it if that is stale."
fi
trap cleanup EXIT

# ------------------------------------------------------------- preflight ----

command -v claude >/dev/null 2>&1 || die "claude CLI not found on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"
if [ "$NO_PUSH" != "1" ]; then
  command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"
fi

[ -f "$HISTORY" ] || echo '[]' > "$HISTORY"

log "=== git-builder run $STAMP ==="

# -------------------------------------------------------------- 1. scout ----

log "phase 1: scouting recent AI releases (model=$SCOUT_MODEL)"

SCOUT_PROMPT="$(mktemp -t gb-scout)"
python3 - "$ROOT/prompts/scout.md" "$HISTORY" "$SCOUT_PROMPT" <<'PY'
import json, sys
tmpl_path, hist_path, out_path = sys.argv[1:4]
tmpl = open(tmpl_path, encoding="utf-8").read()
hist = json.load(open(hist_path, encoding="utf-8"))
if hist:
    block = "\n".join(
        "- %s (%s) - built against: %s" % (e.get("slug", ""), e.get("title", ""), e.get("trigger", ""))
        for e in hist[-60:]
    )
else:
    block = "(nothing yet - this is the first run)"
open(out_path, "w", encoding="utf-8").write(tmpl.replace("{{HISTORY}}", block))
PY

SPEC_JSON=""
for attempt in 1 2; do
  log "scout attempt $attempt"
  if ! SCOUT_OUT="$(ask_claude "$SCOUT_MODEL" "$SCOUT_BUDGET_USD" "$SCOUT_TIMEOUT" "$ROOT" "$SCOUT_PROMPT")"; then
    log "scout attempt $attempt failed to run"
    continue
  fi
  # The model was told to emit bare JSON; be forgiving anyway.
  if SPEC_JSON="$(printf '%s' "$SCOUT_OUT" | python3 -c '
import json, re, sys
raw = sys.stdin.read().strip()
raw = re.sub(r"^```(?:json)?|```$", "", raw, flags=re.M).strip()
start = raw.find("{")
if start == -1:
    sys.exit(1)
try:
    obj, _ = json.JSONDecoder().raw_decode(raw[start:])
except ValueError:
    sys.exit(1)
required = ["slug", "title", "trigger", "pitch", "stack", "features", "smoke_test"]
missing = [k for k in required if not obj.get(k)]
if missing:
    sys.stderr.write("spec missing fields: %s\n" % ", ".join(missing))
    sys.exit(1)
obj["slug"] = re.sub(r"[^a-z0-9-]", "", obj["slug"].lower().replace(" ", "-")).strip("-")
if not obj["slug"]:
    sys.exit(1)
print(json.dumps(obj, indent=2))
')"; then
    break
  fi
  log "scout attempt $attempt produced unusable output"
  SPEC_JSON=""
done

[ -n "$SPEC_JSON" ] || die "scouting failed after 2 attempts — see $LOG"

printf '%s\n' "$SPEC_JSON" > "$ROOT/state/last-spec.json"

spec_field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$ROOT/state/last-spec.json" "$1"; }

SLUG="$(spec_field slug)"
TITLE="$(spec_field title)"
TRIGGER="$(spec_field trigger)"
SMOKE="$(spec_field smoke_test)"
PITCH="$(spec_field pitch)"

log "idea: $TITLE ($SLUG)"
log "built against: $TRIGGER"

# -------------------------------------------------------------- 2. build ----

REPO_NAME="${REPO_PREFIX}${SLUG}"
WORKDIR="$BUILD_ROOT/$DATE-$SLUG"
[ -e "$WORKDIR" ] && WORKDIR="$WORKDIR-$(date +%H%M%S)"

mkdir -p "$WORKDIR"
git -C "$WORKDIR" init -q -b main

log "phase 2: building in $WORKDIR (model=$BUILD_MODEL)"

BUILD_PROMPT="$(mktemp -t gb-build)"
python3 - "$ROOT/prompts/build.md" "$ROOT/state/last-spec.json" "$BUILD_PROMPT" <<'PY'
import json, sys
tmpl_path, spec_path, out_path = sys.argv[1:4]
tmpl = open(tmpl_path, encoding="utf-8").read()
spec = json.load(open(spec_path, encoding="utf-8"))
lines = [
    "Title: %s" % spec["title"],
    "Repo name: %s" % spec["slug"],
    "Pitch: %s" % spec["pitch"],
    "Built against: %s (%s, announced %s)" % (
        spec["trigger"], spec.get("trigger_url", "no url"), spec.get("trigger_date", "unknown")),
    "Why now: %s" % spec.get("why_now", ""),
    "Stack: %s" % spec["stack"],
    "",
    "Features (all of these must work):",
]
lines += ["  %d. %s" % (i, f) for i, f in enumerate(spec["features"], 1)]
lines += ["", "Smoke test command (must exist and exit 0): %s" % spec["smoke_test"]]
open(out_path, "w", encoding="utf-8").write(tmpl.replace("{{SPEC}}", "\n".join(lines)))
PY

BUILD_OK=1
BUILD_SUMMARY=""
if BUILD_SUMMARY="$(ask_claude "$BUILD_MODEL" "$BUILD_BUDGET_USD" "$BUILD_TIMEOUT" "$WORKDIR" "$BUILD_PROMPT")"; then
  log "build phase returned"
else
  BUILD_OK=0
  log "build phase failed or timed out"
fi

# ------------------------------------------------------------- 3. verify ----

SMOKE_OK=0
SMOKE_OUT=""
if [ "$BUILD_OK" = "1" ]; then
  if [ -z "$(ls -A "$WORKDIR" 2>/dev/null | grep -v '^\.git$' || true)" ]; then
    log "verify: build directory is empty, nothing was produced"
  else
    log "verify: running smoke test -> $SMOKE"
    if SMOKE_OUT="$(cd "$WORKDIR" && run_limited 300 bash -lc "$SMOKE" 2>&1)"; then
      SMOKE_OK=1
      log "verify: smoke test PASSED"
    else
      log "verify: smoke test FAILED"
    fi
  fi
fi

# ------------------------------------------------------------ 4. publish ----

REPO_URL=""
PUSHED=0
if [ "$SMOKE_OK" = "1" ]; then
  git -C "$WORKDIR" add -A
  git -C "$WORKDIR" \
      -c user.name="$(git config --global user.name)" \
      -c user.email="$(git config --global user.email)" \
      commit -q -m "feat: $TITLE

Built overnight against: $TRIGGER

$PITCH" || log "publish: nothing to commit"

  if [ "$NO_PUSH" = "1" ]; then
    log "publish: NO_PUSH=1, staying local"
  else
    log "publish: creating GitHub repo $REPO_NAME ($REPO_VISIBILITY)"
    DESC="$(printf '%s' "$PITCH" | cut -c1-340)"
    if (cd "$WORKDIR" && gh repo create "$REPO_NAME" \
          --"$REPO_VISIBILITY" --source=. --remote=origin --push \
          --description "$DESC" >>"$LOG" 2>&1); then
      PUSHED=1
      REPO_URL="$(gh repo view "$REPO_NAME" --json url -q .url 2>/dev/null || echo "")"
      log "publish: pushed to $REPO_URL"
    else
      log "publish: gh repo create failed — see $LOG. Code is committed locally."
    fi
  fi
else
  log "publish: SKIPPED (smoke test did not pass). Nothing was pushed."
fi

# ------------------------------------------------------------- 5. record ----

if [ "$SMOKE_OK" = "1" ]; then
  python3 - "$HISTORY" "$ROOT/state/last-spec.json" "$DATE" "$REPO_URL" <<'PY'
import json, sys
hist_path, spec_path, date, url = sys.argv[1:5]
hist = json.load(open(hist_path, encoding="utf-8"))
spec = json.load(open(spec_path, encoding="utf-8"))
hist.append({
    "date": date, "slug": spec["slug"], "title": spec["title"],
    "trigger": spec["trigger"], "trigger_url": spec.get("trigger_url", ""),
    "pitch": spec["pitch"], "repo_url": url,
})
json.dump(hist, open(hist_path, "w", encoding="utf-8"), indent=2)
PY
  log "recorded in history"
fi

# ------------------------------------------------------------- 6. report ----

{
  echo "# $DATE — $TITLE"
  echo
  if [ "$SMOKE_OK" = "1" ] && [ "$PUSHED" = "1" ]; then
    echo "**Shipped.** ${REPO_URL:-pushed}"
  elif [ "$SMOKE_OK" = "1" ]; then
    echo "**Built and committed locally** (not pushed)."
  else
    echo "**Did not ship.** The build failed verification, so nothing was pushed."
  fi
  echo
  echo "## The idea"
  echo
  python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))
print("- **Pitch:** %s" % s["pitch"])
print("- **Built against:** %s" % s["trigger"])
if s.get("trigger_url"):
    print("- **Source:** %s" % s["trigger_url"])
if s.get("trigger_date"):
    print("- **Announced:** %s" % s["trigger_date"])
print("- **Stack:** %s" % s["stack"])
print()
print("**Why now:** %s" % s.get("why_now", "n/a"))
print()
print("**Features:**")
for f in s["features"]:
    print("- %s" % f)
' "$ROOT/state/last-spec.json"
  echo
  echo "## Verification"
  echo
  echo '```'
  echo "\$ $SMOKE"
  printf '%s\n' "${SMOKE_OUT:-(not run)}" | tail -40
  echo '```'
  echo
  if [ "$SMOKE_OK" = "1" ]; then echo "Result: **passed**"; else echo "Result: **failed**"; fi
  echo
  if [ -f "$WORKDIR/BUILD_NOTES.md" ]; then
    echo "## Build notes"
    echo
    cat "$WORKDIR/BUILD_NOTES.md"
    echo
  fi
  echo "## Where it lives"
  echo
  echo "- Local: \`$WORKDIR\`"
  [ -n "$REPO_URL" ] && echo "- Remote: $REPO_URL"
  echo "- Log: \`$LOG\`"
  echo
  echo "---"
  echo
  echo "_Agent summary:_ ${BUILD_SUMMARY:-(none)}"
} > "$REPORT"

log "report written to $REPORT"

if [ "$SMOKE_OK" = "1" ]; then
  notify "git-builder shipped" "$TITLE"
else
  notify "git-builder needs you" "$TITLE failed verification"
fi

rm -f "$SCOUT_PROMPT" "$BUILD_PROMPT"
log "=== done ==="

[ "$SMOKE_OK" = "1" ] || exit 1

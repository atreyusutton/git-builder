#!/usr/bin/env bash
#
# Show last night's build. Run with no arguments for the most recent report,
# or pass a date:  bin/morning.sh 2026-08-30
#
# Flags:
#   -l, --list    list all reports
#   -o, --open    also open the pushed repo in a browser

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORTS="$ROOT/reports"

OPEN=0
WANT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -l|--list)
      if [ -d "$REPORTS" ] && ls "$REPORTS"/*.md >/dev/null 2>&1; then
        for f in "$REPORTS"/*.md; do
          printf '%s  %s\n' "$(basename "$f" .md)" "$(head -1 "$f" | sed 's/^# //')"
        done
      else
        echo "No reports yet."
      fi
      exit 0
      ;;
    -o|--open) OPEN=1; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) WANT="$1"; shift ;;
  esac
done

if [ -n "$WANT" ]; then
  REPORT="$REPORTS/$WANT.md"
  [ -f "$REPORT" ] || { echo "No report for $WANT. Try: bin/morning.sh --list"; exit 1; }
else
  REPORT="$(ls -1 "$REPORTS"/*.md 2>/dev/null | tail -1 || true)"
  [ -n "$REPORT" ] || { echo "No reports yet. Run bin/nightly.sh once, or wait for tonight."; exit 1; }
fi

# Render with glow/bat if available, otherwise plain.
if command -v glow >/dev/null 2>&1; then
  glow -w 100 "$REPORT"
elif command -v bat >/dev/null 2>&1; then
  bat --style=plain --language=markdown "$REPORT"
else
  cat "$REPORT"
fi

if [ "$OPEN" = "1" ]; then
  URL="$(grep -o 'https://github.com/[^ )]*' "$REPORT" | head -1 || true)"
  if [ -n "$URL" ]; then
    echo
    echo "Opening $URL"
    open "$URL"
  else
    echo
    echo "No repo URL in that report (build may not have shipped)."
  fi
fi

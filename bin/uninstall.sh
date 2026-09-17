#!/usr/bin/env bash
#
# Remove the nightly launchd job. Leaves builds, reports and history alone.

set -euo pipefail

LABEL="com.atreyusutton.git-builder"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed $LABEL"
else
  echo "$LABEL is not installed (no plist at $PLIST)"
fi

echo "Your builds, reports and history.json were left untouched."

#!/usr/bin/env bash
#
# Install the nightly launchd job. Runs at RUN_HOUR:RUN_MINUTE local time.
# If the Mac is asleep at that time, launchd runs the job when it next wakes.
#
#   bin/install.sh            # install at the default 02:30
#   RUN_HOUR=3 bin/install.sh # install at 03:00

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.atreyusutton.git-builder"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

RUN_HOUR="${RUN_HOUR:-2}"
RUN_MINUTE="${RUN_MINUTE:-30}"

chmod +x "$ROOT/bin/nightly.sh" "$ROOT/bin/morning.sh" "$ROOT/bin/uninstall.sh"

mkdir -p "$HOME/Library/LaunchAgents" "$ROOT/logs"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>exec "$ROOT/bin/nightly.sh"</string>
  </array>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>$RUN_HOUR</integer>
    <key>Minute</key><integer>$RUN_MINUTE</integer>
  </dict>

  <key>WorkingDirectory</key>
  <string>$ROOT</string>

  <key>StandardOutPath</key>
  <string>$ROOT/logs/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$ROOT/logs/launchd.err.log</string>

  <key>RunAtLoad</key>
  <false/>
  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
PLIST_EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

printf 'Installed %s\n' "$LABEL"
printf 'Scheduled for %02d:%02d local time, nightly.\n' "$RUN_HOUR" "$RUN_MINUTE"
printf 'Plist: %s\n\n' "$PLIST"
printf 'Verify:   launchctl list | grep git-builder\n'
printf 'Run now:  launchctl start %s\n' "$LABEL"
printf 'Remove:   bin/uninstall.sh\n'

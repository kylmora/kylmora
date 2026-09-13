#!/bin/bash
#
# Measures Kylmora's launch time, its own memory footprint, and the WebKit
# processes it is responsible for.
#
# WebKit's content, network and GPU processes are XPC services parented to
# launchd, and macOS exposes no public way to ask which client started one. So
# they are attributed by controlled diff: the set of system WebKit processes is
# recorded with Kylmora not running, then again while it runs, and only the new
# ones are counted. Close other apps that use the system WebKit (Safari, Mail,
# anything with a web view) before trusting the numbers.

set -euo pipefail

APP="${1:-build/Kylmora.app}"
SETTLE="${SETTLE:-8}"

webkit_pids() {
    pgrep -f "System/Library/Frameworks/WebKit.framework.*XPCServices" || true
}

footprint() {
    # vmmap reports the same "physical footprint" the kernel uses for limits.
    vmmap --summary "$1" 2>/dev/null | awk -F: '/Physical footprint:/ {gsub(/ /,"",$2); print $2; exit}'
}

# Sandboxed builds relocate Application Support into the app container.
CONTAINER="$HOME/Library/Containers/com.kylmora.Kylmora/Data/Library/Application Support/com.kylmora.Kylmora"
PLAIN="$HOME/Library/Application Support/com.kylmora.Kylmora"
LOG="$CONTAINER/measurements.log"
[ -f "$LOG" ] || LOG="$PLAIN/measurements.log"

echo "== baseline (Kylmora not running) =="
osascript -e 'quit app "Kylmora"' 2>/dev/null || true
sleep 3
rm -f "$LOG"
BEFORE=$(webkit_pids | sort -u)
echo "system WebKit processes already running: $(echo "$BEFORE" | grep -c . || true)"

echo
echo "== launching =="
defaults write com.kylmora.Kylmora KylmoraMeasurementLogging -bool YES
open "$APP"
sleep "$SETTLE"

KYLMORA_PID=$(pgrep -f "$(basename "$APP" .app)$" | head -1)
if [ -z "$KYLMORA_PID" ]; then
    echo "Kylmora did not start" >&2
    exit 1
fi

echo "launch timing (from the kernel's exec timestamp):"
tail -3 "$LOG" 2>/dev/null | sed 's/^/  /' || echo "  nothing logged"

echo
echo "== memory =="
printf 'browser UI process (pid %s): %s\n' "$KYLMORA_PID" "$(footprint "$KYLMORA_PID")"

AFTER=$(webkit_pids | sort -u)
NEW=$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") || true)

if [ -z "$NEW" ]; then
    echo "no new WebKit processes appeared"
else
    echo "WebKit processes started by Kylmora:"
    for pid in $NEW; do
        name=$(ps -o comm= -p "$pid" | xargs basename)
        printf '  %-34s pid %-7s %s\n' "$name" "$pid" "$(footprint "$pid")"
    done
fi

echo
echo "== bundle =="
du -sh "$APP"

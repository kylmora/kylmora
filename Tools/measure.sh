#!/bin/bash
#
# Measures Kylmora's launch time and what the whole browser costs in memory.
#
# The headline number is the TOTAL: the UI process plus every WebKit process
# working for it. Kylmora's own process alone is a fraction of what the browser
# costs, because pages render in WebKit content, network and GPU processes that
# are XPC services parented to launchd. Quoting the browser process on its own
# is true and still gives the wrong impression, which is how the website came
# to publish a memory figure a reader could not reconcile with Activity Monitor.
#
# Attribution is by client bundle id, not by diffing the process list. Each
# WebKit service writes its client's bundle id into its own cache and temp
# directory names -- com.apple.WebKit.GPU+com.kylmora.Kylmora for the services,
# Caches/com.kylmora.Kylmora for the content process -- so lsof says which app
# a service belongs to, exactly. The old before-and-after diff mis-attributed
# any service that started or lingered during the run, and silently dropped
# ones that were already warm.

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

# A fresh start, so the launch timing is a launch and not a re-activation.
# Attribution no longer needs a baseline, but the app does need to be stopped:
# `open` on a running app just brings its window forward and logs nothing.
echo "== stopping any running copy =="
osascript -e 'quit app "Kylmora"' 2>/dev/null || true
sleep 3
pkill -x Kylmora 2>/dev/null || true
sleep 2
rm -f "$LOG"

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

BID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null \
      || echo com.kylmora.Kylmora)

# "428.7M" -> 428.7, so the parts can be added up. Megabytes throughout.
as_mb() {
    awk -v s="$1" 'BEGIN {
        u = substr(s, length(s));
        v = substr(s, 1, length(s) - 1) + 0;
        if (u == "K") v /= 1024; else if (u == "G") v *= 1024;
        printf "%.1f", v;
    }'
}

total=$(as_mb "$(footprint "$KYLMORA_PID")")

echo "WebKit processes belonging to $BID:"
found=0
for pid in $(webkit_pids); do
    lsof -p "$pid" 2>/dev/null | grep -qE "[+/]${BID}[/+]" || continue
    f=$(footprint "$pid")
    [ -z "$f" ] && continue
    found=1
    name=$(ps -o comm= -p "$pid" | xargs basename)
    total=$(awk -v a="$total" -v b="$(as_mb "$f")" 'BEGIN { printf "%.1f", a + b }')
    printf '  %-34s pid %-7s %s\n' "$name" "$pid" "$f"
done
[ "$found" = 0 ] && echo "  none"

echo
printf 'TOTAL, whole browser: %s MB\n' "$total"
echo "(The UI process plus every WebKit process above. This is the number to quote.)"

echo
echo "== bundle =="
du -sh "$APP"
printf 'architectures: %s\n' "$(lipo -archs "$APP/Contents/MacOS/$(basename "$APP" .app)" 2>/dev/null || echo unknown)"

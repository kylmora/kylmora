#!/bin/bash
# Submits one artifact to Apple's notary service, waits for a verdict, and
# staples the ticket to it.
#
#   Tools/notarize.sh build/Kylmora.app        # zipped for upload, stapled in place
#   Tools/notarize.sh build/Kylmora.dmg
#
# Requires APPLE_ID, APPLE_APP_PASSWORD and APPLE_TEAM_ID in the environment.
#
# The wait is deliberately uncapped. Apple's queue has no ceiling and capping it
# here only turns a slow submission into a failed build; the one limit that
# matters is GitHub's own six-hour job limit, and hitting that is the honest
# signal that Apple is stuck rather than slow.
#
# Unlike a bare `notarytool submit --wait`, this prints the submission ID before
# blocking, so a stalled submission can be chased by hand while the job waits.
# On rejection it prints Apple's log, which names the offending binary —
# otherwise all you get is "Invalid".
set -euo pipefail

ARTIFACT="${1:?usage: notarize.sh <path to .app or .dmg>}"

for var in APPLE_ID APPLE_APP_PASSWORD APPLE_TEAM_ID; do
    if [ -z "${!var:-}" ]; then
        echo "notarize: $var is not set" >&2
        exit 1
    fi
done

CREDS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")

# A bundle has to be zipped to be uploaded; a disk image is sent as-is.
if [[ "$ARTIFACT" == *.app ]]; then
    UPLOAD="${TMPDIR:-/tmp}/$(basename "$ARTIFACT").zip"
    ditto -c -k --keepParent "$ARTIFACT" "$UPLOAD"
else
    UPLOAD="$ARTIFACT"
fi

echo "notarize: uploading $(du -h "$UPLOAD" | cut -f1) to Apple..."
SUBMISSION_ID=$(
    xcrun notarytool submit "$UPLOAD" "${CREDS[@]}" --output-format json \
        | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
)
echo "notarize: submission $SUBMISSION_ID — waiting for Apple"

# Poll rather than one blocking `wait`. A runner losing its network for a
# moment used to read as a refusal and threw away hours of queueing; here only
# a real verdict ends the loop, and a connection error is just retried. Exit 2
# marks that as infrastructure, distinct from exit 1 for an actual rejection.
UNREACHABLE=0
while true; do
    if INFO=$(xcrun notarytool info "$SUBMISSION_ID" "${CREDS[@]}" \
                  --output-format json 2>/dev/null); then
        UNREACHABLE=0
        STATUS=$(printf '%s' "$INFO" \
            | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
        [ "$STATUS" = "In Progress" ] || break
    else
        UNREACHABLE=$((UNREACHABLE + 1))
        echo "notarize: cannot reach Apple (${UNREACHABLE}/30) — retrying in 60s"
        if [ "$UNREACHABLE" -ge 30 ]; then
            echo "notarize: no route to Apple for 30 minutes — giving up" >&2
            exit 2
        fi
    fi
    sleep 60
done

if [ "$STATUS" != "Accepted" ]; then
    echo "notarize: $STATUS — Apple's log follows" >&2
    xcrun notarytool log "$SUBMISSION_ID" "${CREDS[@]}" >&2 || true
    exit 1
fi

xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
echo "notarize: $ARTIFACT is notarized and stapled"

#!/bin/bash
# Talks to Apple's notary service. Split into subcommands because notarisation
# has no guaranteed ceiling — Apple's queue has held this team's submissions for
# hours — and a CI job cannot block that long: GitHub kills any job at six.
#
# So CI submits in one short job and staples in another, later:
#
#   Tools/notarize.sh submit build/Kylmora.dmg    # prints the submission ID
#   Tools/notarize.sh status <id>                 # Accepted | In Progress | ...
#   Tools/notarize.sh log <id>                    # Apple's verdict, once there is one
#   Tools/notarize.sh staple build/Kylmora.dmg    # attach the ticket
#
# For a local build, where blocking is fine, the whole round trip in one go:
#
#   Tools/notarize.sh run build/Kylmora.app       # zipped for upload, stapled in place
#
# Requires APPLE_ID, APPLE_APP_PASSWORD and APPLE_TEAM_ID in the environment
# (except `staple`, which only needs the network).
set -euo pipefail

COMMAND="${1:?usage: notarize.sh <submit|status|log|staple|run> <artifact or id>}"
TARGET="${2:?usage: notarize.sh $COMMAND <artifact or id>}"

require_credentials() {
    for var in APPLE_ID APPLE_APP_PASSWORD APPLE_TEAM_ID; do
        if [ -z "${!var:-}" ]; then
            echo "notarize: $var is not set" >&2
            exit 1
        fi
    done
    CREDS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD"
           --team-id "$APPLE_TEAM_ID")
}

# A bundle has to be zipped to be uploaded; a disk image is sent as-is.
upload_path_for() {
    local artifact="$1"
    if [[ "$artifact" == *.app ]]; then
        local zip="${TMPDIR:-/tmp}/$(basename "$artifact").zip"
        ditto -c -k --keepParent "$artifact" "$zip"
        echo "$zip"
    else
        echo "$artifact"
    fi
}

json_field() {
    /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"
}

case "$COMMAND" in
    # Hands the artifact to Apple and returns immediately. The submission ID goes
    # to stdout on its own so a caller can capture it; everything else is stderr.
    submit)
        require_credentials
        UPLOAD="$(upload_path_for "$TARGET")"
        echo "notarize: uploading $(du -h "$UPLOAD" | cut -f1) to Apple..." >&2
        xcrun notarytool submit "$UPLOAD" "${CREDS[@]}" --output-format json \
            | json_field id
        ;;

    # One word, so a workflow can branch on it. Anything other than "Accepted"
    # or "In Progress" is a refusal and the log will say why.
    status)
        require_credentials
        xcrun notarytool info "$TARGET" "${CREDS[@]}" --output-format json \
            | json_field status
        ;;

    # Apple only writes a log once it has reached a verdict, so its absence is
    # itself the answer for a submission still sitting in the queue.
    log)
        require_credentials
        xcrun notarytool log "$TARGET" "${CREDS[@]}" \
            || echo "notarize: no log yet — Apple has not finished processing $TARGET"
        ;;

    # Writes the ticket into the artifact so it validates on a machine that is
    # offline. Needs no credentials: the ticket is public once it exists.
    staple)
        xcrun stapler staple "$TARGET"
        xcrun stapler validate "$TARGET"
        echo "notarize: $TARGET is notarized and stapled"
        ;;

    # The old blocking behaviour, kept for local builds where waiting is fine.
    run)
        require_credentials
        UPLOAD="$(upload_path_for "$TARGET")"
        echo "notarize: uploading $(du -h "$UPLOAD" | cut -f1) to Apple..." >&2
        SUBMISSION_ID=$(
            xcrun notarytool submit "$UPLOAD" "${CREDS[@]}" --output-format json \
                | json_field id
        )
        echo "notarize: submission $SUBMISSION_ID — waiting up to ${NOTARY_TIMEOUT:-2h}" >&2
        if ! xcrun notarytool wait "$SUBMISSION_ID" "${CREDS[@]}" \
                --timeout "${NOTARY_TIMEOUT:-2h}"; then
            echo "notarize: not accepted — Apple's log follows" >&2
            xcrun notarytool log "$SUBMISSION_ID" "${CREDS[@]}" >&2 || true
            exit 1
        fi
        "$0" staple "$TARGET"
        ;;

    *)
        echo "notarize: unknown command '$COMMAND'" >&2
        exit 1
        ;;
esac

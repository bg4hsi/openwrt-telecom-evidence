#!/bin/sh
set -u

BASE_DIR="${BASE_DIR:-/root/telecom-evidence}"
MAIN_SCRIPT="${MAIN_SCRIPT:-/usr/bin/telecom-evidence.sh}"

SH_DAY="$(TZ=Asia/Shanghai date +%F)"
SH_HM="$(TZ=Asia/Shanghai date +%H%M)"

case "$SH_HM" in
    ''|*[!0-9]*)
        exit 1
        ;;
esac

[ "$SH_HM" -ge 2030 ] || exit 0

MARKDIR="$BASE_DIR/.scheduler"
mkdir -p "$MARKDIR" || exit 1

DONE_MARK="$MARKDIR/$SH_DAY.done"
FAILED_MARK="$MARKDIR/$SH_DAY.failed"

[ -e "$DONE_MARK" ] && exit 0

STARTED_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

"$MAIN_SCRIPT"
RC=$?

FINALDIR=""

for d in "$BASE_DIR/$SH_DAY"/*
do
    [ -d "$d" ] || continue

    case "$(basename "$d")" in
        .inprogress_*)
            continue
            ;;
    esac

    if [ -s "$d/90_summary.txt" ] &&
       [ -s "$d/SHA256SUMS.txt" ]; then
        FINALDIR="$d"
    fi
done

if [ "$RC" -eq 0 ] && [ -n "$FINALDIR" ]; then
    TMP_MARK="$DONE_MARK.tmp.$$"

    {
        echo "started_utc=$STARTED_UTC"
        echo "completed_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "completed_shanghai=$(TZ=Asia/Shanghai date '+%Y-%m-%dT%H:%M:%S%z')"
        echo "target_time=20:30 Asia/Shanghai"
        echo "script_exit_code=$RC"
        echo "final_directory=$FINALDIR"
        echo "summary_sha256=$(sha256sum "$FINALDIR/90_summary.txt" | awk '{print $1}')"
        echo "manifest_sha256=$(sha256sum "$FINALDIR/SHA256SUMS.txt" | awk '{print $1}')"
    } > "$TMP_MARK" || exit 1

    mv "$TMP_MARK" "$DONE_MARK" || exit 1
    rm -f "$FAILED_MARK"

    exit 0
fi

[ "$RC" -ne 0 ] || RC=3

TMP_MARK="$FAILED_MARK.tmp.$$"

{
    echo "started_utc=$STARTED_UTC"
    echo "failed_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "failed_shanghai=$(TZ=Asia/Shanghai date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "target_time=20:30 Asia/Shanghai"
    echo "script_exit_code=$RC"
    echo "final_directory=${FINALDIR:-NONE}"
    echo "reason=no_valid_finalized_evidence_directory"
    echo "retry_allowed=yes"
} > "$TMP_MARK"

mv "$TMP_MARK" "$FAILED_MARK"

exit "$RC"

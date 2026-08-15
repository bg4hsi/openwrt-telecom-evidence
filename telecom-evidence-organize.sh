#!/bin/sh
# shellcheck disable=SC2029,SC2086
set -u

CONF="/etc/telecom-evidence-organizer.conf"
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

BASE_DIR="${BASE_DIR:-/root/telecom-evidence}"
EXPORT_ROOT="${EXPORT_ROOT:-/root/telecom-evidence-export}"
VPS_HOST="${VPS_HOST:-}"
VPS_USER="${VPS_USER:-root}"
VPS_DIR="${VPS_DIR:-/root/telecom-evidence-backup}"
SSH_KEY="${SSH_KEY:-/root/.ssh/telecom_evidence_backup_key}"
LOCK="/tmp/telecom-evidence-organizer.lock"
LOG="/tmp/telecom-evidence-organizer-last.log"

mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT INT TERM

exec >"$LOG" 2>&1

echo "===== ORGANIZER START ====="
date
date -u

# OpenWrt often lacks zoneinfo. Compute Shanghai time from UTC epoch directly.
sh_date() {
    _fmt="$1"
    _now="$(date -u +%s 2>/dev/null)"
    case "$_now" in ''|*[!0-9]*) return 1 ;; esac
    _sh=$((_now + 28800))
    date -u -d "@$_sh" "$_fmt" 2>/dev/null
}

SH_DAY="$(sh_date +%F)" || {
    echo "ERROR: BusyBox date cannot calculate Shanghai date from epoch"
    exit 1
}
SH_HM="$(sh_date +%H%M)" || exit 1
SH_ISO="$(sh_date +%Y-%m-%dT%H:%M:%S+08:00)" || exit 1

echo "shanghai_day=$SH_DAY"
echo "shanghai_time=$SH_ISO"

case "$SH_HM" in ''|*[!0-9]*) exit 1 ;; esac
# Main collection normally begins around 04:30 Shanghai. Never organize before 04:40.
[ "$SH_HM" -ge 0440 ] || {
    echo "too_early=yes"
    exit 0
}

DAYDIR="$BASE_DIR/$SH_DAY"
[ -d "$DAYDIR" ] || {
    echo "no_day_directory=$DAYDIR"
    exit 0
}

FINALDIR=""
for d in "$DAYDIR"/*; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in .inprogress_*) continue ;; esac
    if [ -s "$d/90_summary.txt" ] && [ -s "$d/SHA256SUMS.txt" ]; then
        FINALDIR="$d"
    fi
done

[ -n "$FINALDIR" ] || {
    echo "no_finalized_directory=yes"
    exit 0
}

OUTDIR="$EXPORT_ROOT/$SH_DAY"
COMPLETE="$OUTDIR/.complete"
if [ -s "$COMPLETE" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "already_processed=$OUTDIR"
    exit 0
fi

mkdir -p "$OUTDIR" "$EXPORT_ROOT/weekly" || exit 1
TMP="$OUTDIR/.tmp.$$"
mkdir -p "$TMP" || exit 1
trap 'rm -rf "$TMP" 2>/dev/null || true; rmdir "$LOCK" 2>/dev/null || true' EXIT INT TERM

SRCBASE="$(basename "$FINALDIR")"
VERIFY="$TMP/source-sha256-check.txt"
(
    cd "$FINALDIR" || exit 1
    sha256sum -c SHA256SUMS.txt
) >"$VERIFY" 2>&1
VERIFY_RC=$?

if [ "$VERIFY_RC" -ne 0 ]; then
    echo "SOURCE HASH VERIFICATION FAILED"
    cat "$VERIFY"
    cp "$VERIFY" "$OUTDIR/source-sha256-check-FAILED.txt" 2>/dev/null || true
    exit 2
fi

ARCHIVE_TMP="$TMP/evidence-$SH_DAY.tar.gz"
ARCHIVE="$OUTDIR/evidence-$SH_DAY.tar.gz"
ARCHIVE_SHA="$OUTDIR/evidence-$SH_DAY.tar.gz.sha256"
REPORT="$OUTDIR/daily-report.txt"
METRICS="$OUTDIR/daily-metrics.txt"

# Archive the untouched finalized source directory.
tar -C "$DAYDIR" -czf "$ARCHIVE_TMP" "$SRCBASE" || exit 3
mv "$ARCHIVE_TMP" "$ARCHIVE" || exit 3
( cd "$OUTDIR" && sha256sum "evidence-$SH_DAY.tar.gz" > "evidence-$SH_DAY.tar.gz.sha256" ) || exit 3

HTTP_BPS="$(sed -n 's/^speed_upload_Bps=//p' "$FINALDIR/51_http_put_upload.txt" 2>/dev/null | tail -n1)"
HTTPS_BPS="$(sed -n 's/^speed_upload_Bps=//p' "$FINALDIR/52_https_put_upload.txt" 2>/dev/null | tail -n1)"
WAN_IP="$(sed -n '1{s/[[:space:]]//g;p;}' "$FINALDIR/10_public_ip.txt" 2>/dev/null)"

bps_to_mbps() {
    _v="$1"
    case "$_v" in ''|*[!0-9.]*) echo "NA" ;; *) awk -v b="$_v" 'BEGIN{printf "%.3f",b*8/1000000}' ;; esac
}
HTTP_MBPS="$(bps_to_mbps "$HTTP_BPS")"
HTTPS_MBPS="$(bps_to_mbps "$HTTPS_BPS")"

PREV_SHA="NONE"
_now="$(date -u +%s)"
_prev=$((_now + 28800 - 86400))
PREV_DAY="$(date -u -d "@$_prev" +%F 2>/dev/null || true)"
if [ -n "$PREV_DAY" ] && [ -r "$EXPORT_ROOT/$PREV_DAY/evidence-$PREV_DAY.tar.gz.sha256" ]; then
    PREV_SHA="$(awk '{print $1; exit}' "$EXPORT_ROOT/$PREV_DAY/evidence-$PREV_DAY.tar.gz.sha256")"
fi

{
    echo "evidence_day_shanghai=$SH_DAY"
    echo "organized_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "organized_shanghai=$SH_ISO"
    echo "source_directory=$FINALDIR"
    echo "source_summary_sha256=$(sha256sum "$FINALDIR/90_summary.txt" | awk '{print $1}')"
    echo "source_manifest_sha256=$(sha256sum "$FINALDIR/SHA256SUMS.txt" | awk '{print $1}')"
    echo "source_hash_verification=PASS"
    echo "archive_sha256=$(awk '{print $1}' "$ARCHIVE_SHA")"
    echo "previous_day_archive_sha256=$PREV_SHA"
    echo "wan_ipv4=${WAN_IP:-UNKNOWN}"
    echo "http_upload_mbps=$HTTP_MBPS"
    echo "https_upload_mbps=$HTTPS_MBPS"
} > "$METRICS"

{
    echo "===== DAILY EVIDENCE REPORT ====="
    cat "$METRICS"
    echo
    echo "===== SOURCE HASH CHECK ====="
    cat "$VERIFY"
    echo
    echo "===== ORIGINAL 90_summary.txt ====="
    cat "$FINALDIR/90_summary.txt"
    echo
    echo "===== HTTP UPLOAD RAW RESULT ====="
    cat "$FINALDIR/51_http_put_upload.txt" 2>/dev/null || echo "MISSING"
    echo
    echo "===== HTTPS UPLOAD RAW RESULT ====="
    cat "$FINALDIR/52_https_put_upload.txt" 2>/dev/null || echo "MISSING"
    echo
    echo "===== HTTP SERVER RECEIPT ====="
    cat "$FINALDIR/51_http_receipt.json" 2>/dev/null || echo "MISSING"
    echo
    echo "===== HTTPS SERVER RECEIPT ====="
    cat "$FINALDIR/52_https_receipt.json" 2>/dev/null || echo "MISSING"
} > "$REPORT"

cp "$VERIFY" "$OUTDIR/source-sha256-check.txt"

# Build a rolling 7-day summary from immutable daily metrics.
ROLL="$EXPORT_ROOT/weekly/rolling-7day-$SH_DAY.txt"
{
    echo "===== ROLLING 7-DAY EVIDENCE SUMMARY ====="
    echo "generated_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "through_shanghai_day=$SH_DAY"
    echo
    i=6
    while [ "$i" -ge 0 ]; do
        _ts=$((_now + 28800 - i*86400))
        _day="$(date -u -d "@$_ts" +%F 2>/dev/null || true)"
        if [ -n "$_day" ] && [ -r "$EXPORT_ROOT/$_day/daily-metrics.txt" ]; then
            echo "### $_day"
            grep -E '^(wan_ipv4|http_upload_mbps|https_upload_mbps|archive_sha256|source_hash_verification)=' "$EXPORT_ROOT/$_day/daily-metrics.txt"
            echo
        fi
        i=$((i-1))
    done
} > "$ROLL"

# Seal generated export files. .complete is written last.
sha256sum "$REPORT" "$METRICS" "$OUTDIR/source-sha256-check.txt" "$ROLL" > "$OUTDIR/export-files.sha256"
chmod 444 "$ARCHIVE" "$ARCHIVE_SHA" "$REPORT" "$METRICS" "$OUTDIR/source-sha256-check.txt" "$OUTDIR/export-files.sha256" "$ROLL" 2>/dev/null || true

BACKUP_STATUS="SKIPPED_NOT_CONFIGURED"
if [ -n "$VPS_HOST" ]; then
  BACKUP_STATUS="SKIPPED_NO_PASSWORDLESS_SSH"
fi
if [ -n "$VPS_HOST" ] && command -v ssh >/dev/null 2>&1 && command -v scp >/dev/null 2>&1 && [ -r "$SSH_KEY" ]; then
    SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=8"
    # Intentional splitting: BusyBox sh has no arrays and SSH_OPTS is internal.
    if ssh $SSH_OPTS "$VPS_USER@$VPS_HOST" "mkdir -p '$VPS_DIR/$SH_DAY' '$VPS_DIR/weekly'" >/dev/null 2>&1; then
        if scp -q -i "$SSH_KEY" \
            "$ARCHIVE" "$ARCHIVE_SHA" "$REPORT" "$METRICS" "$OUTDIR/source-sha256-check.txt" "$OUTDIR/export-files.sha256" \
            "$VPS_USER@$VPS_HOST:$VPS_DIR/$SH_DAY/" >/dev/null 2>&1 && \
           scp -q -i "$SSH_KEY" "$ROLL" "$VPS_USER@$VPS_HOST:$VPS_DIR/weekly/" >/dev/null 2>&1 && \
           ssh $SSH_OPTS "$VPS_USER@$VPS_HOST" "cd '$VPS_DIR/$SH_DAY' && sha256sum -c 'evidence-$SH_DAY.tar.gz.sha256' >/dev/null" >/dev/null 2>&1; then
            BACKUP_STATUS="PASS"
            ssh $SSH_OPTS "$VPS_USER@$VPS_HOST" "chmod 444 '$VPS_DIR/$SH_DAY/'* '$VPS_DIR/weekly/rolling-7day-$SH_DAY.txt' 2>/dev/null || true" >/dev/null 2>&1 || true
        else
            BACKUP_STATUS="FAILED_TRANSFER_OR_REMOTE_VERIFY"
        fi
    else
        BACKUP_STATUS="FAILED_SSH_AUTH_OR_CONNECT"
    fi
fi

{
    echo "completed_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "evidence_day_shanghai=$SH_DAY"
    echo "source_directory=$FINALDIR"
    echo "backup_status=$BACKUP_STATUS"
    echo "archive_sha256=$(awk '{print $1}' "$ARCHIVE_SHA")"
} > "$COMPLETE"
chmod 444 "$COMPLETE" 2>/dev/null || true

rm -rf "$TMP"
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT INT TERM

echo "===== ORGANIZER COMPLETE ====="
echo "export_directory=$OUTDIR"
echo "backup_status=$BACKUP_STATUS"
echo "rolling_summary=$ROLL"

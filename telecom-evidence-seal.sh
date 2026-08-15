#!/bin/sh
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

CONF="/etc/telecom-evidence.conf"
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
BASE_DIR="${BASE_DIR:-/root/telecom-evidence}"
MANUAL="$BASE_DIR/manual"
LEDGER="$BASE_DIR/MANUAL_CHAIN.log"
ALERT="$BASE_DIR/INTEGRITY_ALERT.log"

mkdir -p "$MANUAL" 2>/dev/null || exit 1
chmod 0700 "$MANUAL" 2>/dev/null || true

# Recover known current-session /tmp artifacts exactly once before a reboot can erase them.
# A persistent marker prevents duplicate 32 MB copies on every daily run.
RECOVERY_MARK="$BASE_DIR/.manual_tmp_recovery_done"
REC="$MANUAL/recovered_$(TZ='CST-8' date +%Y-%m-%d)_$(date -u +%H%M%SZ)"
made=0
if [ ! -e "$RECOVERY_MARK" ]; then
  for f in \
    /tmp/evidence-test-32m.bin \
    /tmp/http-receipt.json \
    /tmp/https-receipt.json \
    /tmp/swap-https18080-receipt.json \
    /tmp/swap-http18443-receipt.json
  do
    if [ -f "$f" ]; then
      if [ "$made" -eq 0 ]; then
        mkdir -p "$REC" || exit 1
        made=1
      fi
      b="$(basename "$f")"
      [ -e "$REC/$b" ] || cp -p "$f" "$REC/$b"
    fi
  done
fi

if [ "$made" -eq 1 ]; then
  {
    echo "recovery_reason=known_tmp_evidence_artifacts"
    echo "archived_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "archived_shanghai=$(TZ='CST-8' date '+%Y-%m-%dT%H:%M:%S+08:00')"
    echo "router_local=$(date -R 2>/dev/null || date)"
    echo "server=${TEST_SERVER_IP:-NOT_CONFIGURED}"
    if [ -n "${TEST_SERVER_IP:-}" ]; then
      echo "route:"
      ip route get "$TEST_SERVER_IP" 2>/dev/null || true
    fi
    echo "public_ip:"
    curl -4 -sS --interface "${WAN_IF:-pppoe-wan}" --max-time 15 https://icanhazip.com 2>/dev/null || true
    echo "client_script:"
    sha256sum /usr/bin/telecom-evidence.sh 2>/dev/null || true
    echo "ca:"
    sha256sum /etc/telecom-evidence-vps-ca.pem 2>/dev/null || true
  } > "$REC/metadata.txt"
  {
    echo "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "recovery_dir=$REC"
  } > "$RECOVERY_MARK"
  chmod 0444 "$RECOVERY_MARK" 2>/dev/null || true
elif [ ! -e "$RECOVERY_MARK" ]; then
  # Mark the one-time scan complete even if there was nothing left in /tmp.
  echo "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) no_tmp_artifacts=1" > "$RECOVERY_MARK"
  chmod 0444 "$RECOVERY_MARK" 2>/dev/null || true
fi

# Seal any manual directory that is not yet sealed. Existing manifests are never rewritten.
find "$MANUAL" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | while IFS= read -r d; do
  [ -d "$d" ] || continue
  # Temporarily permit owner write only when a manifest is absent, so we can create it.
  if [ ! -f "$d/SHA256SUMS.txt" ]; then
    chmod u+w "$d" 2>/dev/null || true
    find "$d" -type f -exec chmod u+w {} \; 2>/dev/null || true
    (
      cd "$d" || exit 1
      # shellcheck disable=SC2094
      find . -type f ! -name SHA256SUMS.txt -print | sort | while IFS= read -r f; do
        sha256sum "$f"
      done > SHA256SUMS.txt
    )
  fi
  find "$d" -type f -exec chmod 0444 {} \; 2>/dev/null || true
  find "$d" -type d -exec chmod 0555 {} \; 2>/dev/null || true
done

# Verify every finalized automatic run and every manual seal.
find "$BASE_DIR" -type f -name SHA256SUMS.txt 2>/dev/null | sort | while IFS= read -r m; do
  d="$(dirname "$m")"
  if ! (cd "$d" && sha256sum -c SHA256SUMS.txt >/dev/null 2>&1); then
    printf '%s VERIFY_FAIL path=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$d" >> "$ALERT"
    logger -t telecom-evidence "INTEGRITY VERIFY FAIL: $d" 2>/dev/null || true
  fi
done

# Rebuild the manual chain ONLY if it does not exist yet. Once created, append new manifests only.
if [ ! -f "$LEDGER" ]; then
  : > "$LEDGER"
  prev="NONE_FIRST_MANUAL"
  find "$MANUAL" -mindepth 2 -maxdepth 2 -type f -name SHA256SUMS.txt 2>/dev/null | sort | while IFS= read -r m; do
    cur="$(sha256sum "$m" | awk '{print $1}')"
    printf '%s previous_manifest_sha256=%s current_manifest_sha256=%s path=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$prev" "$cur" "$(dirname "$m")"
    prev="$cur"
  done > "$LEDGER"
else
  # Append any manual manifest hash not already represented by path.
  find "$MANUAL" -mindepth 2 -maxdepth 2 -type f -name SHA256SUMS.txt 2>/dev/null | sort | while IFS= read -r m; do
    d="$(dirname "$m")"
    grep -F "path=$d" "$LEDGER" >/dev/null 2>&1 && continue
    prev="$(tail -1 "$LEDGER" 2>/dev/null | sed -n 's/.*current_manifest_sha256=\([^ ]*\).*/\1/p')"
    [ -n "$prev" ] || prev="UNKNOWN"
    cur="$(sha256sum "$m" | awk '{print $1}')"
    printf '%s previous_manifest_sha256=%s current_manifest_sha256=%s path=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$prev" "$cur" "$d" >> "$LEDGER"
  done
fi
chmod 0600 "$LEDGER" 2>/dev/null || true

exit 0

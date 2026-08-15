#!/bin/sh
set -u

VERSION="1.4.1"
CONF="/etc/telecom-evidence.conf"
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

BASE_DIR="${BASE_DIR:-/root/telecom-evidence}"
WAN_IF="${WAN_IF:-pppoe-wan}"
TEST_SERVER_IP="${TEST_SERVER_IP:-}"
IPERF_HOST="${IPERF_HOST:-$TEST_SERVER_IP}"
IPERF_PORT="${IPERF_PORT:-5201}"
SPEEDTEST_SERVER_IDS="${SPEEDTEST_SERVER_IDS:-}"
HTTP_UPLOAD_URL="${HTTP_UPLOAD_URL:-}"
HTTPS_UPLOAD_URL="${HTTPS_UPLOAD_URL:-}"
HTTPS_CA_FILE="${HTTPS_CA_FILE:-/etc/telecom-evidence-vps-ca.pem}"
TEST_FILE_MB="${TEST_FILE_MB:-32}"
IPERF_SECONDS="${IPERF_SECONDS:-15}"
PCAP_ENABLED="${PCAP_ENABLED:-1}"
PCAP_SNAPLEN="${PCAP_SNAPLEN:-256}"
MIN_FREE_KB="${MIN_FREE_KB:-2097152}"
STRICT_CLEAN_ENV="${STRICT_CLEAN_ENV:-0}"

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

say(){ printf '%s\n' "$*"; }
log(){ logger -t telecom-evidence "$*" 2>/dev/null || true; say "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

check_only=0
[ "${1:-}" = "--check" ] && check_only=1

if [ ! -d "$BASE_DIR" ]; then
  mkdir -p "$BASE_DIR" 2>/dev/null || {
    BASE_DIR="/root/telecom-evidence"
    mkdir -p "$BASE_DIR" || exit 1
  }
fi

if [ "$check_only" -eq 1 ]; then
  say "telecom-evidence v$VERSION"
  say "BASE_DIR=$BASE_DIR"
  say "WAN_IF=$WAN_IF"
  say "TEST_SERVER_IP=$TEST_SERVER_IP"
  for x in date ip ifstatus curl sha256sum df dd awk sed grep find sort speedtest iperf3 tcpdump nft traceroute ping; do
    if have "$x"; then say "OK   $x -> $(command -v "$x")"; else say "MISS $x"; fi
  done
  if have tc; then say "OK   tc -> $(command -v tc)"; else say "INFO tc not installed (qdisc section will be marked unavailable)"; fi
  exit 0
fi

LOCKDIR="/tmp/telecom-evidence.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  log "another evidence run is active; exiting"
  exit 2
fi
# shellcheck disable=SC2329
cleanup_lock(){ rmdir "$LOCKDIR" 2>/dev/null || true; }
trap cleanup_lock EXIT INT TERM

UTC_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# China has no DST; POSIX TZ CST-8 is fixed UTC+8 and does not require tzdata.
SH_DAY="$(TZ='CST-8' date +%Y-%m-%d)"
SH_STAMP="$(TZ='CST-8' date +%Y%m%dT%H%M%S)"
DAYDIR="$BASE_DIR/$SH_DAY"
TMPDIR="$DAYDIR/.inprogress_${UTC_STAMP}_$$"
FINALDIR="$DAYDIR/${UTC_STAMP}_SH${SH_STAMP}"
mkdir -p "$TMPDIR" || exit 1

STATUS=0
WARN=0
PCAP_PID=""
TESTFILE="/tmp/telecom-evidence-test.$$.bin"

# shellcheck disable=SC2329
cleanup_runtime(){
  if [ -n "$PCAP_PID" ]; then kill "$PCAP_PID" 2>/dev/null || true; wait "$PCAP_PID" 2>/dev/null || true; fi
  rm -f "$TESTFILE" 2>/dev/null || true
}
trap 'cleanup_runtime; cleanup_lock' EXIT INT TERM

WAN_IPV4="$(ip -4 -o addr show dev "$WAN_IF" scope global 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}')"

exec_cmd(){
  name="$1"; shift
  (
    echo "# started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# command=$*"
    "$@"
    rc=$?
    echo "# exit_code=$rc"
    echo "# finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    exit "$rc"
  ) >"$TMPDIR/$name" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || STATUS=1
  return "$rc"
}

{
  echo "evidence_script_version=$VERSION"
  echo "run_id=$UTC_STAMP"
  echo "router_local_time_rfc2822=$(date -R 2>/dev/null || date)"
  echo "shanghai_time=$(TZ='CST-8' date '+%Y-%m-%dT%H:%M:%S+08:00')"
  echo "utc_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "epoch=$(date +%s)"
  echo "router_timezone_env=${TZ:-unset}"
  [ -r /etc/TZ ] && echo "router_etc_TZ=$(cat /etc/TZ 2>/dev/null)"
  echo "evidence_day_shanghai=$SH_DAY"
  echo "wan_if=$WAN_IF"
  echo "wan_ipv4=${WAN_IPV4:-UNAVAILABLE}"
  echo "test_server_ip=$TEST_SERVER_IP"
  echo "iperf_host=$IPERF_HOST"
  echo "iperf_port=$IPERF_PORT"
  echo "speedtest_server_ids=$SPEEDTEST_SERVER_IDS"
  echo "http_upload_configured=$([ -n "$HTTP_UPLOAD_URL" ] && echo yes || echo no)"
  echo "https_upload_configured=$([ -n "$HTTPS_UPLOAD_URL" ] && echo yes || echo no)"
  echo "https_ca_file=$HTTPS_CA_FILE"
  if [ -r "$HTTPS_CA_FILE" ] && have sha256sum; then echo "https_ca_sha256=$(sha256sum "$HTTPS_CA_FILE" | awk '{print $1}')"; else echo "https_ca_sha256=UNAVAILABLE"; fi
  echo "test_file_mb=$TEST_FILE_MB"
  echo "pcap_enabled=$PCAP_ENABLED"
  echo "pcap_snaplen=$PCAP_SNAPLEN"
} > "$TMPDIR/00_run_metadata.txt"

if have sha256sum; then
  {
    [ -r "$0" ] && sha256sum "$0"
    [ -r /etc/config/network ] && sha256sum /etc/config/network
    [ -r /etc/config/firewall ] && sha256sum /etc/config/firewall
    [ -r /etc/config/dhcp ] && sha256sum /etc/config/dhcp
    [ -r "$HTTPS_CA_FILE" ] && sha256sum "$HTTPS_CA_FILE"
  } > "$TMPDIR/01_config_hashes.txt" 2>&1
fi

{
  echo "=== system board ==="
  ubus call system board 2>/dev/null || true
  echo "=== uname ==="
  uname -a 2>/dev/null || true
  echo "=== uptime ==="
  uptime 2>/dev/null || true
  echo "=== tool versions ==="
  speedtest --version 2>/dev/null | head -5 || true
  iperf3 --version 2>/dev/null | head -5 || true
  curl --version 2>/dev/null | head -5 || true
  tcpdump --version 2>/dev/null | head -5 || true
} > "$TMPDIR/02_system_versions.txt"

{
  echo "=== ifstatus wan ==="
  ifstatus wan 2>/dev/null || true
  echo "=== wan addr ==="
  ip addr show dev "$WAN_IF" 2>/dev/null || true
  echo "=== wan counters ==="
  ip -s link show dev "$WAN_IF" 2>/dev/null || true
  echo "=== ip rules ==="
  ip rule show 2>/dev/null || true
  echo "=== routes all tables ==="
  ip route show table all 2>/dev/null || true
  echo "=== route to controlled test server ==="
  if [ -z "$TEST_SERVER_IP" ]; then
    echo "not_configured"
  elif [ -n "$WAN_IPV4" ]; then
    ip route get "$TEST_SERVER_IP" from "$WAN_IPV4" 2>/dev/null || true
  else
    ip route get "$TEST_SERVER_IP" 2>/dev/null || true
  fi
  echo "=== qdisc ==="
  if have tc; then
    tc -s qdisc show dev "$WAN_IF" 2>/dev/null || true
  else
    echo "tc_not_installed"
  fi
} > "$TMPDIR/03_network_state.txt"

{
  echo "=== possible traffic modifiers (PID only) ==="
  for p in openvpn xray sing-box singbox hysteria hysteria2 fakehttp FakeHTTP udp2raw clash mihomo zerotier-one tailscaled; do
    if pidof "$p" >/dev/null 2>&1; then
      echo "$p RUNNING pid=$(pidof "$p" 2>/dev/null)"
      WARN=1
    else
      echo "$p not_running"
    fi
  done
  if have wg; then
    echo "wireguard_interfaces=$(wg show interfaces 2>/dev/null)"
  fi
  echo "=== tunnel-like interfaces ==="
  ip -o link show 2>/dev/null | grep -Ei '(^|: )(wg|tun|tap|zt|tailscale|ovpn)' || true
} > "$TMPDIR/04_environment_check.txt"

# Capture the active nftables ruleset for reproducibility; this contains no stored passwords.
if have nft; then
  nft list ruleset > "$TMPDIR/05_nft_ruleset.txt" 2>&1 || true
fi

# Public IP: user's preferred endpoint only.
if have curl; then
  exec_cmd 10_public_ip.txt curl -4 -sS --interface "$WAN_IF" --connect-timeout 10 --max-time 20 https://icanhazip.com || true
fi

# Basic reachability to the controlled test server.
if have ping && [ -n "$TEST_SERVER_IP" ]; then
  exec_cmd 11_ping_test_server.txt ping -c 20 -W 2 "$TEST_SERVER_IP" || true
fi
if have traceroute && [ -n "$TEST_SERVER_IP" ]; then
  exec_cmd 12_traceroute_test_server.txt traceroute -n -w 2 -q 1 "$TEST_SERVER_IP" || true
fi

# Speedtest: fixed server IDs, raw JSON retained. Bind explicitly to WAN interface
# when this Ookla CLI supports --interface. A failed command is retained and flagged.
if have speedtest && [ -n "$SPEEDTEST_SERVER_IDS" ]; then
  if speedtest --help 2>&1 | grep -q -- '--interface'; then
    SPEEDTEST_BIND_SUPPORTED=1
  else
    SPEEDTEST_BIND_SUPPORTED=0
    WARN=1
  fi
  for sid in $SPEEDTEST_SERVER_IDS; do
    {
      echo "# started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "# wan_interface=$WAN_IF"
      echo "# wan_ipv4=${WAN_IPV4:-UNAVAILABLE}"
      echo "# speedtest_interface_bind_supported=$SPEEDTEST_BIND_SUPPORTED"
      if [ "$SPEEDTEST_BIND_SUPPORTED" -eq 1 ]; then
        speedtest --accept-license --accept-gdpr --server-id "$sid" --interface "$WAN_IF" --format=json
      else
        speedtest --accept-license --accept-gdpr --server-id "$sid" --format=json
      fi
      rc=$?
      echo "# exit_code=$rc"
      echo "# finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      [ "$rc" -eq 0 ] || STATUS=1
    } > "$TMPDIR/20_speedtest_server_${sid}.jsonlog" 2>&1
    rc=$?
    [ "$rc" -eq 0 ] || STATUS=1
  done
fi

# iperf3 tests to the same controlled endpoint. Bind to the PPPoE WAN IPv4
# so the source identity is explicit even if tunnel interfaces exist.
if have iperf3 && [ -n "$IPERF_HOST" ]; then
  if [ -n "$WAN_IPV4" ]; then
    exec_cmd 30_iperf_up_1stream.json iperf3 -4 -B "$WAN_IPV4" -c "$IPERF_HOST" -p "$IPERF_PORT" -t "$IPERF_SECONDS" -P 1 -J || true
    exec_cmd 31_iperf_up_4stream.json iperf3 -4 -B "$WAN_IPV4" -c "$IPERF_HOST" -p "$IPERF_PORT" -t "$IPERF_SECONDS" -P 4 -J || true
    exec_cmd 32_iperf_down_1stream.json iperf3 -4 -B "$WAN_IPV4" -c "$IPERF_HOST" -p "$IPERF_PORT" -t "$IPERF_SECONDS" -P 1 -R -J || true
  else
    WARN=1
    exec_cmd 30_iperf_up_1stream.json iperf3 -4 -c "$IPERF_HOST" -p "$IPERF_PORT" -t "$IPERF_SECONDS" -P 1 -J || true
    exec_cmd 31_iperf_up_4stream.json iperf3 -4 -c "$IPERF_HOST" -p "$IPERF_PORT" -t "$IPERF_SECONDS" -P 4 -J || true
    exec_cmd 32_iperf_down_1stream.json iperf3 -4 -c "$IPERF_HOST" -p "$IPERF_PORT" -t "$IPERF_SECONDS" -P 1 -R -J || true
  fi
fi

FREE_KB="$(df -Pk "$BASE_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
case "$FREE_KB" in ''|*[!0-9]*) FREE_KB=0;; esac
{
  echo "free_kb_before_large_tests=$FREE_KB"
  echo "minimum_required_kb=$MIN_FREE_KB"
} > "$TMPDIR/40_storage_check.txt"

CAN_LARGE=1
if [ "$FREE_KB" -lt "$MIN_FREE_KB" ]; then
  CAN_LARGE=0
  WARN=1
  echo "LOW_SPACE: pcap/upload evidence skipped; old evidence was NOT deleted." >> "$TMPDIR/40_storage_check.txt"
fi

if [ "$STRICT_CLEAN_ENV" = "1" ] && [ "$WARN" -ne 0 ]; then
  CAN_LARGE=0
  echo "STRICT_CLEAN_ENV=1 and possible traffic modifiers were detected; large tests skipped." >> "$TMPDIR/40_storage_check.txt"
fi

if [ "$CAN_LARGE" -eq 1 ] && { [ -n "$HTTP_UPLOAD_URL" ] || [ -n "$HTTPS_UPLOAD_URL" ]; }; then
  dd if=/dev/urandom of="$TESTFILE" bs=1M count="$TEST_FILE_MB" 2> "$TMPDIR/41_testfile_generation.txt"
  if [ -f "$TESTFILE" ] && have sha256sum; then
    sha256sum "$TESTFILE" > "$TMPDIR/42_testfile_sha256.txt"
  fi

  if [ "$PCAP_ENABLED" = "1" ] && have tcpdump && [ -n "$TEST_SERVER_IP" ]; then
    tcpdump -i "$WAN_IF" -n -s "$PCAP_SNAPLEN" -U -w "$TMPDIR/50_vps_upload_traffic.pcap" "host $TEST_SERVER_IP" > "$TMPDIR/50_tcpdump_console.txt" 2>&1 &
    PCAP_PID=$!
    sleep 2
  fi

  CURL_FMT='remote_ip=%{remote_ip}\nlocal_ip=%{local_ip}\nhttp_code=%{http_code}\nsize_upload=%{size_upload}\nspeed_upload_Bps=%{speed_upload}\ntime_connect=%{time_connect}\ntime_starttransfer=%{time_starttransfer}\ntime_total=%{time_total}\nssl_verify_result=%{ssl_verify_result}\n'

  if [ -n "$HTTP_UPLOAD_URL" ]; then
    curl -4 --interface "$WAN_IF" --connect-timeout 10 --max-time 600 --retry 0 \
      -o "$TMPDIR/51_http_receipt.json" -sS -T "$TESTFILE" -w "$CURL_FMT" \
      "$HTTP_UPLOAD_URL" > "$TMPDIR/51_http_put_upload.txt" 2>&1 || STATUS=1
  fi
  if [ -n "$HTTPS_UPLOAD_URL" ]; then
    # Certificate verification remains enabled. The dedicated receiver certificate
    # is supplied explicitly with --cacert and is NOT installed into system trust.
    if [ -r "$HTTPS_CA_FILE" ]; then
      curl -4 --interface "$WAN_IF" --connect-timeout 10 --max-time 600 --retry 0 \
        --cacert "$HTTPS_CA_FILE" -o "$TMPDIR/52_https_receipt.json" -sS -T "$TESTFILE" -w "$CURL_FMT" \
        "$HTTPS_UPLOAD_URL" > "$TMPDIR/52_https_put_upload.txt" 2>&1 || STATUS=1
    else
      echo "HTTPS_CA_FILE missing or unreadable: $HTTPS_CA_FILE" > "$TMPDIR/52_https_put_upload.txt"
      STATUS=1
      WARN=1
    fi
  fi

  if [ -n "$PCAP_PID" ]; then
    kill "$PCAP_PID" 2>/dev/null || true
    wait "$PCAP_PID" 2>/dev/null || true
    PCAP_PID=""
  fi
fi

rm -f "$TESTFILE" 2>/dev/null || true

# Cryptographic run chain: current manifest will commit to the previous run manifest hash.
PREV_MANIFEST="$(find "$BASE_DIR" -type f -name SHA256SUMS.txt 2>/dev/null | sort | tail -1)"
{
  echo "chain_version=1"
  echo "current_run_id=$UTC_STAMP"
  if [ -n "$PREV_MANIFEST" ] && [ -r "$PREV_MANIFEST" ]; then
    echo "previous_manifest_path=$PREV_MANIFEST"
    echo "previous_manifest_sha256=$(sha256sum "$PREV_MANIFEST" | awk '{print $1}')"
  else
    echo "previous_manifest_path=NONE_FIRST_RUN"
    echo "previous_manifest_sha256=NONE_FIRST_RUN"
  fi
} > "$TMPDIR/89_chain_link.txt"

{
  echo "run_id=$UTC_STAMP"
  echo "script_version=$VERSION"
  echo "status=$([ "$STATUS" -eq 0 ] && echo COMPLETE_WITHOUT_COMMAND_ERRORS || echo COMPLETE_WITH_SOME_COMMAND_ERRORS)"
  echo "environment_warning=$WARN"
  echo "finalized_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "finalized_shanghai=$(TZ='CST-8' date '+%Y-%m-%dT%H:%M:%S+08:00')"
  echo "environment_class=$([ "$WARN" -eq 0 ] && echo NO_COMMON_MODIFIER_DETECTED || echo POTENTIAL_TRAFFIC_MODIFIER_PRESENT)"
  echo "note=Raw outputs are preserved. No historical evidence was deleted by this script."
} > "$TMPDIR/90_summary.txt"

# Build manifest last, excluding itself.
(
  cd "$TMPDIR" || exit 1
  # shellcheck disable=SC2094
  find . -type f ! -name SHA256SUMS.txt -print | sort | while IFS= read -r f; do
    sha256sum "$f"
  done > SHA256SUMS.txt
)

# Finalize atomically-ish: rename in-progress directory, then make files read-only.
mv "$TMPDIR" "$FINALDIR" || exit 1
find "$FINALDIR" -type f -exec chmod 0444 {} \; 2>/dev/null || true
find "$FINALDIR" -type d -exec chmod 0555 {} \; 2>/dev/null || true

# Append-only-style chain ledger (script never truncates/deletes it).
CHAIN_LEDGER="$BASE_DIR/CHAIN.log"
CUR_MANIFEST_SHA="$(sha256sum "$FINALDIR/SHA256SUMS.txt" | awk '{print $1}')"
PREV_SHA="$(awk -F= '/^previous_manifest_sha256=/{print $2}' "$FINALDIR/89_chain_link.txt" 2>/dev/null)"
printf '%s run_id=%s previous_manifest_sha256=%s current_manifest_sha256=%s path=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$UTC_STAMP" "${PREV_SHA:-UNKNOWN}" "$CUR_MANIFEST_SHA" "$FINALDIR" >> "$CHAIN_LEDGER"
chmod 0600 "$CHAIN_LEDGER" 2>/dev/null || true

log "evidence run finalized: $FINALDIR"
exit 0

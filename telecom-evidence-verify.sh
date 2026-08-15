#!/bin/sh
set -u
CONF="/etc/telecom-evidence.conf"
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
BASE_DIR="${BASE_DIR:-/root/telecom-evidence}"
bad=0
count=0
list="/tmp/telecom-evidence-verify.$$"
trap 'rm -f "$list"' EXIT INT TERM
find "$BASE_DIR" -type f -name SHA256SUMS.txt 2>/dev/null | sort > "$list"
while IFS= read -r m; do
  d="$(dirname "$m")"
  count=$((count+1))
  if (cd "$d" && sha256sum -c SHA256SUMS.txt >/dev/null 2>&1); then
    echo "OK   $d"
  else
    echo "FAIL $d"
    bad=1
  fi
done < "$list"
[ -f "$BASE_DIR/INTEGRITY_ALERT.log" ] && {
  echo
  echo "INTEGRITY ALERT LOG EXISTS:"
  cat "$BASE_DIR/INTEGRITY_ALERT.log"
}
echo
echo "checked=$count failed=$bad"
exit "$bad"

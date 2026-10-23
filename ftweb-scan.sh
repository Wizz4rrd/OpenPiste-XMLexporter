#!/bin/sh
# ftweb-scan.sh
# -------------
# Sweep the local /24 (or a given subnet) looking for hosts that answer the
# FTWeb endpoint, so you can find which machine is running Fencing Time Web.
# Favorites are probed first.
#
# Usage:
#   ./ftweb-scan.sh [options]
#
# Options:
#   -b, --base PREFIX     First three octets to scan, e.g. 172.20.0
#                         (default: auto-detected from this machine's IP)
#   -p, --path PATH       Probe path on each host   (default: /ftweb/Tournaments)
#   -f, --favorites "A B" Space-separated IPs to check first (default: 172.20.0.1)
#   -t, --timeout SEC     Per-host connect timeout   (default: 1)
#   -h, --help            Show this help
#
# Example:
#   ./ftweb-scan.sh
#   ./ftweb-scan.sh -b 172.20.0 -f "172.20.0.1 172.20.0.251" -t 2

set -u

PATH_PROBE="/ftweb/Tournaments"
TIMEOUT=1
FAVORITES="172.20.0.1"
BASE=""

usage() {
  cat <<'EOF'
Usage: ftweb-scan.sh [options]

  -b, --base PREFIX     First three octets to scan, e.g. 172.20.0
                        (default: auto-detected from this machine's IP)
  -p, --path PATH       Probe path on each host    (default: /ftweb/Tournaments)
  -f, --favorites "A B" Space-separated IPs to check first (default: 172.20.0.1)
  -t, --timeout SEC     Per-host connect timeout    (default: 1)
  -h, --help            Show this help

Example:
  ftweb-scan.sh
  ftweb-scan.sh -b 172.20.0 -f "172.20.0.1 172.20.0.251" -t 2
EOF
}

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -b|--base)      BASE="${2:?missing value for $1}"; shift 2 ;;
    -p|--path)      PATH_PROBE="${2:?missing value for $1}"; shift 2 ;;
    -f|--favorites) FAVORITES="${2:?missing value for $1}"; shift 2 ;;
    -t|--timeout)   TIMEOUT="${2:?missing value for $1}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "curl is required but not found."
case "$TIMEOUT" in ''|*[!0-9]*) die "timeout must be a whole number of seconds: '$TIMEOUT'";; esac

# ---------------- auto-detect subnet prefix ----------------
detect_prefix() {
  ip=""
  # macOS
  if command -v ipconfig >/dev/null 2>&1; then
    for ifc in en0 en1 en2; do
      ip="$(ipconfig getifaddr "$ifc" 2>/dev/null)" && [ -n "$ip" ] && break
    done
  fi
  # Linux
  if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  if [ -z "$ip" ] && command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  [ -n "$ip" ] || return 1
  echo "$ip" | awk -F. '{print $1"."$2"."$3}'
}

if [ -z "$BASE" ]; then
  BASE="$(detect_prefix)" || { echo "Could not auto-detect subnet; pass -b <x.y.z>" >&2; exit 1; }
  echo "Auto-detected subnet: ${BASE}.0/24"
fi

# ---------------- probe one host ----------------
probe() {
  ip="$1"
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout "$TIMEOUT" --max-time "$((TIMEOUT+2))" \
          "http://${ip}${PATH_PROBE}" 2>/dev/null)"
  # Any HTTP reply from the app (200 ok, 302 redirect, even 404 page) means a web server answered.
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    printf '  [HTTP %s]  http://%s%s\n' "$code" "$ip" "$PATH_PROBE"
  fi
}

echo "Probing ${PATH_PROBE} (timeout ${TIMEOUT}s)"
echo

echo "Favorites:"
for ip in $FAVORITES; do probe "$ip"; done

echo
echo "Sweeping ${BASE}.1 - ${BASE}.254 ..."
# Run in parallel batches for speed; skip IPs already in favorites.
i=1
while [ "$i" -le 254 ]; do
  ip="${BASE}.${i}"
  skip=0
  for f in $FAVORITES; do [ "$f" = "$ip" ] && skip=1; done
  [ "$skip" -eq 0 ] && probe "$ip" &
  # throttle: ~32 concurrent
  if [ "$((i % 32))" -eq 0 ]; then wait; fi
  i=$((i+1))
done
wait

echo
echo "Done. Lines above = a web server answered on ${PATH_PROBE}."

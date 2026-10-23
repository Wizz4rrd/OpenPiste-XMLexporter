#!/bin/sh
# ftweb-export.sh
# ---------------
# List FencingTime (FTWeb) tournaments, pick one, and periodically fetch every
# event's XML into a target location (local folder or SMB share), replacing the
# previous copy each cycle (atomic move, so a half-written file never lands).
#
# POSIX sh. Tested shape: macOS /bin/sh and Linux dash/bash.
#
# SECURITY NOTE: credentials passed with -c appear in the process list (ps) and
# shell history while running. Fine for a throwaway LAN export; for anything
# persistent, mount the share out-of-band and pass the mount point as -l.

set -eu

# ---------------- defaults ----------------
SERVER="http://172.20.0.1/ftweb"
LOCATION="./ftweb-export"
CREDS=""
INTERVAL=5
TOURNAMENT_ID=""
ONCE=0
DEBUG=0

usage() {
  cat <<'EOF'
Usage: ftweb-export.sh [options]

  -s, --server URL       Server IP or URL; /ftweb is added if no path is given
                          (default: http://172.20.0.1/ftweb)
  -l, --location PATH     Destination: local dir OR share (//host/share or \\host\share)
                          (default: ./ftweb-export)
  -c, --creds USER:PASS   Credentials for the share (omit for a local path)
  -i, --interval MIN      Refresh interval in minutes         (default: 5)
  -e, --event TID         Skip the menu, use this tournament id directly
  -1, --once              Run one cycle and exit (no loop)
      --debug             Dump raw listing HTML to /tmp to help tune the scraper
  -h, --help              Show this help

Examples:
  ftweb-export.sh
  ftweb-export.sh -l //172.20.0.251/export -c fencingtime:fencingtime
  ftweb-export.sh -s http://172.20.0.1/ftweb -i 2 -e 229376 -l /Volumes/export
EOF
}

die() { echo "error: $*" >&2; exit 1; }

# ---------------- args ----------------
while [ $# -gt 0 ]; do
  case "$1" in
    -s|--server)   SERVER="${2:?missing value for $1}"; shift 2 ;;
    -l|--location) LOCATION="${2:?missing value for $1}"; shift 2 ;;
    -c|--creds)    CREDS="${2:?missing value for $1}"; shift 2 ;;
    -i|--interval) INTERVAL="${2:?missing value for $1}"; shift 2 ;;
    -e|--event)    TOURNAMENT_ID="${2:?missing value for $1}"; shift 2 ;;
    -1|--once)     ONCE=1; shift ;;
    --debug)       DEBUG=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "curl is required but not found."
case "$INTERVAL" in ''|*[!0-9]*) die "interval must be a whole number of minutes: '$INTERVAL'";; esac
[ "$INTERVAL" -ge 1 ] || die "interval must be >= 1 minute."
SERVER="${SERVER%/}"
case "$SERVER" in
  http://*|https://*) ;;
  *://*) die "server URL must use http:// or https://." ;;
  *) SERVER="http://$SERVER" ;;
esac
case "${SERVER#*://}" in
  */*) ;;
  *) SERVER="$SERVER/ftweb" ;;
esac

# ---------------- destination setup ----------------
MOUNT_TMP=""
MOUNTED=0
DEST=""

is_share() {
  case "$1" in //*|\\*) return 0 ;; *) return 1 ;; esac
}

mount_share() {
  share="$(printf '%s' "$1" | tr '\\' '/')"   # \\host\share -> //host/share
  host_share="$share"
  while [ "${host_share#/}" != "$host_share" ]; do
    host_share="${host_share#/}"
  done
  case "$host_share" in
    */?*) ;;
    *) die "share must include a host and share name, for example //172.20.0.251/export." ;;
  esac
  MOUNT_TMP="$(mktemp -d -t ftexport)"
  echo "Mounting //$host_share ..."
  case "$(uname -s)" in
    Darwin)
      if [ -n "$CREDS" ]; then
        user="${CREDS%%:*}"; pass="${CREDS#*:}"
        mount_smbfs "//${user}:${pass}@${host_share}" "$MOUNT_TMP" \
          || die "Could not mount //$host_share. Check network access, share name, and SMB credentials."
      else
        mount_smbfs "//${host_share}" "$MOUNT_TMP" \
          || die "Could not mount //$host_share. Check network access, share name, and SMB credentials."
      fi ;;
    Linux)
      if [ -n "$CREDS" ]; then
        user="${CREDS%%:*}"; pass="${CREDS#*:}"
        sudo mount -t cifs "//${host_share}" "$MOUNT_TMP" -o "username=${user},password=${pass}"
      else
        sudo mount -t cifs "//${host_share}" "$MOUNT_TMP" -o guest
      fi ;;
    *) die "Unsupported OS for auto-mount; mount the share yourself and pass its path as -l." ;;
  esac
  MOUNTED=1
  DEST="$MOUNT_TMP"
}

cleanup() {
  if [ -n "$MOUNT_TMP" ]; then
    if [ "$MOUNTED" -eq 1 ]; then
      umount "$MOUNT_TMP" 2>/dev/null || sudo -n umount "$MOUNT_TMP" 2>/dev/null \
        || { echo "error: Could not unmount $MOUNT_TMP; unmount it manually." >&2; return 1; }
      MOUNTED=0
    fi
    rmdir "$MOUNT_TMP" || return 1
    MOUNT_TMP=""
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if is_share "$LOCATION"; then
  mount_share "$LOCATION"
else
  mkdir -p "$LOCATION"
  DEST="$LOCATION"
fi
echo "Destination: $DEST"

# ---------------- listing / scraping ----------------
# Tournament rows link to Events/<tournament-id>; event rows link to the XML API.
fetch() { curl -fsS --max-time 15 "$1"; }

list_tournaments() {
  html="$(fetch "$SERVER/Tournaments")" || return 1
  [ "$DEBUG" -eq 1 ] && { printf '%s\n' "$html" > /tmp/ftweb_tournaments.html; echo "(raw -> /tmp/ftweb_tournaments.html)" >&2; }
  printf '%s\n' "$html" | awk '
    BEGIN { RS = "</tr>" }
    match($0, /(Events|Tournaments)\/[0-9]+/) {
      link = substr($0, RSTART, RLENGTH)
      id = link
      sub(/^[^\/]*\//, "", id)
      if (seen[id]++) next
      if (split($0, cells, /<\/td>/) >= 3) {
        name = cells[2]
        sub(/^.*<td[^>]*>/, "", name)
      } else {
        name = substr($0, RSTART + RLENGTH)
        sub(/^[^>]*>/, "", name)
        sub(/<\/a>.*/, "", name)
      }
      gsub(/<[^>]*>/, "", name)
      gsub(/[[:space:]]+/, " ", name)
      sub(/^ /, "", name)
      sub(/ $/, "", name)
      printf "%s\t%s\n", id, name
    }'
}

list_event_ids() {
  tid="$1"
  html="$(fetch "$SERVER/Events/$tid")" \
    || html="$(fetch "$SERVER/Tournaments/$tid")" \
    || html="$(fetch "$SERVER/Events?tournament=$tid")" \
    || { echo "  could not fetch events for tournament $tid" >&2; return 1; }
  [ "$DEBUG" -eq 1 ] && { printf '%s\n' "$html" > /tmp/ftweb_events.html; echo "(raw -> /tmp/ftweb_events.html)" >&2; }
  printf '%s\n' "$html" \
    | grep -oEi 'api/v1/events/[0-9]+/xml[0-9]*|Events/[0-9]+' \
    | sed -E 's#.*[eE]vents/([0-9]+).*#\1#' \
    | awk '!s[$0]++'
}

# ---------------- pick a tournament ----------------
if [ -z "$TOURNAMENT_ID" ]; then
  echo "Fetching tournaments from $SERVER/Tournaments ..."
  LIST="$(list_tournaments)" || die "Could not fetch $SERVER/Tournaments. Include the FTWeb application path in --server (for example, http://172.20.0.1/ftweb)."
  [ -n "$LIST" ] || die "No tournaments parsed. Re-run with --debug and share /tmp/ftweb_tournaments.html, or pass -e <id>."
  echo
  printf '  #  %-10s %s\n' "ID" "Tournament"
  echo "  ---------------------------------------------"
  printf '%s\n' "$LIST" | awk -F'\t' '{printf "  %2d  %-10s %s\n", NR, $1, $2}'
  echo
  printf 'Choose a number: '
  read -r choice
  TOURNAMENT_ID="$(printf '%s\n' "$LIST" | awk -F'\t' -v n="$choice" 'NR==n{print $1}')"
  [ -n "$TOURNAMENT_ID" ] || die "Invalid choice: '$choice'."
  echo "Selected tournament id: $TOURNAMENT_ID"
fi

# ---------------- the fetch-all-XMLs cycle ----------------
export_cycle() {
  ids="$(list_event_ids "$TOURNAMENT_ID")" || return 1
  [ -n "$ids" ] || { echo "  no event ids found for tournament $TOURNAMENT_ID" >&2; return 1; }
  n=0
  failed=0
  for eid in $ids; do
    tmp="$(mktemp -t ftxml)"
    if curl -fsS --max-time 20 "$SERVER/api/v1/events/$eid/xml2019" -o "$tmp"; then
      mv -f "$tmp" "$DEST/event_${eid}.xml"      # atomic replace
      n=$((n + 1))
    else
      echo "  ! failed: event $eid" >&2
      rm -f "$tmp"
      failed=1
    fi
  done
  echo "  $(date '+%H:%M:%S')  wrote $n XML file(s) to $DEST"
  return "$failed"
}

echo "Starting export (interval ${INTERVAL} min). Ctrl-C to stop."
while :; do
  if ! export_cycle; then
    echo "Export cycle failed." >&2
    [ "$ONCE" -eq 1 ] && exit 1
  fi
  [ "$ONCE" -eq 1 ] && break
  sleep "$((INTERVAL * 60))"
done

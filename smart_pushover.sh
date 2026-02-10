#!/usr/bin/env bash
set -euo pipefail

# smart_pushover.sh
# Monitor SMART health and send Pushover alerts on failure conditions.
# Ubuntu-focused, honors per-device -d types from smartctl --scan-open.

: "${PUSHOVER_USER_KEY:=REPLACE_ME_USER_KEY}"
: "${PUSHOVER_APP_TOKEN:=REPLACE_ME_APP_TOKEN}"

PUSHOVER_API="https://api.pushover.net/1/messages.json"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"

STATE_DIR="${STATE_DIR:-/var/tmp/smart_pushover_state}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-21600}" # 6 hours

WATCH_ATTRS_REGEX='^(Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable)$'

die() { echo "ERROR: $*" >&2; exit 1; }

send_pushover() {
  local title="$1"
  local msg="$2"
  local priority="${3:-0}"

  [[ "$PUSHOVER_USER_KEY" != "REPLACE_ME_USER_KEY" ]] || die "Set PUSHOVER_USER_KEY in environment"
  [[ "$PUSHOVER_APP_TOKEN" != "REPLACE_ME_APP_TOKEN" ]] || die "Set PUSHOVER_APP_TOKEN in environment"

  curl -sS     --form-string "token=${PUSHOVER_APP_TOKEN}"     --form-string "user=${PUSHOVER_USER_KEY}"     --form-string "title=${title}"     --form-string "message=${msg}"     --form-string "priority=${priority}"     "${PUSHOVER_API}" >/dev/null
}

sanitize_key() {
  echo "$1" | sed 's#[/ ]#_#g' | sed 's#[^A-Za-z0-9_.-]#_#g'
}

cooldown_ok() {
  local key="$1"
  local now
  now="$(date +%s)"
  mkdir -p "$STATE_DIR"
  local stamp_file="${STATE_DIR}/${key}.stamp"

  if [[ -f "$stamp_file" ]]; then
    local last
    last="$(cat "$stamp_file" 2>/dev/null || echo 0)"
    if (( now - last < COOLDOWN_SECONDS )); then
      return 1
    fi
  fi

  echo "$now" > "$stamp_file"
  return 0
}

scan_devices() {
  smartctl --scan-open 2>/dev/null     | awk '
        $1 ~ /^\/dev\// {
          dev=$1
          dtype=""
          for (i=1;i<=NF;i++) {
            if ($i=="-d" && (i+1)<=NF) { dtype=$(i+1) }
          }
          print dev "|" dtype
        }'
}

smart_health() {
  local dev="$1" dtype="$2"
  local out

  if [[ -n "$dtype" ]]; then
    out="$(smartctl -d "$dtype" -H "$dev" 2>/dev/null || true)"
  else
    out="$(smartctl -H "$dev" 2>/dev/null || true)"
  fi

  if echo "$out" | grep -qiE 'PASSED|OK'; then
    echo "PASS"
  elif echo "$out" | grep -qiE 'FAILED|BAD'; then
    echo "FAIL"
  else
    echo "UNKNOWN"
  fi
}

device_id() {
  local dev="$1" dtype="$2"
  local out
  if [[ -n "$dtype" ]]; then
    out="$(smartctl -d "$dtype" -i "$dev" 2>/dev/null || true)"
  else
    out="$(smartctl -i "$dev" 2>/dev/null || true)"
  fi

  local model serial
  model="$(echo "$out" | awk -F: '/Device Model|Model Number/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
  serial="$(echo "$out" | awk -F: '/Serial Number/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"

  echo "Model=${model:-unknown} Serial=${serial:-unknown}"
}

bad_attrs() {
  local dev="$1" dtype="$2"
  local out
  if [[ -n "$dtype" ]]; then
    out="$(smartctl -d "$dtype" -A "$dev" 2>/dev/null || true)"
  else
    out="$(smartctl -A "$dev" 2>/dev/null || true)"
  fi

  echo "$out" | awk -v re="$WATCH_ATTRS_REGEX" '
    $0 ~ re {
      attr=$2
      raw=$NF
      gsub(/^0+/, "0", raw)
      if (raw ~ /^[0-9]+$/ && raw > 0) print attr " " raw
    }'

  local pct_used spare
  pct_used="$(echo "$out" | awk -F: '/Percentage Used/ {gsub(/[^0-9]/,"",$2); print $2; exit}' || true)"
  spare="$(echo "$out" | awk -F: '/Available Spare/ {gsub(/[^0-9]/,"",$2); print $2; exit}' || true)"

  if [[ -n "${pct_used:-}" ]] && [[ "$pct_used" =~ ^[0-9]+$ ]] && (( pct_used >= 90 )); then
    echo "Percentage_Used ${pct_used}%"
  fi
  if [[ -n "${spare:-}" ]] && [[ "$spare" =~ ^[0-9]+$ ]] && (( spare <= 10 )); then
    echo "Available_Spare ${spare}%"
  fi
}

error_log_excerpt() {
  local dev="$1" dtype="$2"
  local out
  if [[ -n "$dtype" ]]; then
    out="$(smartctl -d "$dtype" -l error "$dev" 2>/dev/null || true)"
  else
    out="$(smartctl -l error "$dev" 2>/dev/null || true)"
  fi

  if echo "$out" | grep -qiE 'No Errors Logged|not supported|Unavailable'; then
    return 0
  fi

  echo "$out" | sed 's/[[:space:]]\+/ /g' | head -n 10
}

main() {
  command -v smartctl >/dev/null 2>&1 || die "smartctl not found"
  command -v curl >/dev/null 2>&1 || die "curl not found"

  while IFS='|' read -r dev dtype; do
    [[ -e "$dev" ]] || continue

    id="$(device_id "$dev" "$dtype")"
    health="$(smart_health "$dev" "$dtype")"
    attrs="$(bad_attrs "$dev" "$dtype" || true)"
    err="$(error_log_excerpt "$dev" "$dtype" || true)"

    reasons=()
    [[ "$health" == "FAIL" ]] && reasons+=("SMART overall health FAILED")
    [[ -n "${attrs:-}" ]] && reasons+=("SMART attributes indicate trouble")
    [[ -n "${err:-}" ]] && reasons+=("SMART error log has entries")

    if (( ${#reasons[@]} > 0 )); then
      sig="$(printf '%s' "${reasons[*]}|${attrs}|${err}" | cksum | awk '{print $1}')"
      key="$(sanitize_key "${dev}_${dtype}_${sig}")"

      if cooldown_ok "$key"; then
        title="SMART alert on ${HOSTNAME_SHORT}: ${dev} (-d ${dtype:-auto})"
        msg=$(cat <<EOF
Host: $HOSTNAME_SHORT
Device: $dev (-d ${dtype:-auto})
$id
Health: $health

${attrs:+Bad attributes:
$attrs

}${err:+Error log excerpt:
$err

}Reasons: ${reasons[*]}
EOF
)
        send_pushover "$title" "$msg" 1
        echo "Alert sent for $dev"
      else
        echo "Within cooldown; skipping $dev"
      fi
    else
      echo "OK: $dev"
    fi
  done < <(scan_devices)
}

main "$@"

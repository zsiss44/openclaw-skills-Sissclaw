#!/usr/bin/env bash
# trader-protection/check.sh — sourceable safety library.
#
# Source this from a trading skill's main script. Functions named *_or_die
# call `exit 0` on breach (intentional halt, not error — cron won't retry).
# protection_validate_snapshot returns non-zero so the caller can `continue`
# past one bad ticker without killing the whole run.

# Resolve this library's own directory so default state/log paths anchor here
# regardless of the caller's CWD.
__PROTECTION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${PROTECTION_KILL_SWITCH:=$HOME/.openclaw/KILL_SWITCH}"
: "${PROTECTION_LOCK_FILE:=/tmp/sissclaw-trader.lock}"
: "${PROTECTION_MAX_DRAWDOWN_PCT:=0.08}"
: "${PROTECTION_MAX_DAILY_LOSS_PCT:=0.03}"
: "${PROTECTION_MAX_SNAPSHOT_AGE_SEC:=120}"
: "${PROTECTION_MAX_GROSS_EXPOSURE_USD:=200000}"
: "${PROTECTION_STATE_DIR:=$__PROTECTION_LIB_DIR/state}"
: "${PROTECTION_LOG_FILE:=$__PROTECTION_LIB_DIR/logs/protection.log}"

protection_init() {
  mkdir -p "$PROTECTION_STATE_DIR" "$(dirname "$PROTECTION_LOG_FILE")"
}

# One JSON line per event. Stays parseable alongside other skills' logs.
protection_log() {
  local event="$1" details="${2:-{\}}"
  local ts
  ts="$(TZ=America/New_York date -Iseconds 2>/dev/null || date -Iseconds)"
  printf '{"timestamp":"%s","skill":"trader-protection","event":"%s","details":%s}\n' \
    "$ts" "$event" "$details" >>"$PROTECTION_LOG_FILE"
}

protection_kill_switch_or_die() {
  if [[ -e "$PROTECTION_KILL_SWITCH" ]]; then
    protection_log "kill_switch_active" \
      "$(jq -nc --arg path "$PROTECTION_KILL_SWITCH" '{path:$path}')"
    exit 0
  fi
}

# Holds a flock across the rest of the process. Second concurrent invocation
# silently exits — better than racing to submit duplicate orders.
protection_acquire_lock_or_die() {
  exec 200>"$PROTECTION_LOCK_FILE"
  if ! flock -n 200; then
    protection_log "lock_held" \
      "$(jq -nc --arg path "$PROTECTION_LOCK_FILE" '{path:$path}')"
    exit 0
  fi
}

protection_drawdown_or_die() {
  local equity="$1"
  local hwm_file="$PROTECTION_STATE_DIR/equity-hwm.json"
  local hwm
  if [[ -f "$hwm_file" ]]; then
    hwm="$(jq -r '.hwm // 0' "$hwm_file")"
  else
    hwm="$equity"
  fi
  if [[ "$(awk -v e="$equity" -v h="$hwm" 'BEGIN{print (e+0 > h+0)}')" -eq 1 ]]; then
    hwm="$equity"
    jq -nc --arg hwm "$equity" --arg ts "$(date -Iseconds)" \
      '{hwm:($hwm|tonumber), hwm_ts:$ts}' >"$hwm_file"
  fi
  local dd
  dd="$(awk -v e="$equity" -v h="$hwm" 'BEGIN{ if (h+0 <= 0) print 0; else printf "%.6f", (h - e) / h }')"
  if [[ "$(awk -v dd="$dd" -v max="$PROTECTION_MAX_DRAWDOWN_PCT" 'BEGIN{print(dd+0 > max+0)}')" -eq 1 ]]; then
    protection_log "max_drawdown_breached" \
      "$(jq -nc --arg hwm "$hwm" --arg eq "$equity" --arg dd "$dd" --arg max "$PROTECTION_MAX_DRAWDOWN_PCT" \
        '{hwm:($hwm|tonumber), equity:($eq|tonumber), drawdown_pct:($dd|tonumber), cap:($max|tonumber)}')"
    exit 0
  fi
}

protection_daily_loss_or_die() {
  local equity="$1"
  local daily_file="$PROTECTION_STATE_DIR/daily-anchor.json"
  local today anchor_date anchor_eq
  today="$(TZ=America/New_York date +%Y-%m-%d)"
  anchor_date=""
  anchor_eq="0"
  if [[ -f "$daily_file" ]]; then
    anchor_date="$(jq -r '.date // ""' "$daily_file")"
    anchor_eq="$(jq -r '.equity_open // 0' "$daily_file")"
  fi
  # First run of the ET day: set anchor and proceed.
  if [[ "$anchor_date" != "$today" ]]; then
    jq -nc --arg d "$today" --arg e "$equity" \
      '{date:$d, equity_open:($e|tonumber)}' >"$daily_file"
    return 0
  fi
  local loss
  loss="$(awk -v e="$equity" -v a="$anchor_eq" 'BEGIN{ if (a+0 <= 0) print 0; else printf "%.6f", (a - e) / a }')"
  if [[ "$(awk -v l="$loss" -v max="$PROTECTION_MAX_DAILY_LOSS_PCT" 'BEGIN{print(l+0 > max+0)}')" -eq 1 ]]; then
    protection_log "max_daily_loss_breached" \
      "$(jq -nc --arg anchor "$anchor_eq" --arg eq "$equity" --arg loss "$loss" --arg max "$PROTECTION_MAX_DAILY_LOSS_PCT" \
        '{anchor:($anchor|tonumber), equity:($eq|tonumber), loss_pct:($loss|tonumber), cap:($max|tonumber)}')"
    exit 0
  fi
}

# Returns 1 (not exit) so the caller can skip one stale-data symbol and continue.
protection_validate_snapshot() {
  local snapshot_json="$1" symbol="$2"
  local trade_ts
  trade_ts="$(jq -r --arg s "$symbol" '.[$s].latestTrade.t // .[$s].latest_trade.t // empty' <<<"$snapshot_json")"
  [[ -z "$trade_ts" ]] && return 0
  local now_sec trade_sec age_sec
  now_sec="$(date +%s)"
  trade_sec="$(date -d "$trade_ts" +%s 2>/dev/null || echo 0)"
  [[ "$trade_sec" -le 0 ]] && return 0
  age_sec=$((now_sec - trade_sec))
  if [[ "$age_sec" -gt "$PROTECTION_MAX_SNAPSHOT_AGE_SEC" ]]; then
    protection_log "stale_snapshot" \
      "$(jq -nc --arg sym "$symbol" --arg age "$age_sec" --arg max "$PROTECTION_MAX_SNAPSHOT_AGE_SEC" \
        '{symbol:$sym, age_sec:($age|tonumber), max_sec:($max|tonumber)}')"
    return 1
  fi
  return 0
}

# Convenience: one call updates HWM (if higher) and sets daily anchor (if first run today).
# Run AFTER drawdown/daily-loss checks so the anchor reflects today's true open.
protection_record_equity() {
  local equity="$1"
  local hwm_file="$PROTECTION_STATE_DIR/equity-hwm.json"
  if [[ -f "$hwm_file" ]]; then
    local hwm
    hwm="$(jq -r '.hwm // 0' "$hwm_file")"
    if [[ "$(awk -v e="$equity" -v h="$hwm" 'BEGIN{print (e+0 > h+0)}')" -eq 1 ]]; then
      jq -nc --arg hwm "$equity" --arg ts "$(date -Iseconds)" \
        '{hwm:($hwm|tonumber), hwm_ts:$ts}' >"$hwm_file"
    fi
  else
    jq -nc --arg hwm "$equity" --arg ts "$(date -Iseconds)" \
      '{hwm:($hwm|tonumber), hwm_ts:$ts}' >"$hwm_file"
  fi
  local daily_file="$PROTECTION_STATE_DIR/daily-anchor.json"
  local today anchor_date
  today="$(TZ=America/New_York date +%Y-%m-%d)"
  anchor_date=""
  if [[ -f "$daily_file" ]]; then
    anchor_date="$(jq -r '.date // ""' "$daily_file")"
  fi
  if [[ "$anchor_date" != "$today" ]]; then
    jq -nc --arg d "$today" --arg e "$equity" \
      '{date:$d, equity_open:($e|tonumber)}' >"$daily_file"
  fi
}

# Hard absolute ceiling — independent of mode/leverage. Pass intended notional in USD.
protection_gross_exposure_or_die() {
  local intended_notional="$1"
  if [[ "$(awk -v n="$intended_notional" -v max="$PROTECTION_MAX_GROSS_EXPOSURE_USD" \
        'BEGIN{print(n+0 > max+0)}')" -eq 1 ]]; then
    protection_log "gross_exposure_breached" \
      "$(jq -nc --arg n "$intended_notional" --arg max "$PROTECTION_MAX_GROSS_EXPOSURE_USD" \
        '{intended_notional:($n|tonumber), cap:($max|tonumber)}')"
    exit 0
  fi
}

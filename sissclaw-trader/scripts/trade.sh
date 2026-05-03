#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
LOG_FILE="$SKILL_DIR/logs/trade-decisions.log"
DRY_RUN="false"
FORCE_RUN="false"
SHOW_HELP="false"

mkdir -p "$(dirname "$LOG_FILE")"

print_usage() {
  cat <<'EOF'
Usage: trade.sh [--dry-run|-n] [--force|-f] [--help|-h]

Options:
  -n, --dry-run   Evaluate strategy and log decisions without submitting orders.
  -f, --force     Skip market-hours open check (useful for manual paper-trade testing).
  -h, --help      Show this help message.

Env:
  TRADE_MODE      build (default) | tilt | yolo | lock
                  build: 25% per-position cap, up to 4 names + TQQQ core
                  tilt:  50% per-position cap, up to 2 names + TQQQ core (catch-up)
                  yolo:  full intraday buying power into single best mover (endgame, behind)
                  lock:  flatten everything on next run, sit in cash (endgame, leading)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run) DRY_RUN="true"; shift ;;
      -f|--force)   FORCE_RUN="true"; shift ;;
      -h|--help)    SHOW_HELP="true"; shift ;;
      *) echo "Unknown argument: $1" >&2; print_usage >&2; exit 2 ;;
    esac
  done
}

parse_args "$@"

if [[ "$SHOW_HELP" == "true" ]]; then
  print_usage
  exit 0
fi

if [[ -f "$PROJECT_ROOT/.env" ]]; then
  set -a
  source "$PROJECT_ROOT/.env"
  set +a
fi

: "${APCA_API_KEY_ID:?APCA_API_KEY_ID is required}"
: "${APCA_API_SECRET_KEY:?APCA_API_SECRET_KEY is required}"

TRADING_BASE_URL="${ALPACA_BASE_URL:-https://paper-api.alpaca.markets}"
DATA_BASE_URL="${ALPACA_DATA_URL:-https://data.alpaca.markets}"
TRADE_MODE="${TRADE_MODE:-build}"
STOP_LOSS_PCT="0.02"
TAKE_PROFIT_PCT="0.04"
TQQQ_CORE_FRACTION="0.30"
TQQQ_TAPE_THRESHOLD="0.30"
GAIN_BAND_MIN="1.0"
GAIN_BAND_MAX="5.0"

case "$TRADE_MODE" in
  build) MAX_POSITION_FRACTION="0.25"; MAX_OPEN_POSITIONS="4"; USE_TQQQ_CORE="true" ;;
  tilt)  MAX_POSITION_FRACTION="0.50"; MAX_OPEN_POSITIONS="2"; USE_TQQQ_CORE="true" ;;
  yolo)  MAX_POSITION_FRACTION="4.00"; MAX_OPEN_POSITIONS="1"; USE_TQQQ_CORE="false" ;;
  lock)  MAX_POSITION_FRACTION="0.00"; MAX_OPEN_POSITIONS="0"; USE_TQQQ_CORE="false" ;;
  *) echo "Unknown TRADE_MODE: $TRADE_MODE (allowed: build|tilt|yolo|lock)" >&2; exit 2 ;;
esac

require_binary() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required dependency: $1" >&2
    exit 1
  fi
}

require_binary curl
require_binary jq
require_binary awk

is_friday_et() {
  [[ "$(TZ=America/New_York date +%u)" == "5" ]]
}

json_escape() {
  jq -n --arg s "$1" '$s'
}

log_decision() {
  local symbol="$1"
  local action="$2"
  local reason="$3"
  local details="${4-}"
  [[ -z "$details" ]] && details='{}'
  local ts
  ts="$(TZ=America/New_York date -Iseconds)"
  printf '{"timestamp":"%s","symbol":"%s","action":"%s","reason":%s,"mode":"%s","details":%s}\n' \
    "$ts" "$symbol" "$action" "$(json_escape "$reason")" "$TRADE_MODE" "$details" >>"$LOG_FILE"
}

trading_get() {
  curl -sS -f \
    -H "APCA-API-KEY-ID: $APCA_API_KEY_ID" \
    -H "APCA-API-SECRET-KEY: $APCA_API_SECRET_KEY" \
    "$TRADING_BASE_URL$1"
}

data_get() {
  curl -sS -f \
    -H "APCA-API-KEY-ID: $APCA_API_KEY_ID" \
    -H "APCA-API-SECRET-KEY: $APCA_API_SECRET_KEY" \
    "$DATA_BASE_URL$1"
}

trading_post() {
  curl -sS -f \
    -X POST \
    -H "APCA-API-KEY-ID: $APCA_API_KEY_ID" \
    -H "APCA-API-SECRET-KEY: $APCA_API_SECRET_KEY" \
    -H "Content-Type: application/json" \
    -d "$2" \
    "$TRADING_BASE_URL$1"
}

cancel_open_orders_for() {
  local symbol="$1" orders_json
  if ! orders_json="$(trading_get "/v2/orders?status=open&symbols=${symbol}&limit=50")"; then
    return 0
  fi
  jq -r '.[]?.id // empty' <<<"$orders_json" | while read -r oid; do
    [[ -z "$oid" ]] && continue
    curl -sS -X DELETE \
      -H "APCA-API-KEY-ID: $APCA_API_KEY_ID" \
      -H "APCA-API-SECRET-KEY: $APCA_API_SECRET_KEY" \
      "$TRADING_BASE_URL/v2/orders/${oid}" >/dev/null 2>&1 || true
  done
}

flatten_symbol() {
  local symbol="$1" qty="$2" reason="$3"
  local abs_qty payload response
  abs_qty="$(awk -v q="$qty" 'BEGIN { if (q < 0) print -q; else print q }')"
  if [[ "$(awk -v q="$abs_qty" 'BEGIN {print (q <= 0)}')" -eq 1 ]]; then
    log_decision "$symbol" "skip" "invalid_position_qty" "{}"
    return
  fi
  cancel_open_orders_for "$symbol"
  payload="$(jq -nc --arg symbol "$symbol" --arg qty "$abs_qty" \
    '{symbol:$symbol, qty:$qty, side:"sell", type:"market", time_in_force:"day"}')"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_decision "$symbol" "sell" "dry_run_${reason}" "$(jq -nc --arg qty "$abs_qty" --argjson payload "$payload" '{qty:$qty,simulated_order:$payload}')"
  elif response="$(trading_post "/v2/orders" "$payload" 2>&1)"; then
    log_decision "$symbol" "sell" "$reason" "$(jq -nc --arg qty "$abs_qty" '{qty:$qty}')"
  else
    log_decision "$symbol" "skip" "${reason}_failed" "$(jq -nc --arg err "$response" '{error:$err}')"
  fi
}

# Friday or yolo/lock → flatten ALL.
# Other days build/tilt → hold green positions overnight, flatten red.
eod_step() {
  local positions_json
  positions_json="$(trading_get "/v2/positions")"
  if [[ "$(jq 'length' <<<"$positions_json")" -eq 0 ]]; then
    log_decision "ALL" "skip" "no_open_positions_at_eod" "{}"
    return
  fi

  local flatten_all="false" reason_default="end_of_day_red_flatten"
  if is_friday_et; then
    flatten_all="true"
    reason_default="friday_flatten_all"
  elif [[ "$TRADE_MODE" == "yolo" || "$TRADE_MODE" == "lock" ]]; then
    flatten_all="true"
    reason_default="${TRADE_MODE}_eod_flatten"
  fi

  jq -c '.[]' <<<"$positions_json" | while read -r pos; do
    local symbol qty unrealized
    symbol="$(jq -r '.symbol' <<<"$pos")"
    qty="$(jq -r '.qty' <<<"$pos")"
    unrealized="$(jq -r '.unrealized_pl // 0' <<<"$pos")"

    if [[ "$flatten_all" == "true" ]]; then
      flatten_symbol "$symbol" "$qty" "$reason_default"
    elif [[ "$(awk -v u="$unrealized" 'BEGIN {print (u < 0)}')" -eq 1 ]]; then
      flatten_symbol "$symbol" "$qty" "$reason_default"
    else
      log_decision "$symbol" "hold" "overnight_hold_green" "$(jq -nc --arg qty "$qty" --arg pl "$unrealized" '{qty:$qty,unrealized_pl:$pl}')"
    fi
  done
}

submit_bracket_buy() {
  local symbol="$1" qty="$2" entry_price="$3" reason="$4" details_extra="${5-}"
  [[ -z "$details_extra" ]] && details_extra='{}'
  local stop_price take_profit_price order_payload order_response details
  stop_price="$(awk -v p="$entry_price" -v pct="$STOP_LOSS_PCT" 'BEGIN { printf "%.2f", p * (1 - pct) }')"
  take_profit_price="$(awk -v p="$entry_price" -v pct="$TAKE_PROFIT_PCT" 'BEGIN { printf "%.2f", p * (1 + pct) }')"
  order_payload="$(jq -nc \
    --arg symbol "$symbol" --arg qty "$qty" \
    --arg stop_price "$stop_price" --arg take_profit_price "$take_profit_price" \
    '{symbol:$symbol, qty:$qty, side:"buy", type:"market", time_in_force:"day",
      order_class:"bracket",
      stop_loss:{stop_price:$stop_price},
      take_profit:{limit_price:$take_profit_price}}')"
  details="$(jq -nc \
    --arg qty "$qty" --arg entry "$entry_price" \
    --arg stop "$stop_price" --arg tp "$take_profit_price" \
    --argjson extra "$details_extra" \
    '$extra + {qty:$qty, entry_price:$entry, stop_price:$stop, take_profit_price:$tp}')"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_decision "$symbol" "buy" "dry_run_${reason}" "$(jq -nc --argjson d "$details" --argjson order "$order_payload" '$d + {simulated_order:$order}')"
    return 0
  elif order_response="$(trading_post "/v2/orders" "$order_payload" 2>&1)"; then
    log_decision "$symbol" "buy" "$reason" "$details"
    return 0
  else
    log_decision "$symbol" "skip" "${reason}_failed" "$(jq -nc --arg err "$order_response" '{error:$err}')"
    return 1
  fi
}

# Hold ~30% of equity in TQQQ when SPY shows tape strength.
# No bracket — TQQQ rides; risk is managed by EOD selective flatten.
# Allocation grows on green days as equity grows (concentration on momentum).
tqqq_core_step() {
  [[ "$USE_TQQQ_CORE" != "true" ]] && return

  local spy_snapshot spy_prev spy_last spy_change_pct
  if ! spy_snapshot="$(data_get "/v2/stocks/snapshots?symbols=SPY")"; then
    log_decision "TQQQ" "skip" "spy_snapshot_fetch_failed" "{}"
    return
  fi
  if declare -F protection_validate_snapshot >/dev/null && \
     ! protection_validate_snapshot "$spy_snapshot" "SPY"; then
    log_decision "TQQQ" "skip" "spy_snapshot_stale" "{}"
    return
  fi
  spy_prev="$(jq -r '.SPY.prevDailyBar.c // 0' <<<"$spy_snapshot")"
  spy_last="$(jq -r '.SPY.latestTrade.p // .SPY.dailyBar.c // 0' <<<"$spy_snapshot")"
  if [[ "$(awk -v p="$spy_prev" -v l="$spy_last" 'BEGIN {print (p <= 0 || l <= 0)}')" -eq 1 ]]; then
    log_decision "TQQQ" "skip" "spy_invalid_price_data" "$(jq -nc --arg prev "$spy_prev" --arg last "$spy_last" '{prev:$prev,last:$last}')"
    return
  fi
  spy_change_pct="$(awk -v p="$spy_prev" -v l="$spy_last" 'BEGIN { printf "%.4f", ((l - p) / p) * 100 }')"

  local positions_json existing_qty
  positions_json="$(trading_get "/v2/positions")"
  existing_qty="$(jq -r '[.[] | select(.symbol == "TQQQ") | (.qty|tonumber)] | add // 0' <<<"$positions_json")"

  if [[ "$(awk -v c="$spy_change_pct" -v t="$TQQQ_TAPE_THRESHOLD" 'BEGIN {print (c < t)}')" -eq 1 ]]; then
    if [[ "$(awk -v q="$existing_qty" 'BEGIN {print (q > 0)}')" -eq 1 ]]; then
      log_decision "TQQQ" "hold" "tqqq_core_red_tape_hold" "$(jq -nc --arg qty "$existing_qty" --arg spy "$spy_change_pct" '{qty:$qty,spy_change_pct:$spy}')"
    else
      log_decision "TQQQ" "skip" "tqqq_core_red_tape" "$(jq -nc --arg spy "$spy_change_pct" --arg threshold "$TQQQ_TAPE_THRESHOLD" '{spy_change_pct:$spy,threshold:$threshold}')"
    fi
    return
  fi

  local account_json equity buying_power snapshot last_price target_value current_value gap target_notional qty
  account_json="$(trading_get "/v2/account")"
  equity="$(jq -r '.equity' <<<"$account_json")"
  buying_power="$(jq -r '.buying_power' <<<"$account_json")"

  if ! snapshot="$(data_get "/v2/stocks/snapshots?symbols=TQQQ")"; then
    log_decision "TQQQ" "skip" "tqqq_snapshot_fetch_failed" "{}"
    return
  fi
  if declare -F protection_validate_snapshot >/dev/null && \
     ! protection_validate_snapshot "$snapshot" "TQQQ"; then
    log_decision "TQQQ" "skip" "tqqq_snapshot_stale" "{}"
    return
  fi
  last_price="$(jq -r '.TQQQ.latestTrade.p // .TQQQ.dailyBar.c // 0' <<<"$snapshot")"
  if [[ "$(awk -v l="$last_price" 'BEGIN {print (l <= 0)}')" -eq 1 ]]; then
    log_decision "TQQQ" "skip" "tqqq_invalid_price" "{}"
    return
  fi

  target_value="$(awk -v e="$equity" -v f="$TQQQ_CORE_FRACTION" 'BEGIN { printf "%.2f", e * f }')"
  current_value="$(jq -r '[.[] | select(.symbol == "TQQQ") | (.market_value|tonumber)] | add // 0' <<<"$positions_json")"
  gap="$(awk -v t="$target_value" -v c="$current_value" 'BEGIN { printf "%.2f", t - c }')"

  if [[ "$(awk -v g="$gap" -v p="$last_price" 'BEGIN {print (g < p)}')" -eq 1 ]]; then
    log_decision "TQQQ" "hold" "tqqq_core_already_full" "$(jq -nc --arg target "$target_value" --arg current "$current_value" --arg spy "$spy_change_pct" '{target:$target,current:$current,spy_change_pct:$spy}')"
    return
  fi

  target_notional="$(awk -v g="$gap" -v bp="$buying_power" 'BEGIN { t = g < bp ? g : bp; printf "%.2f", t }')"
  if [[ "$(awk -v t="$target_notional" 'BEGIN {print (t <= 0)}')" -eq 1 ]]; then
    log_decision "TQQQ" "skip" "tqqq_insufficient_buying_power" "$(jq -nc --arg bp "$buying_power" '{buying_power:$bp}')"
    return
  fi
  qty="$(awk -v t="$target_notional" -v p="$last_price" 'BEGIN { q = int(t / p); if (q < 1) q = 0; print q }')"
  if [[ "$qty" -lt 1 ]]; then
    log_decision "TQQQ" "skip" "tqqq_quantity_below_one_share" "$(jq -nc --arg target "$target_notional" --arg last "$last_price" '{target:$target,last:$last}')"
    return
  fi

  declare -F protection_gross_exposure_or_die >/dev/null && \
    protection_gross_exposure_or_die "$target_notional"

  local payload response
  payload="$(jq -nc --arg symbol "TQQQ" --arg qty "$qty" '{symbol:$symbol,qty:$qty,side:"buy",type:"market",time_in_force:"day"}')"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_decision "TQQQ" "buy" "dry_run_tqqq_core_entry" "$(jq -nc --arg qty "$qty" --arg spy "$spy_change_pct" --arg target "$target_notional" --argjson payload "$payload" '{qty:$qty,spy_change_pct:$spy,target_notional:$target,simulated_order:$payload}')"
  elif response="$(trading_post "/v2/orders" "$payload" 2>&1)"; then
    log_decision "TQQQ" "buy" "tqqq_core_entry" "$(jq -nc --arg qty "$qty" --arg spy "$spy_change_pct" --arg target "$target_notional" '{qty:$qty,spy_change_pct:$spy,target_notional:$target}')"
  else
    log_decision "TQQQ" "skip" "tqqq_core_entry_failed" "$(jq -nc --arg err "$response" '{error:$err}')"
  fi
}

fetch_most_actives() {
  local most_active_json
  if ! most_active_json="$(data_get "/v1beta1/screener/stocks/most-actives?top=100")"; then
    return 1
  fi
  jq -r '.most_actives[]?.symbol // .mostActives[]?.symbol // empty' <<<"$most_active_json" | head -n 20
}

scan_and_enter_momentum() {
  local candidates_tmp
  candidates_tmp="$(mktemp)"
  trap "rm -f \"$candidates_tmp\"" RETURN

  if ! fetch_most_actives >"$candidates_tmp"; then
    log_decision "ALL" "skip" "most_actives_fetch_failed" "{}"
    return
  fi

  local candidate_count
  candidate_count="$(wc -l <"$candidates_tmp" | tr -d ' ')"
  if [[ "$candidate_count" -eq 0 ]]; then
    log_decision "ALL" "skip" "no_most_active_candidates" "{}"
    return
  fi

  local positions_json open_count
  positions_json="$(trading_get "/v2/positions")"
  open_count="$(jq 'length' <<<"$positions_json")"

  cat "$candidates_tmp" | while read -r symbol; do
    [[ -z "$symbol" ]] && continue

    if [[ "$open_count" -ge "$MAX_OPEN_POSITIONS" ]]; then
      log_decision "$symbol" "skip" "max_open_positions_reached" "$(jq -nc --arg open "$open_count" --arg max "$MAX_OPEN_POSITIONS" '{open:$open,max:$max}')"
      continue
    fi

    local snapshot_json snapshot_data prev_close last_price change_pct
    if ! snapshot_json="$(data_get "/v2/stocks/snapshots?symbols=${symbol}")"; then
      log_decision "$symbol" "skip" "snapshot_fetch_failed" "{}"
      continue
    fi
    if declare -F protection_validate_snapshot >/dev/null && \
       ! protection_validate_snapshot "$snapshot_json" "$symbol"; then
      log_decision "$symbol" "skip" "snapshot_stale" "{}"
      continue
    fi
    snapshot_data="$(jq -r ".[\"${symbol}\"] // {}" <<<"$snapshot_json")"
    prev_close="$(jq -r '.prevDailyBar.c // 0' <<<"$snapshot_data")"
    last_price="$(jq -r '.latestTrade.p // .dailyBar.c // 0' <<<"$snapshot_data")"

    if [[ "$(awk -v p="$prev_close" -v l="$last_price" 'BEGIN {print (p <= 0 || l <= 0)}')" -eq 1 ]]; then
      log_decision "$symbol" "skip" "invalid_price_data" "$(jq -nc --arg prev "$prev_close" --arg last "$last_price" '{prev_close:$prev,last_price:$last}')"
      continue
    fi

    change_pct="$(awk -v p="$prev_close" -v l="$last_price" 'BEGIN { printf "%.4f", ((l - p) / p) * 100 }')"

    if [[ "$(awk -v c="$change_pct" -v lo="$GAIN_BAND_MIN" -v hi="$GAIN_BAND_MAX" 'BEGIN {print (c < lo || c > hi)}')" -eq 1 ]]; then
      log_decision "$symbol" "skip" "outside_gain_band" "$(jq -nc --arg change_pct "$change_pct" --arg band "${GAIN_BAND_MIN}_to_${GAIN_BAND_MAX}" '{change_pct:$change_pct,band:$band}')"
      continue
    fi

    local account_json equity buying_power max_position_notional current_position_value remaining_capacity target_notional qty extra
    account_json="$(trading_get "/v2/account")"
    equity="$(jq -r '.equity' <<<"$account_json")"
    buying_power="$(jq -r '.buying_power' <<<"$account_json")"

    max_position_notional="$(awk -v e="$equity" -v f="$MAX_POSITION_FRACTION" 'BEGIN { printf "%.2f", e * f }')"
    positions_json="$(trading_get "/v2/positions")"
    current_position_value="$(jq -r --arg sym "$symbol" '[.[] | select(.symbol == $sym) | (.market_value|tonumber)] | add // 0' <<<"$positions_json")"
    remaining_capacity="$(awk -v max="$max_position_notional" -v cur="$current_position_value" 'BEGIN { printf "%.2f", max - cur }')"

    if [[ "$(awk -v rc="$remaining_capacity" 'BEGIN {print (rc <= 0)}')" -eq 1 ]]; then
      log_decision "$symbol" "skip" "max_position_cap" "$(jq -nc --arg equity "$equity" --arg current "$current_position_value" --arg max "$max_position_notional" '{equity:$equity,current_position_value:$current,max_position_notional:$max}')"
      continue
    fi

    target_notional="$(awk -v rc="$remaining_capacity" -v bp="$buying_power" 'BEGIN { t = rc < bp ? rc : bp; printf "%.2f", t }')"
    if [[ "$(awk -v t="$target_notional" 'BEGIN {print (t <= 0)}')" -eq 1 ]]; then
      log_decision "$symbol" "skip" "insufficient_buying_power" "$(jq -nc --arg buying_power "$buying_power" --arg target "$target_notional" '{buying_power:$buying_power,target_notional:$target}')"
      continue
    fi

    qty="$(awk -v t="$target_notional" -v p="$last_price" 'BEGIN { q = int(t / p); if (q < 1) q = 0; print q }')"
    if [[ "$qty" -lt 1 ]]; then
      log_decision "$symbol" "skip" "quantity_below_one_share" "$(jq -nc --arg target "$target_notional" --arg last "$last_price" '{target_notional:$target,last_price:$last}')"
      continue
    fi

    declare -F protection_gross_exposure_or_die >/dev/null && \
      protection_gross_exposure_or_die "$target_notional"

    extra="$(jq -nc --arg equity "$equity" --arg buying_power "$buying_power" --arg change_pct "$change_pct" '{equity:$equity,buying_power:$buying_power,change_pct:$change_pct}')"
    if submit_bracket_buy "$symbol" "$qty" "$last_price" "momentum_entry" "$extra"; then
      open_count=$((open_count + 1))
    fi
  done
}

# Endgame: pick the single highest-change_pct mover, dump full intraday BP into it,
# no bracket — flattened by EOD step at 3:30. Only run when behind on day 10.
yolo_entry() {
  local candidates_tmp
  candidates_tmp="$(mktemp)"
  trap "rm -f \"$candidates_tmp\"" RETURN

  if ! fetch_most_actives >"$candidates_tmp"; then
    log_decision "ALL" "skip" "yolo_most_actives_fetch_failed" "{}"
    return
  fi

  local best_symbol="" best_change="-100" best_price="0"
  while read -r symbol; do
    [[ -z "$symbol" ]] && continue
    local snapshot_json prev_close last_price change_pct
    if ! snapshot_json="$(data_get "/v2/stocks/snapshots?symbols=${symbol}")"; then continue; fi
    if declare -F protection_validate_snapshot >/dev/null && \
       ! protection_validate_snapshot "$snapshot_json" "$symbol"; then continue; fi
    prev_close="$(jq -r ".[\"${symbol}\"].prevDailyBar.c // 0" <<<"$snapshot_json")"
    last_price="$(jq -r ".[\"${symbol}\"].latestTrade.p // .[\"${symbol}\"].dailyBar.c // 0" <<<"$snapshot_json")"
    if [[ "$(awk -v p="$prev_close" -v l="$last_price" 'BEGIN {print (p <= 0 || l <= 0)}')" -eq 1 ]]; then continue; fi
    change_pct="$(awk -v p="$prev_close" -v l="$last_price" 'BEGIN { printf "%.4f", ((l - p) / p) * 100 }')"
    if [[ "$(awk -v c="$change_pct" -v b="$best_change" 'BEGIN {print (c > b)}')" -eq 1 ]]; then
      best_symbol="$symbol"
      best_change="$change_pct"
      best_price="$last_price"
    fi
  done <"$candidates_tmp"

  if [[ -z "$best_symbol" ]]; then
    log_decision "ALL" "skip" "yolo_no_candidate" "{}"
    return
  fi

  local account_json buying_power qty payload response
  account_json="$(trading_get "/v2/account")"
  buying_power="$(jq -r '.daytrading_buying_power // .buying_power' <<<"$account_json")"
  qty="$(awk -v t="$buying_power" -v p="$best_price" 'BEGIN { q = int(t / p); if (q < 1) q = 0; print q }')"
  if [[ "$qty" -lt 1 ]]; then
    log_decision "$best_symbol" "skip" "yolo_quantity_below_one" "$(jq -nc --arg t "$buying_power" --arg p "$best_price" '{target:$t,price:$p}')"
    return
  fi

  declare -F protection_gross_exposure_or_die >/dev/null && \
    protection_gross_exposure_or_die "$buying_power"

  payload="$(jq -nc --arg symbol "$best_symbol" --arg qty "$qty" '{symbol:$symbol,qty:$qty,side:"buy",type:"market",time_in_force:"day"}')"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_decision "$best_symbol" "buy" "dry_run_yolo_entry" "$(jq -nc --arg qty "$qty" --arg change "$best_change" --arg target "$buying_power" --argjson payload "$payload" '{qty:$qty,change_pct:$change,target_notional:$target,simulated_order:$payload}')"
  elif response="$(trading_post "/v2/orders" "$payload" 2>&1)"; then
    log_decision "$best_symbol" "buy" "yolo_entry" "$(jq -nc --arg qty "$qty" --arg change "$best_change" --arg target "$buying_power" '{qty:$qty,change_pct:$change,target_notional:$target}')"
  else
    log_decision "$best_symbol" "skip" "yolo_entry_failed" "$(jq -nc --arg err "$response" '{error:$err}')"
  fi
}

main() {
  local run_mode="live"
  [[ "$DRY_RUN" == "true" ]] && run_mode="dry_run"
  log_decision "SYSTEM" "info" "run_start" "$(jq -nc --arg run "$run_mode" --arg force "$FORCE_RUN" '{run_mode:$run,force:$force}')"

  local protection_lib="$SKILL_DIR/../trader-protection/scripts/check.sh"
  if [[ -f "$protection_lib" ]]; then
    # shellcheck disable=SC1090
    source "$protection_lib"
    protection_init
    protection_kill_switch_or_die
    protection_acquire_lock_or_die
  fi

  local clock_json is_open
  clock_json="$(trading_get "/v2/clock")"
  is_open="$(jq -r '.is_open' <<<"$clock_json")"

  if [[ "$FORCE_RUN" == "true" ]]; then
    log_decision "SYSTEM" "info" "force_market_check_bypassed" "{}"
  elif [[ "$is_open" != "true" ]]; then
    log_decision "ALL" "skip" "market_closed" "{}"
    exit 0
  fi

  if [[ "$TRADE_MODE" == "lock" ]]; then
    eod_step
    exit 0
  fi

  local et_hm
  et_hm="$(TZ=America/New_York date +%H:%M)"

  if [[ "$et_hm" > "15:29" ]]; then
    eod_step
    exit 0
  fi

  # Equity-based protection runs only on the entry paths (yolo / build+tilt morning).
  # EOD and lock flatten paths intentionally bypass these so a drawdown breach can
  # still close out positions instead of leaving them stuck open.
  if declare -F protection_drawdown_or_die >/dev/null; then
    local pre_account_json pre_equity
    pre_account_json="$(trading_get "/v2/account")"
    pre_equity="$(jq -r '.equity' <<<"$pre_account_json")"
    protection_drawdown_or_die "$pre_equity"
    protection_daily_loss_or_die "$pre_equity"
    protection_record_equity "$pre_equity"
  fi

  if [[ "$TRADE_MODE" == "yolo" ]]; then
    yolo_entry
    exit 0
  fi

  tqqq_core_step
  scan_and_enter_momentum
}

main

# Cron install commands (EST/ET weekdays at 9:35 AM and 3:30 PM):
# (crontab -l 2>/dev/null; echo '35 9 * * 1-5 TZ=America/New_York /docker/openclaw-gsej/data/.openclaw/skills/sissclaw-trader/scripts/trade.sh >> /docker/openclaw-gsej/data/.openclaw/skills/sissclaw-trader/logs/cron.log 2>&1') | crontab -
# (crontab -l 2>/dev/null; echo '30 15 * * 1-5 TZ=America/New_York /docker/openclaw-gsej/data/.openclaw/skills/sissclaw-trader/scripts/trade.sh >> /docker/openclaw-gsej/data/.openclaw/skills/sissclaw-trader/logs/cron.log 2>&1') | crontab -
#
# Mode switching: TRADE_MODE=tilt /docker/.../trade.sh (or set TRADE_MODE in .env)

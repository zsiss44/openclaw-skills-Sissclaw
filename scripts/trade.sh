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
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run)
        DRY_RUN="true"
        shift
        ;;
      -f|--force)
        FORCE_RUN="true"
        shift
        ;;
      -h|--help)
        SHOW_HELP="true"
        shift
        ;;
      *)
        echo "Unknown argument: $1" >&2
        print_usage >&2
        exit 2
        ;;
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
MAX_POSITION_FRACTION="0.10"
STOP_LOSS_PCT="0.02"
TAKE_PROFIT_PCT="0.04"

require_binary() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required dependency: $1" >&2
    exit 1
  fi
}

require_binary curl
require_binary jq
require_binary awk

json_escape() {
  jq -Rsa . <<<"$1"
}

log_decision() {
  local symbol="$1"
  local action="$2"
  local reason="$3"
  local details="${4:-{}}"
  local ts
  ts="$(TZ=America/New_York date -Iseconds)"

  printf '{"timestamp":"%s","symbol":"%s","action":"%s","reason":%s,"details":%s}\n' \
    "$ts" "$symbol" "$action" "$(json_escape "$reason")" "$details" >>"$LOG_FILE"
}

trading_get() {
  local path="$1"
  curl -sS -f \
    -H "APCA-API-KEY-ID: $APCA_API_KEY_ID" \
    -H "APCA-API-SECRET-KEY: $APCA_API_SECRET_KEY" \
    "$TRADING_BASE_URL$path"
}

data_get() {
  local path="$1"
  curl -sS -f \
    -H "APCA-API-KEY-ID: $APCA_API_KEY_ID" \
    -H "APCA-API-SECRET-KEY: $APCA_API_SECRET_KEY" \
    "$DATA_BASE_URL$path"
}

trading_post() {
  local path="$1"
  local body="$2"
  curl -sS -f \
    -X POST \
    -H "APCA-API-KEY-ID: $APCA_API_KEY_ID" \
    -H "APCA-API-SECRET-KEY: $APCA_API_SECRET_KEY" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$TRADING_BASE_URL$path"
}

sell_all_positions() {
  local positions_json
  positions_json="$(trading_get "/v2/positions")"

  local position_count
  position_count="$(jq 'length' <<<"$positions_json")"
  if [[ "$position_count" -eq 0 ]]; then
    log_decision "ALL" "skip" "no_open_positions_at_eod" "{}"
    return
  fi

  jq -c '.[]' <<<"$positions_json" | while read -r pos; do
    local symbol qty abs_qty side payload
    symbol="$(jq -r '.symbol' <<<"$pos")"
    qty="$(jq -r '.qty' <<<"$pos")"

    abs_qty="$(awk -v q="$qty" 'BEGIN { if (q < 0) print -q; else print q }')"
    if [[ "$(awk -v q="$abs_qty" 'BEGIN {print (q <= 0)}')" -eq 1 ]]; then
      log_decision "$symbol" "skip" "invalid_position_qty" "{}"
      continue
    fi

    side="sell"

    payload="$(jq -nc \
      --arg symbol "$symbol" \
      --arg qty "$abs_qty" \
      --arg side "$side" \
      '{symbol:$symbol, qty:$qty, side:$side, type:"market", time_in_force:"day"}')"

    if [[ "$DRY_RUN" == "true" ]]; then
      log_decision "$symbol" "sell" "dry_run_end_of_day_flatten" "$(jq -nc --arg qty "$abs_qty" --argjson payload "$payload" '{qty:$qty,simulated_order:$payload}')"
    elif response="$(trading_post "/v2/orders" "$payload" 2>&1)"; then
      log_decision "$symbol" "sell" "end_of_day_flatten" "$(jq -nc --arg qty "$abs_qty" '{qty:$qty}')"
    else
      log_decision "$symbol" "skip" "eod_sell_failed" "$(jq -nc --arg err "$response" '{error:$err}')"
    fi
  done
}

fetch_sp500_symbols() {
  curl -sS -f "https://datahub.io/core/s-and-p-500-companies/r/constituents.csv" \
    | awk -F, 'NR>1 { gsub(/\"/, "", $1); print $1 }'
}

main() {
  local run_mode
  run_mode="live"
  if [[ "$DRY_RUN" == "true" ]]; then
    run_mode="dry_run"
  fi
  log_decision "SYSTEM" "info" "run_start" "$(jq -nc --arg mode "$run_mode" --arg force "$FORCE_RUN" '{mode:$mode,force:$force}')"

  local account_json equity buying_power
  account_json="$(trading_get "/v2/account")"
  equity="$(jq -r '.equity' <<<"$account_json")"
  buying_power="$(jq -r '.buying_power' <<<"$account_json")"

  local clock_json is_open
  clock_json="$(trading_get "/v2/clock")"
  is_open="$(jq -r '.is_open' <<<"$clock_json")"

  if [[ "$FORCE_RUN" == "true" ]]; then
    log_decision "SYSTEM" "info" "force_market_check_bypassed" "{}"
  elif [[ "$is_open" != "true" ]]; then
    log_decision "ALL" "skip" "market_closed" "$(jq -nc --arg buying_power "$buying_power" '{buying_power:$buying_power}')"
    exit 0
  fi

  local et_hm
  et_hm="$(TZ=America/New_York date +%H:%M)"

  if [[ "$et_hm" > "15:29" ]]; then
    sell_all_positions
    exit 0
  fi

  local candidates_tmp
  candidates_tmp="$(mktemp)"
  trap "rm -f \"$candidates_tmp\"" EXIT

  local most_active_json
  most_active_json="$(data_get "/v1beta1/screener/stocks/most-actives?top=100")"

  # Use the top 20 most-active symbols directly (no S&P500 intersection)
  jq -r '.most_actives[]?.symbol // .mostActives[]?.symbol // empty' <<<"$most_active_json" | head -n 20 >"$candidates_tmp" || true

  local candidate_count
  candidate_count="$(wc -l <"$candidates_tmp" | tr -d ' ')"
  if [[ "$candidate_count" -eq 0 ]]; then
    log_decision "ALL" "skip" "no_sp500_most_active_candidates" "{}"
    exit 0
  fi

  local symbols_csv
  symbols_csv="$(paste -sd, "$candidates_tmp")"


    cat "$candidates_tmp" | while read -r symbol; do
      [[ -z "$symbol" ]] && continue

      local bars_json bars_count prev_close last_price change_pct
      if ! bars_json="$(data_get "/v2/stocks/${symbol}/bars?timeframe=1Day&limit=2")"; then
        log_decision "$symbol" "skip" "bars_fetch_failed" "$(jq -nc --arg err "failed_to_fetch_bars" '{error:$err}')"
        continue
      fi

      bars_count="$(jq '.bars | length' <<<"$bars_json")"
      
      # If insufficient daily bars, fall back to snapshots endpoint
      if [[ "$bars_count" -lt 2 ]]; then
        local snapshots_json snapshot_data
        if snapshots_json="$(data_get "/v2/stocks/snapshots?symbols=${symbol}")"; then
          snapshot_data="$(jq -r ".[\"${symbol}\"] // {}" <<<"$snapshots_json")"
          prev_close="$(jq -r '.prevDailyBar.c // 0' <<<"$snapshot_data")"
          last_price="$(jq -r '.latestTrade.p // .dailyBar.c // 0' <<<"$snapshot_data")"
          
          # If snapshots also failed to provide valid data, skip
          if [[ "$(awk -v p="$prev_close" -v l="$last_price" 'BEGIN {print (p <= 0 || l <= 0)}')" -eq 1 ]]; then
            log_decision "$symbol" "skip" "invalid_price_data_fallback" "$(jq -nc --arg prev "$prev_close" --arg last "$last_price" '{prev_close:$prev,last_price:$last,source:"snapshots"}')"
            continue
          fi
        else
          log_decision "$symbol" "skip" "insufficient_bars_and_snapshot_fetch_failed" "$(jq -nc --arg count "$bars_count" '{bars:$count}')"
          continue
        fi
      else
        prev_close="$(jq -r '.bars[1].c // 0' <<<"$bars_json")"
        last_price="$(jq -r '.bars[0].c // 0' <<<"$bars_json")"
      fi

      if [[ "$(awk -v p="$prev_close" -v l="$last_price" 'BEGIN {print (p <= 0 || l <= 0)}')" -eq 1 ]]; then
        log_decision "$symbol" "skip" "invalid_price_data" "$(jq -nc --arg prev "$prev_close" --arg last "$last_price" '{prev_close:$prev,last_price:$last}')"
        continue
      fi

      change_pct="$(awk -v p="$prev_close" -v l="$last_price" 'BEGIN { printf "%.4f", ((l - p) / p) * 100 }')"

      if [[ "$(awk -v c="$change_pct" 'BEGIN {print (c < 0.5)}')" -eq 1 ]]; then
        log_decision "$symbol" "skip" "below_min_gain" "$(jq -nc --arg change_pct "$change_pct" '{change_pct:$change_pct}')"
        continue
      fi

      account_json="$(trading_get "/v2/account")"
      equity="$(jq -r '.equity' <<<"$account_json")"
      buying_power="$(jq -r '.buying_power' <<<"$account_json")"

      local max_position_notional current_position_value remaining_capacity target_notional qty
      max_position_notional="$(awk -v e="$equity" -v f="$MAX_POSITION_FRACTION" 'BEGIN { printf "%.2f", e * f }')"

      local positions_json
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

      local stop_price take_profit_price
      stop_price="$(awk -v p="$last_price" -v pct="$STOP_LOSS_PCT" 'BEGIN { printf "%.2f", p * (1 - pct) }')"
      take_profit_price="$(awk -v p="$last_price" -v pct="$TAKE_PROFIT_PCT" 'BEGIN { printf "%.2f", p * (1 + pct) }')"

      local order_payload order_response
      order_payload="$(jq -nc \
        --arg symbol "$symbol" \
        --arg qty "$qty" \
        --arg stop_price "$stop_price" \
        --arg take_profit_price "$take_profit_price" \
        '{
          symbol:$symbol,
          qty:$qty,
          side:"buy",
          type:"market",
          time_in_force:"day",
          order_class:"bracket",
          stop_loss:{stop_price:$stop_price},
          take_profit:{limit_price:$take_profit_price}
        }')"

      if [[ "$DRY_RUN" == "true" ]]; then
        log_decision "$symbol" "buy" "dry_run_momentum_entry" "$(jq -nc \
          --arg qty "$qty" \
          --arg equity "$equity" \
          --arg buying_power "$buying_power" \
          --arg change_pct "$change_pct" \
          --arg last_price "$last_price" \
          --arg stop_price "$stop_price" \
          --arg take_profit_price "$take_profit_price" \
          --argjson order_payload "$order_payload" \
          '{qty:$qty,equity:$equity,buying_power:$buying_power,change_pct:$change_pct,last_price:$last_price,stop_price:$stop_price,take_profit_price:$take_profit_price,simulated_order:$order_payload}')"
      elif order_response="$(trading_post "/v2/orders" "$order_payload" 2>&1)"; then
        log_decision "$symbol" "buy" "momentum_entry" "$(jq -nc \
          --arg qty "$qty" \
          --arg equity "$equity" \
          --arg buying_power "$buying_power" \
          --arg change_pct "$change_pct" \
          --arg last_price "$last_price" \
          --arg stop_price "$stop_price" \
          --arg take_profit_price "$take_profit_price" \
          '{qty:$qty,equity:$equity,buying_power:$buying_power,change_pct:$change_pct,last_price:$last_price,stop_price:$stop_price,take_profit_price:$take_profit_price}')"
      else
        log_decision "$symbol" "skip" "order_submit_failed" "$(jq -nc --arg err "$order_response" '{error:$err}')"
      fi
    done
  }

main

# Cron install commands (EST/ET weekdays at 9:35 AM and 3:30 PM):
# (crontab -l 2>/dev/null; echo '35 9 * * 1-5 TZ=America/New_York /docker/openclaw-gsej/data/.openclaw/skills/sissclaw-trader/scripts/trade.sh >> /docker/openclaw-gsej/data/.openclaw/skills/sissclaw-trader/logs/cron.log 2>&1') | crontab -
# (crontab -l 2>/dev/null; echo '30 15 * * 1-5 TZ=America/New_York /docker/openclaw-gsej/data/.openclaw/skills/sissclaw-trader/scripts/trade.sh >> /docker/openclaw-gsej/data/.openclaw/skills/sissclaw-trader/logs/cron.log 2>&1') | crontab -

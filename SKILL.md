---
name: sissclaw-trader
description: Autonomous Alpaca paper-trading momentum strategy with mode-tiered leverage, TQQQ core, and selective overnight holds — built for a short-horizon competition where highest absolute return wins.
allowed-tools:
  - bash
---

# sissclaw-trader

## Purpose

`sissclaw-trader` runs an autonomous momentum strategy against the Alpaca paper trading API at `https://paper-api.alpaca.markets`. Tuned for a multi-week competition: highest absolute % return wins, no real downside on paper losses, so the scoring rewards variance — especially when behind.

Authenticates via env vars:
- `APCA_API_KEY_ID`
- `APCA_API_SECRET_KEY`

## Schedule (ET, Weekdays)

- `9:35 AM` — entries (TQQQ core + momentum scan, or yolo single pick)
- `3:30 PM` — EOD policy (selective flatten, or hard flatten depending on mode/day)

Cron:
- `35 9 * * 1-5`
- `30 15 * * 1-5`

## Trading Modes (`TRADE_MODE` env var)

Switch modes by setting `TRADE_MODE` before running. Default is `build`.

| Mode | Per-position cap | Max names | TQQQ core | Use |
|---|---|---|---|---|
| `build` | 25% of equity | 4 | yes | Days 1–7 |
| `tilt` | 50% of equity | 2 | yes | Catch-up, days 8–9 |
| `yolo` | full intraday BP | 1 | no | Endgame, only when behind |
| `lock` | 0% | 0 | no | Endgame, when leading — flatten and sit |

## Strategy Rules

1. Verify market is open before any action (override with `--force`).
2. Verify account buying power before every trade.
3. Scan top 20 most-active stocks from Alpaca's screener.
4. Buy only symbols up **1% to 5%** from previous close (the momentum entry band).
5. Per-position cap is mode-dependent (see table). Cap also bounds the open-position count.
6. Bracket every individual-name entry:
   - stop-loss: 2% below entry
   - take-profit: 4% above entry
7. **TQQQ core** (build/tilt only): if SPY is up ≥ 0.30% at the morning run, hold ~30% of equity in TQQQ. No bracket — TQQQ rides; risk is managed by the EOD policy. Allocation grows on green days as equity grows (concentrating into momentum).
8. **EOD policy at 3:30 PM**:
   - Friday → flatten everything (no weekend gap risk).
   - `yolo` or `lock` mode → flatten everything.
   - Otherwise (build/tilt M–Th) → **hold green positions overnight, flatten red ones.** Captures momentum drift while containing losses.
9. **Yolo mode**: at 9:35, pick the single best mover from the most-actives list (no upper band cap), enter with full daytrading buying power (~4× equity), no bracket. Flattens at 3:30 same day. Use only when behind on the final day(s).
10. **Lock mode**: flatten everything on next run, sit in cash until mode is changed.
11. Every decision (buy/sell/hold/skip/info) is logged with reason, mode, and metrics.

## Execution Outline

1. Pull account + clock state from Alpaca.
2. Abort with log entry if market is closed (unless `--force`).
3. If `TRADE_MODE=lock`: flatten everything and exit.
4. If past 15:29 ET: run EOD policy and exit.
5. If `TRADE_MODE=yolo`: pick single best mover, dump intraday BP, exit.
6. Otherwise (build/tilt morning):
   - TQQQ core step (enter/hold/skip based on SPY tape).
   - Momentum scan: top 20 most-actives → 1–5% gainer band → mode-sized bracket buy → log.

## Logging

Each line is one JSON object with fields:
- `timestamp` (ISO 8601 ET)
- `symbol`
- `action` — `buy` | `sell` | `hold` | `skip` | `info`
- `reason` — e.g. `momentum_entry`, `tqqq_core_entry`, `outside_gain_band`, `max_position_cap`, `overnight_hold_green`, `friday_flatten_all`, `yolo_entry`, `end_of_day_red_flatten`
- `mode` — current `TRADE_MODE`
- `details` — equity, buying power, change %, qty, prices, etc.

Logs land in `logs/trade-decisions.log` (gitignored).

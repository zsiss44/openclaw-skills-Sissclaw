---
name: trader-protection
description: Sourceable bash library of pre-trade safety checks (kill-switch, drawdown circuit-breaker, daily loss cap, stale-data guard, cron lock, hard $ ceiling). Designed to be sourced by other trading skills (e.g. sissclaw-trader/scripts/trade.sh) before any order is submitted. Use when adding hard-coded limits to an autonomous trading agent.
allowed-tools:
  - bash
---

# trader-protection

A defensive bash library that other trading skills source before submitting
orders. Implements the **Protection** layer of the 7-skill agent framework:
hard-coded limits, kill-switches, and pre-trade sanity checks.

This skill ships **no executable** of its own — it is consumed via:

```bash
source /path/to/trader-protection/scripts/check.sh
```

## Functions

| Function | Behavior on breach | Use |
|---|---|---|
| `protection_init` | — | Call once at startup; ensures state dir exists. |
| `protection_kill_switch_or_die` | `exit 0` | First check in `main()`. Touch `$PROTECTION_KILL_SWITCH` to halt all trading. |
| `protection_acquire_lock_or_die` | `exit 0` | Prevents two concurrent cron runs from racing. |
| `protection_drawdown_or_die <equity>` | `exit 0` | Tracks high-water-mark; aborts if drawdown from HWM exceeds cap. |
| `protection_daily_loss_or_die <equity>` | `exit 0` | Anchors equity at first run each ET trading day; aborts if intraday loss exceeds cap. |
| `protection_validate_snapshot <json> <symbol>` | `return 1` | Caller should `continue`/skip the symbol — does **not** exit, since stale data on one ticker shouldn't kill the whole run. |
| `protection_record_equity <equity>` | — | Convenience wrapper: updates HWM, sets daily anchor if first run today. |

All breach actions exit `0` (intentional halt, not error) so cron doesn't
keep retrying and emailing failures. Each breach writes one JSON line to
the protection log.

## Configuration (env vars, all optional)

| Var | Default | Notes |
|---|---|---|
| `PROTECTION_KILL_SWITCH` | `$HOME/.openclaw/KILL_SWITCH` | Touch this file to stop all trading. |
| `PROTECTION_LOCK_FILE` | `/tmp/sissclaw-trader.lock` | One per trader skill — separate locks for separate strategies. |
| `PROTECTION_MAX_DRAWDOWN_PCT` | `0.08` | 8% from HWM. Matches teacher's framework. |
| `PROTECTION_MAX_DAILY_LOSS_PCT` | `0.03` | 3% from today's open equity. |
| `PROTECTION_MAX_SNAPSHOT_AGE_SEC` | `120` | Reject snapshots older than 2 min. |
| `PROTECTION_MAX_GROSS_EXPOSURE_USD` | `200000` | Hard $ ceiling regardless of mode/leverage. |
| `PROTECTION_STATE_DIR` | `<this skill>/state` | HWM and daily anchor JSON live here. |
| `PROTECTION_LOG_FILE` | `<this skill>/logs/protection.log` | One JSON object per line. |

## State files

`state/equity-hwm.json`:
```json
{"hwm": 64000.00, "hwm_ts": "2026-04-30T14:00:00-04:00"}
```

`state/daily-anchor.json`:
```json
{"date": "2026-04-30", "equity_open": 63800.00}
```

State files are gitignored (real equity numbers are mildly sensitive even on
paper, and they cause merge churn).

## Integration pattern

In a trading skill's `main()`:

```bash
source "$PROTECTION_LIB"      # path to trader-protection/scripts/check.sh
protection_init
protection_kill_switch_or_die
protection_acquire_lock_or_die

# fetch equity from broker
equity="$(get_equity_from_alpaca)"
protection_drawdown_or_die "$equity"
protection_daily_loss_or_die "$equity"
protection_record_equity "$equity"

# now do trading work; before each snapshot-driven entry:
if ! protection_validate_snapshot "$snap_json" "$symbol"; then
  continue
fi
```

## Current wiring

As of skill creation: **only `protection_kill_switch_or_die` is wired into
`sissclaw-trader/scripts/trade.sh`** as a smoke test. The rest of the
functions are implemented but uncalled — the user will review and wire the
remaining hooks once the kill-switch path is verified.

## Testing

Smoke test the kill switch:

```bash
mkdir -p ~/.openclaw && touch ~/.openclaw/KILL_SWITCH
bash /docker/openclaw-gsej/data/.openclaw/skills/sissclaw-trader/scripts/trade.sh --dry-run
# Should exit immediately with "kill_switch_active" in protection log.
rm ~/.openclaw/KILL_SWITCH
```

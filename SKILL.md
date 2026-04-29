---
name: sissclaw-trader
description: Autonomous Alpaca paper-trading momentum strategy with strict risk controls, scheduled weekday runs, and full trade-decision logging.
allowed-tools:
  - bash
---

# sissclaw-trader

## Purpose

`sissclaw-trader` runs an autonomous momentum strategy against the Alpaca paper trading API at `https://paper-api.alpaca.markets`.

It must authenticate using environment variables:
- `APCA_API_KEY_ID`
- `APCA_API_SECRET_KEY`

## Schedule (EST, Weekdays)

Run on cron at:
- `9:35 AM EST` (market session scan and entries)
- `3:30 PM EST` (pre-close risk-off exit)

Example cron expression (weekday-only):
- `35 9 * * 1-5`
- `30 15 * * 1-5`

## Required Strategy Rules

1. Check US market hours before doing anything.
2. Verify account buying power before every trade.
3. Scan the top 20 most active S&P 500 stocks.
4. Buy only symbols up 2% to 5% from previous close.
5. Never allocate more than 10% of total equity to one position.
6. Attach hard exits to every entry:
    - stop-loss: 2% below entry
    - take-profit: 4% above entry
7. At `3:30 PM EST`, sell all open positions before market close.
8. Log every trade decision (buy, skip, sell) with a specific reason.

## Execution Outline

1. Pull account + clock state from Alpaca.
2. Abort with log entry if market is closed.
3. At morning run:
    - fetch top 20 most active S&P 500 symbols,
    - compute percent change from previous close,
    - filter to 2-5% gainers,
    - size each candidate with max position cap (10% of equity),
    - re-check buying power immediately before order submit,
    - submit buy + protective stop-loss/take-profit orders,
    - log action and rationale.
4. At `3:30 PM EST` run:
    - liquidate all open positions,
    - log each close action and reason (`end_of_day_flatten`).

## Logging Requirements

Every decision should include:
- timestamp (EST)
- symbol
- action (`buy` | `sell` | `skip`)
- reason (e.g., `outside_gain_band`, `insufficient_buying_power`, `max_position_cap`, `eod_exit`)
- key metrics used (equity, buying power, change %, calculated size)

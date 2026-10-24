# PRD: Personal Stock Tracker (DRAFT v2)

Status: draft, awaiting answers to open questions.
Data rule: the Google Sheet "Monthly Expense" is the single source of truth for holdings. No holdings or balances are copied into this repo. Generated output goes in a git-ignored folder.

## Goal
A personal tool that watches Lionel's holdings and a separate watchlist of stocks he follows on and off, flags important news and posts as early as practical, and explains why each item matters. It also shows a risk view of the portfolio against his own rules.

## Boundaries
- Flags, summarizes and explains likely impact. It does not give buy, sell or hold recommendations; Lionel decides.
- No client or work data.
- Read-only on the sheet except a new tab added with permission.

## Module A: Watch and alert
- Watchlist = current holdings (read live from the sheet's Tiger tab) plus a separate "Watchlist" tab for other stocks, maintained by Lionel.
- Sources: Trump posts and policy news, X accounts and keywords, Reddit, news and filings (e.g. SEC 8-K, exchange announcements).
- Cadence: a few times a day (decision 24 Oct 2026). Same sensitivity for every stock.
- Output per alert: stock(s) touched, what happened, source link, plausible mechanism, relevance and urgency rating, what to verify next.
- Delivery: Telegram push plus email.
- Must run without the PC being on (cloud scheduled job), with secrets stored in the cloud environment, not in the repo.

## Module B: Risk dashboard
- New "Risk Dashboard" tab in the sheet: concentration, single-stock share, defensive share, margin loan, currency exposure, drawdown from peak, monthly snapshots.
- Thresholds set by Lionel in one editable block.

## Source feasibility (to confirm before building)
- X: official API is paid; scraping is against terms. Alternatives: RSS or news aggregators that quote posts.
- Reddit: official API is rate-limited but free for small personal use.
- Trump posts: Truth Social is his main outlet; X mirrors and news coverage are the practical route.
- News and filings: SEC EDGAR is free; headline feeds vary.

## Decisions (24 Oct 2026, round 2)
- Checks run at 07:00, 22:00 and 23:30 Singapore time (before the day, US pre-market, first hour of US trading).
- Non-holding watchlist lives in a new "Watchlist" tab in the sheet.
- Free data sources only; X coverage will be limited and is labelled as such.
- Starter set of accounts, keywords and subreddits is proposed by Claude and edited by Lionel.

## Open questions
- Non-holding watchlist tickers.
- Approve or edit the starter set of sources.
- Threshold values for Module B.
- Which cloud runner to use for the schedule, and how secrets are stored there.

# Bell

**The exchange has an opening bell. The onchain market for its shares does not.**

Tokenized equities trade around the clock; the shares behind them trade six and a half hours a day. Every
Chainlink equity feed on Robinhood Chain answers `latestRoundData()` at 03:00 on a Sunday, and it answers
with a number that looks exactly like a market price.

Be precise about what the feed does and does not tell you, because an earlier draft of this README was not.
It **does** return `updatedAt`, so the age of the onchain round is available to any caller
([Chainlink API reference](https://docs.chain.link/data-feeds/api-reference)). What no equity feed here can
express is the other half: **whether that price belongs to the regular session**, or to overnight trading,
or to a day the exchange never opened. And `updatedAt` is the time the round was written onchain, not the
time of the market observation behind it. Bell is the layer that answers the session question, attaches the
age to it, and refuses when the pair is not fit to act on.

> Buildathon work (Arbitrum Open House Singapore, 14 Sept to 4 Oct 2026), solo, unaudited.
> Everything below is live on chainId 4663 and meant to be checked rather than believed.

## Sixty seconds

```bash
python script/verify.py     # no key, no wallet: reads every contract and checks every claim here
```

| Contract | Answers | Address |
|---|---|---|
| **PushFeedGuard** | is this feed's price fit to act on right now, for **all 35 equity feeds** | `0x8aF68a9fF7583097A7476060C6B56eB33dA7a711` |
| **SessionLog** | a public, write-once record of what the feeds said at each bell | `0xc482943C7fEE1dD7807Edad1c88260E4263fD0Ad` |
| **Bell** | session status and a session reference price from DON-signed Data Streams reports, with a receipt | `0x88a5a0414c9fd615201814ddbec4e4d9e4d283d0` |
| **BellFeedAdapter** | the same Chainlink signature, but it reverts instead of returning an inadmissible price | `0x4F0331DDbdDfE3349e16e37F80219A868B876655` |
| **SettleOnMark** | a USDG trade that settles only on a recorded closing mark, and refunds otherwise | `0x52a0E0d3BD4729BCD622fed437EDb428835658Ac` |

**What is proven today, on mainnet:**

- the guard answers for all 35 Chainlink equity feeds from one stateless deployment, with the reason
  attached, and a run six hours before the bell returned **35 REJECT / OUTSIDE_SESSION** while every one
  of those feeds was happily serving a price ([full output](docs/session_report_2026-09-21T0714Z.txt));
- Bell verified two **real DON-signed reports** through the official Chainlink verifier, wrote receipts,
  and then refused to serve them: `checkLive` answers `WAIT / OBS_STALE`. A valid signature is not
  permission;
- the audit in [`docs/REPLAY.md`](docs/REPLAY.md) shows what the absence of this layer already permits:
  of 30 settlements on the chain's only live stock market, **28 read the same feed round on both sides**,
  so a tie-break rule decided them rather than any price movement. The same section attacks its own
  sample: 23 of those 30 were locked and settled within a minute of each other, which looks like an
  operator testing rather than a market trading; the 11.9 hour median price age is an out-of-session
  number, while the two fully in-session cases were 4 and 8 minutes old; and 26 of the 30 markets had no
  bet at all, with 0.009 ETH ever staked across all of them. What survives: a deployed contract on this
  chain can settle a stock market on a price from a day the exchange never opened, and nothing in the
  data it reads can tell it so.

## How much money is on the other side of this question

A guard is only worth as much as the flow it guards, so here is the flow, measured rather than asserted.
Two scripts, public RPC only, no key:

```bash
python script/rh_equity_pools.py   # find the pools, drop the impostor tokens
python script/equity_flow.py       # one week of swaps, split by session
python script/feed_rounds.py       # what the feeds publish, and when
```

**The venue.** Robinhood Chain has 5,944 Uniswap v3 pools holding USDG. Sixty-two of them pair USDG with a
token whose symbol matches one of the 35 Chainlink equity feeds, and four of those sixty-two are impostors:
a fake AMD, two fake SLV, a fake USO. A symbol is a claim, not an identity. The genuine tokens are 283-byte
beacon proxies with the stock-token beacon `0xe10b6f6b275de231345c20d14ab812db62151b00` burned into their
runtime code, so the test is where a contract gets its logic, not what string it returns. The impostors are
3,877 to 8,120 bytes of unrelated code and fail it. That leaves **58 pools across 17 tickers**
([`docs/equity_pools_4663.json`](docs/equity_pools_4663.json)).

The limit of that test, stated because it is weaker than it looks: anyone can deploy an identical proxy on
the same beacon, so this proves lineage, not issuance. What closes the practical gap is that the 58 pools
carry 17 tickers across 17 distinct token addresses, with no ticker claimed twice. Absent a published
registry from the issuer, that is the strongest check available from the chain alone.

**The flow.** Over the seven days ending at block 68,728,047 those 58 pools saw **1,011,296 swaps and
$418,290,551 of USDG volume**. **$212,136,382 of it, 50.7% of the volume and 64.0% of the swaps, traded
while the regular session was shut** ([`docs/equity_flow_4663.json`](docs/equity_flow_4663.json)). The
session split is computed by binary-searching the block at each opening and closing bell, then cross-checked
against the deployed `PushFeedGuard.sessionAt`: **20 probes on the boundaries, 0 disagreements**.

Turn that around before anyone else does, because the flattering framing is not the true one. The regular
session is 32.5 of the window's 168.3 hours, 19.3% of it, and it carries $6,343,205 per hour against
$1,561,718 per hour while shut: **intensity inside the session is 4.1x higher**. This chain does hear the
bell. The claim is narrower and survives the arithmetic: half the week's flow still lands in the hours when
the feed's number belongs to a different session, and the feed does not say so. The figure is also a floor,
because only Uniswap v3 is measured here; the v4 PoolManager on this chain holds more than ten thousand
further USDG pools that this count ignores.

**The feeds.** Over one common ten-day window, the 35 equity feeds published 1,003 rounds, of which
**509 landed outside the regular session** ([`docs/feed_rounds_4663.json`](docs/feed_rounds_4663.json),
drawn in [`docs/feed_rounds.svg`](docs/feed_rounds.svg)). The window matters: an earlier version of this
paragraph counted "the last 30 rounds of each feed", and those thirty rounds span a day and a half on
`Robinhood MSTR / USD` and forty-four days on `RHMSFT / USD`, so the pooled figure was adding up different
amounts of time. A common window says the same thing without the sleight of hand.

**The rate is not a constant a consumer could hard-code.** `RHTSLA / USD` publishes 4 rounds of 30 outside
the session, `Robinhood PLTR / USD` 6, `RHSPY / USD` 18, and `Robinhood MSTR / USD` and
`Robinhood CRCL / USD` 30 of 30. The longest observed gap between rounds is 96.0 hours, on
`Robinhood SGOV-USD`. The chart is the argument: the marks do not line up with the shading, and they do not
line up the same way from one row to the next.

This is also where an earlier version of this README was wrong in the other direction. The feed does not
freeze overnight. On `RHSPY / USD`, round 139 landed at 00:00:26 UTC on Monday 2026-09-21, 59.6 hours after
the previous round and with the price **moved by +0.49%**, while NYSE had been shut since Friday 20:00 UTC.
The first round after each weekend lands at 00:00:2x UTC, which is 20:00 ET Sunday, three weekends out of
three. The number a contract reads at 06:30 UTC is fresh, real and recent. It is simply not a regular-session
number, and nothing in the response says which it is.

**What this does not claim.** $418M is gross volume: an arbitrage round trip is counted on both legs, so it
is an upper bound on economic flow, not a headcount of users. The pools hold $13,890,185 of USDG between
them, so the week represents about thirty turns of that capital. In the largest pool (NVDA/USDG, 0.05%) over
8.4 hours, the top three senders account for 72.0% of swaps but only 31.6% of volume across 102 distinct
senders and 311 distinct recipients, so the flow is bot-heavy in count and broader in value. None of this
shows anyone lost money, or that anyone wants this contract.

**And the honest counterweight:** lending against equities on this chain is not where the money is. Morpho
Blue (`0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010`) carries $461,393,489 of debt on chainId 4663, of which
equity collateral accounts for **$17,119 measured onchain** by `balanceOf` per token, times the feed price,
against $17,548 reported by Morpho's own API. That is 0.0014% of the book. The large markets are
stablecoin against stablecoin, where the concept of a trading session does not apply and this project has
nothing to offer. The flow is on the DEX side; the lending side is still empty.

**What is not proven yet, stated before anyone asks:**

- the ladder, Bell's DON-signed session reference, has never resolved on a real bell. Every signed report
  we hold is mid-session, and US equity Data Streams are not sold to a self-serve account today, so that
  half is code and tests waiting for access, not a live claim ([Limitations](#limitations-we-state-ourselves));
- nobody outside this repo uses any of it yet. The adapter exists so that integrating is one address
  change rather than a rewrite, but a one-line integration is still not an integration.

## Deployed, in full

| | |
|---|---|
| Chain | Robinhood Chain mainnet, chainId 4663 |
| Bell deploy tx | `0xbec3cb1a8813dadf0aa52e66f87d79ecb4dd487b95413fdf2062286a6187c540`, block 68,238,358 |
| Verifier it reads | `0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7` (official Chainlink Data Streams VerifierProxy) |
| Owner | none, and no upgrade path anywhere. `POLICY_VERSION` 2, `CALENDAR_VERSION` 1 |
| Escrow token | Paxos USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, 6 decimals |
| Tests | 144 unit tests and 6 fork tests against the real verifier, all green |

Two calls that need no wallet:

```bash
cast call 0x8aF68a9fF7583097A7476060C6B56eB33dA7a711 "check(address,uint64)(uint8,uint8,int256,uint256)"   0x6B22A786bAa607d76728168703a39Ea9C99f2cD0 900 --rpc-url https://rpc.mainnet.chain.robinhood.com/
# AAPL through the guard: verdict, reason, price, updatedAt

cast call 0x88a5a0414c9fd615201814ddbec4e4d9e4d283d0 "checkLive(bytes32)(uint8,uint8)"   0x000bbd87a23775b4c11092ae9a1fc7b3393636ae1dbb9f1ef460f845c0f4cff1 --rpc-url https://rpc.mainnet.chain.robinhood.com/
# 1 3 = WAIT / OBS_STALE
```

## Already live on mainnet

The contract is not waiting for a subscription to be useful. Two **real DON-signed reports** we extracted
from mainnet calldata were posted into it on 2026-09-21, verified by the official Chainlink verifier, and
turned into receipts:

| | |
|---|---|
| AAPL report, obs 2026-09-09 18:00:00 UTC | tx `0x3a35de5a3aa310ccdae720ed75081f485763f6c64af33064b6272428464f25bd`, block 68,272,266, 344,350 gas |
| SPY report, same second | tx `0x9bf9d7e68af55084a3a1738d3cae1d35a8eab85fbd09f80d6485525181ebf7f1`, block 68,272,301, 344,398 gas |
| Receipt id of the AAPL report | `0xb8584c6f20c0bb4bd8e04048867d4cf5b2eac4da7131a720c4db1a18181e88c2` |
| Stored observation | mid 313.25735, bid 313.2128, ask 313.31, `marketStatus` 2, expires 2026-10-09 |

And then the part that matters. Ask the contract whether anyone may act on that price right now:

```bash
cast call 0x88a5a0414c9fd615201814ddbec4e4d9e4d283d0 "checkLive(bytes32)(uint8,uint8)"   0x000bbd87a23775b4c11092ae9a1fc7b3393636ae1dbb9f1ef460f845c0f4cff1 --rpc-url https://rpc.mainnet.chain.robinhood.com/
# 1 3  =  WAIT / OBS_STALE
```

A DON signature is not permission. The report is authentic, the receipt is permanent, and the answer is
still no, because the observation is days old. That is the whole product in one call, and it is running
now, with real signed data, on the chain the buildathon is about.

What is **not** live yet: the ladder has never resolved on a real opening or closing bell, because every
report we hold is mid-session. That needs a paid Data Streams subscription, and the README will say what
the live day showed, whichever way it goes.

## The audit: what the chain's only live stock market settles on

We pointed the same question at somebody else's contract and wrote the answer down in
[`docs/REPLAY.md`](docs/REPLAY.md), with a script that reproduces it from public data in one command.
Short version: of 30 settlements on the chain's live parimutuel stock market, **28 read the same feed
round on both sides**, so a tie-break rule decided the outcome rather than any price movement; the price
was a median of 11.9 hours old at the lock call, up to 71.6 hours; and 28 of the 30 had at least one leg
outside regular NYSE hours. Stated with the same honesty: the total ever staked in those markets is
**0.009 ETH**, so nobody was hurt. The defect is mechanical, not yet expensive.

## The problem, measured

All measurements are ours unless stated; sources and limits are next to each number. They describe *when* prices move and *what* the feeds publish; they are not causal claims about why.

- **Push feeds have no session status and sleep off-hours.** Of the 57 Chainlink feeds on Robinhood Chain (chainId 4663), 35 are US-equity feeds on the `us_equities_24/5` schedule; all 57 run with a 24 h heartbeat and a 0.5 % deviation threshold (Chainlink reference-data directory, `feeds-robinhood-mainnet.json`, snapshot 2026-09-17). Chainlink's own docs: the feeds "may hold the last published price" and have "no heartbeats during off-hours" (docs.chain.link, tokenized-equity-feeds/robinhood).
- **The first print after the open is late and unlabelled** - on the *push* feeds, which is the unit this bullet is about. Over the last 300 rounds per feed (read via `getRoundData`, 2026-09-17): first AAPL update after 13:30 UTC came at a median of 5.0 min, p90 29 min, max 340 min (33 weekdays; only 52 % of days within 5 min). Pauses inside the regular session reached 6.4 h. Weekends: 52 to 78 h without a print. No round says which session its price came from.
> **Two different products, one honest line between them.** Everything measured above is Chainlink *push* feeds, the ones a contract reads with `getRoundData`. Bell consumes Chainlink *Data Streams*, a pull product with its own latency profile, and **we have not measured how quickly a Data Streams equity report is available at the opening bell**: our 38 fixtures are all mid-session. So Bell's claim is not "the stream is slow". It is that no contract on this chain publishes DON-signed session status at all, and that a reference price needs a selection rule a poster cannot bend. The open-latency question is answered by a live day on a paid stream, and the answer will be written here either way.

- **The open is where prices move.** Hourly variance ratio 13 UTC vs 14 UTC (GeckoTerminal hourly candles, 10 weekdays): AAPL 2.89x, NVDA 1.31x, SPCX 4.75x, WETH control 0.95x. Per-swap 5-minute markout (third-party measurement, method fixed in `docs/DATA-markout-and-tests.uk.md`, 125,485 AAPL/USDG and 211,393 NVDA/USDG swaps, 9 weekdays): +1.6 to +2.9 bps against LPs in 13:30 to 14:00 UTC vs a +0.1 to +0.4 bps baseline; the same hours on weekends are ~0. Note the unit: this is markout per swap, not LP profit; both pools charge 5 bps per swap (`fee() == 500` read onchain 2026-09-18 from `0xaae0…2d6d` and `0xd4eb…14a3`), so the average LP is still paid in that window and the exposure sits in the tail (opening gap > 2 % on 23 % of 30 observed days, GeckoTerminal, coarse).
- **A live contract already settles this way.** The only live stock prediction market on the chain (contracts `0x72DAb8B1B53b3CF028e9A0d1E21178981f264245` and `0x59DF30E22bdaC70764a5DbF8bBa51BC5a595759C`): in **28 of 30** settlements the lock price equals the settle price, and in exactly the same 28 the feed served **one round on both sides**, so the code's `close >= open` tie rule decided the outcome rather than any price movement. Equality alone would prove nothing (a flat price looks identical); the round id is what separates them, and [`docs/REPLAY.md`](docs/REPLAY.md) shows the per-case table. Denominators, since an earlier draft of this README mixed them: 27 of 27 in the v2 contract and 1 of 3 in v1, which is the 28 of 30 above. Total ever staked in those markets: 0.009 ETH.

## The finding

Robinhood Chain has the Chainlink Data Streams **VerifierProxy 2.0.0** at `0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7` (docs.robinhood.com/chain/data-streams). Onchain: `s_feeManager = 0x0`, `s_accessController = 0x0`, i.e. verification is free and permissionless. Data Streams reports for US equities (schema v11) carry `marketStatus` (1 pre-market, 2 regular, 3 post-market, 4 overnight, 5 closed), `mid/bid/ask`, `lastSeenTimestampNs` and `expiresAt` (30 days).

Since genesis the verifier has emitted 2,112 `ReportVerified` events; 48 of them are v11 equity reports (AAPL and SPY, all `marketStatus == 2`), posted by one private contract for its own use. Nobody publishes the status. The same reports, with the same `configDigest` `0x00094bae…`, verify on Ethereum mainnet: reports are portable across chains.

We extracted those 48 real DON-signed reports from calldata (`script/extract_reports.py`) and use them as fixtures. `test/VerifyFixture.t.sol` verifies them through the **real** proxy on a fork of 4663: signatures accepted, a flipped byte rejected, replays accepted by the proxy (so replay protection is the consumer's job, which Bell does).

One more thing the fixtures show: every report is a signed **window** `[validFromTimestamp, observationsTimestamp]`. Of the 38 distinct reports, 32 have `validFromTimestamp == observationsTimestamp` (a one-second interval) and 6 span two seconds (own decode of `test/fixtures/reports_v11/index.json`, 2026-09-19; counted over 48 posted instances the split is 42 and 6, because 10 reports were posted twice). Chainlink documents the rule: "every time interval belonging to exactly one report" (docs.chain.link/data-streams/how-report-timestamps-work). Bell's selection rule is built on that property.

## What Bell does

One contract, no owner, no upgrade (`src/Bell.sol`, spec in `docs/SPEC-v0.1.uk.md`).

- `post(bytes payload)`: verifies a signed v11 report through the official proxy, rejects expired, skewed or malformed reports, stores the latest admissible observation per feed, and writes a **receipt** (hash of the signed payload, config digest, timestamps, mid, status, block, multiplier snapshot).
- **Session reference price, Bell policy v2 ("the ladder").** For each ET trading day (calendar in `src/SessionCalendar.sol`: US DST computed by rule, NYSE holidays and early closes tabulated, unsupported years fail closed) the OPEN fixing has 8 target seconds fixed by the calendar alone: `O + 30·i` for `i = 0..7`. A posted report is evidence for rung `i` when its signed window covers the target. Evidence that is regular-session and fresh (`marketStatus == 2`, mid seen within 60 s, mid updated at or after the bell) is the **candidate** for that rung; any other evidence **proves the rung out**. The reference is the candidate at the lowest rung whose lower rungs are all proven out. CLOSE mirrors it downwards from `C − 1`. Posting closes 300 s after the boundary.
- **Why a ladder.** Policy v1 took the earliest regular report inside the window. A poster could then withhold the 13:30:00 report and publish 13:32:10 instead, and the contract could not tell. With the ladder every rung has exactly one DON statement, so the only freedom left to a poster is *publish or not*: withholding ends in UNRESOLVED, never in a different price. Two different signed statements covering the same rung are a conflict, also UNRESOLVED. There is no fallback to a previous price, by design.
- **States are a function of time, not of a keeper call:** `NO_DATA → OPEN_PENDING → OPEN_FINAL | OPEN_UNRESOLVED → CLOSE_PENDING → CLOSE_FINAL | CLOSE_UNRESOLVED`. A late post after the deadline cannot reopen it, and cannot even raise a conflict.
- **Admissibility checks**: `checkLive(feedId)` and `checkSettle(feedId, tradingDate, isClose)` return `ALLOW / WAIT / REJECT` plus a reason (`EXPIRED`, `OBS_STALE`, `MID_STALE`, `STATUS_UNKNOWN`, `NON_REGULAR`, `OUTSIDE_SESSION`, `REFERENCE_PENDING`, `REFERENCE_UNRESOLVED`, `NO_SESSION`, `CA_PAUSED`). Halts of a single stock are not reflected in `marketStatus` (Chainlink 24/5 US Equities guide); Bell catches them through `lastSeenTimestampNs`.
- **Corporate actions.** A feed can be bound once, at deployment, to its ERC-8056 stock token. Every accepted report then snapshots the token's `uiMultiplier()` at acceptance (kept in the receipt and in the reference), and `tokenizedReference(feedId, tradingDate, isClose)` = reference mid × *that* multiplier, so a settlement never mixes two corporate-action epochs. While the issuer's `oraclePaused()` is true, every check returns `REJECT / CA_PAUSED`.
- **For posters and UIs:** `rungTarget(tradingDate, isClose, i)` gives the target seconds, `provenRungs(...)` the proof bitmap, `openReference / closeReference` the candidate with its rung.

What Bell is **not**: it is not the Nasdaq Opening Cross and not an official exchange print. What it publishes is a **session reference price under Bell's policy** - the DON mid of the lowest rung that is not proven out, together with the receipt that produced it. A consumer who needs the exchange's official opening or closing print must take it from the tape; Bell does not claim to reproduce it.

**Which rung will hold in practice is not yet measured, and we say so.** In the 38 distinct signed reports we hold, the mid (`lastSeenTimestampNs`) trails the report's own `observationsTimestamp` by a median of 2.57 s (min -0.06 s, max 5.25 s, 36 of 38 lags positive; own decode of `index.json`, 2026-09-19). A rung is a one-second target, so a report covering the bell second will usually carry a mid last seen a few seconds *before* the bell, which the `l >= O` rule proves out, moving the reference one rung up. The limit of that inference: **all 38 reports are mid-session** (obs from 2026-09-08 15:10:00 UTC to 2026-09-09 18:00:00 UTC, one poster, a 30-minute cadence), so not one of them sits on an opening rung, and the quiet-hour lag does not have to equal the lag in the first seconds after the bell, when quotes update fastest. The test that settles it is a Data Streams subscription that can request 13:30:00 directly; until then this is an observation, not a property of the open.

## Every equity feed on the chain, asked the session question: PushFeedGuard

Bell's reference needs DON-signed Data Streams reports, and those are not sold to a self-serve account
today (see [Limitations](#limitations-we-state-ourselves)). The session logic does not need them.
`src/PushFeedGuard.sol` is stateless, serves **all 35 Chainlink equity push feeds on this chain from one
deployment**, and answers the question those feeds cannot: is this number from the regular session, and
how old is it.

| | |
|---|---|
| Live guard | `0x8aF68a9fF7583097A7476060C6B56eB33dA7a711` |
| Deploy tx | `0x54e40b298ae9c2d7098b297ef2ca4a2b03eea4cfadb39b7ca0d39245892f467f` |
| Feeds covered | 35 (Chainlink reference data, listed in [`docs/equity_feeds_4663.json`](docs/equity_feeds_4663.json)) |
| Cost to a consumer | free: a view call, no subscription, no keeper |

```bash
python script/chain_session_report.py      # one eth_call, all 35 feeds, live
```

A real run, 2026-09-21 07:14:02 UTC, six hours before the opening bell
([full output](docs/session_report_2026-09-21T0714Z.txt)):

```
calendar: trading day 20260921, session 13:30 to 20:00 UTC

feed                         verdict  reason                   price        age
AAPL / USD                   REJECT   OUTSIDE_SESSION         335.53       7.2h
TSLA / USD                   REJECT   OUTSIDE_SESSION         367.02       6.1h
SPY  / USD                   REJECT   OUTSIDE_SESSION         765.29       7.2h
CRCL / USD                   REJECT   OUTSIDE_SESSION          91.49        68s
...
35 equity feeds: 0 ALLOW, 0 WAIT, 35 REJECT
```

Read that carefully, because the honest reading is more interesting than the loud one. Those feeds are
not broken and not asleep: they run on a 24/5 schedule, so `CRCL` had moved 68 seconds earlier in
overnight trading, while `AAPL` had simply not travelled 0.5 % since the previous close. Both are valid
numbers. Neither is a regular-session price, and `latestRoundData()` has no way to say so. A contract
that settles, liquidates or prices at 07:14 UTC gets a number that looks exactly like a market price.

The guard returns `REJECT / OUTSIDE_SESSION` for all 35, and during the session it returns `ALLOW` with
the price and its age, or `WAIT / PRICE_STALE` when the feed has gone quieter than the caller's budget.
The staleness budget is a parameter, not a house rule: a settlement wants minutes, a slow collateral
check can accept an hour, and `PushFeedGuard` makes that choice explicit instead of implicit.

`GuardedPushFeed` binds one feed and one budget behind the exact Chainlink signature, so an existing
consumer integrates by changing one address. 19 tests cover the session boundaries to the second, the
early-close day, Thanksgiving, the staleness budget, a zero price, an incomplete round, a reverting feed
and a feed address with no code at all.

## The page: web/index.html

One HTML file, no build step, no framework, no backend. It reads the chain from the visitor's own
browser: `eth_call` to `PushFeedGuard.checkMany` for all 35 feeds plus one call for the calendar, then
renders the verdicts. Serve it from anywhere, or open it locally:

```bash
python -m http.server 8765 && open http://127.0.0.1:8765/web/index.html
```

Every number on that page is a call the visitor made, not a number we cached, which is the same standard
the rest of this repo holds itself to.

## The record that grows on its own: SessionLog

Every claim about oracle latency on this chain is a screenshot in somebody's README, ours included.
`src/SessionLog.sol` turns the claim into a public record. Anyone may call it inside a bounded window
around a session boundary; it writes what the feed answered at that moment and cannot be rewritten
afterwards. No owner, first writer wins.

| | |
|---|---|
| Live log | `0xc482943C7fEE1dD7807Edad1c88260E4263fD0Ad` |
| Deploy tx | `0x84199713ffe5d84eadb8c16935b409f56b45c57ca55f21248d5a67ee3eb40909` |
| Keeper | `script/keeper.py --watch`, about 15 transactions a trading day, roughly a cent of gas |

Three marks per feed per day:

- **`markOpen`**, inside `[O, O+300)`: exactly what a contract reading at the opening bell would have
  been told, including how old that price already was;
- **`markFirstPrint`**, any time in the session: the feed's first update stamped at or after the bell.
  The stored delay is measured from the bell to the feed's own `updatedAt`, so a late caller cannot make
  it look smaller than it was, only larger;
- **`markClose`**, inside `[C-300, C)`: the last state before the exchange shuts.

This is the honest version of the number we have been quoting from an off-chain script since 2026-09-17
("first AAPL print after the open: median 5.0 min, p90 29 min, max 340 min"). From now on the same
measurement accumulates on mainnet, signed by nobody, checkable by anyone, growing one session at a time.
12 tests cover the windows to the second, the immutability of a written mark, the refusal outside a
trading day, and the fact that a late caller cannot understate a delay.

## Integration is one address: BellFeedAdapter

Every contract on this chain that prices a stock token already calls `latestRoundData()` on a Chainlink
proxy. That call cannot fail and cannot say "the exchange is closed". `src/BellFeedAdapter.sol` keeps the
signature and changes one thing: **when the data is not fit to act on, the call reverts instead of
returning a number.** Integration is a constructor argument, not a rewrite.

| | |
|---|---|
| Live adapter (AAPL/USD) | `0x4F0331DDbdDfE3349e16e37F80219A868B876655` |
| Deploy tx | `0x25a4aad10832b3f3b65e9a7d1e78e5c7ed1c4ea4b39621c35497df46f2636515` |
| Units | Bell keeps 18 decimals, the adapter reports **8**, matching the equity proxies on this chain |

Try it on mainnet right now, against the real report we posted:

```bash
cast call 0x4F0331DDbdDfE3349e16e37F80219A868B876655 "latestRoundData()(uint80,int256,uint256,uint256,uint80)"   --rpc-url https://rpc.mainnet.chain.robinhood.com/
# execution reverted: NotAdmissible(3)  ->  OBS_STALE

cast call 0x4F0331DDbdDfE3349e16e37F80219A868B876655 "tryLatestRoundData()(bool,uint8,int256,uint256)"   --rpc-url https://rpc.mainnet.chain.robinhood.com/
# false 3 0 0   ->  the same answer for callers that prefer a flag to a revert
```

`test/BellFeedAdapter.t.sol` includes a `NaiveMarket` written exactly like the contracts already running
here: lock on `latestRoundData()`, settle on `latestRoundData()`, tie pays BULL. Pointed at a push feed it
resolves markets on a weekend. Pointed at this adapter, the same contract cannot even lock, and a second
read seconds later needs a second admissible observation instead of silently returning the first number.
That is the audit in `docs/REPLAY.md`, turned into a test, and into one address a builder can paste.

## The consumer that can run today: SettleOnMark

`SettleMini` settles on Bell's DON-signed session reference and waits for a Data Streams subscription.
`src/SettleOnMark.sol` settles on something that exists right now: the **closing mark** that `SessionLog`
recorded for a feed on a trading day. Same discipline, no subscription.

Money moves only if three checks on the *record* pass, and each one is a check the audited market skipped:

1. a closing mark for that feed and trading day exists, and marks are write-once;
2. its verdict is ALLOW, so the exchange was open and the number was a real price;
3. the marked price was younger than the trade's own `maxPriceAge` at the moment it was recorded.

Otherwise there is no settlement, only `refund()`. A trade pointed at a Saturday can never pay out,
because `SessionLog` refuses to record a mark on a day the calendar has no session at all. That is the
2026-07-03 holiday settlement from [`docs/REPLAY.md`](docs/REPLAY.md), made structurally impossible.

| | |
|---|---|
| Live demo trade | `0x52a0E0d3BD4729BCD622fed437EDb428835658Ac` |
| Terms | AAPL/USD, trading day 2026-09-21, strike 335.00, 1 USDG a side, staleness budget 900 s |
| Escrow token | Paxos USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, 6 decimals |

Both sides of that particular trade are wallets we control, and we say so rather than dressing it up as
adoption: the demo is about where the number comes from, not about who won. 12 tests cover both payoff
directions, the exact-strike rule, a missing mark, a mark from a closed exchange, a marked price older
than the budget, refunds refused while a trade is still settleable, and double settlement.

## The consumer: SettleMini

`src/SettleMini.sol` is one trade between two parties, escrowed in USDG (Paxos USDG on this chain is
`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, 6 decimals). The payoff is the simplest one that can exist,
long wins at or above the strike, because the payoff is not the point. Three things are:

- money moves only when `checkSettle` answers ALLOW, which happens only when the ladder for that trading
  day is FINAL;
- the `Settled` event carries the **receipt id of the DON report** behind the price, so whoever was paid
  can be told exactly which signed statement paid them;
- `refund()` is the mirror: if the session never resolves, the contract does not invent a price and does
  not hold the stakes hostage. Both sides get their money back after the deadline. A silent poster can
  cancel a settlement; it can never move one.

Nine tests cover both directions of the payoff, the exact-strike case, settling while the fixing is still
pending, the withholding case ending in a refund, refunds refused when the session did resolve, and double
settlement.

## Prior art, stated by us

- **Pyth Pro is deployed on Robinhood Chain** (proxy `0xACeA761c27A909d4D3895128EBe6370FDE2dF481`, docs.pyth.network contract addresses; onchain 2026-09-18: ERC-1967 proxy to a 7,351-byte implementation). Whether its US equities plan ($5,000 per month, pyth.network blog 2026-06-12) is purchasable for 4663 we did not verify. Pyth Core, and with it `parsePriceFeedUpdatesUnique` (first update after a given time), is not listed for 4663.
- **Note Systems** (autocallable notes on Robinhood stock tokens, testnet 46630) has a `MarketCalendar`, a 5-minute close grace and deferred settlement (note.systems/docs). Its observed price is "the last round stamped at or before closeTs" of the Chainlink *push* feeds, i.e. exactly the stale-print pattern measured above; Pyth Pro is its fallback.
- **Chainlink Data Streams** documents that report authenticity is the verifier's job and data suitability is the application's. Bell is the application side.

Bell's claim is therefore narrow: DON-signed session status and a calendar-fixed, withholding-proof selection rule, readable for free by any contract, with a receipt per accepted report. Not "the only source".

## Tests

```
forge test                                                        # mock proxy: 74 tests
forge test --fork-url robinhood --match-contract "VerifyFixture|BellRobustnessFork" -vv   # real proxy, real signed reports: 6 tests
python script/replay_prediction_market.py                         # the audit, from public data, no key
python poster/poster.py --dry-run                                 # the poster's plan, no credentials
```

`test/Bell.t.sol` follows the numbered list in the spec: replay, expired report, status-2 observation before the boundary, late poster and backfill anchored to the boundary, same-rung conflict, status 0 and 4, halt via `lastSeenTimestampNs`, early close (2026-11-27), sessions not merging without overnight reports, immutability after the deadline, exact deadline boundary, wrong schema. `test/BellLadder.t.sol` is the adversarial set: withholding rung 0, proof chains, order independence, the two-second mainnet window shape, wide windows, conflicts at the same rung, a gap in the chain, the full ladder to rung 7, and the CLOSE mirror. `test/BellCorporateAction.t.sol` covers the multiplier snapshot and the issuer pause.

`test/BellRobustness.t.sol` (2026-09-19) states the ladder as a **payout** rule rather than a state machine: a five-report evidence set is run through all 120 permutations, four posting-time patterns inside the window, all 32 subsets, byte-identical replays and late posts, against a stub that moves USDG out of escrow at `qty * reference`. The invariants: every permutation pays the same, every subset pays either that same price or nothing at all (withholding can silence a fixing, never reprice it), a poster publishing only a higher rung gets no settlement, and nothing posted after the deadline moves a payout in either direction. `test/BellRobustnessFork.t.sol` runs the 38 real signed reports through the real proxy in three orders and asserts the readable state is identical, plus the limit we keep repeating: none of them is evidence for any fixing.

Mutation checks. 2026-09-18: removing the proof-chain requirement, replacing window containment with exact-second matching, or removing the posting deadline each makes tests fail. 2026-09-19, against the robustness suite only: letting a higher rung overwrite the candidate kills 4 of the 10 tests, dropping the proof chain kills 3, removing the posting deadline kills 2. Logs in `docs/MUTATION-2026-09-18.md`.

## Who pays, honestly

In US equity markets the consolidated tape is paid for by data subscribers and its revenue is allocated among the exchanges and FINRA: about $390 million shared by SROs in 2018 (SEC, Market Data Infrastructure release, footnote 1747). Onchain, session-aware equity data already has a price: Pyth Pro's US Equities plan is $5,000 per month (pyth.network blog, 2026-06-12); Chainlink Data Streams start at $150 per stream per month (docs.chain.link/data-streams/sign-up). Bell is the tape, not the vendor: reading status and references is free for every contract, forever. What costs money is the poster's subscription, and the ask to the chain sponsor is exactly that: 5 flagship tickers × $150 = $750 per month plus gas. We do not project revenue; we show the cost of its absence: the 28 of 30 one-round settlements above, and $944,359 of stock collateral on Morpho marked against feeds that sleep up to 78 hours (measured 2026-09-16).

## Roadmap inside the buildathon

1. Poster (Node, Data Streams SDK): fetches every rung of the OPEN and CLOSE ladders and posts them; two independent posters; latency after the boundary published as a metric.
2. Deploy on Robinhood Chain testnet (46630) and mainnet (4663).
3. Replay: re-run the 30 settlements above against Bell's reference and report the payout difference per case, with `CONFIRMED_DEFECT / COUNTERFACTUAL / UNVERIFIABLE` kept apart.
4. One consumer that moves USDG through a full lifecycle on Bell's reference, and one external integrator.

## The number we are still missing, and how it is being measured

Everything measured so far describes closed markets, where a quiet feed is exactly what a 24/5 schedule
with a 0.5 % deviation band should produce. The number that decides whether a staleness guard is worth
anything is the other one: **while the exchange is open, how old is the price a contract would read?**

`script/staleness_sampler.py` samples all 35 feeds every five minutes and appends to
[`docs/staleness_samples.csv`](docs/staleness_samples.csv). View calls only, no key and no gas. A first
snapshot, 2026-09-21 08:54 UTC with the session closed, for the shape of the thing:

```
35 feeds, session CLOSED: median age 3036 s, p90 32060 s, max 32078 s
older than 1 min 94%, 5 min 89%, 15 min 74%, 1 h 31%
```

The same lines during the session are what we will publish before submission, whichever way they come
out. If the feeds turn out to be seconds fresh inside regular hours, the guard's value is the session
boundary alone and we will say so; if the tail is long, the staleness budget is the other half of the
product. We are not going to decide which sentence is true before the data does.

## What this adds over five lines of local checking, measured against ourselves

The strongest objection to any guard is that a consumer can check `updatedAt` itself and skip the
dependency. `script/policy_comparison.py` answers it with the 30 audited settlements run through five
policies, all on the same 900 s budget, and writes [`docs/POLICY_COMPARISON.md`](docs/POLICY_COMPARISON.md).

| Policy | Settles | Refuses |
|---|---:|---:|
| 1. As deployed (the market's own rule) | 30 | 0 |
| 2. Freshness check only | 3 | 27 |
| 3. Calendar + freshness + same-round refusal (a careful local patch) | 0 | 30 |
| 4. PushFeedGuard alone | **2** | 28 |
| 5. PushFeedGuard + SettlementPairGuard | 0 | 30 |

Row 4 is the point of running this. **A careful local patch was stricter than our deployed guard on two
settlements** (PLTR and AMD, 2026-08-25): both reads inside the regular session, the price four and eight
minutes old, so every per-read check passes, yet the two reads were four and eleven seconds apart and
returned the same feed round. A per-read guard cannot see a relationship between two reads.

So we built the missing rule instead of arguing with the number. `src/SettlementPairGuard.sol`
(`0x16dC769Ef04E77292A350298E87132994C8c293e`, tx `0x04d3242d…`) adds exactly one thing: the second read of
a settlement pair must not carry the same `updatedAt` as the first. Seven tests, including the PLTR case
reproduced second by second.

What this comparison does **not** claim: that a careful developer could not write those rules themselves.
Rows 3 and 5 now agree on all 30. The contribution is that the rule is written once, tested against the
official NYSE calendar, deployed, and callable by anyone, rather than reimplemented per consumer with a
holiday table somebody has to maintain.

## The calendar, checked day by day against NYSE's own schedule

A calendar bug is the quiet kind: it does not revert, it calls a closed day open or an early close a full
session, on exactly the day a settlement is most sensitive. So the calendar is no longer asserted by
spot checks. `test/SessionCalendarSchedule.t.sol` walks **every day of 2026 and 2027** and compares the
contract with the holiday and early-closing list NYSE Group published itself (ir.theice.com, read
2026-09-21, transcribed into the test so a reviewer can diff it against the press release):

- 251 trading days in each year, and the existence of a session asserted for all 730 days;
- both DST transitions, where the session moves by an hour in UTC;
- all three early closes (2026-11-27, 2026-12-24, 2027-11-26) asserted at exactly 3 h 30 m;
- 2025 and 2028 asserted to have no sessions at all, because the table ends and the contract fails closed.

Every date in the contract matched the official list on the first run. The bug that test found was in the
test: `(dst ? 20 : 21) * 3600` types the ternary as `uint8`, so the multiplication overflowed `uint16` and
panicked. Worth writing down, because it is the same class of mistake the contract is meant to catch in
other people's code.

## What we found auditing ourselves, and fixed

Before a reviewer could, we attacked our own contracts and redeployed. Both findings are in the tests now,
so a regression would fail the suite rather than surprise somebody.

- **A price stamped in the future used to look fresher than a real one.** `PushFeedGuard` reads whatever
  address a consumer hands it, and an arbitrary contract can claim any `updatedAt`. The staleness check
  only looked backwards, so a hostile "feed" reporting a timestamp an hour ahead would have been
  permanently admissible. It now returns `ROUND_INCOMPLETE` for anything stamped more than two seconds
  ahead of the block, and two seconds of sequencer skew stay acceptable.
- **The mark window was a lever for whoever called first.** `SessionLog` accepts a closing mark anywhere
  in `[C-300, C)`, which is right for a record but wrong for money: a party to a trade could wait for a
  favourable tick inside those five minutes. `SettleOnMark` now requires the mark it settles on to sit
  within its own `markWindow` of the bell (120 s for the live demo trade) and refunds otherwise. This is
  the same class of problem the ladder solves for Bell, found in our own newer code.

Also tightened while we were there: every USDG transfer now checks the returned boolean instead of
assuming a revert on failure.

## Limitations we state ourselves

- The ladder relies on Chainlink's documented window semantics (one report per time interval). If two different signed reports ever cover the same target second, Bell records a conflict and the fixing is UNRESOLVED: a liveness failure, never a chosen price. The REST semantics of "report for timestamp T" (window containing T vs. observed at T) are to be confirmed empirically on a paid stream.
- Early-close behaviour of the DON has not been observed onchain (no equity report was verified anywhere on 2026-07-03, and the next early close is 2026-11-27); it is covered by synthetic tests only.
- One poster is a liveness risk, not a safety risk: a missed rung ends in UNRESOLVED, never in a wrong price. Say the sharper version of that out loud: a poster who also holds a position cannot move the price, but can still *decline to resolve* a fixing that is about to go against them, and a deliberate silence looks exactly like a crashed poster. The structural answer is that posting is permissionless - the other side of a trade can subscribe and post the same DON report - so a consumer that cares should either fund a second poster or treat UNRESOLVED as a refund path. Bell does not pretend that one poster is enough.
- A deactivated DON configuration makes older reports unverifiable; receipts of already accepted reports stay, and `digestActive()` exposes the routing state.
- Data Streams access is a paid subscription (from $150 per stream per month); a shared, sponsored poster is the honest ask to the chain.
- The calendar table covers 2026 and 2027 only (`SessionCalendar._yearSupported`). From 2028 every day answers `NO_SESSION`, fail closed: no new fixing can open, while every reference and receipt recorded before then stays readable forever. A new year means a new deployment, which is the price of having no owner and no upgrade.
- The contract compiles with `via_ir` (stack depth in the ladder loop); gas numbers will be published with the deployment.

## License

MIT

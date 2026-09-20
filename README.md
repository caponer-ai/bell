# Bell

**Onchain session status and a session reference price for tokenized US equities on Robinhood Chain, computed from DON-signed Chainlink Data Streams reports under a published policy.**

Stock tokens trade 24/7. The equity behind them trades 6.5 hours a day. Every protocol on Robinhood Chain that settles, lends or prices against a stock token needs to know two things the existing push feeds cannot tell it: *is the market open right now*, and *what the regular-session reference price was at the open and at the close, under a stated policy*. Bell answers both, with a receipt, under a selection rule that nobody, including the poster, can bend.

> Status: buildathon work in progress (Arbitrum Open House Singapore, Sept 14 to Oct 4, 2026). Not audited. Read the code, run the tests, form your own view.

## Deployed

| | |
|---|---|
| **Bell** | `0x88a5a0414c9fd615201814ddbec4e4d9e4d283d0` |
| Chain | Robinhood Chain mainnet, chainId 4663 |
| Deploy tx | `0xbec3cb1a8813dadf0aa52e66f87d79ecb4dd487b95413fdf2062286a6187c540`, block 68,238,358 |
| Verifier it reads | `0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7` (official Chainlink Data Streams VerifierProxy) |
| Owner | none, and no upgrade path. The calendar is compiled in; `POLICY_VERSION` 2, `CALENDAR_VERSION` 1 |
| Feed bindings | none. Every check works; `tokenizedReference` returns 0 until a bound instance is deployed against verified ERC-8056 addresses |

Read it yourself, no wallet needed:

```bash
cast call 0x88a5a0414c9fd615201814ddbec4e4d9e4d283d0 "digestActive(bytes32)(bool)"   0x00094baebfda9b87680d8e59aa20a3e565126640ee7caeab3cd965e5568b17ee --rpc-url https://rpc.mainnet.chain.robinhood.com/
# true: the DON config our fixtures were signed under is still routed by the proxy

cast call 0x88a5a0414c9fd615201814ddbec4e4d9e4d283d0 "rungTarget(uint32,bool,uint8)(uint64)" 20260922 false 0 --rpc-url https://rpc.mainnet.chain.robinhood.com/
# 1790083800 = 2026-09-22 13:30:00 UTC, the bell. Weekends and NYSE holidays return 0.
```

Until a poster feeds it, `checkSettle` answers `REJECT / REFERENCE_UNRESOLVED` for every day, which is the honest answer, not a failure: the contract refuses to hand out a reference it has no DON evidence for.

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
was a median of 12.2 hours old at the lock call, up to 71.6 hours; and 28 of the 30 had at least one leg
outside regular NYSE hours. Stated with the same honesty: the total ever staked in those markets is
**0.009 ETH**, so nobody was hurt. The defect is mechanical, not yet expensive.

## The problem, measured

All measurements are ours unless stated; sources and limits are next to each number. They describe *when* prices move and *what* the feeds publish; they are not causal claims about why.

- **Push feeds have no session status and sleep off-hours.** Of the 57 Chainlink feeds on Robinhood Chain (chainId 4663), 35 are US-equity feeds on the `us_equities_24/5` schedule; all 57 run with a 24 h heartbeat and a 0.5 % deviation threshold (Chainlink reference-data directory, `feeds-robinhood-mainnet.json`, snapshot 2026-09-17). Chainlink's own docs: the feeds "may hold the last published price" and have "no heartbeats during off-hours" (docs.chain.link, tokenized-equity-feeds/robinhood).
- **The first print after the open is late and unlabelled** - on the *push* feeds, which is the unit this bullet is about. Over the last 300 rounds per feed (read via `getRoundData`, 2026-09-17): first AAPL update after 13:30 UTC came at a median of 5.0 min, p90 29 min, max 340 min (33 weekdays; only 52 % of days within 5 min). Pauses inside the regular session reached 6.4 h. Weekends: 52 to 78 h without a print. No round says which session its price came from.
> **Two different products, one honest line between them.** Everything measured above is Chainlink *push* feeds, the ones a contract reads with `getRoundData`. Bell consumes Chainlink *Data Streams*, a pull product with its own latency profile, and **we have not measured how quickly a Data Streams equity report is available at the opening bell**: our 38 fixtures are all mid-session. So Bell's claim is not "the stream is slow". It is that no contract on this chain publishes DON-signed session status at all, and that a reference price needs a selection rule a poster cannot bend. The open-latency question is answered by a live day on a paid stream, and the answer will be written here either way.

- **The open is where prices move.** Hourly variance ratio 13 UTC vs 14 UTC (GeckoTerminal hourly candles, 10 weekdays): AAPL 2.89x, NVDA 1.31x, SPCX 4.75x, WETH control 0.95x. Per-swap 5-minute markout (third-party measurement, method fixed in `docs/DATA-markout-and-tests.uk.md`, 125,485 AAPL/USDG and 211,393 NVDA/USDG swaps, 9 weekdays): +1.6 to +2.9 bps against LPs in 13:30 to 14:00 UTC vs a +0.1 to +0.4 bps baseline; the same hours on weekends are ~0. Note the unit: this is markout per swap, not LP profit; both pools charge 5 bps per swap (`fee() == 500` read onchain 2026-09-18 from `0xaae0…2d6d` and `0xd4eb…14a3`), so the average LP is still paid in that window and the exposure sits in the tail (opening gap > 2 % on 23 % of 30 observed days, GeckoTerminal, coarse).
- **The damage is already onchain.** The only live stock prediction market on the chain (contracts `0x72DAb8B1B53b3CF028e9A0d1E21178981f264245` and `0x59DF30E22bdaC70764a5DbF8bBa51BC5a595759C`): in 27 of 30 settlements lock price == settle price with a median 4 s between lock and settle, and the code's fallback "BULL wins by default" decided the outcome. The first lock happened on 2026-07-03, a full NYSE holiday. Stakes were 0.00025 ETH each. Equality alone does not prove a defect (a flat price gives the same picture); the Replay in the roadmap separates CONFIRMED_DEFECT from COUNTERFACTUAL per case.

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

## Prior art, stated by us

- **Pyth Pro is deployed on Robinhood Chain** (proxy `0xACeA761c27A909d4D3895128EBe6370FDE2dF481`, docs.pyth.network contract addresses; onchain 2026-09-18: ERC-1967 proxy to a 7,351-byte implementation). Whether its US equities plan ($5,000 per month, pyth.network blog 2026-06-12) is purchasable for 4663 we did not verify. Pyth Core, and with it `parsePriceFeedUpdatesUnique` (first update after a given time), is not listed for 4663.
- **Note Systems** (autocallable notes on Robinhood stock tokens, testnet 46630) has a `MarketCalendar`, a 5-minute close grace and deferred settlement (note.systems/docs). Its observed price is "the last round stamped at or before closeTs" of the Chainlink *push* feeds, i.e. exactly the stale-print pattern measured above; Pyth Pro is its fallback.
- **Chainlink Data Streams** documents that report authenticity is the verifier's job and data suitability is the application's. Bell is the application side.

Bell's claim is therefore narrow: DON-signed session status and a calendar-fixed, withholding-proof selection rule, readable for free by any contract, with a receipt per accepted report. Not "the only source".

## Tests

```
forge test                                                        # mock proxy: 65 tests
forge test --fork-url robinhood --match-contract "VerifyFixture|BellRobustnessFork" -vv   # real proxy, real signed reports: 6 tests
```

`test/Bell.t.sol` follows the numbered list in the spec: replay, expired report, status-2 observation before the boundary, late poster and backfill anchored to the boundary, same-rung conflict, status 0 and 4, halt via `lastSeenTimestampNs`, early close (2026-11-27), sessions not merging without overnight reports, immutability after the deadline, exact deadline boundary, wrong schema. `test/BellLadder.t.sol` is the adversarial set: withholding rung 0, proof chains, order independence, the two-second mainnet window shape, wide windows, conflicts at the same rung, a gap in the chain, the full ladder to rung 7, and the CLOSE mirror. `test/BellCorporateAction.t.sol` covers the multiplier snapshot and the issuer pause.

`test/BellRobustness.t.sol` (2026-09-19) states the ladder as a **payout** rule rather than a state machine: a five-report evidence set is run through all 120 permutations, four posting-time patterns inside the window, all 32 subsets, byte-identical replays and late posts, against a stub that moves USDG out of escrow at `qty * reference`. The invariants: every permutation pays the same, every subset pays either that same price or nothing at all (withholding can silence a fixing, never reprice it), a poster publishing only a higher rung gets no settlement, and nothing posted after the deadline moves a payout in either direction. `test/BellRobustnessFork.t.sol` runs the 38 real signed reports through the real proxy in three orders and asserts the readable state is identical, plus the limit we keep repeating: none of them is evidence for any fixing.

Mutation checks. 2026-09-18: removing the proof-chain requirement, replacing window containment with exact-second matching, or removing the posting deadline each makes tests fail. 2026-09-19, against the robustness suite only: letting a higher rung overwrite the candidate kills 4 of the 10 tests, dropping the proof chain kills 3, removing the posting deadline kills 2. Logs in `docs/MUTATION-2026-09-18.md`.

## Who pays, honestly

In US equity markets the consolidated tape is paid for by data subscribers and its revenue is allocated among the exchanges and FINRA: about $390 million shared by SROs in 2018 (SEC, Market Data Infrastructure release, footnote 1747). Onchain, session-aware equity data already has a price: Pyth Pro's US Equities plan is $5,000 per month (pyth.network blog, 2026-06-12); Chainlink Data Streams start at $150 per stream per month (docs.chain.link/data-streams/sign-up). Bell is the tape, not the vendor: reading status and references is free for every contract, forever. What costs money is the poster's subscription, and the ask to the chain sponsor is exactly that: 5 flagship tickers × $150 = $750 per month plus gas. We do not project revenue; we show the cost of its absence: the 27 of 30 same-price settlements above, and $944,359 of stock collateral on Morpho marked against feeds that sleep up to 78 hours (measured 2026-09-16).

## Roadmap inside the buildathon

1. Poster (Node, Data Streams SDK): fetches every rung of the OPEN and CLOSE ladders and posts them; two independent posters; latency after the boundary published as a metric.
2. Deploy on Robinhood Chain testnet (46630) and mainnet (4663).
3. Replay: re-run the 30 settlements above against Bell's reference and report the payout difference per case, with `CONFIRMED_DEFECT / COUNTERFACTUAL / UNVERIFIABLE` kept apart.
4. One consumer that moves USDG through a full lifecycle on Bell's reference, and one external integrator.

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

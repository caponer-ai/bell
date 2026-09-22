# Replay: what the only live stock market on this chain actually settled on

Reproduce it yourself, no API key and no archive node:

```bash
pip install pycryptodome        # the only dependency: keccak for event topics
python script/replay_prediction_market.py
```

The table below is a snapshot taken 2026-09-21 at chain head 68,272,000 and is committed as
[`docs/replay_settlements.json`](replay_settlements.json), so a later run that finds new settlements can be
compared against it rather than silently replacing it.

## The target

Robinhood Chain (4663) has one live parimutuel market on stock prices, deployed by pplmaverick
([repo](https://github.com/pplmaverick/robinhood-stock-prediction-market), MIT): `0x72DAb8B1B53b3CF028e9A0d1E21178981f264245`
and an earlier `0x59DF30E22bdaC70764a5DbF8bBa51BC5a595759C`. Between 2026-07-03 and 2026-09-08 they
settled 30 markets on TSLA, AMZN, PLTR, AMD and NVDA.

**They found it first.** pplmaverick's own verification layer (commit `da13c80`, 2026-09-03) already
reports that all real settlements resolved via tie-defaults-to-BULL. This audit reproduces that finding
independently and adds the round ids and price ages. On 2026-09-22 they shipped a fix
([V3](https://robinhoodchain.blockscout.com/address/0x06897Ce6A2492BE99B59a7c023A64A6C0Af37849)): ties now
refund, the open price is taken at creation, and every read must be at most 4 hours old. That closes the
tie problem. It does not ask which session a price came from: across the 35 equity feeds, a 4 hour check
accepts the latest round in a median 27.3 % of the minutes when NYSE is shut (`script/staleness_gate_gap.py`,
30 rounds per feed, so each window is short). Whether that matters depends on what the market promises.

Their settlement, from `StockPredictionMarketV2.sol` (read 2026-09-21):

```solidity
function lockMarket(uint256 id)  { (, int256 p,,,) = feed.latestRoundData(); m.openPrice  = p; }
function settleMarket(uint256 id){ (, int256 p,,,) = feed.latestRoundData(); m.closePrice = p;
                                   winner = p >= m.openPrice ? BULL : BEAR; }
```

Two reads of a push feed, whenever the operator calls them, and a tie pays BULL. The repo says so
itself: *"a Chainlink round that hasn't updated yet between lockMarket() and settleMarket() can produce
openPrice == closePrice"* and *"BULL wins by default, there is no REFUND market state"*.

## What we checked about the code we quote

The deployed bytecode is **not** byte-identical to the repo's current file: on chain the bet event is
`BetPlaced(uint256,address,uint8,uint256)`, while the published `StockPredictionMarketV2.sol` declares it
with a trailing `isAgentBet` flag. So the deployment is an earlier revision. What we quote above is
unaffected: `MarketCreated(uint256,string,address)`, `MarketLocked(uint256,int256)` and
`MarketSettled(uint256,int256,uint8)` match the published source exactly, and those three carry the
settle logic this audit is about.

The script decodes `markets(uint256)` positionally, so it checks itself: for every market the pools it
reads from the struct must equal the sum of that market's bet events. A layout drift would stop the run
with a named error rather than quietly flip a pool or a winner.

## What we measured

Equal prices prove nothing on their own: a flat market gives the same picture. The test that separates
the two is the feed's **round id**. The address each market stores is pplmaverick's `ChainlinkPriceFeed`
adapter; the real Chainlink proxy is its `aggregator()` (for TSLA `0x4A1166a659A55625345e9515b32adECea5547C38`,
the `proxyAddress` of "Robinhood TSLA / USD" in Chainlink's reference data). We read `getRoundData` on that
proxy and resolved which round was current at the lock call and at the settle call.

| Result | Count | Interval |
|---|---|---|
| Settlements audited (2026-07-03 to 2026-09-08) | **30** | this is the whole population, not a sample |
| Same feed round on both sides: the two snapshots read one number, so the tie rule decided the market | **28** (93.3 %) | 95 % Wilson: **78.7 % to 98.2 %** |
| Price actually moved between the two calls | 2 (6.7 %) | |
| At least one leg outside the regular NYSE session (holiday, weekend, 02:37-04:38 UTC pre-market) | **28** (93.3 %) | 95 % Wilson: **78.7 % to 98.2 %** |
| Age of the price at the lock call | median **11.9 h** | Q1 2.45 h, Q3 15.38 h, **IQR 12.9 h**; min 4.2 min, max 71.6 h |
| Interval between `lockMarket` and `settleMarket` | median **4 s** | Q1 4 s, Q3 10 s, max 10.8 h |
| Total ever staked across all 30 markets | **0.009 ETH** | |
| Markets with any bet at all | 4 of 30 | |

Thirty is a small number and the table now says so out loud. The Wilson interval on 28 of 30 runs from
78.7 % to 98.2 %: the defect is clearly common in this contract's history, and anyone claiming the precise
93.3 % transfers to some other market is overreading. The age of the price is quoted with its quartiles
rather than its maximum, because 71.6 hours is one holiday weekend and not a description of the sample.

### What this does not say, checked by attacking our own sample

Three things weaken the table above, and they are ours to state, not a reviewer's to discover.

- **Most of these look like test runs, not trading.** The median interval between `lockMarket` and
  `settleMarket` is **4.5 seconds**, and 23 of the 30 settled within a minute of being locked. An operator
  locking and settling in the same breath is exercising a contract, not running a market. The defect that
  remains after saying so is still a defect, and it is a design one: `settleMarket` has no minimum
  interval after `lockMarket`, so the window in which the price is allowed to move can be zero seconds
  wide, and the tie rule then decides by construction.
- **The 11.9 hour median is an out-of-session number.** It is driven by the 28 settlements with at least
  one leg outside regular hours (median 12.4 h there). In the only two settlements that ran entirely
  inside the session, the price was **4 and 8 minutes old**. Quoting 11.9 hours as though it described
  trading hours would be dishonest; outside the session the feeds are quiet, which is exactly what a 24/5
  schedule with a 0.5 % deviation band produces.
- **Almost nobody was playing.** 26 of the 30 markets had no bet at all; the 0.009 ETH sits in four of
  them. This is a mechanism audit on a market that was barely used, and it is worth reading as one.

What survives all three: on this chain, today, a deployed contract can resolve a stock market on a price
from a day the exchange never opened, with the winner chosen by a tie-break rule, and nothing in the data
it reads can tell it otherwise. That is worth fixing before the size arrives, not after.

Read the last two rows before the first six. **Nobody lost real money here**: this market is tiny, and
we are not going to inflate 0.009 ETH into a disaster. What the audit establishes is mechanical, and it
does not depend on the size of the pool: on this chain, today, a contract can settle a stock market on a
price that is 71 hours old, on a day the exchange never opened, and hand the win to one side by a
tie-break rule. The same code with real size behind it is a different sentence.

One more thing the table says quietly: two markets settled *inside* regular hours (2026-08-25) and still
landed on one round, because the market lasted four seconds and the feed updates on a 0.5 % deviation or a
24 h heartbeat. A push feed has no notion of "the price at this instant". That is the gap Data Streams
fills with a signed report for a stated time, and the gap Bell turns into something a contract can check.

## What Bell would have answered

Bell is not a drop-in fix for that contract, and pretending otherwise would be dishonest: it settles on
`latestRoundData`, Bell speaks a different interface. What Bell gives a settlement contract is the two
answers the push feed cannot give:

- `checkLive(feedId)` returns a reason instead of a number when the data is not fit to act on. Stated
  precisely, because the reasons differ: 28 of the 30 settlements ran while the exchange was closed on at
  least one leg (`OUTSIDE_SESSION`), and the remaining 2 ran inside regular hours but on observations 4
  and 8 minutes old, well past
  Bell's 30-second admissibility bound (`OBS_STALE`), and in every one of the 30 there was no fresh
  signed report at all, which is `NO_DATA`. Bell hands out no price in any of the 30; what changes
  between them is which word it answers with.
- `checkSettle(feedId, tradingDate, isClose)` returns the session reference price only once the ladder
  is FINAL, with the receipt id of the DON report it came from, so the "open" and the "close" are fixed
  by the calendar rather than by when an operator clicks.

The refusal path is not theory: it runs on mainnet today. See [the live receipts](../README.md#already-live-on-mainnet).

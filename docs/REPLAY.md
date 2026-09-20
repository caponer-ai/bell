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

| Result | Count |
|---|---|
| Settlements audited (2026-07-03 to 2026-09-08) | **30** |
| Same feed round on both sides: the two snapshots read one number, so the tie rule decided the market | **28** |
| Price actually moved between the two calls | 2 |
| At least one leg outside the regular NYSE session (holiday, weekend, 02:37-04:38 UTC pre-market) | **28** |
| Age of the price at the lock call | median **11.9 h**, max **71.6 h**, min 4.2 min |
| Total ever staked across all 30 markets | **0.009 ETH** |
| Markets with any bet at all | 4 of 30 |

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

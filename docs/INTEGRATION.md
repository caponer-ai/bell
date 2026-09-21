# Integrating this, in ten minutes

Written after looking at this repository as somebody who wants to use it rather than admire it, and finding
that it answered none of the four questions such a person actually asks: what do I call, what does it cost,
what do I do with each answer, and how do I change the budget.

There is nothing to install and nothing to deploy. `PushFeedGuard` is already on chainId 4663 at
**`0x8aF68a9fF7583097A7476060C6B56eB33dA7a711`**, it is stateless, it has no owner and no upgrade path, and
it serves all 35 equity feeds. Calling it is free.

## The interface, in full

```solidity
interface IPushFeedGuard {
    enum Verdict { ALLOW, WAIT, REJECT }
    enum Reason  { OK, NO_SESSION, OUTSIDE_SESSION, PRICE_STALE, ROUND_INCOMPLETE, BAD_PRICE, NO_FEED }

    /// Judge one feed reading against your own staleness budget.
    function check(address feed, uint64 maxAge)
        external view returns (Verdict, Reason, int256 answer, uint256 updatedAt);

    /// Same question, many feeds, one call.
    function checkMany(address[] calldata feeds, uint64 maxAge)
        external view returns (Verdict[] memory, Reason[] memory, int256[] memory, uint256[] memory);

    /// Revert instead of returning, for paths that should stop rather than branch.
    function requireAdmissible(address feed, uint64 maxAge)
        external view returns (int256 answer, uint256 updatedAt);

    /// The calendar on its own, for schedulers and keepers.
    function sessionAt(uint64 timestamp) external pure returns (Session memory);
    function sessionForDate(uint32 tradingDate) external pure returns (Session memory);
}
```

## The whole integration

```solidity
IPushFeedGuard constant GUARD = IPushFeedGuard(0x8aF68a9fF7583097A7476060C6B56eB33dA7a711);

function settle(address feed) external {
    (IPushFeedGuard.Verdict v, IPushFeedGuard.Reason r, int256 price,) = GUARD.check(feed, 900);
    if (v != IPushFeedGuard.Verdict.ALLOW) revert NotNow(uint8(r));
    // price is a regular-session price, no older than your 900 seconds
}
```

That is the entire change. If you already read `latestRoundData()` somewhere, the shape of the replacement
is one call and one branch.

## What each answer means, and what to do with it

The verdict tells you **whether to act**. The reason tells you **why not**, so you can decide whether to
wait, refuse, or fall back to something else. This split exists because a contract that only ever reverts
takes the decision away from you.

| Verdict | Reason | What happened | Sensible response |
|---|---|---|---|
| `ALLOW` | `OK` | Regular session, price within your budget | Use the price |
| `WAIT` | `PRICE_STALE` | Session is open, the feed has not published recently enough for you | Retry later, or widen `maxAge` if your product can tolerate it |
| `WAIT` | `ROUND_INCOMPLETE` | The round carries a timestamp in the future | Retry; never treat as a price |
| `REJECT` | `OUTSIDE_SESSION` | Trading day, but before the bell or after the close | Refuse, and say so to the user |
| `REJECT` | `NO_SESSION` | Weekend, NYSE holiday, or a year the calendar does not tabulate | Refuse. Do not retry today |
| `REJECT` | `BAD_PRICE` | The feed answered zero or negative | Refuse and alert. This is not a timing problem |
| `REJECT` | `NO_FEED` | Nothing that answers `latestRoundData()` at that address | Fix the address |

**`WAIT` and `REJECT` are different on purpose.** `WAIT` means the same call may succeed in a minute.
`REJECT` means it will not, until a later day or a different address. A consumer that treats them alike
will either hammer the chain or give up too early.

## What it costs

Measured by `test/Gas.t.sol`, asserted so a refactor cannot quietly triple it:

| Call | Gas |
|---|---|
| `check()` inside the session | **27,305** |
| `check()` outside the session | **15,926** |
| `sessionAt()`, calendar only | **11,151** |
| `checkMany()`, 35 feeds | 750,946 total, **21,455 per feed** |

Refusing is cheaper than admitting, because outside the session the guard answers from the calendar and
never reads the feed at all. Batching saves about 21 % per feed against asking one at a time.

At the gas price this chain has been running (roughly 0.055 gwei, from a 2,623,812-gas deploy that cost
0.000143596 ETH), an in-session `check()` is on the order of **0.4 US cents**. That is the number to weigh
against putting a third-party call in your hot path.

## Choosing `maxAge`

`maxAge` is yours, not ours. The guard does not have an opinion about how stale is too stale, because that
depends on what you are doing with the price.

The thing to know before you choose: **these feeds go quiet inside the session too.** They publish on a
0.5 % deviation threshold or a 24-hour heartbeat, so a calm hour produces no rounds at all, and that is
normal rather than broken. Our own measurement across ten days found the maximum gap between rounds at 96.0
hours on `Robinhood SGOV-USD`, and the AAPL feed went 3.2 hours without publishing before the close on
2026-09-21, which is what refused our first live settlement.

| Your use | Suggested `maxAge` | Why |
|---|---|---|
| Settling a trade on the close | 300 to 900 s | Tight, and expect refusals on quiet feeds |
| Liquidation trigger | 900 to 3600 s | Refusing too eagerly can block a liquidation that needs to happen |
| Display or analytics | 86400 s | You want the latest, not a guarantee |

If you pick a tight budget, decide in advance what happens when the answer is `WAIT`. A settlement that
refunds is a design; a settlement that reverts forever is a bug. Ours refunds, and the exit path never
reads the oracle at all, which is tested in
[`test/Adversarial.t.sol`](../test/Adversarial.t.sol).

## If you would rather it reverted

`BellFeedAdapter` at `0x4F0331DDbdDfE3349e16e37F80219A868B876655` has Chainlink's own signature and reverts
when the reading is inadmissible, so an existing consumer can switch to it by changing one address:

```solidity
// before
AggregatorV3Interface feed = AggregatorV3Interface(0x6B22A786bAa607d76728168703a39Ea9C99f2cD0);
// after
AggregatorV3Interface feed = AggregatorV3Interface(0x4F0331DDbdDfE3349e16e37F80219A868B876655);
```

Read the warning in the table above first. An adapter that reverts is the right shape for a settlement and
the wrong shape for anything that has to run when the market is shut.

## The one rule a single check cannot express

If two reads decide one outcome, they must not be the same observation. `PushFeedGuard` judges each read in
isolation and cannot see the relationship, which our own policy comparison caught us on. That rule lives in
`SettlementPairGuard` at `0x16dC769Ef04E77292A350298E87132994C8c293e`:

```solidity
(, , , uint256 firstUpdatedAt) = PAIR.checkFirstRead(feed, 900);
// ... time passes, the market moves ...
(Verdict v, Reason r, , int256 price, ) = PAIR.checkSecondRead(feed, 900, firstUpdatedAt);
// r == SAME_OBSERVATION means both reads returned one round: your tie rule is about to decide, not the market
```

This is the exact defect the audit in [`REPLAY.md`](REPLAY.md) found in 28 of 30 settlements on this chain.

## Checking any of this before you trust it

```bash
python script/verify.py    # no key, no wallet: reads the deployed contracts and checks every claim
forge test --fork-url robinhood --match-path "test/DemoFork.t.sol" -vv    # the guard against live feeds
```

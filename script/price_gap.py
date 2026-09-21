#!/usr/bin/env python3
"""What it costs, in the pool's own numbers, not to know which session a feed price belongs to.

Everything else in this repo argues that a push feed cannot say whether its price is a regular-session
price. This script puts a price tag on that. For every swap in the 58 genuine equity/USDG pools it takes
the pool's own mid price out of the swap's `sqrtPriceX96`, finds the Chainlink round that a contract would
have read at that same moment, and measures the gap between them.

The gap is the error a contract wears when it settles, liquidates or quotes off the feed. Split by session
state, it answers the question this project exists for:

  * inside the session both sources track the same live market, so the gap should be small
  * outside it, the pool keeps trading and the feed publishes on its own schedule, so the gap is whatever
    the market moved by in between, and nothing in `latestRoundData()` warns the caller

It is also the number that decides whether there is anything to trade here: a gap smaller than the taker
cost is not an opportunity, it is noise.

    python script/price_gap.py [--window-blocks 6000000] [--rounds 200]

Public RPC only, no key, no gas. Writes docs/price_gap_4663.json.
"""

import argparse
import bisect
import datetime as dt
import json

from equity_flow import (
    _exact_times,
    session_boundary_blocks,
    signed,
    stream_swaps,
    weekend_boundary_blocks,
)
from rh_equity_pools import ROOT, USDG, keccak, post, rpc, words

OUT = ROOT / "docs" / "price_gap_4663.json"
ANCHOR_STEP = 25_000  # about 42 minutes of chain; feeds move on a scale of hours


def calls(pairs, size=20):
    out = []
    for i in range(0, len(pairs), size):
        chunk = pairs[i : i + size]
        res = post(
            [
                {
                    "jsonrpc": "2.0",
                    "id": n,
                    "method": "eth_call",
                    "params": [{"to": to, "data": d}, "latest"],
                }
                for n, (to, d) in enumerate(chunk)
            ]
        )
        by_id = {r["id"]: r for r in res}
        for n in range(len(chunk)):
            r = by_id.get(n, {})
            out.append(r.get("result") if "error" not in r else None)
    return out


def decode_round(res):
    if not res or res == "0x":
        return None
    w = [int(res[2:][i * 64 : (i + 1) * 64], 16) for i in range(5)]
    answer = w[1] - (1 << 256) if w[1] >= (1 << 255) else w[1]
    return {"roundId": w[0], "answer": answer, "updatedAt": w[3]}


def feed_history(feeds, tickers, rounds):
    """The last `rounds` rounds of every feed we need, as sorted (updatedAt, price) lists."""
    wanted = {t: f for t in tickers for f in feeds if _ticker_of(f) == t}
    missing = sorted(set(tickers) - set(wanted))
    if missing:
        print("  no feed for %s" % ", ".join(missing))
    sel = keccak("getRoundData(uint80)")[:10]
    history = {}
    for t, f in wanted.items():
        latest = f.get("latest") or {}
        rid = latest.get("roundId")
        if rid is None:
            rid = decode_round(
                calls([(f["proxy"], keccak("latestRoundData()")[:10])])[0]
            )["roundId"]
        ids = [rid - i for i in range(rounds)]
        raw = calls([(f["proxy"], sel + hex(i)[2:].rjust(64, "0")) for i in ids])
        rows = [r for r in (decode_round(x) for x in raw) if r]
        scale = 10 ** (f.get("decimals") or 8)
        rows = sorted({(r["updatedAt"], r["answer"] / scale) for r in rows})
        history[t] = rows
        span = (rows[-1][0] - rows[0][0]) / 86400 if len(rows) > 1 else 0
        print("  %-7s %3d rounds spanning %.1f days" % (t, len(rows), span))
    return history


USDG_USD_FEED = "0x61b7e5650328764b076a108eff5fa7282a1b9ad2"


def usdg_history(rounds=60):
    """The USDG/USD feed, so the pool price can be stated in dollars rather than in a stablecoin.

    A pool quotes shares in USDG; the equity feed quotes them in USD. Treating the two as the same thing
    hides any depeg inside the measured gap, and a depeg would move every ticker at once, which is exactly
    what a session effect must not look like. Measured 21.09 the range is 1.31 basis points over the last
    seven days and 4.44 over two months, so this correction is small, but small and applied beats small
    and assumed.
    """
    sel = keccak("getRoundData(uint80)")[:10]
    latest = decode_round(calls([(USDG_USD_FEED, keccak("latestRoundData()")[:10])])[0])
    dec_raw = calls([(USDG_USD_FEED, keccak("decimals()")[:10])])[0]
    scale = 10 ** (int(dec_raw, 16) if dec_raw else 8)
    ids = [latest["roundId"] - i for i in range(rounds)]
    raw = calls([(USDG_USD_FEED, sel + hex(i)[2:].rjust(64, "0")) for i in ids])
    rows = sorted({(r["updatedAt"], r["answer"] / scale) for r in (decode_round(x) for x in raw) if r})
    print("  USDG/USD: %d rounds, %.6f to %.6f" % (len(rows), min(r[1] for r in rows), max(r[1] for r in rows)))
    return rows


def _ticker_of(feed):
    return (
        feed["name"]
        .replace("Robinhood ", "")
        .split(" /")[0]
        .split("-")[0]
        .strip()
        .upper()
    )


def build_clock(lo, hi):
    """Block to UTC seconds, linear between anchors 25 000 blocks apart.

    Feeds publish on a scale of hours and the anchors are 42 minutes apart, so interpolation error is
    irrelevant to the question being asked here. Session membership is NOT taken from this clock: that
    still comes from the exact boundary blocks.
    """
    anchors = list(range(lo, hi + ANCHOR_STEP, ANCHOR_STEP)) + [hi]
    known = _exact_times(anchors)
    grid = sorted((int(b), t) for b, t in known.items() if lo <= int(b) <= hi)
    xs = [g[0] for g in grid]
    ys = [g[1] for g in grid]

    def at(block):
        i = bisect.bisect_left(xs, block)
        if i < len(xs) and xs[i] == block:
            return ys[i]
        if i == 0:
            return ys[0]
        if i >= len(xs):
            return ys[-1]
        span = xs[i] - xs[i - 1]
        return ys[i - 1] + (ys[i] - ys[i - 1]) * (block - xs[i - 1]) / span

    print("  clock built from %d anchors" % len(xs))
    return at


def pool_price(sqrt_price_x96, usdg_is_token0, stock_decimals):
    """The pool's mid price of one share, in USDG.

    `sqrtPriceX96` squared is token1 raw units per token0 raw unit. USDG carries 6 decimals and the stock
    tokens 18, so the decimal correction is explicit rather than assumed.
    """
    ratio = (sqrt_price_x96 / 2**96) ** 2
    if ratio == 0:
        return None
    if usdg_is_token0:
        return (1 / ratio) * 10 ** (stock_decimals - 6)
    return ratio * 10 ** (stock_decimals - 6)


def pre_swap_sqrt(sqrt_after, liquidity, amount1):
    """The pool price before the swap moved it.

    `sqrtPriceX96` in a Swap event is the price *after* the trade, so it already contains that trade's own
    impact. In a single tick the relationship is exact: d(sqrtP) = dy / L. Crossing a tick breaks it, so
    this is an approximation for large swaps and exact for the small ones that dominate the sample, and
    both the pre and post figures are reported rather than one being quietly preferred.
    """
    if not liquidity:
        return None
    delta = (amount1 * (1 << 96)) // liquidity
    before = sqrt_after - delta
    return before if before > 0 else None


def quantiles(values, weights=None):
    if not values:
        return {}
    if weights is None:
        s = sorted(values)
        pick = lambda q: s[min(len(s) - 1, int(q * len(s)))]  # noqa: E731
        return {"p50": pick(0.5), "p90": pick(0.9), "p99": pick(0.99), "max": s[-1]}
    pairs = sorted(zip(values, weights))
    total = sum(weights)
    acc = 0
    out = {}
    targets = [("p50", 0.5), ("p90", 0.9), ("p99", 0.99)]
    for v, w in pairs:
        acc += w
        while targets and acc >= targets[0][1] * total:
            out[targets[0][0]] = v
            targets.pop(0)
    out["max"] = pairs[-1][0]
    for name, _ in targets:
        out[name] = pairs[-1][0]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--window-blocks", type=int, default=6_000_000)
    ap.add_argument("--rounds", type=int, default=200)
    ap.add_argument(
        "--edge-minutes",
        type=int,
        default=5,
        help="also report the sample with swaps this close to an opening or closing bell removed",
    )
    ap.add_argument(
        "--threshold",
        type=float,
        default=0.5,
        help="deviation in percent worth counting",
    )
    args = ap.parse_args()

    pools = [
        p
        for p in json.loads(
            (ROOT / "docs" / "equity_pools_4663.json").read_text(encoding="utf-8")
        )
        if p.get("genuine")
    ]
    by_addr = {p["pool"]: p for p in pools}
    tickers = sorted({p["ticker"] for p in pools})

    head = int(rpc("eth_blockNumber", []), 16)
    from_block = max(min(p["block"] for p in pools), head - args.window_blocks)
    print(
        "%d pools, %d tickers, window %d..%d"
        % (len(pools), len(tickers), from_block, head)
    )

    feeds = json.loads(
        (ROOT / "docs" / "feed_rounds_4663.json").read_text(encoding="utf-8")
    )["feeds"]
    print("feed history:")
    history = feed_history(feeds, tickers, args.rounds)
    stamps = {t: [r[0] for r in rows] for t, rows in history.items()}

    usdg_rows = usdg_history()
    usdg_stamps = [r[0] for r in usdg_rows]

    def usdg_usd(ts):
        i = bisect.bisect_right(usdg_stamps, ts) - 1
        return usdg_rows[i][1] if i >= 0 else 1.0

    print("clock and session boundaries:")
    clock = build_clock(from_block, head)
    edges = session_boundary_blocks(from_block, head)
    weekend = weekend_boundary_blocks(from_block, head)
    edge_blocks = [e["block"] for e in edges]
    weekend_blocks = [e["block"] for e in weekend]

    def state_of(block):
        i = bisect.bisect_right(edge_blocks, block) - 1
        if i < 0:
            return "CLOSED"
        return "REGULAR" if edges[i]["kind"] == "open" else "CLOSED"

    def is_weekend(block):
        i = bisect.bisect_right(weekend_blocks, block) - 1
        if i < 0:
            return bool(weekend) and weekend[0]["kind"] == "end"
        return weekend[i]["kind"] == "start"

    # decimals of every stock token, so the price maths is not guessed
    tokens = sorted({p["other"] for p in pools})
    dec_raw = calls([(t, keccak("decimals()")[:10]) for t in tokens])
    decimals = {
        t: (int(r, 16) if r and r != "0x" else 18) for t, r in zip(tokens, dec_raw)
    }

    # These are ERC-8056 tokens: `uiMultiplier()` scales the displayed amount while raw balances stay
    # fixed, and it is not 1 for seven of the seventeen (SPY 1.001718, NVDA 1.000775, AAPL 1.000566,
    # META 1.000541, MSFT 1.000413, GOOGL 1.000194, MU 1.000075, measured 21.09). A pool quotes raw
    # units, so comparing its price with a feed without applying the multiplier measures the unit rather
    # than the market. It moves on the scale of corporate actions, so over one week it is a level shift,
    # but a level shift of up to 17 basis points is larger than most of the effect being looked for.
    mul_raw = calls([(t, keccak("uiMultiplier()")[:10]) for t in tokens])
    multiplier = {}
    for t, r in zip(tokens, mul_raw):
        multiplier[t] = (int(r, 16) / 1e18) if r and r != "0x" and int(r, 16) > 0 else 1.0
    moved = sum(1 for v in multiplier.values() if abs(v - 1) > 1e-9)
    print("  uiMultiplier is not 1 on %d of %d tokens" % (moved, len(tokens)))

    buckets = {}
    unmatched = {"noFeed": 0, "beforeHistory": 0}

    def fold(batch):
        for lg in batch:
            pool = by_addr.get(lg["address"].lower())
            if pool is None:
                continue
            t = pool["ticker"]
            rows = history.get(t)
            if not rows:
                unmatched["noFeed"] += 1
                continue
            w = words(lg["data"])
            a0, a1 = signed(w[0]), signed(w[1])
            sqrt_price = w[2]
            usdg_is_0 = pool["token0"].lower() == USDG.lower()
            usdg = abs(a0 if usdg_is_0 else a1) / 1e6
            px = pool_price(sqrt_price, usdg_is_0, decimals.get(pool["other"], 18))
            if not px:
                continue
            block = int(lg["blockNumber"], 16)
            ts = clock(block)
            i = bisect.bisect_right(stamps[t], ts) - 1
            if i < 0:
                unmatched["beforeHistory"] += 1
                continue
            feed_ts, feed_px = rows[i]
            if feed_px <= 0:
                continue
            mult = multiplier.get(pool["other"], 1.0)
            # state the pool price in dollars before comparing it with a dollar feed
            px_usd = px * mult * usdg_usd(ts)
            gap = (px_usd / feed_px - 1) * 100
            gap_raw = (px / feed_px - 1) * 100

            # the same comparison on the price before this swap moved it
            pre = pre_swap_sqrt(sqrt_price, w[3], a1)
            gap_pre = None
            if pre:
                px_pre = pool_price(pre, usdg_is_0, decimals.get(pool["other"], 18))
                if px_pre:
                    gap_pre = (px_pre * mult * usdg_usd(ts) / feed_px - 1) * 100

            # which way the trade went: a buyer of the share pushes the pool price up
            buying_share = (a0 > 0) if usdg_is_0 else (a1 > 0)
            age = ts - feed_ts
            state = state_of(block)
            if state == "CLOSED" and is_weekend(block):
                state = "WEEKEND"
            b = buckets.setdefault(
                (t, state),
                {
                    "n": 0,
                    "vol": 0.0,
                    "gaps": [],
                    "signed": [],
                    "raw": [],
                    "weights": [],
                    "overVol": 0.0,
                    "overN": 0,
                    "ages": [],
                    "freshGaps": [],
                    "freshWeights": [],
                    "preGaps": [],
                    "awayFromEdge": [],
                    "awayWeights": [],
                    "sameBlockAsFeed": 0,
                    "buyGaps": [],
                    "sellGaps": [],
                },
            )
            b["n"] += 1
            b["vol"] += usdg
            b["gaps"].append(abs(gap))
            b["signed"].append(gap)
            b["raw"].append(abs(gap_raw))
            b["weights"].append(usdg)
            b["ages"].append(age)
            if gap_pre is not None:
                b["preGaps"].append(abs(gap_pre))
            # Kimi's sensitivity check: an effect that lives in the five minutes around a bell is an
            # artefact of the boundary, not of the session. Removing that band must not change the answer.
            if min(abs(ts - e["ts"]) for e in edges) > args.edge_minutes * 60:
                b["awayFromEdge"].append(abs(gap))
                b["awayWeights"].append(usdg)
            # GPT's ordering objection: a feed round written later in the same block was not available to
            # this swap. Blocks are 0.1 s here and feeds publish hours apart, so this counts how often the
            # two even land together instead of assuming it never happens.
            if abs(ts - feed_ts) <= 1:
                b["sameBlockAsFeed"] += 1
            (b["buyGaps"] if buying_share else b["sellGaps"]).append(gap)
            # The strongest boring explanation for any gap is simply that a threshold feed has not yet
            # crossed its 0.5% trigger. Conditioning on a feed younger than five minutes removes it: what
            # is left cannot be the feed lagging, because the feed has just spoken.
            if age <= 300:
                b["freshGaps"].append(abs(gap))
                b["freshWeights"].append(usdg)
            if abs(gap) >= args.threshold:
                b["overVol"] += usdg
                b["overN"] += 1

    print("swaps:")
    stream_swaps(pools, from_block, head, fold)
    print("unmatched: %s" % unmatched)

    # ---- report -----------------------------------------------------------------------------------
    states = ["REGULAR", "CLOSED", "WEEKEND"]
    report = {}
    print("")
    print(
        "%-8s%-9s%9s%16s%10s%10s%10s%14s"
        % (
            "ticker",
            "session",
            "swaps",
            "USDG volume",
            "p50 gap",
            "p90 gap",
            "p99 gap",
            "vol over %.1f%%" % args.threshold,
        )
    )
    for t in tickers:
        for s in states:
            b = buckets.get((t, s))
            if not b:
                continue
            q = quantiles(b["gaps"], b["weights"])
            qraw = quantiles(b["raw"], b["weights"])
            qfresh = quantiles(b["freshGaps"], b["freshWeights"])
            signed_sorted = sorted(b["signed"])
            report["%s/%s" % (t, s)] = {
                "signedP50Pct": signed_sorted[len(signed_sorted) // 2],
                "gapP50PctUncorrected": qraw.get("p50"),
                "freshFeedSwaps": len(b["freshGaps"]),
                "freshGapP50Pct": qfresh.get("p50"),
                "freshGapP90Pct": qfresh.get("p90"),
                "swaps": b["n"],
                "volumeUsdg": b["vol"],
                "gapP50Pct": q.get("p50"),
                "gapP90Pct": q.get("p90"),
                "gapP99Pct": q.get("p99"),
                "gapMaxPct": q.get("max"),
                "volumeOverThresholdUsdg": b["overVol"],
                "swapsOverThreshold": b["overN"],
                "medianFeedAgeSeconds": sorted(b["ages"])[len(b["ages"]) // 2],
            }
            print(
                "%-8s%-9s%9s%16s%9.3f%%%9.3f%%%9.3f%%%14s"
                % (
                    t,
                    s,
                    "{:,}".format(b["n"]),
                    "{:,.0f}".format(b["vol"]),
                    q.get("p50", 0),
                    q.get("p90", 0),
                    q.get("p99", 0),
                    "{:,.0f}".format(b["overVol"]),
                )
            )

    totals = {}
    for s in states:
        rows = [b for (t, st), b in buckets.items() if st == s]
        if not rows:
            continue
        gaps = [g for b in rows for g in b["gaps"]]
        weights = [w for b in rows for w in b["weights"]]
        q = quantiles(gaps, weights)
        qfresh = quantiles(
            [g for b in rows for g in b["freshGaps"]], [w for b in rows for w in b["freshWeights"]]
        )
        signed_sorted = sorted(g for b in rows for g in b["signed"])
        pre_sorted = sorted(g for b in rows for g in b["preGaps"])
        qaway = quantiles(
            [g for b in rows for g in b["awayFromEdge"]], [w for b in rows for w in b["awayWeights"]]
        )
        same_block = sum(b["sameBlockAsFeed"] for b in rows)
        buys = sorted(g for b in rows for g in b["buyGaps"])
        sells = sorted(g for b in rows for g in b["sellGaps"])
        med = lambda xs: xs[len(xs) // 2] if xs else None  # noqa: E731
        totals[s] = {
            "gapPreSwapP50Pct": med(pre_sorted),
            "gapAwayFromBellsP50Pct": qaway.get("p50"),
            "gapAwayFromBellsP90Pct": qaway.get("p90"),
            "swapsAwayFromBells": sum(len(b["awayFromEdge"]) for b in rows),
            "swapsInTheSameSecondAsAFeedRound": same_block,
            "signedP50WhenBuyingSharePct": med(buys),
            "signedP50WhenSellingSharePct": med(sells),
            "buySwaps": len(buys),
            "sellSwaps": len(sells),
            "signedP50Pct": signed_sorted[len(signed_sorted) // 2] if signed_sorted else None,
            "freshFeedSwaps": sum(len(b["freshGaps"]) for b in rows),
            "freshGapP50Pct": qfresh.get("p50"),
            "freshGapP90Pct": qfresh.get("p90"),
            "freshGapP99Pct": qfresh.get("p99"),
            "swaps": sum(b["n"] for b in rows),
            "volumeUsdg": sum(b["vol"] for b in rows),
            "gapP50Pct": q.get("p50"),
            "gapP90Pct": q.get("p90"),
            "gapP99Pct": q.get("p99"),
            "gapMaxPct": q.get("max"),
            "volumeOverThresholdUsdg": sum(b["overVol"] for b in rows),
            "swapsOverThreshold": sum(b["overN"] for b in rows),
        }
    print("")
    print("sensitivity: the same sample with swaps within %d min of a bell removed" % args.edge_minutes)
    for s_name, v in totals.items():
        print(
            "  %-9s p50 %s  p90 %s  (n=%s)   swaps sharing a second with a feed round: %s"
            % (
                s_name,
                ("%.3f%%" % v["gapAwayFromBellsP50Pct"]) if v["gapAwayFromBellsP50Pct"] is not None else "n/a",
                ("%.3f%%" % v["gapAwayFromBellsP90Pct"]) if v["gapAwayFromBellsP90Pct"] is not None else "n/a",
                "{:,}".format(v["swapsAwayFromBells"]),
                "{:,}".format(v["swapsInTheSameSecondAsAFeedRound"]),
            )
        )
    print("")
    print("controls: price before the swap, and the sign split by trade direction")
    for s_name, v in totals.items():
        print(
            "  %-9s pre-swap p50 %s   buying the share %s (n=%s)   selling it %s (n=%s)"
            % (
                s_name,
                ("%.3f%%" % v["gapPreSwapP50Pct"]) if v["gapPreSwapP50Pct"] is not None else "n/a",
                ("%+.3f%%" % v["signedP50WhenBuyingSharePct"]) if v["signedP50WhenBuyingSharePct"] is not None else "n/a",
                "{:,}".format(v["buySwaps"]),
                ("%+.3f%%" % v["signedP50WhenSellingSharePct"]) if v["signedP50WhenSellingSharePct"] is not None else "n/a",
                "{:,}".format(v["sellSwaps"]),
            )
        )
    print("")
    print("conditioned on a feed younger than five minutes, which removes the threshold-lag explanation:")
    for s, v in totals.items():
        print(
            "  %-9s %9s swaps  p50 %s  p90 %s   (signed p50 of all swaps: %+.3f%%)"
            % (
                s,
                "{:,}".format(v["freshFeedSwaps"]),
                ("%.3f%%" % v["freshGapP50Pct"]) if v["freshGapP50Pct"] is not None else "n/a",
                ("%.3f%%" % v["freshGapP90Pct"]) if v["freshGapP90Pct"] is not None else "n/a",
                v["signedP50Pct"] or 0,
            )
        )
    print("")
    for s, v in totals.items():
        print(
            "%-9s %9s swaps  $%14s  p50 %.3f%%  p90 %.3f%%  p99 %.3f%%  volume over %.1f%%: $%s (%.1f%%)"
            % (
                s,
                "{:,}".format(v["swaps"]),
                "{:,.0f}".format(v["volumeUsdg"]),
                v["gapP50Pct"],
                v["gapP90Pct"],
                v["gapP99Pct"],
                args.threshold,
                "{:,.0f}".format(v["volumeOverThresholdUsdg"]),
                v["volumeOverThresholdUsdg"] / v["volumeUsdg"] * 100
                if v["volumeUsdg"]
                else 0,
            )
        )

    OUT.write_text(
        json.dumps(
            {
                "generated": dt.datetime.now(dt.timezone.utc).isoformat(),
                "window": {"fromBlock": from_block, "toBlock": head},
                "thresholdPct": args.threshold,
                "totals": totals,
                "perTickerSession": report,
                "unmatched": unmatched,
            },
            indent=1,
        ),
        encoding="utf-8",
    )
    print("")
    print("wrote %s" % OUT)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""The money question: how much real USDG trades on tokenized equities while the market is shut.

docs/REPLAY.md audits a prediction market with 0.009 ETH ever staked. That proves the mechanism, not that
anyone cares. This script measures the other side: the 62 Uniswap v3 pools on Robinhood Chain that pair
USDG with a tokenized equity (found by script/rh_equity_pools.py), every swap they have ever seen, and
which of those swaps happened at a moment when the Chainlink push feed for that ticker was NOT inside a
regular NYSE session -- that is, when the only number a naive contract could read was a leftover from the
previous close.

A swap outside the session is not itself wrong: an AMM price is whatever traders agree on. The claim this
number supports is narrower and checkable: on this chain there is continuous real USDG flow on equity
tokens at hours when the oracle for those same tickers is not moving, so any contract that settles,
liquidates or quotes off that feed is exposed for exactly as long as the flow continues.

The session classification is computed locally and then verified against the deployed PushFeedGuard at
0x8aF68a9fF7583097A7476060C6B56eB33dA7a711, which carries the same calendar onchain.

    python script/equity_flow.py

Public RPC only, no key, no gas.
"""

import datetime as dt
import json
import random

from rh_equity_pools import CACHE, ROOT, USDG, batch_call, keccak, post, rpc, words

POOLS = ROOT / "docs" / "equity_pools_4663.json"
GUARD = "0x8aF68a9fF7583097A7476060C6B56eB33dA7a711"
OUT = ROOT / "docs" / "equity_flow_4663.json"
SWAP = keccak("Swap(address,address,int256,int256,uint160,uint128,int24)")

# Blocks come every 0.1007 s (measured over 10 000 blocks, 21.09), so this is about fourteen days. The
# window is bounded on purpose: the claim is about the flow that exists now, not about chain history.
WINDOW_BLOCKS = 6_000_000  # about seven days

# --- a local NYSE calendar, deliberately a second implementation of SessionCalendar.sol -------------
HOLIDAYS = {
    (2026, 1, 1),
    (2026, 1, 19),
    (2026, 2, 16),
    (2026, 4, 3),
    (2026, 5, 25),
    (2026, 6, 19),
    (2026, 7, 3),
    (2026, 9, 7),
    (2026, 11, 26),
    (2026, 12, 25),
    (2027, 1, 1),
    (2027, 1, 18),
    (2027, 2, 15),
    (2027, 3, 26),
    (2027, 5, 31),
    (2027, 6, 18),
    (2027, 7, 5),
    (2027, 9, 6),
    (2027, 11, 25),
    (2027, 12, 24),
}
EARLY = {(2026, 11, 27), (2026, 12, 24), (2027, 11, 26)}


def _nth_weekday(year, month, weekday, n):
    d = dt.date(year, month, 1)
    d += dt.timedelta((weekday - d.weekday()) % 7)
    return d + dt.timedelta(7 * (n - 1))


def _is_dst(day):
    start = _nth_weekday(day.year, 3, 6, 2)  # second Sunday of March
    end = _nth_weekday(day.year, 11, 6, 1)  # first Sunday of November
    return start <= day < end


def session_for(ts):
    """Returns (state, tradingDate) for a UTC timestamp. State is one of REGULAR, CLOSED."""
    day = dt.datetime.fromtimestamp(ts, dt.timezone.utc).date()
    for candidate in (day, day - dt.timedelta(1)):
        if candidate.year not in (2026, 2027):
            continue
        if (
            candidate.weekday() >= 5
            or (candidate.year, candidate.month, candidate.day) in HOLIDAYS
        ):
            continue
        dst = _is_dst(candidate)
        midnight = dt.datetime(
            candidate.year, candidate.month, candidate.day, tzinfo=dt.timezone.utc
        ).timestamp()
        open_utc = midnight + (13 if dst else 14) * 3600 + 1800
        early = (candidate.year, candidate.month, candidate.day) in EARLY
        close_hour = (17 if dst else 18) if early else (20 if dst else 21)
        close_utc = midnight + close_hour * 3600
        if open_utc <= ts < close_utc:
            return "REGULAR", int(
                "%d%02d%02d" % (candidate.year, candidate.month, candidate.day)
            )
    return "CLOSED", 0


# --- chain reading ---------------------------------------------------------------------------------
def swaps_for(pools, from_block):
    """All Swap logs for the given pool addresses, shrinking the window when the node refuses."""
    head = int(rpc("eth_blockNumber", []), 16)
    addrs = [p["pool"] for p in pools]
    logs = []
    start = from_block
    span = head - from_block
    while start <= head:
        end = min(head, start + span)
        res = rpc(
            "eth_getLogs",
            [
                {
                    "address": addrs,
                    "topics": [SWAP],
                    "fromBlock": hex(start),
                    "toBlock": hex(end),
                }
            ],
        )
        if isinstance(res, dict):
            if span <= 1:
                raise SystemExit("cannot read even a single block: %s" % res)
            span = max(1, span // 4)
            continue
        logs += res
        print(
            "  blocks %d..%d: %d swaps (total %d)" % (start, end, len(res), len(logs))
        )
        start = end + 1
        if len(res) < 4000:
            span = max(1, min(max(head - start, 1), span * 2))
    return logs, head


def _exact_times(blocks):
    """Exact timestamps for the given block numbers, cached on disk."""
    path = CACHE / "block_times.json"
    known = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    missing = [b for b in blocks if str(b) not in known]
    for i in range(0, len(missing), 100):
        chunk = missing[i : i + 100]
        for j in range(0, len(chunk), 25):
            part = chunk[j : j + 25]
            out = post(
                [
                    {
                        "jsonrpc": "2.0",
                        "id": n,
                        "method": "eth_getBlockByNumber",
                        "params": [hex(b), False],
                    }
                    for n, b in enumerate(part)
                ]
            )
            by_id = {r["id"]: r for r in out}
            for n, b in enumerate(part):
                r = by_id.get(n, {}).get("result")
                if r:
                    known[str(b)] = int(r["timestamp"], 16)
        path.write_text(json.dumps(known), encoding="utf-8")
    return known


def _session_edges(day):
    """(open, close) as UTC timestamps for a trading day, or () when it is not one."""
    if day.year not in (2026, 2027):
        return ()
    if day.weekday() >= 5 or (day.year, day.month, day.day) in HOLIDAYS:
        return ()
    dst = _is_dst(day)
    midnight = dt.datetime(day.year, day.month, day.day, tzinfo=dt.timezone.utc).timestamp()
    early = (day.year, day.month, day.day) in EARLY
    close_hour = (17 if dst else 18) if early else (20 if dst else 21)
    return (midnight + (13 if dst else 14) * 3600 + 1800, midnight + close_hour * 3600)


def weekend_boundary_blocks(lo_block, hi_block):
    """The block where each weekend starts (Saturday 00:00 UTC) and ends (Monday 00:00 UTC)."""
    times = _exact_times([lo_block, hi_block])
    t_lo, t_hi = times[str(lo_block)], times[str(hi_block)]
    marks = []
    day = dt.datetime.fromtimestamp(t_lo, dt.timezone.utc).date() - dt.timedelta(2)
    last = dt.datetime.fromtimestamp(t_hi, dt.timezone.utc).date() + dt.timedelta(2)
    while day <= last:
        midnight = dt.datetime(day.year, day.month, day.day, tzinfo=dt.timezone.utc).timestamp()
        if day.weekday() == 5 and t_lo < midnight < t_hi:
            marks.append({"kind": "start", "ts": midnight, "date": day.isoformat()})
        if day.weekday() == 0 and t_lo < midnight < t_hi:
            marks.append({"kind": "end", "ts": midnight, "date": day.isoformat()})
        day += dt.timedelta(1)
    marks.sort(key=lambda m: m["ts"])
    return _locate(marks, lo_block, hi_block)


def _locate(marks, lo_block, hi_block):
    """Binary-search the first block at or after each timestamp, all searches in lockstep."""
    if not marks:
        return marks
    los = [lo_block] * len(marks)
    his = [hi_block] * len(marks)
    rounds = 0
    while any(los[i] < his[i] for i in range(len(marks))):
        mids = [(los[i] + his[i]) // 2 for i in range(len(marks))]
        known = _exact_times(sorted({m for i, m in enumerate(mids) if los[i] < his[i]}))
        for i, mark in enumerate(marks):
            if los[i] >= his[i]:
                continue
            if known[str(mids[i])] < mark["ts"]:
                los[i] = mids[i] + 1
            else:
                his[i] = mids[i]
        rounds += 1
        if rounds > 40:
            break
    for i, mark in enumerate(marks):
        mark["block"] = los[i]
    return marks


def session_boundary_blocks(lo_block, hi_block):
    """The block number at every opening and closing bell inside the window.

    Asking the node for the timestamp of each of a million swap blocks is not an option, and interpolating
    between anchors is only as honest as the block rate happens to be. The session state of a block is a
    step function with two steps per trading day, so the cheap and exact way is to find where the steps
    are: binary-search the first block at or after each bell. Ten trading days cost about twenty searches,
    run in lockstep so each round of the search is one batched request.
    """
    times = _exact_times([lo_block, hi_block])
    t_lo, t_hi = times[str(lo_block)], times[str(hi_block)]
    edges = []
    day = dt.datetime.fromtimestamp(t_lo, dt.timezone.utc).date() - dt.timedelta(1)
    last = dt.datetime.fromtimestamp(t_hi, dt.timezone.utc).date() + dt.timedelta(1)
    while day <= last:
        for kind, edge in zip(("open", "close"), _session_edges(day)):
            if t_lo < edge < t_hi:
                edges.append({"kind": kind, "ts": edge, "date": day.isoformat()})
        day += dt.timedelta(1)
    edges.sort(key=lambda e: e["ts"])
    print("  %d session boundaries inside the window" % len(edges))
    return _locate(edges, lo_block, hi_block)

    los = [lo_block] * len(edges)
    his = [hi_block] * len(edges)
    rounds = 0
    while any(los[i] < his[i] for i in range(len(edges))):
        mids = [(los[i] + his[i]) // 2 for i in range(len(edges))]
        known = _exact_times(sorted({m for i, m in enumerate(mids) if los[i] < his[i]}))
        for i, e in enumerate(edges):
            if los[i] >= his[i]:
                continue
            t = known[str(mids[i])]
            if t < e["ts"]:
                los[i] = mids[i] + 1
            else:
                his[i] = mids[i]
        rounds += 1
        if rounds > 40:
            break
    for i, e in enumerate(edges):
        e["block"] = los[i]
    print("  located in %d rounds of batched search" % rounds)
    return edges


def signed(w):
    return w - (1 << 256) if w >= (1 << 255) else w


def stream_swaps(pools, from_block, head, on_batch):
    """Walk the window in getLogs pages, handing each page straight to the caller.

    A week of these pools is on the order of a million swaps. Holding them all in memory on a machine that
    already fights its commit limit is a good way to lose the measurement at the last step, so nothing is
    kept: each page is folded into the accumulator and dropped.
    """
    addrs = [p["pool"] for p in pools]
    start = from_block
    span = 200_000
    seen = 0
    while start <= head:
        end = min(head, start + span)
        res = rpc(
            "eth_getLogs",
            [{"address": addrs, "topics": [SWAP], "fromBlock": hex(start), "toBlock": hex(end)}],
        )
        if isinstance(res, dict):
            if span <= 1:
                raise SystemExit("cannot read even a single block: %s" % res)
            span = max(1, span // 4)
            continue
        on_batch(res)
        seen += len(res)
        pct = (end - from_block) / max(1, head - from_block) * 100
        print("  %5.1f%%  block %d  +%d swaps (total %d)" % (pct, end, len(res), seen))
        start = end + 1
        if len(res) < 3000:
            span = max(1, min(max(head - start, 1), span * 2))
    return seen


def main():
    pools = json.loads(POOLS.read_text(encoding="utf-8"))
    # A ticker symbol is a claim, not an identity: four of the pools found by symbol pair USDG with an
    # impostor token (a fake AMD, two fake SLV, a fake USO). Only tokens whose deployed bytecode hashes
    # to the same value as the known-good AAPL token at 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9 are
    # counted. See script/.cache/token_code_hash.json.
    dropped = [p for p in pools if not p.get("genuine")]
    pools = [p for p in pools if p.get("genuine")]
    print("dropped %d pools on impostor tokens: %s" % (len(dropped), sorted({d["ticker"] for d in dropped})))
    by_addr = {p["pool"]: p for p in pools}
    first_block = min(p["block"] for p in pools)

    head = int(rpc("eth_blockNumber", []), 16)
    from_block = max(first_block, head - WINDOW_BLOCKS)
    print("%d equity/USDG pools, window %d..%d" % (len(pools), from_block, head))

    edges = session_boundary_blocks(from_block, head)
    # A second, coarser question: how much of the out-of-session flow lands on the weekend, when even a
    # 24/5 feed publishes nothing and the pool is the only price anywhere.
    weekend = weekend_boundary_blocks(from_block, head)
    import bisect

    edge_blocks = [e["block"] for e in edges]
    weekend_blocks = [e["block"] for e in weekend]

    def is_weekend(block):
        i = bisect.bisect_right(weekend_blocks, block) - 1
        if i < 0:
            return weekend and weekend[0]["kind"] == "end"
        return weekend[i]["kind"] == "start"

    def state_of(block):
        """REGULAR when the block falls between an opening bell and the next closing bell."""
        i = bisect.bisect_right(edge_blocks, block) - 1
        if i < 0:
            return ("REGULAR" if edges and edges[0]["kind"] == "close" else "CLOSED", "")
        e = edges[i]
        return ("REGULAR" if e["kind"] == "open" else "CLOSED", e["date"])

    per = {}
    totals = {"n": 0, "vol": 0.0, "nClosed": 0, "closed": 0.0, "nWeekend": 0, "weekend": 0.0}

    def fold(batch):
        for lg in batch:
            pool = by_addr.get(lg["address"].lower())
            if pool is None:
                continue
            w = words(lg["data"])
            a0, a1 = signed(w[0]), signed(w[1])
            usdg_is_0 = pool["token0"].lower() == USDG.lower()
            usdg = abs(a0 if usdg_is_0 else a1) / 1e6
            state, _ = state_of(int(lg["blockNumber"], 16))
            d = per.setdefault(
                pool["ticker"], {"vol": 0.0, "closed": 0.0, "weekend": 0.0, "n": 0, "nClosed": 0, "nWeekend": 0}
            )
            d["vol"] += usdg
            d["n"] += 1
            totals["vol"] += usdg
            totals["n"] += 1
            if state == "CLOSED":
                d["closed"] += usdg
                d["nClosed"] += 1
                totals["closed"] += usdg
                totals["nClosed"] += 1
                if is_weekend(int(lg["blockNumber"], 16)):
                    d["weekend"] += usdg
                    d["nWeekend"] += 1
                    totals["weekend"] += usdg
                    totals["nWeekend"] += 1

    stream_swaps(pools, from_block, head, fold)

    stamps = _exact_times([from_block, head])
    span_days = (stamps[str(head)] - stamps[str(from_block)]) / 86400

    print("")
    print("window: %.1f days, %d swaps in %d pools" % (span_days, totals["n"], len(pools)))
    print("total USDG volume:        %s" % ("{:>14,.0f}".format(totals["vol"])))
    print(
        "while the market is shut: {:>14,.0f}  ({:.1f}% of volume, {:.1f}% of swaps)".format(
            totals["closed"],
            totals["closed"] / totals["vol"] * 100 if totals["vol"] else 0,
            totals["nClosed"] / totals["n"] * 100 if totals["n"] else 0,
        )
    )
    session_hours = len([e for e in edges if e["kind"] == "open"]) * 6.5
    window_hours = span_days * 24
    shut_hours = window_hours - session_hours
    open_vol = totals["vol"] - totals["closed"]
    print(
        "the other way round: the regular session is {:.1f} of {:.1f} hours ({:.0f}% of the window) and "
        "carries ${:,.0f}/h, against ${:,.0f}/h while shut, so intensity inside the session is {:.1f}x".format(
            session_hours,
            window_hours,
            session_hours / window_hours * 100,
            open_vol / session_hours if session_hours else 0,
            totals["closed"] / shut_hours if shut_hours else 0,
            (open_vol / session_hours) / (totals["closed"] / shut_hours) if session_hours and shut_hours else 0,
        )
    )
    print(
        "of the out-of-session volume, ${:,.0f} ({:.1f}%) fell on a weekend, when no feed publishes at all".format(
            totals["weekend"], totals["weekend"] / totals["closed"] * 100 if totals["closed"] else 0
        )
    )
    print("")
    print("%-7s%10s%18s%18s%8s" % ("ticker", "swaps", "USDG volume", "while shut", "share"))
    for t, d in sorted(per.items(), key=lambda kv: -kv[1]["vol"]):
        print(
            "{:<7}{:>10,}{:>18,.0f}{:>18,.0f}{:>7.1f}%".format(
                t, d["n"], d["vol"], d["closed"], d["closed"] / d["vol"] * 100 if d["vol"] else 0
            )
        )

    # spot-check the boundary blocks against the deployed contract: the block at an opening bell must be
    # inside a session according to PushFeedGuard, and the block before it must not be.
    sel = keccak("sessionAt(uint64)")[:10]
    probe = edges[: min(12, len(edges))]
    probe_times = _exact_times([e["block"] for e in probe] + [e["block"] - 1 for e in probe])
    checked = 0
    mismatch = 0
    for e in probe:
        for block, expect in ((e["block"], e["kind"] == "open"), (e["block"] - 1, e["kind"] != "open")):
            t = probe_times.get(str(block))
            if t is None:
                continue
            raw = batch_call([(GUARD, sel + hex(t)[2:].rjust(64, "0"))])[0]
            if not raw:
                continue
            w = words(raw)
            # Session is (bool exists, bool earlyClose, uint32 tradingDate, uint64 openUtc, uint64 closeUtc)
            inside = bool(w[0] & 1) and w[3] <= t < w[4]
            checked += 1
            if inside != expect:
                mismatch += 1
                print("    disagreement at block %d (%s %s)" % (block, e["kind"], e["date"]))
    print("")
    print(
        "boundary cross-check against PushFeedGuard.sessionAt: %d probes, %d disagreements"
        % (checked, mismatch)
    )

    OUT.write_text(
        json.dumps(
            {
                "generated": dt.datetime.now(dt.timezone.utc).isoformat(),
                "window": {"fromBlock": from_block, "toBlock": head, "days": span_days},
                "pools": len(pools),
                "swaps": totals["n"],
                "totalUsdg": totals["vol"],
                "closedUsdg": totals["closed"],
                "closedSwaps": totals["nClosed"],
                "weekendUsdg": totals["weekend"],
                "weekendSwaps": totals["nWeekend"],
                "sessionHours": session_hours,
                "windowHours": window_hours,
                "perTicker": per,
                "boundaryCrossCheck": {"checked": checked, "mismatches": mismatch},
            },
            indent=1,
        ),
        encoding="utf-8",
    )
    print("wrote %s" % OUT)


if __name__ == "__main__":
    main()

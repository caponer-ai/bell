#!/usr/bin/env python3
"""Who actually trades at each hour, and whether the out-of-session flow is just the same few bots.

A reviewer put the objection sharply: if the overnight and weekend volume is a handful of bots moving
inventory between pools, then "half the week's flow happens while the exchange is shut" describes a closed
loop rather than a market, and the number should not be used to argue that anyone is exposed to anything.

This counts it. For every swap in the 58 genuine equity/USDG pools it records the `sender` (topic 1, the
router or bot that called the pool) and the `recipient` (topic 2, where the output went), split by session
state. If concentration is the same inside and outside the session, the out-of-session flow is the same
market at a quieter hour. If it spikes outside, the objection is right.

    python script/concentration.py [--window-blocks 6000000]

Public RPC only, no key, no gas. Writes docs/concentration_4663.json.
"""

import argparse
import collections
import datetime as dt
import json

from equity_flow import (
    session_boundary_blocks,
    signed,
    stream_swaps,
    weekend_boundary_blocks,
)
from rh_equity_pools import ROOT, USDG, rpc, words

OUT = ROOT / "docs" / "concentration_4663.json"


def share(counter, top):
    total = sum(counter.values())
    if not total:
        return 0.0
    return sum(v for _, v in counter.most_common(top)) / total * 100


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--window-blocks", type=int, default=6_000_000)
    args = ap.parse_args()

    pools = [
        p
        for p in json.loads(
            (ROOT / "docs" / "equity_pools_4663.json").read_text(encoding="utf-8")
        )
        if p.get("genuine")
    ]
    by_addr = {p["pool"]: p for p in pools}

    head = int(rpc("eth_blockNumber", []), 16)
    from_block = max(min(p["block"] for p in pools), head - args.window_blocks)
    print("%d pools, window %d..%d" % (len(pools), from_block, head))

    edges = session_boundary_blocks(from_block, head)
    weekend = weekend_boundary_blocks(from_block, head)
    import bisect

    edge_blocks = [e["block"] for e in edges]
    weekend_blocks = [e["block"] for e in weekend]

    def state_of(block):
        i = bisect.bisect_right(edge_blocks, block) - 1
        if i < 0:
            return "CLOSED"
        if edges[i]["kind"] == "open":
            return "REGULAR"
        j = bisect.bisect_right(weekend_blocks, block) - 1
        if j >= 0 and weekend[j]["kind"] == "start":
            return "WEEKEND"
        return "CLOSED"

    senders = {s: collections.Counter() for s in ("REGULAR", "CLOSED", "WEEKEND")}
    recipients = {s: collections.Counter() for s in ("REGULAR", "CLOSED", "WEEKEND")}
    volume = {s: collections.Counter() for s in ("REGULAR", "CLOSED", "WEEKEND")}
    swaps = collections.Counter()

    def fold(batch):
        for lg in batch:
            pool = by_addr.get(lg["address"].lower())
            if pool is None:
                continue
            w = words(lg["data"])
            usdg_is_0 = pool["token0"].lower() == USDG.lower()
            amount = abs(signed(w[0]) if usdg_is_0 else signed(w[1])) / 1e6
            state = state_of(int(lg["blockNumber"], 16))
            sender = "0x" + lg["topics"][1][-40:]
            recipient = "0x" + lg["topics"][2][-40:]
            senders[state][sender] += 1
            recipients[state][recipient] += 1
            volume[state][sender] += amount
            swaps[state] += 1

    stream_swaps(pools, from_block, head, fold)

    report = {}
    print("")
    print(
        "%-9s%10s%10s%12s%12s%12s%12s"
        % (
            "state",
            "swaps",
            "senders",
            "recipients",
            "top3 swaps",
            "top3 volume",
            "top10 vol",
        )
    )
    for s in ("REGULAR", "CLOSED", "WEEKEND"):
        if not swaps[s]:
            continue
        row = {
            "swaps": swaps[s],
            "distinctSenders": len(senders[s]),
            "distinctRecipients": len(recipients[s]),
            "top3SwapSharePct": share(senders[s], 3),
            "top3VolumeSharePct": share(volume[s], 3),
            "top10VolumeSharePct": share(volume[s], 10),
            "topSenders": [
                {"address": a, "swaps": n, "volumeUsdg": volume[s][a]}
                for a, n in senders[s].most_common(5)
            ],
        }
        report[s] = row
        print(
            "%-9s%10s%10s%12s%11.1f%%%11.1f%%%11.1f%%"
            % (
                s,
                "{:,}".format(row["swaps"]),
                "{:,}".format(row["distinctSenders"]),
                "{:,}".format(row["distinctRecipients"]),
                row["top3SwapSharePct"],
                row["top3VolumeSharePct"],
                row["top10VolumeSharePct"],
            )
        )

    # the question the table is meant to answer
    if "REGULAR" in report and "WEEKEND" in report:
        print("")
        print(
            "distinct recipients per 1,000 swaps: regular %.1f, closed %.1f, weekend %.1f"
            % tuple(
                report[s]["distinctRecipients"] / report[s]["swaps"] * 1000
                for s in ("REGULAR", "CLOSED", "WEEKEND")
            )
        )

    OUT.write_text(
        json.dumps(
            {
                "generated": dt.datetime.now(dt.timezone.utc).isoformat(),
                "window": {"fromBlock": from_block, "toBlock": head},
                "byState": report,
            },
            indent=1,
        ),
        encoding="utf-8",
    )
    print("wrote %s" % OUT)


if __name__ == "__main__":
    main()

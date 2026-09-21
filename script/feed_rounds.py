#!/usr/bin/env python3
"""What a Chainlink equity feed on this chain actually publishes, round by round.

The whole project rests on one claim: a push feed hands a contract a number and no way to tell which
trading session that number belongs to. This script tests the claim instead of repeating it. For every
equity feed in docs/equity_feeds_4663.json it walks the last N rounds through `getRoundData`, stamps each
one with the NYSE session state at its `updatedAt`, and reports:

  * how many rounds are published while the regular session is open, and how many outside it
  * how much the price moves in each case
  * the longest gap between rounds, which is what a staleness budget is really up against

A contract that reads `latestRoundData()` at 06:30 UTC gets a real, recent, non-stale number. It is just
not a regular-session number. That distinction is the product, and this script is the evidence for it.

    python script/feed_rounds.py [--rounds 40]

Public RPC only, no key, no gas. Results go to docs/feed_rounds_4663.json.
"""

import argparse
import datetime as dt
import json
import sys

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))

from equity_flow import session_for  # noqa: E402
from rh_equity_pools import ROOT, keccak, post  # noqa: E402

OUT = ROOT / "docs" / "feed_rounds_4663.json"


def calls(pairs, size=25):
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


def decode_string(res):
    if not res or res == "0x":
        return None
    b = res[2:]
    try:
        off = int(b[:64], 16) * 2
        ln = int(b[off : off + 64], 16)
        return bytes.fromhex(b[off + 64 : off + 64 + ln * 2]).decode(errors="replace")
    except Exception:
        return None


def decode_round(res):
    if not res or res == "0x":
        return None
    w = [int(res[2:][i * 64 : (i + 1) * 64], 16) for i in range(5)]
    answer = w[1] - (1 << 256) if w[1] >= (1 << 255) else w[1]
    return {"roundId": w[0], "answer": answer, "startedAt": w[2], "updatedAt": w[3]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rounds", type=int, default=40)
    args = ap.parse_args()

    feeds = json.loads(
        (ROOT / "docs" / "equity_feeds_4663.json").read_text(encoding="utf-8")
    )
    print("%d feeds" % len(feeds))

    meta = calls(
        [(f["proxy"], keccak("description()")[:10]) for f in feeds]
        + [(f["proxy"], keccak("decimals()")[:10]) for f in feeds]
        + [(f["proxy"], keccak("latestRoundData()")[:10]) for f in feeds]
    )
    n = len(feeds)
    for i, f in enumerate(feeds):
        f["description"] = decode_string(meta[i])
        f["decimals"] = int(meta[n + i], 16) if meta[n + i] else None
        f["latest"] = decode_round(meta[2 * n + i])

    sel = keccak("getRoundData(uint80)")[:10]
    report = []
    for f in feeds:
        if not f["latest"]:
            print("  %s: no latestRoundData" % f["name"])
            continue
        rid = f["latest"]["roundId"]
        ids = [rid - i for i in range(args.rounds)]
        raw = calls([(f["proxy"], sel + hex(i)[2:].rjust(64, "0")) for i in ids])
        rounds = [r for r in (decode_round(x) for x in raw) if r]
        rounds.sort(key=lambda r: r["updatedAt"])
        scale = 10 ** (f["decimals"] or 8)

        inside = outside = 0
        move_in = []
        move_out = []
        gaps = []
        prev = None
        for r in rounds:
            state, _ = session_for(r["updatedAt"])
            r["session"] = state
            if state == "REGULAR":
                inside += 1
            else:
                outside += 1
            if prev:
                gaps.append(r["updatedAt"] - prev["updatedAt"])
                move = (
                    abs(r["answer"] - prev["answer"]) / prev["answer"] * 100
                    if prev["answer"]
                    else 0
                )
                (move_in if state == "REGULAR" else move_out).append(move)
            prev = r

        row = {
            "name": f["name"],
            "description": f["description"],
            "proxy": f["proxy"],
            "rounds": len(rounds),
            "inside": inside,
            "outside": outside,
            "maxGapHours": max(gaps) / 3600 if gaps else None,
            "medianMoveInsidePct": sorted(move_in)[len(move_in) // 2]
            if move_in
            else None,
            "medianMoveOutsidePct": sorted(move_out)[len(move_out) // 2]
            if move_out
            else None,
            "latestAnswer": f["latest"]["answer"] / scale,
            "latestUpdatedAt": f["latest"]["updatedAt"],
            "history": [
                {
                    "updatedAt": r["updatedAt"],
                    "answer": r["answer"] / scale,
                    "session": r["session"],
                }
                for r in rounds
            ],
        }
        report.append(row)
        print(
            "  %-28s %3d rounds  inside %3d  outside %3d (%.0f%%)  max gap %5.1f h"
            % (
                f["description"] or f["name"],
                len(rounds),
                inside,
                outside,
                outside / len(rounds) * 100 if rounds else 0,
                (max(gaps) / 3600) if gaps else 0,
            )
        )

    tot_in = sum(r["inside"] for r in report)
    tot_out = sum(r["outside"] for r in report)
    print("")
    print(
        "across %d feeds: %d rounds published inside the regular session, %d outside (%.1f%%)"
        % (len(report), tot_in, tot_out, tot_out / (tot_in + tot_out) * 100)
    )
    worst = max(report, key=lambda r: r["maxGapHours"] or 0)
    print(
        "longest gap between rounds: %.1f h on %s"
        % (worst["maxGapHours"], worst["description"])
    )

    OUT.write_text(
        json.dumps(
            {
                "generated": dt.datetime.now(dt.timezone.utc).isoformat(),
                "roundsRequested": args.rounds,
                "feeds": report,
                "totals": {"inside": tot_in, "outside": tot_out},
            },
            indent=1,
        ),
        encoding="utf-8",
    )
    print("wrote %s" % OUT)


if __name__ == "__main__":
    main()

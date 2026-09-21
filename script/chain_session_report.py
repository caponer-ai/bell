#!/usr/bin/env python3
"""Ask the live PushFeedGuard about every US equity feed on Robinhood Chain, in one call.

There are 35 Chainlink push feeds for US equities on chain 4663 (Chainlink reference data,
docs/equity_feeds_4663.json). Each answers latestRoundData() at any hour of any day and none of them
says whether the exchange is open or how old the number is. This script asks the deployed guard
instead, with `checkMany`, and prints what a contract would be told right now.

    python script/chain_session_report.py            # 15 minute staleness budget
    python script/chain_session_report.py --max-age 60

No key, no subscription: the guard is a public view contract.
"""

import argparse
import datetime as dt
import json
import pathlib
import urllib.request

RPC = "https://rpc.mainnet.chain.robinhood.com/"
GUARD = "0x8aF68a9fF7583097A7476060C6B56eB33dA7a711"
ROOT = pathlib.Path(__file__).resolve().parent.parent
VERDICTS = ["ALLOW", "WAIT", "REJECT"]
REASONS = [
    "OK",
    "NO_SESSION",
    "OUTSIDE_SESSION",
    "PRICE_STALE",
    "ROUND_INCOMPLETE",
    "BAD_PRICE",
    "NO_FEED",
]


def keccak(text):
    from Crypto.Hash import keccak as _k

    k = _k.new(digest_bits=256)
    k.update(text.encode())
    return "0x" + k.hexdigest()


def rpc(method, params):
    req = urllib.request.Request(
        RPC,
        data=json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
        ).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "bell/0.1"},
    )
    out = json.loads(urllib.request.urlopen(req, timeout=60).read())
    if "error" in out:
        raise RuntimeError(out["error"])
    return out["result"]


def words(hexstr):
    body = hexstr[2:]
    return [int(body[i * 64 : (i + 1) * 64], 16) for i in range(len(body) // 64)]


def signed(x):
    return x - (1 << 256) if x >= (1 << 255) else x


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--max-age", type=int, default=900, help="tolerated staleness in seconds"
    )
    args = ap.parse_args()

    feeds = json.loads(
        (ROOT / "docs" / "equity_feeds_4663.json").read_text(encoding="utf-8")
    )
    addrs = [f["proxy"] for f in feeds]

    selector = keccak("checkMany(address[],uint64)")[:10]
    head = "0000000000000000000000000000000000000000000000000000000000000040"
    max_age = hex(args.max_age)[2:].rjust(64, "0")
    arr = hex(len(addrs))[2:].rjust(64, "0") + "".join(
        a.lower().replace("0x", "").rjust(64, "0") for a in addrs
    )
    data = selector + head + max_age + arr

    res = rpc("eth_call", [{"to": GUARD, "data": data}, "latest"])
    w = words(res)
    n = len(addrs)
    # four dynamic arrays: verdicts, reasons, answers, ages
    offs = [w[i] // 32 for i in range(4)]
    verdicts = w[offs[0] + 1 : offs[0] + 1 + n]
    reasons = w[offs[1] + 1 : offs[1] + 1 + n]
    answers = [signed(x) for x in w[offs[2] + 1 : offs[2] + 1 + n]]
    ages = w[offs[3] + 1 : offs[3] + 1 + n]

    block = rpc("eth_getBlockByNumber", ["latest", False])
    now = int(block["timestamp"], 16)
    session = rpc(
        "eth_call",
        [
            {
                "to": GUARD,
                "data": keccak("sessionAt(uint64)")[:10] + hex(now)[2:].rjust(64, "0"),
            },
            "latest",
        ],
    )
    s = words(session)
    exists, early, date, open_utc, close_utc = bool(s[0]), bool(s[1]), s[2], s[3], s[4]

    stamp = dt.datetime.fromtimestamp(now, dt.timezone.utc).strftime(
        "%Y-%m-%d %H:%M:%S UTC"
    )
    print(
        f"chain time {stamp}, block {int(block['number'], 16)}, staleness budget {args.max_age}s"
    )
    if exists:
        o = dt.datetime.fromtimestamp(open_utc, dt.timezone.utc).strftime("%H:%M")
        c = dt.datetime.fromtimestamp(close_utc, dt.timezone.utc).strftime("%H:%M")
        print(
            f"calendar: trading day {date}, session {o} to {c} UTC{', early close' if early else ''}"
        )
    else:
        print(
            "calendar: no trading day (weekend, NYSE holiday, or a year outside the table)"
        )
    print()
    print(f"{'feed':28} {'verdict':8} {'reason':17} {'price':>12} {'age':>10}")
    for f, v, r, a, age in zip(feeds, verdicts, reasons, answers, ages):
        name = f["name"].replace("Robinhood ", "")
        price = f"{a / 1e8:,.2f}" if a > 0 else "-"
        age_s = "-" if age == 0 else (f"{age}s" if age < 3600 else f"{age / 3600:.1f}h")
        print(f"{name:28} {VERDICTS[v]:8} {REASONS[r]:17} {price:>12} {age_s:>10}")

    allow = sum(1 for v in verdicts if v == 0)
    wait = sum(1 for v in verdicts if v == 1)
    reject = sum(1 for v in verdicts if v == 2)
    fresh = [age for age, v in zip(ages, verdicts) if v == 0]
    print(f"\n{len(feeds)} equity feeds: {allow} ALLOW, {wait} WAIT, {reject} REJECT")
    if fresh:
        fresh.sort()
        print(
            f"age of the admissible ones: median {fresh[len(fresh) // 2]}s, oldest {fresh[-1]}s"
        )
    stale = [
        (f["name"].replace("Robinhood ", ""), age)
        for f, age, r in zip(feeds, ages, reasons)
        if r == 3
    ]
    if stale:
        stale.sort(key=lambda x: -x[1])
        worst = ", ".join(f"{n} {a / 3600:.1f}h" for n, a in stale[:3])
        print(f"quietest feeds: {worst}")


if __name__ == "__main__":
    main()

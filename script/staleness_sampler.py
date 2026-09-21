#!/usr/bin/env python3
"""Sample how stale the equity feeds are *while the exchange is open*.

Everything we have measured so far is about closed markets, where a quiet feed is expected. The number
that decides whether a staleness guard is worth anything is the other one: during the regular session,
how old is the price a contract would read? This samples all 35 feeds every few minutes through the
session and writes one row per feed per sample to docs/staleness_samples.csv.

    python script/staleness_sampler.py --interval 300     # run through today's session
    python script/staleness_sampler.py --summary          # print the distribution from the CSV

View calls only: no key, no gas, nothing written onchain.
"""

import argparse
import csv
import datetime as dt
import json
import pathlib
import time
import urllib.request

RPC = "https://rpc.mainnet.chain.robinhood.com/"
GUARD = "0x8aF68a9fF7583097A7476060C6B56eB33dA7a711"
ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "staleness_samples.csv"


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
        headers={"Content-Type": "application/json", "User-Agent": "bell-sampler/0.1"},
    )
    out = json.loads(urllib.request.urlopen(req, timeout=60).read())
    if "error" in out:
        raise RuntimeError(out["error"])
    return out["result"]


def words(h):
    b = h[2:]
    return [int(b[i * 64 : (i + 1) * 64], 16) for i in range(len(b) // 64)]


def pad(x):
    return (
        hex(x)[2:].rjust(64, "0")
        if isinstance(x, int)
        else x.lower().replace("0x", "").rjust(64, "0")
    )


def feeds():
    return json.loads(
        (ROOT / "docs" / "equity_feeds_4663.json").read_text(encoding="utf-8")
    )


def sample():
    """One snapshot: (chain time, trading date, in_session, [(name, age_seconds, verdict)])."""
    rows = feeds()
    addrs = [f["proxy"] for f in rows]
    now = int(rpc("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)
    s = words(
        rpc(
            "eth_call",
            [
                {"to": GUARD, "data": keccak("sessionAt(uint64)")[:10] + pad(now)},
                "latest",
            ],
        )
    )
    exists, date, open_utc, close_utc = bool(s[0]), s[2], s[3], s[4]
    in_session = exists and open_utc <= now < close_utc

    # a huge budget, so the ages come back raw and the verdict reflects the session only
    data = (
        keccak("checkMany(address[],uint64)")[:10]
        + pad(0x40)
        + pad(2**63)
        + pad(len(addrs))
        + "".join(pad(a) for a in addrs)
    )
    w = words(rpc("eth_call", [{"to": GUARD, "data": data}, "latest"]))
    n = len(addrs)
    off = [w[i] // 32 for i in range(4)]
    verdicts = w[off[0] + 1 : off[0] + 1 + n]
    ages = w[off[3] + 1 : off[3] + 1 + n]
    out = [
        (r["name"].replace("Robinhood ", ""), ages[i], verdicts[i])
        for i, r in enumerate(rows)
    ]
    return now, date, in_session, out


def append(now, date, in_session, rows):
    new = not OUT.exists()
    with open(OUT, "a", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        if new:
            w.writerow(
                [
                    "chain_time",
                    "trading_date",
                    "in_session",
                    "feed",
                    "age_seconds",
                    "verdict",
                ]
            )
        for name, age, verdict in rows:
            w.writerow([now, date, int(in_session), name, age, verdict])


def summary():
    if not OUT.exists():
        print("no samples yet")
        return
    rows = list(csv.DictReader(open(OUT, encoding="utf-8")))
    inside = [int(r["age_seconds"]) for r in rows if r["in_session"] == "1"]
    outside = [int(r["age_seconds"]) for r in rows if r["in_session"] == "0"]
    samples = len({r["chain_time"] for r in rows})
    print(
        f"{len(rows)} observations over {samples} snapshots, {len(inside)} of them while the session was open"
    )
    for label, xs in (("session OPEN", inside), ("session CLOSED", outside)):
        if not xs:
            continue
        xs.sort()
        med = xs[len(xs) // 2]
        p90 = xs[int(len(xs) * 0.9)]
        over = lambda k: 100.0 * sum(1 for x in xs if x > k) / len(xs)  # noqa: E731
        print(f"\n  {label}: n={len(xs)}")
        print(f"    age of price: median {med}s, p90 {p90}s, max {xs[-1]}s")
        print(
            f"    older than 1 min {over(60):.0f}%, 5 min {over(300):.0f}%, 15 min {over(900):.0f}%, 1 h {over(3600):.0f}%"
        )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=int, default=300)
    ap.add_argument("--summary", action="store_true")
    ap.add_argument("--once", action="store_true")
    args = ap.parse_args()
    if args.summary:
        return summary()

    while True:
        now, date, in_session, rows = sample()
        append(now, date, in_session, rows)
        stamp = dt.datetime.fromtimestamp(now, dt.timezone.utc).strftime("%H:%M:%S")
        ages = sorted(a for _, a, _ in rows)
        print(
            f"{stamp} UTC  session {'OPEN ' if in_session else 'CLOSED'}  median age {ages[len(ages) // 2]}s  max {ages[-1]}s"
        )
        if args.once:
            return
        time.sleep(args.interval)


if __name__ == "__main__":
    main()

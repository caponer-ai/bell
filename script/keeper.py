#!/usr/bin/env python3
"""Bell keeper: write the public session record, one trading day at a time.

At the opening bell it marks what every watched feed says, then polls until each feed prints its first
regular-session update and records the delay, and at the close it marks the last state before the
exchange shuts. Everything lands in SessionLog on mainnet, permissionless and append-only.

    python script/keeper.py --dry-run        # show the plan for today, send nothing
    python script/keeper.py --open           # mark the open now (inside the 300 s window)
    python script/keeper.py --first-print    # try to record first prints for feeds that have printed
    python script/keeper.py --close          # mark the close now
    python script/keeper.py --watch          # sleep until each boundary and do all of it unattended

Needs PRIVATE_KEY in .env (the poster wallet) and `cast` on PATH. Gas per mark is about 60k, which on
this chain is a fraction of a cent.
"""

import argparse
import datetime as dt
import json
import pathlib
import subprocess
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
RPC = "https://rpc.mainnet.chain.robinhood.com/"
GUARD = "0x005554C0FeD814a3Ac450e226B455Ada0D04aec6"
LOG = "0xA3f6ba97e1a346c0D6b243C2C570e04414f64BC1"

# Five flagship tickers by default: the record is about the pattern, not about breadth, and gas is real.
WATCHED = ["AAPL / USD", "TSLA / USD", "NVDA / USD", "SPY / USD", "QQQ / USD"]


def env(name):
    dotenv = ROOT / ".env"
    if dotenv.exists():
        for line in dotenv.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                if k.strip() == name:
                    return v.strip()
    return None


def rpc(method, params):
    req = urllib.request.Request(
        RPC,
        data=json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
        ).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "bell-keeper/0.1"},
    )
    out = json.loads(urllib.request.urlopen(req, timeout=60).read())
    if "error" in out:
        raise RuntimeError(out["error"])
    return out["result"]


def chain_now():
    return int(rpc("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)


def feeds():
    rows = json.loads(
        (ROOT / "docs" / "equity_feeds_4663.json").read_text(encoding="utf-8")
    )
    by_name = {r["name"].replace("Robinhood ", ""): r["proxy"] for r in rows}
    return [(name, by_name[name]) for name in WATCHED if name in by_name]


def session_today():
    """(exists, tradingDate, openUtc, closeUtc) as the deployed calendar sees the current moment."""
    from Crypto.Hash import keccak

    k = keccak.new(digest_bits=256)
    k.update(b"sessionAt(uint64)")
    sel = "0x" + k.hexdigest()[:8]
    now = chain_now()
    res = rpc(
        "eth_call", [{"to": GUARD, "data": sel + hex(now)[2:].rjust(64, "0")}, "latest"]
    )
    b = res[2:]
    w = [int(b[i * 64 : (i + 1) * 64], 16) for i in range(len(b) // 64)]
    return bool(w[0]), w[2], w[3], w[4], now


def send(signature, *args):
    key = env("PRIVATE_KEY")
    if not key:
        raise SystemExit("PRIVATE_KEY missing in .env")
    cmd = [
        "cast",
        "send",
        LOG,
        signature,
        *[str(a) for a in args],
        "--private-key",
        key,
        "--rpc-url",
        RPC,
        "--json",
    ]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        return None, out.stderr.strip().splitlines()[-1][
            :160
        ] if out.stderr else "failed"
    r = json.loads(out.stdout)
    return r["transactionHash"], int(r["gasUsed"], 16)


def do_mark(kind: int, label: str):
    for name, addr in feeds():
        tx, gas = send("mark(address,uint8)(bytes32)", addr, kind)
        if tx:
            print(f"  {label} {name:12} {tx} ({gas} gas)")
        else:
            print(f"  {label} {name:12} skipped: {gas}")


def do_first_prints():
    for name, addr in feeds():
        tx, gas = send("markFirstPrint(address)(uint64)", addr)
        if tx:
            print(f"  first print {name:12} {tx} ({gas} gas)")
        else:
            print(f"  first print {name:12} not yet: {gas}")


def stamp(ts):
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime(
        "%Y-%m-%d %H:%M:%S UTC"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--open", action="store_true")
    ap.add_argument("--close", action="store_true")
    ap.add_argument("--first-print", action="store_true")
    ap.add_argument("--watch", action="store_true")
    args = ap.parse_args()

    exists, date, open_utc, close_utc, now = session_today()
    print(f"chain time {stamp(now)}")
    if not exists:
        print("no trading day today: the calendar says weekend or NYSE holiday")
        return
    print(f"trading day {date}, session {stamp(open_utc)} to {stamp(close_utc)}")
    print(f"watching {len(feeds())} feeds: {', '.join(n for n, _ in feeds())}")

    if args.dry_run:
        print("\nplan:")
        print(
            f"  mark OPEN         between {stamp(open_utc)} and {stamp(open_utc + 300)}"
        )
        print("  mark FIRST PRINT  whenever each feed's updatedAt reaches the bell")
        print(
            f"  mark CLOSE        between {stamp(close_utc - 300)} and {stamp(close_utc)}"
        )
        return

    if args.open:
        print("\nmarking the open")
        do_mark(0, "open ")
    if args.first_print:
        print("\nrecording first prints")
        do_first_prints()
    if args.close:
        print("\nmarking the close")
        do_mark(1, "close")

    if args.watch:
        if now < open_utc:
            wait = open_utc - now + 2
            print(f"\nsleeping {wait}s until the opening bell")
            time.sleep(wait)
        print("\nmarking the open")
        do_mark(0, "open ")
        deadline = min(close_utc - 600, open_utc + 3600)
        while chain_now() < deadline:
            print(f"\npolling first prints at {stamp(chain_now())}")
            do_first_prints()
            time.sleep(120)
        wait = close_utc - 60 - chain_now()
        if wait > 0:
            print(f"\nsleeping {wait}s until the closing bell")
            time.sleep(wait)
        print("\nmarking the close")
        do_mark(1, "close")


if __name__ == "__main__":
    main()

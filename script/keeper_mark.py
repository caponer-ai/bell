#!/usr/bin/env python3
"""Write the closing mark for a trading day, and settle if the recorded price is fit to settle on.

`SessionLog.mark` only accepts a closing mark inside `[C - 300, C)`, five minutes wide, so somebody has to
be awake at the bell. This is that somebody. It is deliberately a separate, dumb process rather than
something a person does by hand, because the threat model's one working attack is nobody writing the mark.

Inside the window it prefers a fresh price: `SettleOnMark` will refuse a mark whose price is older than the
trade's budget, so the keeper waits for the feed to publish and only falls back to marking a stale price at
the last moment. A recorded refusal is still worth more than no record at all, which is the whole point of
a write-once public log.

    python script/keeper_mark.py --trade 0x52a0... --feed 0x6B22... --close 1790107200

Needs PRIVATE_KEY in .env and `cast` on PATH. Writes a transcript to docs/keeper_log.txt.
"""

import argparse
import datetime as dt
import json
import os
import pathlib
import subprocess
import time
import urllib.request

RPC = "https://rpc.mainnet.chain.robinhood.com/"
ROOT = pathlib.Path(__file__).resolve().parent.parent
LOG_FILE = ROOT / "docs" / "keeper_log.txt"

GUARD = "0x8aF68a9fF7583097A7476060C6B56eB33dA7a711"
SESSION_LOG = "0xc482943C7fEE1dD7807Edad1c88260E4263fD0Ad"
WINDOW = 300  # SessionLog.WINDOW


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
        headers={"Content-Type": "application/json", "User-Agent": "bell-keeper/0.1"},
    )
    for attempt in range(6):
        try:
            out = json.loads(urllib.request.urlopen(req, timeout=60).read())
            return out.get("result")
        except Exception:
            if attempt == 5:
                raise
            time.sleep(2 * (attempt + 1))


def say(text):
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%H:%M:%S")
    line = f"[{stamp}Z] {text}"
    print(line, flush=True)
    with open(LOG_FILE, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def feed_state(feed, budget=900):
    data = (
        keccak("check(address,uint64)")[:10]
        + feed[2:].lower().rjust(64, "0")
        + hex(budget)[2:].rjust(64, "0")
    )
    raw = rpc("eth_call", [{"to": GUARD, "data": data}, "latest"])
    w = [int(raw[2:][i * 64 : (i + 1) * 64], 16) for i in range(4)]
    answer = w[2] - (1 << 256) if w[2] >= (1 << 255) else w[2]
    return {"verdict": w[0], "reason": w[1], "answer": answer, "updatedAt": w[3]}


def read(to, sig, extra=""):
    """One eth_call by signature, so every number this keeper uses comes from the chain."""
    return rpc("eth_call", [{"to": to, "data": keccak(sig)[:10] + extra}, "latest"])


def chain_now():
    blk = rpc("eth_getBlockByNumber", ["latest", False])
    return int(blk["timestamp"], 16)


def cast_send(to, sig, *args, key_env="PRIVATE_KEY"):
    cmd = [
        "cast",
        "send",
        to,
        sig,
        *[str(a) for a in args],
        "--rpc-url",
        RPC,
        "--private-key",
        os.environ[key_env],
    ]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    text = out.stdout + out.stderr
    tx = ""
    ok = False
    for line in text.splitlines():
        if line.startswith("transactionHash"):
            tx = line.split()[-1]
        if line.startswith("status"):
            ok = "1" in line
    return ok, tx, text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trade", required=True, help="the only thing this needs; everything else is read")
    args = ap.parse_args()

    # Nothing here is passed in by hand. On 2026-09-21 this keeper was started with the closing timestamp
    # of the wrong day, sat through the window it was meant to cover, and the mark that did get written
    # landed outside the trade's own window and burned the only write the day allows. Both numbers were in
    # the contracts the whole time, so now they are read from there.
    trade = args.trade
    feed = "0x" + read(trade, "feed()")[-40:]
    trading_date = int(read(trade, "tradingDate()"), 16)
    mark_window = int(read(trade, "markWindow()"), 16)
    max_age = int(read(trade, "maxPriceAge()"), 16)
    session = read(GUARD, "sessionForDate(uint32)", hex(trading_date)[2:].rjust(64, "0"))
    w = [int(session[2:][i * 64 : (i + 1) * 64], 16) for i in range(5)]
    if not w[0]:
        say(f"the calendar says {trading_date} is not a trading day. nothing to mark.")
        return
    close_at = w[4]
    args.feed, args.close, args.max_age, args.mark_window = feed, close_at, max_age, mark_window
    open_at = close_at - min(WINDOW, mark_window)
    say(
        f"read from chain: trade {trade}, feed {feed}, date {trading_date}, "
        f"markWindow {mark_window}s, maxPriceAge {max_age}s, close {close_at}"
    )
    say(
        f"log accepts {close_at - WINDOW}..{close_at}, the trade needs {close_at - mark_window} or later, "
        f"so this marks from {open_at} and not a second earlier"
    )

    # wait for the window, checking the feed as we go so the transcript shows what it was doing
    while True:
        now = chain_now()
        if now >= open_at:
            break
        left = open_at - now
        if left % 600 < 30 or left < 120:
            st = feed_state(args.feed, args.max_age)
            age = now - st["updatedAt"]
            say(
                f"{left // 60} min to the window. price {st['answer'] / 1e8:,.2f}, age {age // 60} min"
            )
        time.sleep(min(60, max(5, left / 4)))

    say("window open")
    marked = False
    while not marked:
        now = chain_now()
        if now >= args.close:
            say("window closed without a fresh price; no mark written")
            break
        st = feed_state(args.feed, args.max_age)
        age = now - st["updatedAt"]
        fresh = age <= args.max_age
        last_chance = args.close - now <= 20
        say(
            f"{args.close - now}s left. verdict {st['verdict']} reason {st['reason']}, "
            f"price {st['answer'] / 1e8:,.2f}, age {age}s, fresh={fresh}"
        )
        if fresh or last_chance:
            why = (
                "price is inside the trade's budget"
                if fresh
                else "last seconds of the window"
            )
            say(f"marking now: {why}")
            ok, tx, text = cast_send(SESSION_LOG, "mark(address,uint8)", args.feed, 1)
            say(f"mark sent ok={ok} tx={tx}")
            if not ok:
                say(text.strip()[-400:])
            marked = ok
            if not ok:
                time.sleep(5)
                continue
        else:
            time.sleep(10)

    if not marked:
        say(
            "nothing marked, so nothing to settle. the stakes are refundable after refundAfter."
        )
        return

    # settle, and record the refusal if it refuses
    time.sleep(5)
    q = rpc(
        "eth_call",
        [{"to": args.trade, "data": keccak("quote()")[:10]}, "latest"],
    )
    settleable = bool(int(q[2:][:64], 16)) if q else False
    say(f"quote says settleable={settleable}")
    if not settleable:
        say(
            "the mark was recorded but the trade will not settle on it. that is the honest outcome."
        )
        return
    ok, tx, text = cast_send(args.trade, "settle()")
    say(f"settle sent ok={ok} tx={tx}")
    if not ok:
        say(text.strip()[-400:])


if __name__ == "__main__":
    main()

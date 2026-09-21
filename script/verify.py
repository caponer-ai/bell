#!/usr/bin/env python3
"""Verify every claim in this README against mainnet, in one command, with no key and no wallet.

    python script/verify.py

It reads the deployed contracts on Robinhood Chain (chainId 4663) and prints what they answer right now:
the guard's verdict for all 35 equity feeds, the calendar's view of today, Bell's stored observation and
its refusal, the public record in SessionLog, and the state of the demo trade. Every line is an
`eth_call` you just made, not a number we cached.
"""

import datetime as dt
import json
import pathlib
import sys
import urllib.request

RPC = "https://rpc.mainnet.chain.robinhood.com/"
ROOT = pathlib.Path(__file__).resolve().parent.parent

BELL = "0x88a5a0414c9fd615201814ddbec4e4d9e4d283d0"
ADAPTER = "0x4F0331DDbdDfE3349e16e37F80219A868B876655"
GUARD = "0x005554C0FeD814a3Ac450e226B455Ada0D04aec6"
LOG = "0xA3f6ba97e1a346c0D6b243C2C570e04414f64BC1"
TRADE = "0x5338523cB4629b460c9e21532d9e4F0c7Fc9648C"

AAPL_FEED_ID = "0x000bbd87a23775b4c11092ae9a1fc7b3393636ae1dbb9f1ef460f845c0f4cff1"
DIGEST = "0x00094baebfda9b87680d8e59aa20a3e565126640ee7caeab3cd965e5568b17ee"

VERDICT = ["ALLOW", "WAIT", "REJECT"]
GUARD_REASON = [
    "OK",
    "NO_SESSION",
    "OUTSIDE_SESSION",
    "PRICE_STALE",
    "ROUND_INCOMPLETE",
    "BAD_PRICE",
    "NO_FEED",
]
BELL_REASON = [
    "OK",
    "NO_DATA",
    "EXPIRED",
    "OBS_STALE",
    "MID_STALE",
    "STATUS_UNKNOWN",
    "NON_REGULAR",
    "OUTSIDE_SESSION",
    "REFERENCE_PENDING",
    "REFERENCE_UNRESOLVED",
    "NO_SESSION",
    "CA_PAUSED",
]

OK, BAD = "  ok  ", " FAIL "


def keccak(text):
    try:
        from Crypto.Hash import keccak as _k
    except ImportError:
        sys.exit("pip install pycryptodome")
    k = _k.new(digest_bits=256)
    k.update(text.encode())
    return "0x" + k.hexdigest()


def rpc(method, params):
    req = urllib.request.Request(
        RPC,
        data=json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
        ).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "bell-verify/0.1"},
    )
    out = json.loads(urllib.request.urlopen(req, timeout=60).read())
    if "error" in out:
        return {"__error__": out["error"].get("message", "")}
    return out["result"]


def call(to, data):
    out = rpc("eth_call", [{"to": to, "data": data}, "latest"])
    return None if isinstance(out, dict) else out


def words(h):
    b = h[2:]
    return [int(b[i * 64 : (i + 1) * 64], 16) for i in range(len(b) // 64)]


def signed(x):
    return x - (1 << 256) if x >= (1 << 255) else x


def pad(x):
    return (
        hex(x)[2:].rjust(64, "0")
        if isinstance(x, int)
        else x.lower().replace("0x", "").rjust(64, "0")
    )


def utc(ts):
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime(
        "%Y-%m-%d %H:%M:%S UTC"
    )


def section(title):
    print(f"\n\033[1m{title}\033[0m" if sys.stdout.isatty() else f"\n{title}")
    print("-" * len(title))


def line(ok, text):
    print(f"[{OK if ok else BAD}] {text}")


def main():
    failures = 0
    block = rpc("eth_getBlockByNumber", ["latest", False])
    now = int(block["timestamp"], 16)
    chain_id = int(rpc("eth_chainId", []), 16)

    section("chain")
    line(
        chain_id == 4663,
        f"chainId {chain_id} (Robinhood Chain), block {int(block['number'], 16)}, {utc(now)}",
    )
    failures += chain_id != 4663

    # ---------------------------------------------------------------- calendar
    section("calendar (compiled into every contract below)")
    s = words(call(GUARD, keccak("sessionAt(uint64)")[:10] + pad(now)))
    exists, early, date, open_utc, close_utc = bool(s[0]), bool(s[1]), s[2], s[3], s[4]
    if exists:
        line(
            True,
            f"trading day {date}: session {utc(open_utc)} to {utc(close_utc)}{', early close' if early else ''}",
        )
        state = (
            "before the open"
            if now < open_utc
            else ("open" if now < close_utc else "after the close")
        )
        line(True, f"right now the regular session is {state}")
    else:
        line(True, "no trading day right now: weekend or NYSE holiday")

    # ---------------------------------------------------------------- guard over 35 feeds
    section("PushFeedGuard: all 35 Chainlink equity feeds, one call")
    feeds = json.loads(
        (ROOT / "docs" / "equity_feeds_4663.json").read_text(encoding="utf-8")
    )
    addrs = [f["proxy"] for f in feeds]
    data = (
        keccak("checkMany(address[],uint64)")[:10]
        + pad(0x40)
        + pad(900)
        + pad(len(addrs))
        + "".join(pad(a) for a in addrs)
    )
    w = words(call(GUARD, data))
    n = len(addrs)
    off = [w[i] // 32 for i in range(4)]
    verdicts = w[off[0] + 1 : off[0] + 1 + n]
    reasons = w[off[1] + 1 : off[1] + 1 + n]
    ages = w[off[3] + 1 : off[3] + 1 + n]
    tally = {v: verdicts.count(i) for i, v in enumerate(VERDICT)}
    line(
        sum(tally.values()) == 35,
        f"35 feeds answered: {tally['ALLOW']} ALLOW, {tally['WAIT']} WAIT, {tally['REJECT']} REJECT",
    )
    failures += sum(tally.values()) != 35
    consistent = all(
        (GUARD_REASON[r] in ("NO_SESSION", "OUTSIDE_SESSION"))
        == (not exists or not (open_utc <= now < close_utc))
        for r in reasons
    )
    line(consistent, "every verdict agrees with the calendar state above")
    failures += not consistent
    live = [(f["name"].replace("Robinhood ", ""), ages[i]) for i, f in enumerate(feeds)]
    live.sort(key=lambda x: -x[1])
    print(
        "    oldest prices: " + ", ".join(f"{k} {v / 3600:.1f}h" for k, v in live[:3])
    )
    print("    freshest:      " + ", ".join(f"{k} {v}s" for k, v in live[-3:]))

    # ---------------------------------------------------------------- Bell
    section("Bell: DON-signed reports, receipts, and a refusal")
    pol = words(call(BELL, keccak("POLICY_VERSION()")[:10]))[0]
    active = words(call(BELL, keccak("digestActive(bytes32)")[:10] + pad(DIGEST)))[0]
    line(pol == 2, f"POLICY_VERSION {pol} (the ladder)")
    line(
        active == 1,
        f"digestActive({DIGEST[:14]}…) = {bool(active)}: the DON config our fixtures were signed under is still routed",
    )
    failures += pol != 2 or active != 1

    latest = words(call(BELL, keccak("latest(bytes32)")[:10] + pad(AAPL_FEED_ID)))
    mid, obs, status, accepted = signed(latest[0]), latest[3], latest[5], latest[7]
    line(
        accepted > 0,
        f"stored AAPL observation: mid {mid / 1e18:,.5f}, observed {utc(obs)}, marketStatus {status}",
    )
    v, r = words(call(BELL, keccak("checkLive(bytes32)")[:10] + pad(AAPL_FEED_ID)))
    refuses = VERDICT[v] != "ALLOW"
    line(
        refuses,
        f"checkLive says {VERDICT[v]} / {BELL_REASON[r]}: a valid DON signature is not permission",
    )
    failures += not refuses

    res = rpc(
        "eth_call",
        [{"to": ADAPTER, "data": keccak("latestRoundData()")[:10]}, "latest"],
    )
    reverted = isinstance(res, dict)
    line(
        reverted,
        "BellFeedAdapter.latestRoundData() reverts rather than returning that price",
    )
    failures += not reverted

    # ---------------------------------------------------------------- SessionLog
    section("SessionLog: the public record")
    marks = words(call(LOG, keccak("totalMarks()")[:10]))[0]
    prints = words(call(LOG, keccak("totalFirstPrints()")[:10]))[0]
    line(True, f"{marks} marks and {prints} first prints recorded so far")
    if exists:
        aapl = next(f["proxy"] for f in feeds if f["name"] == "Robinhood AAPL / USD")
        for kind, label in ((0, "open"), (1, "close")):
            m = words(
                call(
                    LOG,
                    keccak("getMark(address,uint32,uint8)")[:10]
                    + pad(aapl)
                    + pad(date)
                    + pad(kind),
                )
            )
            if m[0]:
                age = m[5] - m[6]
                print(
                    f"    AAPL {label} mark: price {signed(m[7]) / 1e8:,.2f}, {age}s old when marked, verdict {VERDICT[m[1]]}"
                )
            else:
                print(f"    AAPL {label} mark: not recorded yet today")

    # ---------------------------------------------------------------- demo trade
    section("SettleOnMark: the USDG demo trade")
    q = call(TRADE, keccak("quote()")[:10])
    if q:
        qw = words(q)
        settleable = bool(qw[0])
        off_r = qw[1] // 32
        rlen = qw[off_r]
        reason = bytes.fromhex(
            q[2:][(off_r + 1) * 64 : (off_r + 1) * 64 + rlen * 2]
        ).decode(errors="replace")
        price, age = signed(qw[2]), qw[3]
        line(
            True,
            f"settleable: {settleable} ({reason})"
            + (f", closing mark {price / 1e8:,.2f}, {age}s old" if price else ""),
        )
    funded = [
        words(call(TRADE, keccak(f"{f}()")[:10]))[0]
        for f in ("longFunded", "shortFunded", "closed")
    ]
    line(
        True,
        f"longFunded {bool(funded[0])}, shortFunded {bool(funded[1])}, closed {bool(funded[2])}",
    )

    section("result")
    if failures:
        print(
            f"{failures} check(s) failed. Every claim above is meant to be reproducible: if one does not hold,"
        )
        print("the README is wrong and we would rather know.")
        sys.exit(1)
    print("all checks hold at this block.")


if __name__ == "__main__":
    main()

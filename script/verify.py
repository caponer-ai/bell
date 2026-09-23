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
import time
import urllib.error
import urllib.request

RPC = "https://rpc.mainnet.chain.robinhood.com/"
ROOT = pathlib.Path(__file__).resolve().parent.parent

BELL = "0x88a5a0414c9fd615201814ddbec4e4d9e4d283d0"
ADAPTER = "0x4F0331DDbdDfE3349e16e37F80219A868B876655"
GUARD = "0x8aF68a9fF7583097A7476060C6B56eB33dA7a711"
LOG = "0xc482943C7fEE1dD7807Edad1c88260E4263fD0Ad"
TRADE = "0x52a0E0d3BD4729BCD622fed437EDb428835658Ac"

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


def rpc(method, params, tries=8):
    """One JSON-RPC call, patient with the public node.

    The node rate-limits, and this script is the first thing a reader runs. Falling over with a 429
    halfway through a verification run would make the repo look broken when it is the node that is busy,
    so this backs off and keeps going.
    """
    req = urllib.request.Request(
        RPC,
        data=json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
        ).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "bell-verify/0.1"},
    )
    for attempt in range(tries):
        try:
            out = json.loads(urllib.request.urlopen(req, timeout=60).read())
            break
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == tries - 1:
                raise
            time.sleep(min(15.0, 1.5 * (attempt + 1) ** 1.5))
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
                # Mark is (bool set, uint8 verdict, uint8 reason, uint32 tradingDate, uint64 markedAt,
                # uint64 updatedAt, int192 answer): seven fields, indices 0 to 6. An earlier version read
                # m[7] and only ever ran on days with no mark, so nothing caught it until a real mark
                # existed. That is the same class of bug this repo keeps finding elsewhere.
                age = m[4] - m[5]
                print(
                    f"    AAPL {label} mark: price {signed(m[6]) / 1e8:,.2f}, {age}s old when marked, "
                    f"verdict {VERDICT[m[1]]}"
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

    section("the numbers in the README against the files they came from")
    # Contracts are checked above by calling them. The measured claims are checked here, by reading the
    # data files and looking for the same figure in README.md. If a measurement is rerun and the prose is
    # not updated, this fails, which is the whole point: a README that drifts from its own data is exactly
    # the failure this project keeps finding in other people's work.
    # The prose lives in two files since the README was cut from 630 lines to 223: the short one a judge
    # reads and the long one a reader digs into. A number may sit in either, so both are searched.
    drift = [0]
    readme = ""
    for name in ("README.md", "docs/DETAILS.md"):
        path = ROOT / name
        if path.exists():
            readme += path.read_text(encoding="utf-8")

    def claim(label, value, fmt="{:,.0f}"):
        text = fmt.format(value)
        present = text in readme
        if not present:
            drift[0] += 1
        line(present, f"{label}: {text}" + ("" if present else "  NOT FOUND IN README"))
        return present

    try:
        flow = json.loads(
            (ROOT / "docs" / "equity_flow_4663.json").read_text(encoding="utf-8")
        )
        claim("weekly USDG volume in the equity pools", flow["totalUsdg"])
        claim("of it while the exchange was shut", flow["closedUsdg"])
        claim("swaps counted", flow["swaps"])
        line(True, f"pools counted: {flow['pools']}")
    except FileNotFoundError:
        line(False, "docs/equity_flow_4663.json missing")

    try:
        rounds = json.loads(
            (ROOT / "docs" / "feed_rounds_4663.json").read_text(encoding="utf-8")
        )
        hist = [r for f in rounds["feeds"] for r in f["history"]]
        newest = max(r["updatedAt"] for r in hist)
        window = [r for r in hist if r["updatedAt"] >= newest - 10 * 86400]
        outside = sum(1 for r in window if r["session"] != "REGULAR")
        claim("rounds published in a common ten-day window", len(window))
        claim("of them outside the regular session", outside)
    except FileNotFoundError:
        line(False, "docs/feed_rounds_4663.json missing")

    try:
        gap = json.loads(
            (ROOT / "docs" / "price_gap_4663.json").read_text(encoding="utf-8")
        )
        for state in ("REGULAR", "CLOSED", "WEEKEND"):
            if state in gap["totals"]:
                claim(
                    f"median pool-to-feed gap, {state.lower()}",
                    gap["totals"][state]["gapP50Pct"],
                    "{:.3f}",
                )
                # counts and volumes too, not only medians: on 2026-09-21 the file was regenerated and the
                # README table kept the previous run's counts while its medians happened to match
                claim(f"swaps in the price-gap sample, {state.lower()}", gap["totals"][state]["swaps"])
                claim(f"USDG volume in the price-gap sample, {state.lower()}", gap["totals"][state]["volumeUsdg"])
        claim("swaps in the price-gap sample", sum(v["swaps"] for v in gap["totals"].values()))
        g = gap["totals"]
        for state in ("REGULAR", "CLOSED", "WEEKEND"):
            claim(f"pre-trade median gap, {state.lower()}", g[state]["gapPreSwapP50Pct"], "{:.3f} %")
        claim("fresh-feed median gap, regular", g["REGULAR"]["freshGapP50Pct"], "{:.3f} %")
        claim("fresh-feed median gap, closed", g["CLOSED"]["freshGapP50Pct"], "{:.3f} %")
        claim("fresh-feed swaps, regular", g["REGULAR"]["freshFeedSwaps"])
        claim("fresh-feed swaps, closed", g["CLOSED"]["freshFeedSwaps"])
        claim("buy-side signed median, regular", g["REGULAR"]["signedP50WhenBuyingSharePct"], "{:.3f} %")
        claim("sell-side signed median, regular", g["REGULAR"]["signedP50WhenSellingSharePct"], "{:.3f} %")
    except FileNotFoundError:
        line(False, "docs/price_gap_4663.json missing")

    try:
        morpho = json.loads(
            (ROOT / "docs" / "morpho_exposure.json").read_text(encoding="utf-8")
        )
        claim(
            "equity collateral on Morpho, read onchain", morpho["onchain"]["totalUsd"]
        )
        line(
            True,
            f"against {morpho['api']['equityCollateralUsd']:,.0f} from Morpho's own API",
        )
    except FileNotFoundError:
        line(False, "docs/morpho_exposure.json missing")

    failures += drift[0]

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

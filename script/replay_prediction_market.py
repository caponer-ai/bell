#!/usr/bin/env python3
"""Replay the settlements of the live parimutuel stock market on Robinhood Chain.

Audit target: the only live stock prediction market on chain 4663, deployed by pplmaverick
(https://github.com/pplmaverick/robinhood-stock-prediction-market, MIT), contracts

    v2  0x72DAb8B1B53b3CF028e9A0d1E21178981f264245
    v1  0x59DF30E22bdaC70764a5DbF8bBa51BC5a595759C

Both settle the same way (StockPredictionMarketV2.sol, read 2026-09-21):

    lockMarket()   -> (, price,,,) = priceFeed.latestRoundData(); openPrice  = price
    settleMarket() -> (, price,,,) = priceFeed.latestRoundData(); closePrice = price
    winner = closePrice >= openPrice ? BULL : BEAR        <- a tie pays BULL

The question this script answers is not "was the price equal" but "could the price have
moved at all": we resolve which *round* of the underlying Chainlink feed was current at the
lock call and at the settle call. Identical round ids mean both snapshots read one number,
so the tie rule decided the market rather than any market movement.

The feed address stored in each market is pplmaverick's ChainlinkPriceFeed adapter; the real
Chainlink proxy is its aggregator() (for TSLA that is 0x4A1166a659A55625345e9515b32adECea5547C38,
the proxyAddress of "Robinhood TSLA / USD" in Chainlink's reference data). Rounds are read from
that proxy with getRoundData, which the adapter itself does not implement.

Everything below is public data. No API key, no archive node.

    python script/replay_prediction_market.py            # full table + summary
"""

import datetime as dt
import json
import pathlib
import sys
import time
import urllib.request

RPC = "https://rpc.mainnet.chain.robinhood.com/"
HEADERS = {"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"}
MARKETS = {
    "v2": "0x72DAb8B1B53b3CF028e9A0d1E21178981f264245",
    "v1": "0x59DF30E22bdaC70764a5DbF8bBa51BC5a595759C",
}

_cache: dict[str, object] = {}


def rpc(method, params):
    key = json.dumps([method, params], sort_keys=True)
    if key in _cache:
        return _cache[key]
    req = urllib.request.Request(
        RPC,
        data=json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
        ).encode(),
        headers=HEADERS,
    )
    for attempt in range(5):
        try:
            payload = json.loads(urllib.request.urlopen(req, timeout=60).read())
            if "error" in payload:
                return {"__error__": payload["error"].get("message", "")}
            _cache[key] = payload["result"]
            time.sleep(0.1)
            return payload["result"]
        except Exception:
            time.sleep(2.0 * (attempt + 1))
    raise RuntimeError(f"RPC {method} did not answer")


def keccak(text: str) -> str:
    try:
        from Crypto.Hash import keccak as _k
    except ImportError:  # pragma: no cover
        sys.exit("pip install pycryptodome")
    k = _k.new(digest_bits=256)
    k.update(text.encode())
    return "0x" + k.hexdigest()


SEL_LATEST = keccak("latestRoundData()")[:10]
SEL_ROUND = keccak("getRoundData(uint80)")[:10]
SEL_AGG = keccak("aggregator()")[:10]
SEL_MARKET = keccak("markets(uint256)")[:10]
TOPIC_LOCKED = keccak("MarketLocked(uint256,int256)")
TOPIC_SETTLED = keccak("MarketSettled(uint256,int256,uint8)")
# The deployed bytecode is an earlier revision than the repo's current file: it emits BetPlaced
# without the isAgentBet flag. Both shapes are accepted; MarketCreated, MarketLocked and
# MarketSettled match the published source exactly, which is where the quoted settle logic lives.
TOPIC_BET = keccak("BetPlaced(uint256,address,uint8,uint256)")
TOPIC_BET_AGENT = keccak("BetPlaced(uint256,address,uint8,uint256,bool)")


def words(hexstr):
    body = hexstr[2:]
    return [int(body[i * 64 : (i + 1) * 64], 16) for i in range(len(body) // 64)]


def signed(x):
    return x - (1 << 256) if x >= (1 << 255) else x


def call(to, data):
    out = rpc("eth_call", [{"to": to, "data": data}, "latest"])
    return None if isinstance(out, dict) else out


def round_of(res):
    w = words(res)
    return {
        "id": w[0],
        "seq": w[0] & ((1 << 64) - 1),
        "answer": signed(w[1]),
        "updatedAt": w[3],
    }


_rounds: dict[str, dict] = {}


def round_at(proxy, ts):
    """The feed round that was current at `ts` (largest updatedAt <= ts).

    Assumes the proxy has stayed on one aggregator phase, which is true for these feeds today
    (every roundId we read carries phase 1). If a feed is ever migrated to a new aggregator, the
    rounds of the older phase must be walked with that phase id instead.
    """
    if proxy not in _rounds:
        latest = round_of(call(proxy, SEL_LATEST))
        _rounds[proxy] = {
            "phase": latest["id"] >> 64,
            "last": latest["seq"],
            "seen": {latest["seq"]: latest},
        }
    state = _rounds[proxy]

    def fetch(seq):
        if seq not in state["seen"]:
            rid = (state["phase"] << 64) | seq
            res = call(proxy, SEL_ROUND + hex(rid)[2:].rjust(64, "0"))
            state["seen"][seq] = round_of(res) if res else None
        return state["seen"][seq]

    lo, hi, best = 1, state["last"], None
    while lo <= hi:
        mid = (lo + hi) // 2
        r = fetch(mid)
        if r is None or r["updatedAt"] == 0:
            hi = mid - 1
            continue
        if r["updatedAt"] <= ts:
            best = r
            lo = mid + 1
        else:
            hi = mid - 1
    return best


# --- NYSE session, computed by rule (same rules as src/SessionCalendar.sol) -------------
def _nth(y, m, weekday, n):
    d = dt.date(y, m, 1)
    d += dt.timedelta(days=(weekday - d.weekday()) % 7)
    return d + dt.timedelta(days=7 * (n - 1))


def _last(y, m, weekday):
    d = dt.date(y, m + 1, 1) - dt.timedelta(days=1)
    while d.weekday() != weekday:
        d -= dt.timedelta(days=1)
    return d


def _easter(y):
    a, b, c = y % 19, y // 100, y % 100
    d, e = b // 4, b % 4
    f = (b + 8) // 25
    g = (b - f + 1) // 3
    h = (19 * a + b - d - g + 15) % 30
    i, k = c // 4, c % 4
    x = (32 + 2 * e + 2 * i - h - k) % 7
    m = (a + 11 * h + 22 * x) // 451
    return dt.date(y, (h + x - 7 * m + 114) // 31, ((h + x - 7 * m + 114) % 31) + 1)


def holidays(y):
    raw = {
        dt.date(y, 1, 1),
        _nth(y, 1, 0, 3),
        _nth(y, 2, 0, 3),
        _easter(y) - dt.timedelta(days=2),
        _last(y, 5, 0),
        dt.date(y, 6, 19),
        dt.date(y, 7, 4),
        _nth(y, 9, 0, 1),
        _nth(y, 11, 3, 4),
        dt.date(y, 12, 25),
    }
    out = set()
    for d in raw:
        out.add(
            d - dt.timedelta(days=1)
            if d.weekday() == 5
            else d + dt.timedelta(days=1)
            if d.weekday() == 6
            else d
        )
    return out


def session_at(ts):
    t = dt.datetime.fromtimestamp(ts, dt.timezone.utc)
    d = t.date()
    if d.weekday() >= 5:
        return "WEEKEND"
    if d in holidays(d.year):
        return "HOLIDAY"
    dst = _nth(d.year, 3, 6, 2) <= d < _nth(d.year, 11, 6, 1)
    opens = 13 * 3600 + 1800 if dst else 14 * 3600 + 1800
    closes = 20 * 3600 if dst else 21 * 3600
    sec = t.hour * 3600 + t.minute * 60 + t.second
    return "PRE" if sec < opens else "POST" if sec >= closes else "REGULAR"


def block_time(bn):
    return int(rpc("eth_getBlockByNumber", [hex(bn), False])["timestamp"], 16)


def read_market(contract, market_id):
    res = call(contract, SEL_MARKET + hex(market_id)[2:].rjust(64, "0"))
    w = words(res)
    off = w[2] // 32
    ln = w[off]
    symbol = bytes.fromhex(res[2:][(off + 1) * 64 : (off + 1) * 64 + ln * 2]).decode(
        errors="replace"
    )
    return {
        "feed": "0x" + hex(w[1])[2:].rjust(40, "0"),
        "symbol": symbol,
        "bull": w[8],
        "bear": w[9],
    }


def main():
    rows = []
    for tag, contract in MARKETS.items():
        logs = rpc(
            "eth_getLogs",
            [{"address": contract, "fromBlock": "0x0", "toBlock": "latest"}],
        )
        events: dict[int, dict] = {}
        for lg in logs:
            topic = lg["topics"][0]
            if topic not in (TOPIC_LOCKED, TOPIC_SETTLED, TOPIC_BET, TOPIC_BET_AGENT):
                continue
            mid = int(lg["topics"][1], 16)
            e = events.setdefault(mid, {})
            bn = int(lg["blockNumber"], 16)
            if topic in (TOPIC_BET, TOPIC_BET_AGENT):
                e["bets_total"] = e.get("bets_total", 0) + words(lg["data"])[1]
            elif topic == TOPIC_LOCKED:
                e["lock_price"], e["lock_block"] = signed(words(lg["data"])[0]), bn
            else:
                w = words(lg["data"])
                e["settle_price"], e["winner"], e["settle_block"] = (
                    signed(w[0]),
                    ("BULL" if w[1] == 0 else "BEAR"),
                    bn,
                )
        for mid, e in sorted(events.items()):
            if "lock_price" not in e or "settle_price" not in e:
                continue
            info = read_market(contract, mid)
            # The struct is decoded positionally, so check it against an independent source: the pools
            # in markets(id) must equal the sum of that market's BetPlaced events. A layout drift in
            # their contract would otherwise flip pools or winners silently.
            if info["bull"] + info["bear"] != e.get("bets_total", 0):
                raise SystemExit(
                    f"layout check failed for {tag} market {mid}: struct pools "
                    f"{info['bull'] + info['bear']} != sum of BetPlaced {e.get('bets_total', 0)}"
                )
            proxy = "0x" + call(info["feed"], SEL_AGG)[-40:]
            lock_ts, settle_ts = (
                block_time(e["lock_block"]),
                block_time(e["settle_block"]),
            )
            r_lock, r_settle = round_at(proxy, lock_ts), round_at(proxy, settle_ts)
            same = bool(r_lock and r_settle and r_lock["id"] == r_settle["id"])
            equal = e["lock_price"] == e["settle_price"]
            rows.append(
                {
                    "contract": tag,
                    "id": mid,
                    "symbol": info["symbol"],
                    "proxy": proxy,
                    "lock_ts": lock_ts,
                    "settle_ts": settle_ts,
                    "gap_s": settle_ts - lock_ts,
                    "lock_session": session_at(lock_ts),
                    "settle_session": session_at(settle_ts),
                    "price_age_h": round((lock_ts - r_lock["updatedAt"]) / 3600, 2)
                    if r_lock
                    else None,
                    "round_lock": r_lock["seq"] if r_lock else None,
                    "round_settle": r_settle["seq"] if r_settle else None,
                    "same_round": same,
                    "equal_price": equal,
                    "winner": e["winner"],
                    "pool_wei": info["bull"] + info["bear"],
                }
            )

    def stamp(ts):
        return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime(
            "%Y-%m-%d %H:%M:%S"
        )

    print(
        f"{'#':>3} {'sym':5} {'locked (UTC)':20} {'gap':>7} {'session':8} {'round@lock':>10} {'round@settle':>12} {'price age':>10} {'decided by':12} {'pool ETH':>9}"
    )
    for r in sorted(rows, key=lambda x: x["lock_ts"]):
        decided = (
            "tie rule"
            if (r["same_round"] and r["equal_price"])
            else ("flat price" if r["equal_price"] else "price move")
        )
        print(
            f"{r['id']:>3} {r['symbol'][:5]:5} {stamp(r['lock_ts']):20} {r['gap_s']:>6}s {r['lock_session'][:8]:8} "
            f"{str(r['round_lock']):>10} {str(r['round_settle']):>12} {str(r['price_age_h']) + 'h':>10} {decided:12} {r['pool_wei'] / 1e18:>9.5f}"
        )
    n = len(rows)
    same = [r for r in rows if r["same_round"] and r["equal_price"]]
    closed = [
        r
        for r in rows
        if r["lock_session"] != "REGULAR" or r["settle_session"] != "REGULAR"
    ]
    ages = sorted(r["price_age_h"] for r in rows if r["price_age_h"] is not None)
    n_ages = len(ages)
    median = (ages[n_ages // 2 - 1] + ages[n_ages // 2]) / 2 if n_ages % 2 == 0 else ages[n_ages // 2]
    print(f"\nsettlements: {n}")
    print(f"  decided by the tie rule (one feed round on both sides): {len(same)}")
    print(f"  at least one leg outside the regular NYSE session:      {len(closed)}")
    print(
        f"  price age at lock: median {median:.2f}h, max {ages[-1]}h, min {ages[0]}h"
    )
    print(
        f"  total staked across every market: {sum(r['pool_wei'] for r in rows) / 1e18:.5f} ETH"
    )
    json.dump(rows, open("replay_settlements.json", "w"), indent=1)
    print("\nwrote replay_settlements.json")


if __name__ == "__main__":
    main()

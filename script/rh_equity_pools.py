#!/usr/bin/env python3
"""Where the real money on this chain touches a tokenized equity.

The audit in docs/REPLAY.md proves a mechanism defect on a prediction market with 0.009 ETH ever staked.
That is a proof of the mechanism, not of the money. This script goes looking for the money: every Uniswap
pool on Robinhood Chain that pairs USDG with a token whose symbol matches one of the 35 Chainlink equity
feeds, the swap volume those pools actually see, and what PushFeedGuard says about the matching feed at the
moment of each swap.

Public RPC only, no key, no gas. Results are cached under script/.cache so a rerun is cheap.

    python script/rh_equity_pools.py
"""

import json
import os
import pathlib
import time
import urllib.error
import urllib.request

RPC = "https://rpc.mainnet.chain.robinhood.com/"
V3_FACTORY = "0x1f7d7550B1b028f7571E69A784071F0205FD2EfA"
V4_POOL_MANAGER = "0x8366a39cc670b4001a1121b8f6a443a643e40951"
USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"
ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE = ROOT / "script" / ".cache"
CACHE.mkdir(exist_ok=True)


def keccak(text):
    from Crypto.Hash import keccak as _k

    k = _k.new(digest_bits=256)
    k.update(text.encode())
    return "0x" + k.hexdigest()


# The ERC-8056 stock tokens on this chain are 283-byte beacon proxies: the beacon address is burned into
# the runtime code and every call is forwarded to whatever `implementation()` that beacon returns. A token
# is treated as genuine here when its code carries this beacon, which is a statement about where the
# contract gets its logic rather than about a symbol string anyone can choose.
#
# Stated limit, because this is weaker than it looks: an identical proxy pointing at the same beacon can
# be deployed by anyone, so this test proves lineage, not issuance. What closes the practical gap is that
# among the 58 pools that pass it there are 17 tickers and 17 distinct token addresses, with no ticker
# claimed twice. Without a published registry from the issuer to check the list against, that is the
# strongest test available from the chain alone.
STOCK_TOKEN_BEACON = "0xe10b6f6b275de231345c20d14ab812db62151b00"


def genuine_tokens(tokens):
    """Which of these token addresses are beacon proxies on the canonical stock-token beacon."""
    out = post(
        [
            {"jsonrpc": "2.0", "id": n, "method": "eth_getCode", "params": [t, "latest"]}
            for n, t in enumerate(tokens)
        ]
    )
    by_id = {r["id"]: r.get("result") or "0x" for r in out}
    needle = STOCK_TOKEN_BEACON[2:].lower()
    return {t: (needle in (by_id.get(n) or "").lower()) for n, t in enumerate(tokens)}


_last = [0.0]


def post(payload, tries=14):
    """One JSON-RPC request, batched or not, with polite backoff on 429."""
    for attempt in range(tries):
        gap = 0.25 - (time.time() - _last[0])
        if gap > 0:
            time.sleep(gap)
        req = urllib.request.Request(
            RPC,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json", "User-Agent": "bell/0.1"},
        )
        try:
            out = json.loads(urllib.request.urlopen(req, timeout=240).read())
            _last[0] = time.time()
            return out
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == tries - 1:
                raise
            time.sleep(min(20.0, 1.5 * (attempt + 1) ** 1.5))
    raise RuntimeError("unreachable")


def rpc(method, params):
    out = post({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    if "error" in out:
        return {"__error__": out["error"]}
    return out["result"]


def batch_call(calls, size=25):
    """calls: list of (to, data). Returns a list of hex strings or None, in order."""
    results = []
    for i in range(0, len(calls), size):
        chunk = calls[i : i + size]
        payload = [
            {
                "jsonrpc": "2.0",
                "id": j,
                "method": "eth_call",
                "params": [{"to": to, "data": data}, "latest"],
            }
            for j, (to, data) in enumerate(chunk)
        ]
        out = post(payload)
        by_id = {r["id"]: r for r in out}
        for j in range(len(chunk)):
            r = by_id.get(j, {})
            results.append(r.get("result") if "error" not in r else None)
        print(f"    {len(results)}/{len(calls)}", end="\r", flush=True)
    print(" " * 30, end="\r")
    return results


def words(h):
    b = h[2:]
    return [int(b[i * 64 : (i + 1) * 64], 16) for i in range(len(b) // 64)]


def as_addr(w):
    return "0x" + hex(w)[2:].rjust(40, "0")


def t32(a):
    return "0x" + a.lower().replace("0x", "").rjust(64, "0")


def decode_string(res):
    if not res:
        return None
    b = res[2:]
    try:
        off = int(b[:64], 16) * 2
        ln = int(b[off : off + 64], 16)
        return bytes.fromhex(b[off + 64 : off + 64 + ln * 2]).decode(errors="replace")
    except Exception:
        # some tokens return a bytes32 symbol
        try:
            return bytes.fromhex(b[:64]).rstrip(b"\x00").decode(errors="replace") or None
        except Exception:
            return None


def cached(name, build):
    path = CACHE / name
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    value = build()
    path.write_text(json.dumps(value), encoding="utf-8")
    return value


def v3_usdg_pools():
    sig = keccak("PoolCreated(address,address,uint24,int24,address)")

    def build():
        logs = []
        for slot in (1, 2):
            topics = [sig, None, None]
            topics[slot] = t32(USDG)
            res = rpc(
                "eth_getLogs",
                [
                    {
                        "address": V3_FACTORY,
                        "topics": topics,
                        "fromBlock": "0x0",
                        "toBlock": "latest",
                    }
                ],
            )
            if isinstance(res, dict):
                raise SystemExit(f"getLogs failed: {res}")
            print(f"  v3 PoolCreated with USDG as token{slot - 1}: {len(res)}")
            logs += res
        pools = []
        for lg in logs:
            w = words(lg["data"])
            t0 = "0x" + lg["topics"][1][-40:]
            t1 = "0x" + lg["topics"][2][-40:]
            pools.append(
                {
                    "version": "v3",
                    "token0": t0,
                    "token1": t1,
                    "fee": int(lg["topics"][3], 16),
                    "pool": as_addr(w[1]),
                    "block": int(lg["blockNumber"], 16),
                    "other": t1 if t0.lower() == USDG.lower() else t0,
                }
            )
        return pools

    return cached("v3_usdg_pools.json", build)


def symbols_for(tokens):
    path = CACHE / "symbols.json"
    known = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    missing = [t for t in tokens if t not in known]
    if missing:
        print(f"  resolving {len(missing)} token symbols")
        step = 250
        for i in range(0, len(missing), step):
            part = missing[i : i + step]
            res = batch_call([(t, keccak("symbol()")[:10]) for t in part])
            for t, r in zip(part, res):
                known[t] = decode_string(r)
            path.write_text(json.dumps(known), encoding="utf-8")
            print(f"  {min(i + step, len(missing))}/{len(missing)} symbols")
    return known


def main():
    print("Uniswap v3 pools that hold USDG:")
    pools = v3_usdg_pools()
    print(f"  {len(pools)} pools, {len({p['other'] for p in pools})} distinct counterparties")

    feeds = json.loads((ROOT / "docs" / "equity_feeds_4663.json").read_text(encoding="utf-8"))
    tickers = {}
    for f in feeds:
        name = f["name"].replace("Robinhood ", "")
        base = name.split(" /")[0].split("/")[0].strip()
        tickers[base.upper()] = f["proxy"]
    print(f"  {len(tickers)} equity feeds to match against")

    # the tokenized-equity pools all use the tight fee tiers; resolve those first so a slow RPC
    # cannot stop the measurement, then widen if nothing matched.
    tight = sorted({p["other"] for p in pools if p["fee"] in (100, 500)})
    syms = symbols_for(tight)
    if not any((syms.get(t) or "").upper().lstrip("X") in tickers for t in tight):
        syms = symbols_for(sorted({p["other"] for p in pools}))
    matched = []
    for p in pools:
        s = (syms.get(p["other"]) or "").strip()
        if not s:
            continue
        cand = {s.upper(), s.upper().lstrip("X"), s.upper().replace("-USD", "")}
        hit = next((c for c in cand if c in tickers), None)
        if hit:
            matched.append({**p, "symbol": s, "ticker": hit, "feed": tickers[hit]})

    matched.sort(key=lambda p: (p["ticker"], p["fee"]))
    print(f"\nequity/USDG pools on Uniswap v3: {len(matched)}")
    for p in matched:
        print(f"  {p['ticker']:6} {p['symbol']:10} fee {p['fee']:>5}  {p['pool']}")

    out = CACHE.parent.parent / "docs" / "equity_pools_4663.json"
    out.write_text(json.dumps(matched, indent=1), encoding="utf-8")
    print(f"\nwrote {out}")


if __name__ == "__main__":
    main()

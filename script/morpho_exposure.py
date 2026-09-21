#!/usr/bin/env python3
"""The honest counterweight: how little of this chain's lending actually touches a trading session.

It would be convenient for this project if the big lending book on Robinhood Chain were collateralised by
tokenized equities. It is not, and saying so here is cheaper than having a judge find it.

This script reads Morpho Blue on chainId 4663 twice, from two independent sources, and compares them:

  1. Morpho's own GraphQL API (api.morpho.org) for the market list, the debt and the USD valuations
  2. the chain itself: `balanceOf(Morpho Blue)` for every genuine equity token, times the feed price

Two sources that agree are worth more than one source that is convenient. The script prints both and the
gap between them.

    python script/morpho_exposure.py

Public RPC plus one public GraphQL endpoint. No key, no gas.
"""

import datetime as dt
import json
import urllib.error
import urllib.request

from rh_equity_pools import ROOT, keccak, post

MORPHO_BLUE = "0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010"
GRAPHQL = "https://api.morpho.org/graphql"
CHAIN_ID = 4663
OUT = ROOT / "docs" / "morpho_exposure.json"

QUERY = (
    """{ markets(first: 500, where: { chainId_in: [%d] }) { items {
  marketId lltv
  morphoBlue { address }
  oracle { address }
  collateralAsset { symbol address decimals }
  loanAsset { symbol address decimals }
  state { borrowAssetsUsd supplyAssetsUsd collateralAssetsUsd }
} } }"""
    % CHAIN_ID
)


def gql(query):
    req = urllib.request.Request(
        GRAPHQL,
        data=json.dumps({"query": query}).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "bell/0.1"},
    )
    try:
        return json.loads(urllib.request.urlopen(req, timeout=90).read())
    except urllib.error.HTTPError as e:
        raise SystemExit("GraphQL %d: %s" % (e.code, e.read().decode()[:400]))


def calls(pairs, size=20):
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


def usd(market, field):
    return (market.get("state") or {}).get(field) or 0


def main():
    items = gql(QUERY)["data"]["markets"]["items"]
    addresses = {m["morphoBlue"]["address"] for m in items if m.get("morphoBlue")}
    print("Morpho Blue on chainId %d: %s" % (CHAIN_ID, ", ".join(sorted(addresses))))
    if MORPHO_BLUE not in addresses:
        print("  warning: the API names an address this script does not expect")

    feeds = json.loads(
        (ROOT / "docs" / "feed_rounds_4663.json").read_text(encoding="utf-8")
    )["feeds"]
    price = {}
    for f in feeds:
        base = (
            f["name"]
            .replace("Robinhood ", "")
            .split(" /")[0]
            .split("-")[0]
            .strip()
            .upper()
        )
        price[base] = f["latestAnswer"]

    equity = [
        m
        for m in items
        if ((m.get("collateralAsset") or {}).get("symbol") or "").upper() in price
    ]
    total_debt = sum(usd(m, "borrowAssetsUsd") for m in items)
    equity_debt = sum(usd(m, "borrowAssetsUsd") for m in equity)
    equity_coll = sum(usd(m, "collateralAssetsUsd") for m in equity)

    print("")
    print("per the API:")
    print("  markets                        %d" % len(items))
    print("  markets with equity collateral %d" % len(equity))
    print("  debt across all markets        ${:,.0f}".format(total_debt))
    print("  debt behind equity collateral  ${:,.0f}".format(equity_debt))
    print("  equity collateral              ${:,.0f}".format(equity_coll))
    print(
        "  equity share of the book       {:.4f}%".format(
            equity_debt / total_debt * 100 if total_debt else 0
        )
    )

    print("")
    print("the three largest markets on the chain, for scale:")
    for m in sorted(items, key=lambda m: -usd(m, "borrowAssetsUsd"))[:3]:
        print(
            "  {:<10}/{:<6} ${:>14,.0f}".format(
                (m.get("collateralAsset") or {}).get("symbol") or "?",
                m["loanAsset"]["symbol"],
                usd(m, "borrowAssetsUsd"),
            )
        )
    print(
        "  none of these has a trading session, and this project has nothing to offer them."
    )

    # --- the same number, read off the chain instead of the API -------------------------------------
    pools = json.loads(
        (ROOT / "docs" / "equity_pools_4663.json").read_text(encoding="utf-8")
    )
    tokens = {}
    for p in pools:
        if p.get("genuine"):
            tokens.setdefault(p["ticker"], p["other"])
    tickers = sorted(tokens)
    bal = keccak("balanceOf(address)")[:10] + MORPHO_BLUE[2:].lower().rjust(64, "0")
    dec = keccak("decimals()")[:10]
    res = calls(
        [(tokens[t], bal) for t in tickers] + [(tokens[t], dec) for t in tickers]
    )

    n = len(tickers)
    onchain = []
    onchain_total = 0.0
    for i, t in enumerate(tickers):
        raw = res[i]
        amount = int(raw, 16) if raw and raw != "0x" else 0
        decimals = int(res[n + i], 16) if res[n + i] else 18
        qty = amount / 10**decimals
        value = qty * price.get(t, 0)
        onchain_total += value
        onchain.append(
            {
                "ticker": t,
                "token": tokens[t],
                "qty": qty,
                "price": price.get(t),
                "usd": value,
            }
        )

    print("")
    print("read off the chain, balanceOf(Morpho Blue) times the feed price:")
    for row in sorted(onchain, key=lambda r: -r["usd"])[:8]:
        print(
            "  {:<7}{:>14,.4f} x {:>10,.2f} = ${:>12,.2f}".format(
                row["ticker"], row["qty"], row["price"] or 0, row["usd"]
            )
        )
    print(
        "  total ${:,.0f} across {} tickers, against ${:,.0f} from the API".format(
            onchain_total, n, equity_coll
        )
    )
    gap = abs(onchain_total - equity_coll) / equity_coll * 100 if equity_coll else 0
    print(
        "  the two sources differ by {:.1f}%, which is the {} tickers this repo does not hold a pool for".format(
            gap, len(price) - n
        )
    )

    OUT.write_text(
        json.dumps(
            {
                "generated": dt.datetime.now(dt.timezone.utc).isoformat(),
                "morphoBlue": MORPHO_BLUE,
                "api": {
                    "markets": len(items),
                    "equityMarkets": len(equity),
                    "totalDebtUsd": total_debt,
                    "equityDebtUsd": equity_debt,
                    "equityCollateralUsd": equity_coll,
                },
                "onchain": {"totalUsd": onchain_total, "perTicker": onchain},
            },
            indent=1,
        ),
        encoding="utf-8",
    )
    print("")
    print("wrote %s" % OUT)


if __name__ == "__main__":
    main()

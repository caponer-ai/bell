#!/usr/bin/env python3
"""Every loan taken against a tokenized stock on Morpho Blue (chainId 4663), with the session it was
taken in and the age of the price the market's oracle was reading at that moment.

The Chainlink equity feeds on this chain answer with a real number at any hour and do not say which
market produced it. Morpho's standard oracle adds nothing on top: it reads `latestRoundData()` and
accepts it. So a loan taken on a Sunday is priced by whatever the feed last printed, and nothing in
the market records that. This script records it, for every Borrow ever emitted by an equity market.

What it does not claim: that anyone lost money. Every loan here can be perfectly safe, because the
borrower chose a low loan-to-value. The output is a label on each loan (which session, how old the
price) and the totals, so a curator can see how much of the book was opened on a price the exchange
never saw that day. Liquidations and bad debt are counted so that the answer "none" is on the record.

    python script/morpho_session_replay.py

Public RPC plus Morpho's public GraphQL API for the list of markets. No key, no gas.
Writes docs/morpho_session_replay.json.
"""

import datetime as dt
import json
import statistics
import sys

from equity_flow import HOLIDAYS, _is_dst, session_for
from morpho_exposure import gql
from replay_prediction_market import call, round_at
from rh_equity_pools import ROOT, keccak, post, rpc

MORPHO_BLUE = "0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010"
OUT = ROOT / "docs" / "morpho_session_replay.json"
CHUNK = 1_000_000
HEARTBEAT = 86_400  # every equity feed on this chain declares a 24 h heartbeat (docs/equity_feeds_4663.json)

T_BORROW = keccak("Borrow(bytes32,address,address,address,uint256,uint256)")
T_REPAY = keccak("Repay(bytes32,address,address,uint256,uint256)")
T_LIQUIDATE = keccak(
    "Liquidate(bytes32,address,address,uint256,uint256,uint256,uint256,uint256)"
)
SEL_BASE_FEED_1 = keccak("BASE_FEED_1()")[:10]

QUERY = """{ markets(first: 500, where: { chainId_in: [4663] }) { items {
  marketId lltv
  oracle { address }
  collateralAsset { symbol address }
  loanAsset { symbol address decimals }
  state { borrowAssetsUsd collateralAssetsUsd }
} } }"""


def words(data):
    h = data[2:]
    return [int(h[i : i + 64], 16) for i in range(0, len(h), 64)]


def when(ts):
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def label(ts):
    """REGULAR, or why the exchange was shut: weekend, holiday, or night on a trading day."""
    state, _ = session_for(ts)
    if state == "REGULAR":
        return "REGULAR"
    utc = dt.datetime.fromtimestamp(ts, dt.timezone.utc)
    # DST is decided on the New York date, as session_for does; the switch happens at 02:00 local on a Sunday,
    # when no session exists, so taking the date at UTC-5 is exact for the purpose of this label.
    et = utc - dt.timedelta(
        hours=4 if _is_dst((utc - dt.timedelta(hours=5)).date()) else 5
    )
    minutes = et.hour * 60 + et.minute
    wd = et.weekday()
    if (
        wd >= 5
        or (wd == 4 and minutes >= 16 * 60)
        or (wd == 0 and minutes < 9 * 60 + 30)
    ):
        return "WEEKEND"
    if (et.year, et.month, et.day) in HOLIDAYS:
        return "HOLIDAY"
    return "NIGHT"


def logs(ids, head):
    """Borrow, Repay and Liquidate for the given markets, from genesis to head.

    The public node allows a 1,000,000 block range only when every topic position holds a single value
    (a list of market ids drops the limit to 100,000), so each event type is fetched on its own and the
    markets are filtered here.
    """
    wanted = set(ids)
    out = []
    for topic0 in (T_BORROW, T_REPAY, T_LIQUIDATE):
        frm, size = 0, CHUNK
        while frm <= head:
            to = min(frm + size - 1, head)
            got = rpc(
                "eth_getLogs",
                [
                    {
                        "address": MORPHO_BLUE,
                        "fromBlock": hex(frm),
                        "toBlock": hex(to),
                        "topics": [topic0],
                    }
                ],
            )
            if not isinstance(got, list):  # an error object: the window was too dense
                if size <= 10_000:
                    raise SystemExit(f"eth_getLogs {frm}..{to}: {got}")
                size //= 4
                continue
            out += [e for e in got if e["topics"][1].lower() in wanted]
            frm = to + 1
            size = min(size * 2, CHUNK)
            print(
                f"\r  {topic0[:10]} scanned to block {to:,} of {head:,}, {len(out)} events kept",
                end="",
                file=sys.stderr,
            )
        print("", file=sys.stderr)
    return out


def block_times(numbers):
    numbers = sorted(set(numbers))
    times = {}
    for i in range(0, len(numbers), 50):
        chunk = numbers[i : i + 50]
        res = post(
            [
                {
                    "jsonrpc": "2.0",
                    "id": n,
                    "method": "eth_getBlockByNumber",
                    "params": [hex(b), False],
                }
                for n, b in enumerate(chunk)
            ]
        )
        for r in res:
            times[chunk[r["id"]]] = int(r["result"]["timestamp"], 16)
    return times


def main():
    # --- which markets lend against a genuine stock token ---------------------------------------------
    pools = json.loads(
        (ROOT / "docs" / "equity_pools_4663.json").read_text(encoding="utf-8")
    )
    genuine = {}
    for p in pools:
        if p.get("genuine"):
            genuine[p["other"].lower()] = p["ticker"]
    inventory = {}
    for f in json.loads(
        (ROOT / "docs" / "equity_feeds_4663.json").read_text(encoding="utf-8")
    ):
        base = (
            f["name"]
            .replace("Robinhood ", "")
            .split(" /")[0]
            .split("-")[0]
            .strip()
            .upper()
        )
        base = (
            base[2:] if base.startswith("RH") and base[2:] in genuine.values() else base
        )
        inventory.setdefault(base, f["proxy"])

    items = gql(QUERY)["data"]["markets"]["items"]
    markets = {}
    impostor_symbols = 0
    for m in items:
        coll = m.get("collateralAsset") or {}
        addr = (coll.get("address") or "").lower()
        if addr in genuine:
            markets[m["marketId"].lower()] = {
                "ticker": genuine[addr],
                "oracle": m["oracle"]["address"],
                "lltv": int(m["lltv"]) / 1e18,
                "decimals": int(m["loanAsset"]["decimals"]),
                "loan": m["loanAsset"]["symbol"],
                "borrowUsdNow": (m.get("state") or {}).get("borrowAssetsUsd") or 0,
                "collateralUsdNow": (m.get("state") or {}).get("collateralAssetsUsd")
                or 0,
            }
        elif (coll.get("symbol") or "").upper() in genuine.values():
            impostor_symbols += 1
    print(
        f"{len(items)} markets on chainId 4663, {len(markets)} lend against a genuine stock token"
    )
    print(
        f"  {impostor_symbols} more carry a stock ticker as the collateral symbol on a token that is not the real one, and are left out"
    )

    # --- the feed each market's oracle reads ---------------------------------------------------------
    print("reading the feed behind each market's oracle", file=sys.stderr)
    for mid, m in markets.items():
        res = call(m["oracle"], SEL_BASE_FEED_1)
        feed = "0x" + res[-40:] if res and len(res) >= 66 and int(res, 16) else None
        m["feed"] = feed or inventory.get(m["ticker"])
        m["feedSource"] = (
            "oracle BASE_FEED_1()"
            if feed
            else "inventory (oracle exposes no BASE_FEED_1)"
        )

    # --- every event, genesis to head ----------------------------------------------------------------
    head = int(rpc("eth_blockNumber", []), 16)
    events = logs(sorted(markets), head)
    times = block_times(int(e["blockNumber"], 16) for e in events)

    borrows, repays, liquidations = [], [], []
    for e in events:
        t0, mid = e["topics"][0], e["topics"][1].lower()
        m = markets[mid]
        bn = int(e["blockNumber"], 16)
        ts = times[bn]
        w = words(e["data"])
        scale = 10 ** m["decimals"]
        if t0 == T_BORROW:
            borrows.append(
                {
                    "market": mid,
                    "ticker": m["ticker"],
                    "tx": e["transactionHash"],
                    "block": bn,
                    "ts": ts,
                    "time": when(ts),
                    "onBehalf": "0x" + e["topics"][2][-40:],
                    "amount": w[1] / scale,
                }
            )
        elif t0 == T_REPAY:
            repays.append({"market": mid, "ts": ts, "amount": w[0] / scale})
        elif t0 == T_LIQUIDATE:
            liquidations.append(
                {
                    "market": mid,
                    "ticker": m["ticker"],
                    "tx": e["transactionHash"],
                    "time": when(ts),
                    "repaid": w[0] / scale,
                    "badDebt": w[3] / scale,
                }
            )

    print(
        f"{len(borrows)} borrows, {len(repays)} repays, {len(liquidations)} liquidations",
        file=sys.stderr,
    )
    # --- label every loan: session, and the age of the price the oracle saw ---------------------------
    for i, b in enumerate(
        sorted(borrows, key=lambda x: (markets[x["market"]]["feed"] or "", x["ts"]))
    ):
        if i % 25 == 0:
            print(f"  labelling loan {i} of {len(borrows)}", file=sys.stderr)
        m = markets[b["market"]]
        r = round_at(m["feed"], b["ts"]) if m["feed"] else None
        b["session"] = label(b["ts"])
        b["priceUpdatedAt"] = r["updatedAt"] if r else None
        b["priceAgeHours"] = round((b["ts"] - r["updatedAt"]) / 3600, 2) if r else None
        b["priceSession"] = label(r["updatedAt"]) if r else None

    # --- totals ---------------------------------------------------------------------------------------
    gross = sum(b["amount"] for b in borrows)
    by_session = {}
    for b in borrows:
        s = by_session.setdefault(b["session"], {"loans": 0, "amount": 0.0})
        s["loans"] += 1
        s["amount"] += b["amount"]
    aged = [b for b in borrows if b["priceAgeHours"] is not None]
    stale = [b for b in aged if b["priceAgeHours"] * 3600 > HEARTBEAT]
    closed = [b for b in borrows if b["session"] != "REGULAR"]
    by_borrower = {}
    for b in borrows:
        by_borrower[b["onBehalf"]] = by_borrower.get(b["onBehalf"], 0) + b["amount"]
    top = sorted(by_borrower.items(), key=lambda kv: -kv[1])[:3]
    biggest = sorted(borrows, key=lambda b: -b["amount"])[:10]

    summary = {
        "head": head,
        "headTime": when(block_times([head])[head]),
        "marketsGenuine": len(markets),
        "marketsWithBorrow": len({b["market"] for b in borrows}),
        "loans": len(borrows),
        "grossBorrowed": gross,
        "borrowedWhileClosed": sum(b["amount"] for b in closed),
        "shareClosed": sum(b["amount"] for b in closed) / gross if gross else 0,
        "bySession": by_session,
        "medianPriceAgeHours": statistics.median(b["priceAgeHours"] for b in aged)
        if aged
        else None,
        "maxPriceAgeHours": max((b["priceAgeHours"] for b in aged), default=None),
        "borrowedOnPriceOlderThanHeartbeat": sum(b["amount"] for b in stale),
        "loansOnPriceOlderThanHeartbeat": len(stale),
        "repays": len(repays),
        "repaid": sum(r["amount"] for r in repays),
        "liquidations": len(liquidations),
        "badDebt": sum(x["badDebt"] for x in liquidations),
        "outstandingUsdNowApi": sum(m["borrowUsdNow"] for m in markets.values()),
        "collateralUsdNowApi": sum(m["collateralUsdNow"] for m in markets.values()),
        "topBorrowers": [
            {"address": a, "amount": v, "share": v / gross if gross else 0}
            for a, v in top
        ],
    }

    OUT.write_text(
        json.dumps(
            {
                "generated": dt.datetime.now(dt.timezone.utc).isoformat(),
                "morphoBlue": MORPHO_BLUE,
                "method": "Borrow/Repay/Liquidate logs from genesis for every market whose collateral is a genuine "
                "stock token (bytecode-checked list in docs/equity_pools_4663.json); session by the NYSE rules of "
                "src/SessionCalendar.sol; price age = block time minus updatedAt of the feed round current at that time",
                "summary": summary,
                "markets": markets,
                "biggest": biggest,
                "liquidations": liquidations,
                "loans": borrows,
            },
            indent=1,
        ),
        encoding="utf-8",
    )

    # --- the human version ----------------------------------------------------------------------------
    print("")
    print(f"at block {head:,} ({summary['headTime']}):")
    print(
        f"  {len(borrows)} loans in {summary['marketsWithBorrow']} markets, {gross:,.0f} USDG borrowed in total"
    )
    for s in ("REGULAR", "NIGHT", "WEEKEND", "HOLIDAY"):
        if s in by_session:
            v = by_session[s]
            print(
                f"    {s:<8} {v['loans']:>4} loans  {v['amount']:>14,.0f} USDG  {v['amount'] / gross * 100:5.1f} %"
            )
    print(
        f"  borrowed while the exchange was shut: {summary['borrowedWhileClosed']:,.0f} USDG ({summary['shareClosed'] * 100:.1f} %)"
    )
    print(
        f"  price age at the moment of the loan: median {summary['medianPriceAgeHours']} h, max {summary['maxPriceAgeHours']} h"
    )
    print(
        f"  on a price older than the feed's own 24 h heartbeat: {len(stale)} loans, {summary['borrowedOnPriceOlderThanHeartbeat']:,.0f} USDG"
    )
    print(
        f"  repaid {summary['repaid']:,.0f} USDG in {len(repays)} repays; liquidations {len(liquidations)}, bad debt {summary['badDebt']:,.2f}"
    )
    print(
        f"  outstanding now per Morpho's API: ${summary['outstandingUsdNowApi']:,.0f} against ${summary['collateralUsdNowApi']:,.0f} of collateral"
    )
    for t in summary["topBorrowers"]:
        print(
            f"  borrower {t['address']}: {t['amount']:,.0f} USDG, {t['share'] * 100:.1f} % of all borrowing"
        )
    print("  the ten largest loans:")
    for b in biggest:
        print(
            f"    {b['time']}  {b['ticker']:<6} {b['amount']:>12,.0f} {markets[b['market']]['loan']:<5} "
            f"{b['session']:<8} price {b['priceAgeHours']} h old  {b['tx'][:12]}"
        )
    print(f"\nwritten to {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()

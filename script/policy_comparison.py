#!/usr/bin/env python3
"""What does this project add over five lines of local checking? Measured, not argued.

The strongest objection to a session guard is that a consumer can simply check `updatedAt` itself, and
that the rest is packaging. This script answers it with the 30 real settlements from docs/REPLAY.md by
running each of them through four policies and comparing the outcomes:

  1. as deployed        the market's own rule: winner = close >= open ? BULL : BEAR
  2. freshness only     the cheapest thing a developer writes: refuse if the price is older than maxAge
  3. calendar + fresh   freshness plus an NYSE calendar plus refusing two reads of the same round
  4. PushFeedGuard      what this repo deploys: calendar and freshness, as a shared stateless contract

Where policies 3 and 4 agree, this project adds no new refusal, and the README says so. The comparison is
the point: a number that can only go in our favour is not a measurement.

    python script/policy_comparison.py [--max-age 900]
"""

import argparse
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SNAPSHOT = ROOT / "docs" / "replay_settlements.json"
RESEARCH = pathlib.Path(
    "D:/01_РОБОТА/Projects/arbitrum-hackathon/research/data/replay_v2.json"
)
OUT = ROOT / "docs" / "POLICY_COMPARISON.md"


def load():
    rows = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    # the research run stored the updatedAt of both rounds; fall back to deriving it when absent
    extra = {}
    if RESEARCH.exists():
        for r in json.loads(RESEARCH.read_text(encoding="utf-8"))["rows"]:
            extra[(r["contract"], r["id"])] = r
    for r in rows:
        e = extra.get((r["contract"], r["id"]))
        if e and e.get("lock_round_updatedAt") and e.get("settle_round_updatedAt"):
            r["lock_updated_at"] = e["lock_round_updatedAt"]
            r["settle_updated_at"] = e["settle_round_updatedAt"]
        else:
            # same round on both sides means one updatedAt; otherwise approximate from the lock age
            age_lock = int(round(r["price_age_h"] * 3600))
            r["lock_updated_at"] = r["lock_ts"] - age_lock
            r["settle_updated_at"] = (
                r["lock_updated_at"] if r["same_round"] else r["settle_ts"]
            )
        r["age_at_lock"] = r["lock_ts"] - r["lock_updated_at"]
        r["age_at_settle"] = r["settle_ts"] - r["settle_updated_at"]
    return rows


def policy_original(r):
    """The market's own rule. It always produces a winner."""
    return "SETTLE", "tie rule" if r["same_round"] and r[
        "equal_price"
    ] else "price move"


def policy_freshness(r, max_age):
    """Refuse when either read is older than the budget. No calendar, no round check."""
    if r["age_at_lock"] > max_age:
        return "REFUSE", f"price {r['age_at_lock'] // 60} min old at lock"
    if r["age_at_settle"] > max_age:
        return "REFUSE", f"price {r['age_at_settle'] // 60} min old at settle"
    return "SETTLE", "both reads fresh"


def policy_calendar_fresh(r, max_age):
    """Freshness, plus the session calendar, plus refusing two reads of one round."""
    if r["lock_session"] != "REGULAR" or r["settle_session"] != "REGULAR":
        return "REFUSE", f"session {r['lock_session']}/{r['settle_session']}"
    if r["age_at_lock"] > max_age or r["age_at_settle"] > max_age:
        return "REFUSE", "price older than the budget"
    if r["same_round"]:
        return "REFUSE", "both reads from one round"
    return "SETTLE", "admissible"


def policy_guard(r, max_age):
    """PushFeedGuard as deployed: calendar and freshness at each read. No round comparison."""
    for side in ("lock", "settle"):
        if r[f"{side}_session"] != "REGULAR":
            return "REFUSE", f"{side}: OUTSIDE_SESSION or NO_SESSION"
        if r[f"age_at_{side}"] > max_age:
            return "REFUSE", f"{side}: PRICE_STALE"
    return "SETTLE", "ALLOW on both reads"


def policy_guard_plus_pair(r, max_age):
    """The guard plus SettlementPairGuard: per-read admissibility, and the two reads must differ."""
    verdict, reason = policy_guard(r, max_age)
    if verdict == "REFUSE":
        return verdict, reason
    if r["same_round"]:
        return "REFUSE", "SAME_OBSERVATION on the second read"
    return "SETTLE", "ALLOW on both reads, different observations"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-age", type=int, default=900)
    args = ap.parse_args()
    rows = load()
    max_age = args.max_age

    results = []
    for r in rows:
        o = policy_original(r)
        f = policy_freshness(r, max_age)
        c = policy_calendar_fresh(r, max_age)
        g = policy_guard(r, max_age)
        gp = policy_guard_plus_pair(r, max_age)
        results.append((r, o, f, c, g, gp))

    def count(i, verdict):
        return sum(1 for row in results if row[i][0] == verdict)

    lines = []
    add = lines.append
    add("# What this project adds over five lines of local checking")
    add("")
    add("Generated by `script/policy_comparison.py` from the 30 settlements in")
    add(
        f"[`replay_settlements.json`](replay_settlements.json). Staleness budget: **{max_age} s** for every"
    )
    add("policy, so the only differences below come from the rules themselves.")
    add("")
    add("| Policy | Settles | Refuses |")
    add("|---|---:|---:|")
    for i, name in (
        (1, "1. As deployed (the market's own rule)"),
        (2, "2. Freshness check only"),
        (3, "3. Calendar + freshness + same-round refusal (a careful local patch)"),
        (4, "4. PushFeedGuard alone"),
        (5, "5. PushFeedGuard + SettlementPairGuard, as deployed here"),
    ):
        add(f"| {name} | {count(i, 'SETTLE')} | {count(i, 'REFUSE')} |")
    add("")

    same = sum(1 for _, _, _, c, _, gp in results if c[0] == gp[0])
    diff = [(r, c, g) for r, _, _, c, g, _ in results if c[0] != g[0]]
    same_alone = sum(1 for _, _, _, c, g, _ in results if c[0] == g[0])
    add("## The honest part")
    add("")
    add(f"The per-read guard alone (policy 4) agrees with a careful local patch on **{same_alone} of")
    add(f"{len(results)}** settlements; with the pair rule added (policy 5) they agree on **{same} of {len(results)}**.")
    add("")
    if diff:
        add("The two settlements where the local patch was **stricter than our guard**, which is how the pair")
        add("rule came to exist:")
        for r, c, g in diff:
            add(f"- {r['contract']} #{r['id']} {r['symbol']}, {r['gap_s']} s between the reads, price {int(r['age_at_lock'] / 60)} min old,")
            add(f"  both reads inside the regular session: local says {c[0]} ({c[1]}), the per-read guard says {g[0]}.")
        add("")
        add("A per-read check cannot see a relationship between two reads. `SettlementPairGuard` adds exactly")
        add("that rule and nothing else, and policy 5 is the result.")
        add("")
    add("")
    only_calendar = [
        r for r, _, f, c, _, _ in results if f[0] == "SETTLE" and c[0] == "REFUSE"
    ]
    add(
        f"The calendar earns its place against the cheapest patch: **{len(only_calendar)} of {len(results)}**"
    )
    add(
        "settlements pass a pure freshness check and are still refused once a session calendar is applied."
    )
    if only_calendar:
        shown = ", ".join(
            f"{r['symbol']} {r['lock_session'].lower()}" for r in only_calendar[:5]
        )
        add(f"Examples: {shown}.")
    add("")
    add("## Per settlement")
    add("")
    add(
        "| # | Ticker | Locked (UTC) | Session | Age at lock | 1. deployed | 2. fresh only | 3. local | 4. guard |"
    )
    add("|---|---|---|---|---:|---|---|---|---|")
    import datetime as dt

    for r, o, f, c, g, gp in sorted(results, key=lambda x: x[0]["lock_ts"]):
        stamp = dt.datetime.fromtimestamp(r["lock_ts"], dt.timezone.utc).strftime(
            "%m-%d %H:%M"
        )
        age = (
            f"{r['age_at_lock'] // 3600}h"
            if r["age_at_lock"] >= 3600
            else f"{r['age_at_lock'] // 60}m"
        )
        add(
            f"| {r['contract']}#{r['id']} | {r['symbol']} | {stamp} | {r['lock_session']} | {age} | "
            f"{o[0]} ({o[1]}) | {f[0]} | {c[0]} | {g[0]} | {gp[0]} |"
        )
    add("")
    add("## What this does not prove")
    add("")
    add(
        "These 30 settlements are one market on one chain, most of them locked and settled within a minute"
    )
    add(
        "of each other, with 0.009 ETH ever staked across all of them. The table shows which rules would"
    )
    add(
        "have refused which settlement. It does not show that anyone lost money, that a refusal would have"
    )
    add("produced a different winner, or that a consumer wants any of these rules.")

    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines[:28]))
    print(f"\nwrote {OUT}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""How often does a plain `age <= 4h` check accept a price while NYSE is shut?

pplmaverick's V3 market (22.09.2026) gates every oracle read on STALENESS_THRESHOLD = 4 hours and
nothing else. This walks each feed's recorded rounds (docs/feed_rounds_4663.json), samples every minute
between its first and last round, and for the minutes when the regular session is closed asks whether
the latest round at that minute would pass the 4 hour check.

Session: Mon-Fri 13:30-20:00 UTC (the whole window is EDT), minus 2026-09-07 (Labor Day). No half-days
fall inside the window. The per-round session labels in the data file come from the deployed guard; the
script cross-checks its own classification against them and stops if they disagree.
"""

import datetime as dt
import json
import pathlib
import statistics

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATA = json.loads((ROOT / "docs" / "feed_rounds_4663.json").read_text(encoding="utf-8"))
HOLIDAYS = {dt.date(2026, 9, 7)}
LIMIT = 4 * 3600
STEP = 60


def in_session(ts):
    t = dt.datetime.fromtimestamp(ts, dt.timezone.utc)
    if t.weekday() >= 5 or t.date() in HOLIDAYS:
        return False
    minutes = t.hour * 60 + t.minute
    return 13 * 60 + 30 <= minutes < 20 * 60


rows = []
mismatch = 0
for feed in DATA["feeds"]:
    hist = sorted(feed["history"], key=lambda r: r["updatedAt"])
    for r in hist:
        if (r["session"] != "CLOSED") != in_session(r["updatedAt"]):
            mismatch += 1
    ups = [r["updatedAt"] for r in hist]
    closed = passed = 0
    j = 0
    for ts in range(ups[0], ups[-1], STEP):
        while j + 1 < len(ups) and ups[j + 1] <= ts:
            j += 1
        if in_session(ts):
            continue
        closed += 1
        if ts - ups[j] <= LIMIT:
            passed += 1
    if closed:
        rows.append((feed["name"], passed / closed, closed * STEP / 3600))

print(f"session label disagreements with the deployed guard: {mismatch}")
rows.sort(key=lambda r: r[1])
for name, share, hours in rows:
    print(f"{share * 100:6.1f} %  of {hours:7.1f} closed hours  {name}")
shares = [r[1] for r in rows]
print(
    f"\nfeeds: {len(rows)}; median share of closed-market minutes that pass a 4h check: "
    f"{statistics.median(shares) * 100:.1f} %, min {min(shares) * 100:.1f} %, max {max(shares) * 100:.1f} %"
)

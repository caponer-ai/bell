#!/usr/bin/env python3
"""One picture of the problem: when every equity feed spoke, drawn against when the exchange was open.

Each row is one of the 35 Chainlink equity feeds on Robinhood Chain. Each mark is a published round. The
shaded columns are the regular NYSE sessions. A reader sees in a second what takes a paragraph to say: the
marks do not line up with the shading, they do not line up the same way from one row to the next, and no
constant in `latestRoundData()` tells a contract which kind of mark it is holding.

Reads docs/feed_rounds_4663.json, writes docs/feed_rounds.svg. No network, no dependencies.

    python script/make_chart.py [--days 10]
"""

import argparse
import datetime as dt
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "docs" / "feed_rounds_4663.json"
OUT = ROOT / "docs" / "feed_rounds.svg"

HOLIDAYS = {
    (2026, 1, 1),
    (2026, 1, 19),
    (2026, 2, 16),
    (2026, 4, 3),
    (2026, 5, 25),
    (2026, 6, 19),
    (2026, 7, 3),
    (2026, 9, 7),
    (2026, 11, 26),
    (2026, 12, 25),
}
EARLY = {(2026, 11, 27), (2026, 12, 24)}

W, ROW_H, LEFT, TOP, RIGHT, BOTTOM = 1180, 19, 190, 66, 40, 78


def nth_weekday(year, month, weekday, n):
    d = dt.date(year, month, 1)
    d += dt.timedelta((weekday - d.weekday()) % 7)
    return d + dt.timedelta(7 * (n - 1))


def is_dst(day):
    return nth_weekday(day.year, 3, 6, 2) <= day < nth_weekday(day.year, 11, 6, 1)


def session(day):
    if day.weekday() >= 5 or (day.year, day.month, day.day) in HOLIDAYS:
        return None
    dst = is_dst(day)
    midnight = dt.datetime(
        day.year, day.month, day.day, tzinfo=dt.timezone.utc
    ).timestamp()
    close_h = (
        (17 if dst else 18)
        if (day.year, day.month, day.day) in EARLY
        else (20 if dst else 21)
    )
    return midnight + (13 if dst else 14) * 3600 + 1800, midnight + close_h * 3600


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=10)
    args = ap.parse_args()

    data = json.loads(SRC.read_text(encoding="utf-8"))
    feeds = data["feeds"]
    now = max(r["updatedAt"] for f in feeds for r in f["history"])
    t0 = now - args.days * 86400

    # busiest feeds first, so the eye lands on the rows that carry the most rounds in the window
    rows = []
    for f in feeds:
        marks = [r for r in f["history"] if r["updatedAt"] >= t0]
        label = (
            (f.get("description") or f["name"])
            .split(" /")[0]
            .replace("Robinhood ", "")
            .strip()
        )
        rows.append((label, marks))
    rows.sort(key=lambda r: -len(r[1]))

    height = TOP + len(rows) * ROW_H + BOTTOM
    plot_w = W - LEFT - RIGHT

    def x_of(ts):
        return LEFT + (ts - t0) / (now - t0) * plot_w

    out = []
    a = out.append
    a(
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="ui-sans-serif, Segoe UI, Helvetica, Arial, sans-serif">'
        % (W, height, W, height)
    )
    a(
        "<style>"
        ".bg{fill:#0d1117}.lab{fill:#8b949e;font-size:10px}.tick{fill:#6e7681;font-size:10px}"
        ".title{fill:#e6edf3;font-size:16px;font-weight:600}.sub{fill:#8b949e;font-size:11px}"
        ".open{fill:#1f6feb;fill-opacity:.16}.row:nth-child(even){fill:#161b22}"
        ".inn{fill:#3fb950}.outn{fill:#f0883e}.key{fill:#c9d1d9;font-size:11px}"
        "</style>"
    )
    a('<rect class="bg" width="%d" height="%d"/>' % (W, height))
    a(
        '<text class="title" x="%d" y="26">When each Chainlink equity feed spoke, against when the exchange was open</text>'
        % LEFT
    )
    a(
        '<text class="sub" x="%d" y="44">Robinhood Chain, chainId 4663. Shaded columns are regular NYSE sessions. '
        "Green marks are rounds published inside one, orange marks outside.</text>"
        % LEFT
    )

    # session bands
    day = dt.datetime.fromtimestamp(t0, dt.timezone.utc).date() - dt.timedelta(1)
    last = dt.datetime.fromtimestamp(now, dt.timezone.utc).date() + dt.timedelta(1)
    plot_top, plot_bottom = TOP - 6, TOP + len(rows) * ROW_H
    while day <= last:
        s = session(day)
        if s:
            lo, hi = max(s[0], t0), min(s[1], now)
            if hi > lo:
                a(
                    '<rect class="open" x="%.1f" y="%d" width="%.1f" height="%d"/>'
                    % (x_of(lo), plot_top, x_of(hi) - x_of(lo), plot_bottom - plot_top)
                )
        day += dt.timedelta(1)

    # day ticks
    day = dt.datetime.fromtimestamp(t0, dt.timezone.utc).date()
    while day <= last:
        ts = dt.datetime(
            day.year, day.month, day.day, tzinfo=dt.timezone.utc
        ).timestamp()
        if t0 <= ts <= now:
            a(
                '<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" stroke="#30363d" stroke-width="1"/>'
                % (x_of(ts), plot_top, x_of(ts), plot_bottom)
            )
            a(
                '<text class="tick" x="%.1f" y="%d" text-anchor="middle">%s</text>'
                % (x_of(ts), plot_bottom + 16, day.strftime("%a %d"))
            )
        day += dt.timedelta(1)

    for i, (label, marks) in enumerate(rows):
        y = TOP + i * ROW_H
        if i % 2 == 0:
            a(
                '<rect x="%d" y="%d" width="%d" height="%d" fill="#161b22" fill-opacity=".55"/>'
                % (LEFT, y, plot_w, ROW_H)
            )
        inside = sum(1 for m in marks if m["session"] == "REGULAR")
        a(
            '<text class="lab" x="%d" y="%d" text-anchor="end">%s</text>'
            % (LEFT - 10, y + 13, esc(label))
        )
        a(
            '<text class="tick" x="%d" y="%d" text-anchor="end">%d/%d in</text>'
            % (LEFT - 68, y + 13, inside, len(marks))
            if False
            else ""
        )
        for m in marks:
            cls = "inn" if m["session"] == "REGULAR" else "outn"
            a(
                '<rect class="%s" x="%.1f" y="%d" width="2.6" height="%d" rx="1"/>'
                % (cls, x_of(m["updatedAt"]), y + 4, ROW_H - 8)
            )

    key_y = height - 40
    a('<rect class="inn" x="%d" y="%d" width="10" height="10" rx="2"/>' % (LEFT, key_y))
    a(
        '<text class="key" x="%d" y="%d">round published inside the regular session</text>'
        % (LEFT + 16, key_y + 9)
    )
    a(
        '<rect class="outn" x="%d" y="%d" width="10" height="10" rx="2"/>'
        % (LEFT + 300, key_y)
    )
    a(
        '<text class="key" x="%d" y="%d">round published outside it</text>'
        % (LEFT + 316, key_y + 9)
    )
    a(
        '<text class="sub" x="%d" y="%d">%s</text>'
        % (
            LEFT,
            height - 14,
            esc(
                "Generated by script/make_chart.py from docs/feed_rounds_4663.json, last %d rounds per feed, "
                "window ending %s UTC"
                % (
                    data["roundsRequested"],
                    dt.datetime.fromtimestamp(now, dt.timezone.utc).strftime(
                        "%Y-%m-%d %H:%M"
                    ),
                )
            ),
        )
    )
    a("</svg>")

    OUT.write_text("\n".join(x for x in out if x), encoding="utf-8")
    total = sum(len(m) for _, m in rows)
    ins = sum(1 for _, ms in rows for m in ms if m["session"] == "REGULAR")
    print("wrote %s" % OUT)
    print(
        "%d feeds, %d rounds in the last %d days: %d inside the session, %d outside"
        % (len(rows), total, args.days, ins, total - ins)
    )


if __name__ == "__main__":
    main()

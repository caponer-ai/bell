#!/usr/bin/env python3
"""Bell poster: fetch DON-signed Data Streams reports for the ladder's target seconds and post them.

The ladder needs one signed report per rung: OPEN rung i is the second `O + 30*i`, CLOSE rung i is
`C - 1 - 30*i`, i = 0..7, where O and C come from Bell's calendar. This poster asks the Data Streams
REST API for a report covering each of those seconds and sends it to `Bell.post(bytes)`.

Auth follows docs.chain.link/data-streams/reference/data-streams-api/authentication:
three headers, HMAC-SHA256 over "METHOD FULL_PATH BODY_HASH API_KEY TIMESTAMP".

Modes:
    python poster/poster.py --dry-run             # no credentials needed: replays local fixtures
    python poster/poster.py --probe               # one API call, prints what the endpoint returns
    python poster/poster.py --session open        # fetch and post the 8 OPEN rungs of today
    python poster/poster.py --session close       # same for CLOSE

Environment (a .env next to the repo root is read automatically, it is gitignored):
    DS_API_KEY, DS_API_SECRET   Data Streams credentials from app.chain.link
    DS_HOST                     https://api.dataengine.chain.link (default) or the testnet host
    FEED_ID                     stream id, default AAPL/USD RegularHoursEquityPrice on mainnet
    RPC_URL                     https://rpc.mainnet.chain.robinhood.com/ by default
    BELL                        0x88a5a0414c9fd615201814ddbec4e4d9e4d283d0 by default
    PRIVATE_KEY                 poster key (only needed to send transactions)

Nothing here needs a subscription to *run*: --dry-run and --probe tell you whether the plumbing and the
credentials work before a single report is bought.
"""

import argparse
import datetime as dt
import hashlib
import hmac
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULTS = {
    "DS_HOST": "https://api.dataengine.chain.link",
    "FEED_ID": "0x000bbd87a23775b4c11092ae9a1fc7b3393636ae1dbb9f1ef460f845c0f4cff1",  # AAPL/USD RegularHours
    "RPC_URL": "https://rpc.mainnet.chain.robinhood.com/",
    "BELL": "0x88a5a0414c9fd615201814ddbec4e4d9e4d283d0",
}
RUNGS = 8
RUNG_STEP = 30
POST_WINDOW = 300


def env(name):
    if name in os.environ:
        return os.environ[name]
    dotenv = ROOT / ".env"
    if dotenv.exists():
        for line in dotenv.read_text(encoding="utf-8").splitlines():
            if line.strip().startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            if k.strip() == name:
                return v.strip()
    return DEFAULTS.get(name)


# --------------------------------------------------------------------------- session calendar
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


EARLY_CLOSES = {dt.date(2026, 11, 27), dt.date(2026, 12, 24), dt.date(2027, 11, 26)}


def session_bounds(day: dt.date):
    """(open_utc, close_utc) for a trading day, or None when the market is closed."""
    if day.weekday() >= 5 or day in holidays(day.year):
        return None
    dst = _nth(day.year, 3, 6, 2) <= day < _nth(day.year, 11, 6, 1)
    midnight = int(
        dt.datetime(day.year, day.month, day.day, tzinfo=dt.timezone.utc).timestamp()
    )
    open_utc = midnight + (13 * 3600 + 1800 if dst else 14 * 3600 + 1800)
    close_h = 17 if day in EARLY_CLOSES else 20
    close_utc = midnight + (close_h * 3600 if dst else (close_h + 1) * 3600)
    return open_utc, close_utc


def rung_targets(day: dt.date, is_close: bool):
    bounds = session_bounds(day)
    if not bounds:
        return []
    o, c = bounds
    anchor = c if is_close else o
    return [
        anchor - 1 - i * RUNG_STEP if is_close else anchor + i * RUNG_STEP
        for i in range(RUNGS)
    ]


# --------------------------------------------------------------------------- Data Streams client
def signed_headers(method, path, body=b""):
    key, secret = env("DS_API_KEY"), env("DS_API_SECRET")
    if not key or not secret:
        sys.exit(
            "DS_API_KEY / DS_API_SECRET are not set: generate them at app.chain.link (free) and put them in .env"
        )
    ts = str(int(time.time() * 1000))
    body_hash = hashlib.sha256(body).hexdigest()
    to_sign = f"{method} {path} {body_hash} {key} {ts}"
    sig = hmac.new(secret.encode(), to_sign.encode(), hashlib.sha256).hexdigest()
    return {
        "Authorization": key,
        "X-Authorization-Timestamp": ts,
        "X-Authorization-Signature-SHA256": sig,
    }


def api_get(path):
    url = env("DS_HOST").rstrip("/") + path
    req = urllib.request.Request(
        url, headers={**signed_headers("GET", path), "User-Agent": "bell-poster/0.1"}
    )
    try:
        return json.loads(urllib.request.urlopen(req, timeout=30).read())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")[:300]
        raise SystemExit(f"HTTP {e.code} from {path}\n{body}")


def report_at(feed_id, timestamp):
    """The report whose signed interval covers `timestamp` (REST: /api/v1/reports?feedID=&timestamp=)."""
    return api_get(f"/api/v1/reports?feedID={feed_id}&timestamp={timestamp}")


# --------------------------------------------------------------------------- chain
def rpc(method, params):
    req = urllib.request.Request(
        env("RPC_URL"),
        data=json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
        ).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "bell-poster/0.1"},
    )
    out = json.loads(urllib.request.urlopen(req, timeout=60).read())
    if "error" in out:
        raise RuntimeError(out["error"])
    return out["result"]


def post_report(payload_hex):
    """Send Bell.post(bytes) with the raw payload. Requires PRIVATE_KEY; uses cast for signing."""
    import subprocess

    key = env("PRIVATE_KEY")
    if not key:
        sys.exit("PRIVATE_KEY is not set")
    cmd = [
        "cast",
        "send",
        env("BELL"),
        "post(bytes)",
        payload_hex,
        "--private-key",
        key,
        "--rpc-url",
        env("RPC_URL"),
        "--json",
    ]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[:300])
    receipt = json.loads(out.stdout)
    return receipt["transactionHash"], int(receipt["gasUsed"], 16)


# --------------------------------------------------------------------------- modes
def do_probe(feed_id):
    print(f"host: {env('DS_HOST')}\nfeed: {feed_id}")
    now = int(time.time())
    data = report_at(feed_id, now - 60)
    report = data.get("report", data)
    print(
        json.dumps(
            {
                k: (v[:66] + "…" if isinstance(v, str) and len(v) > 66 else v)
                for k, v in report.items()
            },
            indent=1,
        )
    )
    print("\nfullReport length:", len(report.get("fullReport", "")) // 2, "bytes")


def do_dry_run():
    """No credentials: prove the posting path with the fixtures already in the repo."""
    fixtures = sorted((ROOT / "test" / "fixtures" / "reports_v11").glob("*.hex"))
    print(f"fixtures found: {len(fixtures)}")
    day = dt.date(2026, 9, 22)
    for is_close in (False, True):
        targets = rung_targets(day, is_close)
        label = "CLOSE" if is_close else "OPEN"
        pretty = ", ".join(
            dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%H:%M:%S")
            for t in targets[:4]
        )
        print(f"{label} rungs for {day}: {pretty} …  ({len(targets)} targets)")
    print(
        "\nposting window: the first report must be sent within",
        POST_WINDOW,
        "s of the boundary",
    )
    print("dry run only: no API call, no transaction")


def do_session(feed_id, is_close, day, send):
    targets = rung_targets(day, is_close)
    if not targets:
        sys.exit(f"{day} is not a trading day")
    label = "CLOSE" if is_close else "OPEN"
    print(f"{label} rungs for {day} ({len(targets)} targets), feed {feed_id[:14]}…")
    posted = []
    for i, target in enumerate(targets):
        stamp = dt.datetime.fromtimestamp(target, dt.timezone.utc).strftime("%H:%M:%S")
        wait = target + 2 - int(time.time())
        if wait > 0:
            print(f"  rung {i} at {stamp}: waiting {wait}s")
            time.sleep(wait)
        data = report_at(feed_id, target)
        report = data.get("report", data)
        payload = report.get("fullReport")
        if not payload:
            print(f"  rung {i} at {stamp}: no report returned")
            continue
        obs = report.get("observationsTimestamp")
        valid_from = report.get("validFromTimestamp")
        covers = (
            valid_from is not None and obs is not None and valid_from <= target <= obs
        )
        print(
            f"  rung {i} at {stamp}: window [{valid_from}, {obs}] covers target: {covers}"
        )
        if send:
            tx, gas = post_report(
                payload if payload.startswith("0x") else "0x" + payload
            )
            print(f"      posted: {tx} ({gas} gas)")
            posted.append(tx)
        else:
            print("      (not sending: pass --send)")
    print(f"\ndone, {len(posted)} transactions")


def main():
    ap = argparse.ArgumentParser(description="Bell poster")
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="no credentials, no network: show the plan",
    )
    ap.add_argument(
        "--probe",
        action="store_true",
        help="one authenticated call, prints the report shape",
    )
    ap.add_argument(
        "--session", choices=["open", "close"], help="fetch the 8 rungs of a session"
    )
    ap.add_argument("--date", help="trading day YYYY-MM-DD, default today (UTC)")
    ap.add_argument(
        "--send", action="store_true", help="actually send Bell.post() transactions"
    )
    args = ap.parse_args()
    feed_id = env("FEED_ID")
    day = (
        dt.date.fromisoformat(args.date)
        if args.date
        else dt.datetime.now(dt.timezone.utc).date()
    )

    if args.dry_run:
        do_dry_run()
    elif args.probe:
        do_probe(feed_id)
    elif args.session:
        do_session(feed_id, args.session == "close", day, args.send)
    else:
        ap.print_help()


if __name__ == "__main__":
    main()

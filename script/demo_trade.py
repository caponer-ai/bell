#!/usr/bin/env python3
"""Drive the SettleOnMark demo trade: fund both sides, settle on the closing mark, or refund.

The trade lives at SettleOnMark on mainnet and points at one feed and one trading day. Both sides of
this particular trade are wallets we control, which the README says out loud: the demo is about where
the number comes from, not about who won.

    python script/demo_trade.py status
    python script/demo_trade.py fund          # both sides post 1 USDG each (needs USDG on both wallets)
    python script/demo_trade.py settle        # after the close has been marked
    python script/demo_trade.py refund        # after refundAfter, when the day produced no mark
"""

import datetime as dt
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RPC = "https://rpc.mainnet.chain.robinhood.com/"
TRADE = "0x5338523cB4629b460c9e21532d9e4F0c7Fc9648C"
USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"
STAKE = 1_000_000  # 1 USDG, six decimals


def env(name):
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            if k.strip() == name:
                return v.strip()
    return None


def cast(*args):
    out = subprocess.run(["cast", *args], capture_output=True, text=True)
    if out.returncode != 0:
        return None, (out.stderr.strip().splitlines() or ["failed"])[-1][:200]
    return out.stdout.strip(), None


def call(sig, *args):
    res, err = cast("call", TRADE, sig, *[str(a) for a in args], "--rpc-url", RPC)
    return res, err


def send(to, sig, key, *args):
    res, err = cast(
        "send",
        to,
        sig,
        *[str(a) for a in args],
        "--private-key",
        key,
        "--rpc-url",
        RPC,
        "--json",
    )
    if err:
        return None, err
    r = json.loads(res)
    return r["transactionHash"], int(r["gasUsed"], 16)


def usdg_balance(addr):
    res, err = cast("call", USDG, "balanceOf(address)(uint256)", addr, "--rpc-url", RPC)
    if err:
        return 0
    return int(res.split()[0].replace(",", ""))


def status():
    long_addr, short_addr = env("DEPLOYER_ADDRESS"), env("COUNTERPARTY_ADDRESS")
    print(f"trade    {TRADE}")
    print(f"long     {long_addr}  USDG {usdg_balance(long_addr) / 1e6:.2f}")
    print(f"short    {short_addr}  USDG {usdg_balance(short_addr) / 1e6:.2f}")
    print(f"escrow   USDG {usdg_balance(TRADE) / 1e6:.2f}")
    for name, sig in (
        ("longFunded", "longFunded()(bool)"),
        ("shortFunded", "shortFunded()(bool)"),
        ("closed", "closed()(bool)"),
    ):
        res, err = call(sig)
        print(f"{name:12} {res if res else err}")
    res, err = call("quote()(bool,string,int192,uint64,address)")
    print("\nquote:")
    print(f"  {res if res else err}")


def fund():
    for label, key_name, addr_name in (
        ("long", "PRIVATE_KEY", "DEPLOYER_ADDRESS"),
        ("short", "COUNTERPARTY_KEY", "COUNTERPARTY_ADDRESS"),
    ):
        key, addr = env(key_name), env(addr_name)
        have = usdg_balance(addr)
        if have < STAKE:
            print(
                f"  {label}: has {have / 1e6:.2f} USDG, needs {STAKE / 1e6:.2f}, skipping"
            )
            continue
        tx, gas = send(USDG, "approve(address,uint256)(bool)", key, TRADE, STAKE)
        print(f"  {label} approve: {tx or gas}")
        tx, gas = send(TRADE, "fund()", key)
        print(f"  {label} fund:    {tx or gas}")


def settle():
    tx, gas = send(TRADE, "settle()(address,int192)", env("PRIVATE_KEY"))
    print(f"settle: {tx or gas}")


def refund():
    tx, gas = send(TRADE, "refund()", env("PRIVATE_KEY"))
    print(f"refund: {tx or gas}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    print(dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"))
    {"status": status, "fund": fund, "settle": settle, "refund": refund}.get(
        cmd, status
    )()

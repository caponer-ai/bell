# Дістає справжні підписані звіти Data Streams v11 з calldata транзакцій refresh(bytes[])
# приватного контракту 0x2a77… на Robinhood Chain і зберігає їх як фікстури для Foundry.
# Навіщо: інтеграційний тест VerifierProxy.verify() з реальними підписами DON без підписки.
import json
import time
import urllib.request
from pathlib import Path

RPC = "https://rpc.mainnet.chain.robinhood.com/"
VERIFIER = "0xb86d1b8a3bb1c5d7809f5e9eb009311d51d933c6"
TOPIC_REPORT_VERIFIED = (
    "0x58ca9502e98a536e06e72d680fcc251e5d10b72291a281665a2c2dc0ac30fcc5"
)
OUT = Path(__file__).resolve().parent.parent / "test" / "fixtures" / "reports_v11"
OUT.mkdir(parents=True, exist_ok=True)


def rpc(method, params, timeout=120):
    req = urllib.request.Request(
        RPC,
        data=json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
        ).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"},
    )
    data = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    if "error" in data:
        raise RuntimeError(data["error"])
    return data["result"]


def word(hexstr, i):
    return int(hexstr[i * 64 : (i + 1) * 64], 16)


def decode_bytes_array(calldata_hex):
    """refresh(bytes[]) -> список payload-ів (hex без 0x)."""
    body = calldata_hex[2 + 8 :]  # без селектора
    arr_off = word(body, 0) // 32
    n = word(body, arr_off)
    payloads = []
    for k in range(n):
        el_off = arr_off + 1 + word(body, arr_off + 1 + k) // 32
        ln = word(body, el_off)
        start = (el_off + 1) * 64
        payloads.append(body[start : start + ln * 2])
    return payloads


def decode_report(payload_hex):
    """payload = abi.encode(bytes32[3] reportContext, bytes reportData, bytes32[] rs, bytes32[] ss, bytes32 rawVs)."""
    ctx = [payload_hex[i * 64 : (i + 1) * 64] for i in range(3)]
    rd_off = word(payload_hex, 3) // 32
    rd_len = word(payload_hex, rd_off)
    rd = payload_hex[(rd_off + 1) * 64 : (rd_off + 1) * 64 + rd_len * 2]
    fields = [word(rd, i) for i in range(14)]
    return {
        "configDigest": "0x" + ctx[0],
        "feedId": "0x" + rd[:64],
        "validFromTimestamp": fields[1],
        "observationsTimestamp": fields[2],
        "expiresAt": fields[5],
        "mid": fields[6],
        "lastSeenTimestampNs": fields[7],
        "bid": fields[8],
        "ask": fields[10],
        "marketStatus": fields[13],
        "reportDataLen": rd_len,
    }


def main():
    logs = rpc(
        "eth_getLogs",
        [
            {
                "address": VERIFIER,
                "topics": [TOPIC_REPORT_VERIFIED],
                "fromBlock": "0x0",
                "toBlock": "latest",
            }
        ],
    )
    v11_txs = sorted(
        {lg["transactionHash"] for lg in logs if lg["topics"][1].startswith("0x000b")}
    )
    print(f"транзакцій з v11-звітами: {len(v11_txs)}")
    index = []
    for h in v11_txs:
        tx = rpc("eth_getTransactionByHash", [h])
        time.sleep(1.2)
        try:
            payloads = decode_bytes_array(tx["input"])
        except Exception as e:  # noqa: BLE001
            print("  не bytes[]:", h[:12], str(e)[:60])
            continue
        for i, pl in enumerate(payloads):
            meta = decode_report(pl)
            name = f"{meta['feedId'][2:10]}_{meta['observationsTimestamp']}.hex"
            (OUT / name).write_text(pl)
            meta.update(
                {"tx": h, "index": i, "file": name, "block": int(tx["blockNumber"], 16)}
            )
            index.append(meta)
    (OUT / "index.json").write_text(json.dumps(index, indent=1))
    print(f"збережено звітів: {len(index)} у {OUT}")
    for m in index[:4]:
        print(
            "  ",
            m["file"],
            "digest",
            m["configDigest"][:12],
            "status",
            m["marketStatus"],
            "mid",
            m["mid"] / 1e18,
        )


if __name__ == "__main__":
    main()

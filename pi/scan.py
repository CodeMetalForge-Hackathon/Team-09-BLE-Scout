#!/usr/bin/env python3
"""Live Bluetooth scanner: lists nearby devices, strongest first.

This is the "radar" step. It proves the radio works and shows you what is
around you. RSSI is loudness in dBm: -40 is close, -90 is far.

Run on the Pi:
    sudo ~/venv/bin/python ~/scan.py
    sudo ~/venv/bin/python ~/scan.py --csv ~/scan.csv

Stop with Ctrl-C. To upload readings to the team's Supabase relay instead of
just listing them, use upload.py (see README.md).
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import sys
import time

from bleak import BleakScanner

CLEAR = "\033[2J\033[H"


def main() -> None:
    parser = argparse.ArgumentParser(description="List nearby Bluetooth devices by signal strength.")
    parser.add_argument("--csv", help="append every observation to this file")
    parser.add_argument("--top", type=int, default=15, help="rows to show")
    parser.add_argument("--min-rssi", type=int, default=-95, help="ignore weaker than this")
    args = parser.parse_args()

    seen: dict[str, dict] = {}

    file_handle = None
    writer = None
    if args.csv:
        file_handle = open(args.csv, "a", newline="", encoding="utf-8")
        writer = csv.writer(file_handle)
        writer.writerow(["t", "address", "name", "rssi"])

    def on_advert(device, adv) -> None:
        if adv.rssi is None or adv.rssi < args.min_rssi:
            return
        name = adv.local_name or device.name or ""
        seen[device.address] = {"name": name, "rssi": adv.rssi, "t": time.time()}
        if writer is not None:
            writer.writerow([round(time.time(), 3), device.address, name, adv.rssi])
            file_handle.flush()

    async def run() -> None:
        async with BleakScanner(
            detection_callback=on_advert,
            bluez={"filters": {"DuplicateData": True}},
        ):
            while True:
                await asyncio.sleep(1.0)
                now = time.time()
                rows = sorted(seen.items(), key=lambda kv: -kv[1]["rssi"])[: args.top]
                print(CLEAR, end="")
                print(f"{len(seen)} devices heard   (Ctrl-C to stop)\n")
                for address, info in rows:
                    if now - info["t"] > 5:
                        continue
                    name = info["name"] or "(unnamed)"
                    print(f"{info['rssi']:>5} dBm   {name:<30} {address}")
                sys.stdout.flush()

    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        if file_handle is not None:
            file_handle.close()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Headless Raspberry Pi scanner: uploads Bluetooth readings to Supabase.

Unlike scan.py (a live terminal radar), this has no UI. It scans continuously and
POSTs a batch every PI_INTERVAL seconds, using the same row and payload format as
the iPhone app in Cloud mode (see groundstation/supabase/schema.sql and
groundstation/station/server.py). The ground station shows it as another device.

Run on the Pi:
    sudo ~/venv/bin/python ~/upload.py
    sudo ~/venv/bin/python ~/upload.py --seconds 30      # short test run
    sudo ~/venv/bin/python ~/upload.py --test            # send one ping row

Config comes from pi/.env, then .env in the repo root, then groundstation/.env
(or pass --env). Copy pi/.env.example to pi/.env and set at least SUPABASE_URL
and SUPABASE_ANON_KEY.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from pathlib import Path

from bleak import BleakScanner

from cloud import (
    DEFAULT_ENV_PATHS,
    Config,
    ConfigError,
    Uploader,
    error_text,
    load_env,
    post_row,
)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Scan Bluetooth on a Raspberry Pi and upload readings to Supabase.")
    parser.add_argument("--env", type=Path, action="append",
                        help="env file to read (repeatable; earlier files win)")
    parser.add_argument("--name", help="override PI_NAME")
    parser.add_argument("--id", dest="device_id", help="override PI_ID")
    parser.add_argument("--interval", type=float, help="override PI_INTERVAL (seconds)")
    parser.add_argument("--min-rssi", type=int, help="override PI_MIN_RSSI (dBm)")
    parser.add_argument("--seconds", type=float, default=0,
                        help="stop after this many seconds (0 = run until Ctrl-C)")
    parser.add_argument("--test", action="store_true", help="send one ping row and exit")
    parser.add_argument("--dry-run", action="store_true", help="print batches instead of uploading")
    return parser.parse_args(argv)


def send_ping(cfg: Config) -> None:
    print(f"Sending a test ping as '{cfg.name}' ({cfg.device_id}) to team {cfg.team}…", flush=True)
    try:
        post_row(cfg, {"ping": True, "name": cfg.name}, kind="ping")
    except Exception as error:  # noqa: BLE001 - show the real reason to the operator
        raise SystemExit(f"✗ Couldn't reach Supabase: {error_text(error)}") from error
    print("✓ Sent. The ground station shows it if it uses the same team code.")


async def run(cfg: Config, args: argparse.Namespace) -> None:
    uploader = Uploader(cfg)
    print(f"Raspberry Pi uploader: '{cfg.name}' ({cfg.device_id})", flush=True)
    print(f"  team {cfg.team} · {cfg.url} · every {cfg.interval:g}s", flush=True)
    print(f"  min RSSI {cfg.min_rssi} dBm · Ctrl-C to stop", flush=True)

    def on_advert(device, advertisement) -> None:
        if advertisement.rssi is None or advertisement.rssi < cfg.min_rssi:
            return
        name = advertisement.local_name or device.name or ""
        uploader.add(device.address, name, advertisement.rssi)

    deadline = time.monotonic() + args.seconds if args.seconds else None
    last_error = 0.0
    async with BleakScanner(
        detection_callback=on_advert,
        bluez={"filters": {"DuplicateData": True}},
    ):
        while deadline is None or time.monotonic() < deadline:
            await asyncio.sleep(cfg.interval)
            samples = uploader.take()
            batch = uploader.build_batch(samples)

            if args.dry_run:
                print(json.dumps(batch, indent=2), flush=True)
                uploader.note_sent(len(samples))
                continue

            try:
                await asyncio.to_thread(post_row, cfg, batch)
            except Exception as error:  # noqa: BLE001 - keep scanning through network trouble
                uploader.restore(samples)
                now = time.monotonic()
                if now - last_error >= 10:  # don't flood the terminal while offline
                    print(f"  {time.strftime('%H:%M:%S')}  upload failed "
                          f"({error_text(error)}); retrying…", flush=True)
                    last_error = now
            else:
                uploader.note_sent(len(samples))
                if samples:
                    print(f"  {time.strftime('%H:%M:%S')}  sent {len(samples)} readings "
                          f"({uploader.sent_samples} total, {len(uploader.named)} named devices)",
                          flush=True)


def main() -> None:
    args = parse_args()
    paths = tuple(args.env) if args.env else DEFAULT_ENV_PATHS
    try:
        cfg = Config.from_env(load_env(paths), name=args.name, device_id=args.device_id,
                              interval=args.interval, min_rssi=args.min_rssi)
    except ConfigError as error:
        raise SystemExit(f"error: {error}\n"
                         "Copy pi/.env.example to pi/.env and fill in the Supabase values.") from error

    if args.test:
        send_ping(cfg)
        return

    try:
        asyncio.run(run(cfg, args))
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Headless Raspberry Pi scanner: uploads Bluetooth readings and camera poses.

Unlike scan.py (a live terminal radar), this has no UI. It scans BLE, tracks the
camera's movement over the ceiling, and POSTs a batch every PI_INTERVAL seconds
using the same row and payload format as the iPhone app in Cloud mode (see
groundstation/supabase/schema.sql and groundstation/station/server.py).

Run on the Pi:
    sudo ~/venv/bin/python ~/upload.py
    sudo ~/venv/bin/python ~/upload.py --seconds 30      # short test run
    sudo ~/venv/bin/python ~/upload.py --no-camera       # Bluetooth only
    sudo ~/venv/bin/python ~/upload.py --test            # send one ping row

Config comes from pi/.env, then .env in the repo root, then groundstation/.env
(or pass --env). Copy pi/.env.example to pi/.env and set at least SUPABASE_URL
and SUPABASE_ANON_KEY. Camera settings are PI_CAMERA_* in the same file.
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
from vision import CameraPoseTracker, VisionConfig, VisionConfigError


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Scan Bluetooth and track camera movement on a Raspberry Pi, "
                    "uploading both to Supabase.")
    parser.add_argument("--env", type=Path, action="append",
                        help="env file to read (repeatable; earlier files win)")
    parser.add_argument("--name", help="override PI_NAME")
    parser.add_argument("--id", dest="device_id", help="override PI_ID")
    parser.add_argument("--interval", type=float, help="override PI_INTERVAL (seconds)")
    parser.add_argument("--min-rssi", type=int, help="override PI_MIN_RSSI (dBm)")
    parser.add_argument("--seconds", type=float, default=0,
                        help="stop after this many seconds (0 = run until Ctrl-C)")
    parser.add_argument("--no-camera", action="store_true", help="don't start the camera")
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


async def run(cfg: Config, vcfg: VisionConfig, args: argparse.Namespace) -> None:
    uploader = Uploader(cfg)
    print(f"Raspberry Pi uploader: '{cfg.name}' ({cfg.device_id})", flush=True)
    print(f"  team {cfg.team} · {cfg.url} · every {cfg.interval:g}s", flush=True)
    print(f"  min RSSI {cfg.min_rssi} dBm · Ctrl-C to stop", flush=True)

    camera: CameraPoseTracker | None = None
    if vcfg.enabled and not args.no_camera:
        try:
            camera = CameraPoseTracker(vcfg)
            camera.start()
            print(f"  camera {camera.status} · facing {vcfg.facing} "
                  f"· {vcfg.plane_distance_m:g} m to surface", flush=True)
        except Exception as error:  # noqa: BLE001 - BLE still works without a camera
            print(f"  camera off ({error}); uploading Bluetooth only", flush=True)
            camera = None
    elif not vcfg.enabled:
        print("  camera off (PI_CAMERA=0)", flush=True)

    def on_advert(device, advertisement) -> None:
        if advertisement.rssi is None or advertisement.rssi < cfg.min_rssi:
            return
        name = advertisement.local_name or device.name or ""
        uploader.add(device.address, name, advertisement.rssi)

    deadline = time.monotonic() + args.seconds if args.seconds else None
    last_error = 0.0
    last_camera_status = None
    last_camera_log = 0.0
    try:
        async with BleakScanner(
            detection_callback=on_advert,
            bluez={"filters": {"DuplicateData": True}},
        ):
            while deadline is None or time.monotonic() < deadline:
                await asyncio.sleep(cfg.interval)

                if camera is not None:
                    for pose in camera.take_poses():
                        uploader.add_pose(**pose)
                    now = time.monotonic()
                    if camera.status != last_camera_status and now - last_camera_log >= 5:
                        print(f"  camera: {camera.status}", flush=True)
                        last_camera_status = camera.status
                        last_camera_log = now

                samples = uploader.take()
                poses = uploader.take_poses()
                batch = uploader.build_batch(samples, poses)

                if args.dry_run:
                    print(json.dumps(batch, indent=2), flush=True)
                    uploader.note_sent(len(samples), len(poses))
                    continue

                try:
                    await asyncio.to_thread(post_row, cfg, batch)
                except Exception as error:  # noqa: BLE001 - keep scanning through network trouble
                    uploader.restore(samples)
                    uploader.restore_poses(poses)
                    now = time.monotonic()
                    if now - last_error >= 10:  # don't flood the terminal while offline
                        print(f"  {time.strftime('%H:%M:%S')}  upload failed "
                              f"({error_text(error)}); retrying…", flush=True)
                        last_error = now
                else:
                    uploader.note_sent(len(samples), len(poses))
                    if samples or poses:
                        print(f"  {time.strftime('%H:%M:%S')}  sent {len(samples)} readings, "
                              f"{len(poses)} poses "
                              f"({uploader.sent_samples} readings / "
                              f"{uploader.sent_poses} poses total)", flush=True)
    finally:
        if camera is not None:
            camera.stop()


def main() -> None:
    args = parse_args()
    paths = tuple(args.env) if args.env else DEFAULT_ENV_PATHS
    env = load_env(paths)
    try:
        cfg = Config.from_env(env, name=args.name, device_id=args.device_id,
                              interval=args.interval, min_rssi=args.min_rssi)
        vcfg = VisionConfig.from_env(env)
    except (ConfigError, VisionConfigError) as error:
        raise SystemExit(f"error: {error}\n"
                         "Copy pi/.env.example to pi/.env and fill in the Supabase values.") from error

    if args.test:
        send_ping(cfg)
        return

    try:
        asyncio.run(run(cfg, vcfg, args))
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    sys.exit(main())

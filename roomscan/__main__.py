"""uv run roomscan [--simulate] [--load scans/scan-....json]"""

from __future__ import annotations

import argparse
import asyncio
import socket
import webbrowser
from pathlib import Path

from aiohttp import web

from .server import Session, build_app


def lan_ip() -> str:
    """This laptop's address on the local network (no packets are sent)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


async def serve(args) -> None:
    session = Session(args.simulate, args.speed, args.save_dir)
    if args.width and args.length:
        session.setup(args.width, args.length, args.lane)
    if args.load:
        session.load(args.load)

    team_url = None
    runner = None
    for port in range(args.port, args.port + 20):
        team_url = f"http://{lan_ip()}:{port}/team"
        runner = web.AppRunner(build_app(session, team_url))
        await runner.setup()
        try:
            await web.TCPSite(runner, "0.0.0.0", port).start()
            break
        except OSError:
            await runner.cleanup()
    else:
        raise SystemExit(f"no free port from {args.port}")

    console = f"http://localhost:{port}"
    print(f"\n  Operator console : {console}"
          f"\n  Rescue team join : {team_url}   (phones on the same Wi-Fi; QR code on the console)"
          f"\n  Mode             : {'SIMULATED room' if args.simulate else 'real Bluetooth'}"
          f"\n  Ctrl-C to stop\n", flush=True)
    if not args.no_browser:
        webbrowser.open(console)
    await asyncio.Event().wait()


def main() -> None:
    p = argparse.ArgumentParser(description="Walk a room, map Bluetooth clusters, dispatch a rescue team.")
    p.add_argument("--simulate", action="store_true", help="fake room and devices; the walk happens by itself")
    p.add_argument("--speed", type=float, default=0.5, help="pacer walking speed, m/s (0.5 = slow, steady walk)")
    p.add_argument("--width", type=float, help="room width in metres (along the wall to the right of the door)")
    p.add_argument("--length", type=float, help="room length in metres (straight in from the door)")
    p.add_argument("--lane", type=float, default=1.5, help="distance between walking lanes, metres")
    p.add_argument("--load", type=Path, help="re-open a saved scan")
    p.add_argument("--save-dir", type=Path, default=Path("scans"))
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--no-browser", action="store_true")
    args = p.parse_args()
    try:
        asyncio.run(serve(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

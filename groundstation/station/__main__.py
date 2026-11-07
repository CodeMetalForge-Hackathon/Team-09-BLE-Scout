"""uv run groundstation  [--port 8765] [--no-browser]"""

from __future__ import annotations

import argparse
import asyncio
import socket
import webbrowser
from pathlib import Path

from aiohttp import web

from .cloud import CloudConfig, poll_supabase
from .server import Station, build_app

SERVICE_TYPE = "_blescout._tcp.local."


def lan_ip() -> str:
    """This Mac's address on the local network (no packets are sent)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


async def advertise(ip: str, port: int, url: str):
    """Announce the station over Bonjour so phones find it without typing an address."""
    try:
        from zeroconf import ServiceInfo
        from zeroconf.asyncio import AsyncZeroconf

        zc = AsyncZeroconf()
        info = ServiceInfo(
            SERVICE_TYPE, f"BLE Scout Ground Station.{SERVICE_TYPE}",
            addresses=[socket.inet_aton(ip)], port=port,
            properties={"url": url, "v": "1"}, server=f"{socket.gethostname().split('.')[0]}.local.",
        )
        await zc.async_register_service(info)
        return zc, info
    except Exception as e:  # e.g. no network permission; phones can still type the URL
        print(f"  (Bonjour announcement failed: {e}. Phones can enter the URL by hand.)", flush=True)
        return None, None


async def serve(args) -> None:
    station = Station(args.data_dir)
    runner = web.AppRunner(build_app(station))
    await runner.setup()
    await web.TCPSite(runner, "0.0.0.0", args.port).start()

    ip = lan_ip()
    station.url = f"http://{ip}:{args.port}"
    zc, info = await advertise(ip, args.port, station.url)

    cloud = None if args.local_only else CloudConfig.load(args.env, args.team)
    cloud_task = None
    if cloud:
        station.team = cloud.team
        cloud_task = asyncio.create_task(poll_supabase(cloud, station))
    print(f"\n  Ground station dashboard : http://localhost:{args.port}"
          + (f"\n  Cloud relay (Supabase)   : team code {cloud.team}  ({cloud.url})" if cloud else
             "\n  Cloud relay (Supabase)   : off (add groundstation/.env to turn on)")
          + f"\n  Local Wi-Fi phones       : {station.url}"
          f"\n  Raw data saved to        : {station.session_dir}"
          f"\n  Ctrl-C to stop\n", flush=True)
    if not args.no_browser:
        webbrowser.open(f"http://localhost:{args.port}")
    try:
        await asyncio.Event().wait()
    finally:
        if cloud_task:
            cloud_task.cancel()
        if zc:
            await zc.async_unregister_service(info)
            await zc.async_close()
        await runner.cleanup()


def main() -> None:
    p = argparse.ArgumentParser(description="BLE Scout ground station: one shared map for all phones.")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--data-dir", type=Path, default=Path("sessions"), help="where raw phone data is saved")
    p.add_argument("--no-browser", action="store_true")
    p.add_argument("--team", help="team code to pull from the cloud relay (default: TEAM_CODE in .env, else TEAM9)")
    p.add_argument("--env", type=Path, default=Path(".env"), help="file with SUPABASE_URL / SUPABASE_SERVICE_KEY")
    p.add_argument("--local-only", action="store_true", help="don't use the cloud relay even if configured")
    args = p.parse_args()
    try:
        asyncio.run(serve(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

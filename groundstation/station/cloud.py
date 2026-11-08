"""Pull phone batches from the Supabase relay (see supabase/schema.sql).

Phones insert rows into `batches` over any internet connection; this polls for new rows
for our team code and feeds them into the same Station the local endpoint uses.
"""

from __future__ import annotations

import asyncio
import os
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

import aiohttp

from .server import Station
from .tls import ssl_context


@dataclass
class CloudConfig:
    url: str
    key: str  # secret / service_role key: reads past the row-level security
    team: str

    @staticmethod
    def load(env_file: Path, team_override: str | None = None) -> "CloudConfig | None":
        env = dict(os.environ)
        if env_file.exists():
            for line in env_file.read_text().splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env.setdefault(k.strip(), v.strip().strip('"').strip("'"))
        url, key = env.get("SUPABASE_URL", "").rstrip("/"), env.get("SUPABASE_SERVICE_KEY", "")
        team = (team_override or env.get("TEAM_CODE", "TEAM9")).strip().upper()
        if not url or not key or "YOUR" in url.upper() or "YOUR" in key.upper():
            return None
        return CloudConfig(url, key, team)


def auth_headers(key: str) -> dict:
    h = {"apikey": key}
    if key.startswith("eyJ"):  # legacy JWT-style keys also go in Authorization
        h["Authorization"] = f"Bearer {key}"
    return h


async def insert_relay(cfg: CloudConfig, row: dict) -> None:
    """Write a relay row (e.g. a dispatch) with the ground station's secret key."""
    headers = {**auth_headers(cfg.key), "Content-Type": "application/json", "Prefer": "return=minimal"}
    connector = aiohttp.TCPConnector(ssl=ssl_context())
    async with aiohttp.ClientSession(connector=connector) as http:
        async with http.post(f"{cfg.url}/rest/v1/relays", json=row, headers=headers,
                             timeout=aiohttp.ClientTimeout(total=8)) as r:
            if r.status >= 300:
                raise RuntimeError(f"Supabase said {r.status}: {(await r.text())[:200]}")


async def poll_relays(cfg: CloudConfig, station: Station, interval: float = 1.0, lookback_min: float = 15) -> None:
    """Forever: pull new signal relays for our team and hand them to the station."""
    since = (datetime.now(timezone.utc) - timedelta(minutes=lookback_min)).isoformat()
    last_id: int | None = None
    warned = False
    endpoint = f"{cfg.url}/rest/v1/relays"
    connector = aiohttp.TCPConnector(ssl=ssl_context())
    async with aiohttp.ClientSession(headers=auth_headers(cfg.key), connector=connector) as http:
        while True:
            params = {"select": "*", "team": f"eq.{cfg.team}", "order": "id.asc", "limit": "200"}
            if last_id is None:
                params["created_at"] = f"gte.{since}"
            else:
                params["id"] = f"gt.{last_id}"
            try:
                async with http.get(endpoint, params=params, timeout=aiohttp.ClientTimeout(total=8)) as r:
                    if r.status != 200:
                        raise RuntimeError(f"HTTP {r.status}: {(await r.text())[:160]}")
                    rows = await r.json()
                warned = False
                for row in rows:
                    last_id = row["id"]
                    station.add_relay(row)
                    if row.get("kind") == "dispatch":
                        continue  # already logged when the dashboard sent it
                    names = " → ".join(h.get("name", "?") for h in row.get("chain") or [])
                    print(f"  {time.strftime('%H:%M:%S')}  relay: '{row.get('target_name')}' via {names}"
                          f" (hop {row.get('hop')})", flush=True)
                if last_id is None:
                    last_id = 0
            except Exception as e:
                if not warned:
                    print(f"  {time.strftime('%H:%M:%S')}  relays: can't read from Supabase ({e}); "
                          f"has the relays table been created? retrying…", flush=True)
                    warned = True
            await asyncio.sleep(interval)


async def poll_supabase(cfg: CloudConfig, station: Station, interval: float = 1.5, lookback_min: float = 15) -> None:
    """Forever: fetch rows newer than the last one seen and ingest them."""
    since = (datetime.now(timezone.utc) - timedelta(minutes=lookback_min)).isoformat()
    last_id: int | None = None
    warned = False
    endpoint = f"{cfg.url}/rest/v1/batches"
    connector = aiohttp.TCPConnector(ssl=ssl_context())
    async with aiohttp.ClientSession(headers=auth_headers(cfg.key), connector=connector) as http:
        while True:
            params = {"select": "id,phone_id,name,kind,payload", "team": f"eq.{cfg.team}",
                      "order": "id.asc", "limit": "500"}
            if last_id is None:
                params["created_at"] = f"gte.{since}"  # on startup: just the recent past
            else:
                params["id"] = f"gt.{last_id}"
            try:
                async with http.get(endpoint, params=params, timeout=aiohttp.ClientTimeout(total=8)) as r:
                    if r.status != 200:
                        raise RuntimeError(f"HTTP {r.status}: {(await r.text())[:200]}")
                    rows = await r.json()
                if warned:
                    print(f"  {time.strftime('%H:%M:%S')}  cloud: reconnected", flush=True)
                    warned = False
                for row in rows:
                    last_id = row["id"]
                    payload = row.get("payload") or {}
                    payload.setdefault("phoneId", row.get("phone_id"))
                    payload.setdefault("name", row.get("name"))
                    if row.get("kind") == "ping":
                        print(f"  {time.strftime('%H:%M:%S')}  cloud: test ping from '{row.get('name')}'", flush=True)
                        continue
                    phone = station.ingest(payload)
                    if phone.batches == 1 or phone.batches % 15 == 0:
                        print(f"  {time.strftime('%H:%M:%S')}  cloud: batch from '{phone.name}' "
                              f"(#{phone.batches}, {phone.samples_received} readings so far)", flush=True)
                if last_id is None:
                    last_id = 0 if not rows else last_id
                    if last_id == 0:  # nothing recent: start from the newest existing row
                        async with http.get(endpoint, params={"select": "id", "order": "id.desc", "limit": "1"}) as r:
                            newest = await r.json() if r.status == 200 else []
                            last_id = newest[0]["id"] if newest else 0
            except Exception as e:
                if not warned:
                    print(f"  {time.strftime('%H:%M:%S')}  cloud: can't read from Supabase ({e}); retrying…", flush=True)
                    warned = True
            await asyncio.sleep(interval)

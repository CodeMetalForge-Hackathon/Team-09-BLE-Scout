"""Upload Raspberry Pi Bluetooth readings to the Supabase relay, like a phone.

The iPhone app in Cloud mode inserts rows into `public.batches` with the public
(anon / publishable) key; the ground station reads them with its secret key. This
module does the same thing headlessly, so the Pi shows up as another device.

Configuration (see pi/.env.example):

    SUPABASE_URL           https://<project>.supabase.co
    SUPABASE_ANON_KEY      public anon / publishable key (never the secret key)
    TEAM_CODE              must match the ground station (default TEAM9)
    PI_NAME                how the Pi is labelled (default: PI_ID)
    PI_ID                  stable device id (default: the Pi's hostname)
    PI_INTERVAL            seconds between uploads (default 2)
    PI_MIN_RSSI            ignore weaker readings (default -95 dBm)
"""

from __future__ import annotations

import json
import os
import socket
import ssl
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Mapping, Sequence

import certifi

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
# First file wins for any key; pi/.env overrides the repo/groundstation values.
DEFAULT_ENV_PATHS = (HERE / ".env", REPO / ".env", REPO / "groundstation" / ".env")

PENDING_CAP = 20_000  # keep retrying old readings, but don't grow without bound


class ConfigError(ValueError):
    """A missing or invalid setting in .env."""


def load_env(paths: Iterable[Path] = DEFAULT_ENV_PATHS) -> dict[str, str]:
    """Read KEY=VALUE files on top of the process environment (first file wins)."""
    env = dict(os.environ)
    for path in paths:
        try:
            text = Path(path).read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            continue
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            if line.startswith("export "):
                line = line[7:].lstrip()
            key, value = line.split("=", 1)
            key = key.strip()
            if key:
                env.setdefault(key, value.strip().strip('"').strip("'"))
    return env


@dataclass(frozen=True)
class Config:
    url: str
    key: str
    team: str
    device_id: str
    name: str
    interval: float = 2.0
    min_rssi: int = -95

    @classmethod
    def from_env(
        cls,
        env: Mapping[str, str],
        *,
        device_id: str | None = None,
        name: str | None = None,
        interval: float | None = None,
        min_rssi: int | None = None,
    ) -> "Config":
        url = (env.get("SUPABASE_URL") or "").strip().rstrip("/")
        key = (env.get("SUPABASE_ANON_KEY") or env.get("SUPABASE_PUBLISHABLE_KEY") or "").strip()
        if not url or not key or "YOUR" in url.upper() or "YOUR" in key.upper():
            raise ConfigError(
                "set SUPABASE_URL and SUPABASE_ANON_KEY (the public/publishable key) "
                "in pi/.env or groundstation/.env"
            )
        if not url.startswith(("http://", "https://")):
            raise ConfigError(f"SUPABASE_URL must start with http:// or https:// (got {url!r})")

        team = (env.get("TEAM_CODE") or "TEAM9").strip().upper()
        if not 1 <= len(team) <= 64:
            raise ConfigError("TEAM_CODE must be 1-64 characters")

        device_id = (device_id or env.get("PI_ID") or socket.gethostname() or "raspberry-pi").strip()
        if not 1 <= len(device_id) <= 64:
            raise ConfigError("PI_ID must be 1-64 characters")

        name = (name or env.get("PI_NAME") or device_id).strip()[:64] or device_id

        try:
            every = float(interval if interval is not None else env.get("PI_INTERVAL", 2))
            floor = int(min_rssi if min_rssi is not None else env.get("PI_MIN_RSSI", -95))
        except (TypeError, ValueError):
            raise ConfigError("PI_INTERVAL and PI_MIN_RSSI must be numbers") from None
        if not 0.2 <= every <= 60:
            raise ConfigError("PI_INTERVAL must be between 0.2 and 60 seconds")

        return cls(url=url, key=key, team=team, device_id=device_id, name=name,
                   interval=every, min_rssi=floor)


def ssl_context() -> ssl.SSLContext:
    """TLS context using certifi's roots (some Python builds lack a system CA file)."""
    return ssl.create_default_context(cafile=certifi.where())


def post_row(cfg: Config, payload: dict, kind: str = "batch") -> None:
    """Insert one row into `batches` exactly like the phone's Cloud mode."""
    row = {"team": cfg.team, "phone_id": cfg.device_id, "name": cfg.name,
           "kind": kind, "payload": payload}
    headers = {"Content-Type": "application/json", "Prefer": "return=minimal", "apikey": cfg.key}
    if cfg.key.startswith("eyJ"):  # legacy JWT-style keys also go in Authorization
        headers["Authorization"] = f"Bearer {cfg.key}"
    request = urllib.request.Request(
        f"{cfg.url}/rest/v1/batches",
        data=json.dumps(row, separators=(",", ":")).encode(),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=8, context=ssl_context()) as response:
        response.read()


def error_text(error: Exception) -> str:
    """A short, useful message for an upload failure."""
    if isinstance(error, urllib.error.HTTPError):
        try:
            body = error.read().decode("utf-8", "replace").strip()
        except OSError:
            body = ""
        return f"HTTP {error.code}" + (f": {body[:200]}" if body else "")
    return str(error)


class Uploader:
    """Accumulates BLE readings and turns them into phone-schema batches."""

    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.session_start = time.time()
        self.pending: list[dict] = []
        self.named: set[str] = set()
        self.unnamed: set[str] = set()
        self.sent_batches = 0
        self.sent_samples = 0

    def add(self, address: str, name: str | None, rssi: int, t: float | None = None) -> None:
        """Record one advertisement. `t` is the same monotonic clock as phone samples."""
        address = str(address)
        name = (name or "").strip() or None
        self.pending.append({
            "t": round(time.monotonic() if t is None else t, 3),
            "id": address,
            "name": name,
            "rssi": int(rssi),
        })
        (self.named if name else self.unnamed).add(address)
        if len(self.pending) > PENDING_CAP:
            del self.pending[: len(self.pending) - PENDING_CAP]

    def take(self) -> list[dict]:
        """Hand over the readings to send; new arrivals go into a fresh list."""
        samples, self.pending = self.pending, []
        return samples

    def restore(self, samples: Sequence[dict]) -> None:
        """Put a failed batch back at the front so it goes with the next attempt."""
        self.pending = list(samples) + self.pending
        if len(self.pending) > PENDING_CAP:
            del self.pending[: len(self.pending) - PENDING_CAP]

    def build_batch(self, samples: Sequence[dict]) -> dict:
        return {
            "v": 1,
            "phoneId": self.cfg.device_id,
            "name": self.cfg.name,
            "sentAt": round(time.time(), 3),
            "uptimeAtSend": round(time.monotonic(), 3),
            "sessionStart": round(self.session_start, 3),
            "running": True,
            "screen": "scan",
            "pose": None,
            "poses": [],
            "samples": list(samples),
            "hotSpots": [],
            "missionTarget": None,
            "stats": {"named": len(self.named), "unnamed": len(self.unnamed - self.named)},
        }

    def note_sent(self, count: int) -> None:
        self.sent_batches += 1
        self.sent_samples += count

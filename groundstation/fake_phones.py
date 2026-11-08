"""Pretend to be several phones running BLE Scout, to try the dashboard without real devices.

    uv run python fake_phones.py                 # 3 phones -> http://localhost:8765
    uv run python fake_phones.py --phones 5 --url http://192.168.1.20:8765
    uv run python fake_phones.py --cloud            # through Supabase, like real phones in Cloud mode
                                                    # (uses SUPABASE_URL, SUPABASE_ANON_KEY, TEAM_CODE from .env)
"""

from __future__ import annotations

import argparse
import json
import math
import random
import time
import urllib.request
import uuid

from station.tls import ssl_context

# A fake building: groups of named devices (people) at fixed spots, metres from the start mark.
GROUPS = [
    ((3.0, 6.0), ["AirPods Pro", "Apple Watch", "Galaxy Buds2"]),
    ((-4.0, 3.0), ["JBL Flip 5", "Bose QC45"]),
    ((6.0, 12.0), ["Pixel Buds", "Fitbit Charge 6", "Tile Mate", "Garmin Venu"]),
    ((-3.0, 11.0), ["Kindle"]),
]
NAMES = ["Alex", "Sam", "Jordan", "Riley", "Casey", "Morgan"]


class FakePhone:
    def __init__(self, i: int, seed: int):
        self.rng = random.Random(seed + i)
        self.id = str(uuid.uuid4())
        self.name = NAMES[i % len(NAMES)]
        self.session_start = time.time()
        self.x, self.y, self.heading = 0.0, 0.0, 0.0
        self.target = (self.rng.uniform(-6, 8), self.rng.uniform(0, 14))
        self.pending_poses: list[dict] = []
        self.pending_samples: list[dict] = []
        self.found: dict[int, tuple[float, float]] = {}  # group index -> this phone's estimate
        self.mission = i == 0  # first phone pretends to be on a mission

    def step(self, dt: float, t: float) -> None:
        dx, dy = self.target[0] - self.x, self.target[1] - self.y
        if math.hypot(dx, dy) < 0.4:
            self.target = (self.rng.uniform(-6, 8), self.rng.uniform(0, 14))
        else:
            self.heading = math.atan2(dx, dy)
            self.x += math.sin(self.heading) * 0.7 * dt
            self.y += math.cos(self.heading) * 0.7 * dt
        self.pending_poses.append({"t": t, "x": self.x, "y": self.y, "heading": self.heading})
        for gi, ((gx, gy), names) in enumerate(GROUPS):
            d = math.hypot(gx - self.x, gy - self.y)
            for n in names:
                rssi = -60 - 25 * math.log10(max(d, 0.3)) + self.rng.gauss(0, 4)
                if rssi > -92 and self.rng.random() < 0.3:
                    self.pending_samples.append({"t": t, "id": f"{gi}-{n}", "name": n, "rssi": round(rssi)})
            if d < 4 and gi not in self.found:  # "located" it: estimate with some error
                self.found[gi] = (gx + self.rng.gauss(0, 0.6), gy + self.rng.gauss(0, 0.6))

    def batch(self, t: float) -> dict:
        spots = [{"id": chr(65 + k), "x": round(x, 2), "y": round(y, 2), "count": len(GROUPS[gi][1]),
                  "roughCount": 0, "names": GROUPS[gi][1], "spread": 0.8, "uncertainty": 0.7}
                 for k, (gi, (x, y)) in enumerate(sorted(self.found.items(), key=lambda kv: -len(GROUPS[kv[0]][1])))]
        target = None
        if self.mission and spots:
            target = {"x": spots[0]["x"], "y": spots[0]["y"], "names": spots[0]["names"]}
        b = {
            "v": 1, "phoneId": self.id, "name": self.name,
            "sentAt": time.time(), "uptimeAtSend": t, "sessionStart": self.session_start,
            "running": True, "screen": "mission" if target else "scan",
            "pose": {"t": t, "x": self.x, "y": self.y, "heading": self.heading},
            "poses": self.pending_poses[::5], "samples": self.pending_samples,
            "hotSpots": spots, "missionTarget": target,
            "stats": {"named": len({s["id"] for s in self.pending_samples}) + sum(len(GROUPS[g][1]) for g in self.found), "unnamed": 0},
        }
        self.pending_poses, self.pending_samples = [], []
        return b


def post_cloud(cfg: dict, phone_id: str, name: str, body: dict) -> None:
    """Insert a row exactly like the app does in Cloud mode (public key, insert only)."""
    row = {"team": cfg["team"], "phone_id": phone_id, "name": name, "kind": "batch", "payload": body}
    headers = {"Content-Type": "application/json", "Prefer": "return=minimal", "apikey": cfg["key"]}
    if cfg["key"].startswith("eyJ"):
        headers["Authorization"] = f"Bearer {cfg['key']}"
    req = urllib.request.Request(f"{cfg['url']}/rest/v1/batches", data=json.dumps(row).encode(),
                                 headers=headers, method="POST")
    urllib.request.urlopen(req, timeout=6, context=ssl_context()).read()


def load_env(path: str = ".env") -> dict:
    env = {}
    try:
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return env


def post(url: str, phone_id: str, body: dict) -> None:
    req = urllib.request.Request(f"{url}/api/phone/{phone_id}/batch", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    urllib.request.urlopen(req, timeout=3).read()


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--url", default="http://localhost:8765")
    p.add_argument("--phones", type=int, default=3)
    p.add_argument("--seconds", type=float, default=0, help="stop after this long (0 = until Ctrl-C)")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--cloud", action="store_true", help="send through Supabase instead of straight to the station")
    args = p.parse_args()
    cloud = None
    if args.cloud:
        env = load_env()
        cloud = {"url": env.get("SUPABASE_URL", "").rstrip("/"), "key": env.get("SUPABASE_ANON_KEY", ""),
                 "team": env.get("TEAM_CODE", "TEAM9").upper()}
        if not cloud["url"] or not cloud["key"]:
            raise SystemExit("--cloud needs SUPABASE_URL and SUPABASE_ANON_KEY in .env")

    phones = [FakePhone(i, args.seed) for i in range(args.phones)]
    print(f"Simulating {len(phones)} phones -> {'Supabase team ' + cloud['team'] if cloud else args.url}  (Ctrl-C to stop)", flush=True)
    t, start = 0.0, time.time()
    try:
        while not args.seconds or time.time() - start < args.seconds:
            for _ in range(20):  # 2 s of walking at 10 Hz
                t += 0.1
                for ph in phones:
                    ph.step(0.1, t)
                time.sleep(0.1)
            for ph in phones:
                try:
                    if cloud:
                        post_cloud(cloud, ph.id, ph.name, ph.batch(t))
                    else:
                        post(args.url, ph.id, ph.batch(t))
                except OSError as e:
                    print(f"  {ph.name}: can't reach ground station ({e})", flush=True)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

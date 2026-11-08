"""Ground station server: phones POST batches of their scan; the dashboard polls the merged state.

Phone batch (JSON, schema v1), sent every ~2 s while a phone is scanning:
    {
      "v": 1, "phoneId": "...", "name": "Evana",
      "sentAt": <unix time>, "uptimeAtSend": <phone uptime>,   # converts phone times to wall clock
      "sessionStart": <unix time the phone pressed Start>,     # changes => new scan on that phone
      "running": true, "screen": "scan" | "mission",
      "pose": {"t", "x", "y", "heading"} | null,               # latest position
      "poses":   [{"t", "x", "y", "heading"}, ...],             # new since last batch (downsampled)
      "samples": [{"t", "id", "name", "rssi"}, ...],            # new raw Bluetooth readings
      "hotSpots": [{"id", "x", "y", "count", "roughCount", "names", "spread", "uncertainty"}, ...],
      "missionTarget": {"x", "y", "names"} | null,
      "stats": {"named": n, "unnamed": m}
    }
Coordinates are metres relative to where that phone pressed Start (+x right, +y ahead).
Phase 1 assumes every phone started on the same mark facing the same way.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path

from aiohttp import web

STATIC = Path(__file__).with_name("static")
PALETTE = ["#3d9bff", "#ff8a3d", "#3ecf8e", "#c77dff", "#ffd23d", "#ff5a8a", "#4dd6d6", "#a0d911"]
OFFLINE_AFTER_S = 8.0
MAX_PATH = 6000


@dataclass
class Phone:
    id: str
    name: str
    color: str
    session_start: float | None = None
    last_seen: float = 0.0
    running: bool = False
    screen: str = "scan"
    pose: dict | None = None
    path: list[dict] = field(default_factory=list)
    hot_spots: list = field(default_factory=list)
    mission_target: dict | None = None
    stats: dict = field(default_factory=dict)
    samples_received: int = 0
    batches: int = 0

    def summary(self, now: float) -> dict:
        step = max(1, len(self.path) // 800)  # keep the dashboard payload small
        return {
            "id": self.id, "name": self.name, "color": self.color,
            "online": now - self.last_seen < OFFLINE_AFTER_S,
            "lastSeenAgo": round(now - self.last_seen, 1) if self.last_seen else None,
            "running": self.running, "screen": self.screen,
            "pose": self.pose,
            "path": [[round(p["x"], 2), round(p["y"], 2)] for p in self.path[::step]],
            "hotSpots": self.hot_spots,
            "missionTarget": self.mission_target,
            "stats": self.stats,
            "samplesReceived": self.samples_received,
            "batches": self.batches,
        }


class Station:
    def __init__(self, data_dir: Path):
        self.phones: dict[str, Phone] = {}
        self.started = time.time()
        self.data_dir = data_dir
        self.session_dir = data_dir / time.strftime("session-%Y%m%d-%H%M%S")
        self.url = ""
        self.team = ""          # set when pulling from the Supabase relay
        self.relays: list[dict] = []  # signal relays (phone -> phone -> ... -> rescuer), oldest first
        self.dispatches: dict[str, dict] = {}  # rescuer phone id -> target the ground station sent it to
        self.cleared: list[dict] = []          # targets tagged by a rescuer: {names, x, y, by, at}
        self.held_spots: list[dict] = []       # big hot spots (7+ signals) kept on the map once seen

    def ingest(self, batch: dict) -> Phone:
        pid = str(batch.get("phoneId") or "").strip()
        if not pid:
            raise web.HTTPBadRequest(text="phoneId missing")
        now = time.time()
        phone = self.phones.get(pid)
        if phone is None:
            phone = Phone(pid, "", PALETTE[len(self.phones) % len(PALETTE)])
            self.phones[pid] = phone
        phone.name = str(batch.get("name") or phone.name or f"Phone {pid[:4]}")[:40]

        start = batch.get("sessionStart")
        if start != phone.session_start:  # that phone began a new scan
            phone.session_start = start
            phone.path = []
            phone.hot_spots = []

        phone.last_seen = now
        phone.batches += 1
        phone.running = bool(batch.get("running", True))
        phone.screen = str(batch.get("screen") or "scan")
        if batch.get("pose"):
            phone.pose = batch["pose"]
        phone.path.extend(p for p in batch.get("poses") or [] if "x" in p and "y" in p)
        if len(phone.path) > MAX_PATH:
            phone.path = phone.path[-MAX_PATH:]
        if "hotSpots" in batch:
            phone.hot_spots = batch.get("hotSpots") or []
            self.hold_big_spots(phone)
        phone.mission_target = batch.get("missionTarget")
        phone.stats = batch.get("stats") or {}
        phone.samples_received += len(batch.get("samples") or [])

        self.record(pid, batch, now)
        return phone

    def record(self, pid: str, batch: dict, received: float) -> None:
        """Keep every raw batch on disk (one JSON line each) for the shared analysis later."""
        self.session_dir.mkdir(parents=True, exist_ok=True)
        safe = "".join(c for c in pid if c.isalnum() or c in "-_")[:64] or "phone"
        with open(self.session_dir / f"{safe}.jsonl", "a") as f:
            f.write(json.dumps({"receivedAt": received, **batch}, separators=(",", ":")) + "\n")

    # ---- big hot spots stay on the map; tagged targets are marked rescued -------------------

    HELD_MIN = 7  # "more than 6 signals"

    @staticmethod
    def _same_place(a: dict, b: dict) -> bool:
        shared = set(a.get("names") or []) & set(b.get("names") or [])
        return len(shared) >= 2 or ((a["x"] - b["x"]) ** 2 + (a["y"] - b["y"]) ** 2) ** 0.5 < 2.0

    def is_cleared(self, spot: dict) -> dict | None:
        """Has a rescuer tagged this? Same signal (label), same spot (< 2 m), or nearby (< 3 m) and
        sharing a device name. One shared name elsewhere on the map doesn't count (hot-spot
        tags can list dozens of names)."""
        for c in self.cleared:
            if c.get("x") is None or spot.get("x") is None:
                continue
            d = ((spot["x"] - c["x"]) ** 2 + (spot["y"] - c["y"]) ** 2) ** 0.5
            shared = set(spot.get("names") or []) & set(c["names"])
            if (spot.get("label") and spot["label"] == c.get("label")) or d < 2.0 or (shared and d < 3.0):
                return c
        return None

    def hold_big_spots(self, phone: "Phone") -> None:
        for h in phone.hot_spots:
            if (h.get("count") or 0) < self.HELD_MIN:
                continue
            match = next((s for s in self.held_spots if self._same_place(s, h)), None)
            if match is None:
                self.held_spots.append({"x": h["x"], "y": h["y"], "count": h["count"], "names": list(h.get("names") or []),
                                        "spread": h.get("spread", 1.0), "uncertainty": h.get("uncertainty", 1.0),
                                        "seenBy": [phone.name], "color": phone.color})
            else:  # latest position, everything ever seen there
                match.update(x=h["x"], y=h["y"], count=max(match["count"], h["count"]),
                             names=sorted(set(match["names"]) | set(h.get("names") or [])),
                             spread=max(match["spread"], h.get("spread", 1.0)))
                if phone.name not in match["seenBy"]:
                    match["seenBy"].append(phone.name)

    def add_relay(self, row: dict) -> None:
        row = {**row, "receivedAt": time.time()}
        if row.get("kind") == "cleared":
            names = list(row.get("target_names") or [row.get("target_name")])
            self.cleared.append({"names": names, "label": row.get("target_name"), "x": row.get("target_x"),
                                 "y": row.get("target_y"), "by": row.get("from_name") or "a rescuer",
                                 "at": row["receivedAt"]})
            print(f"  {time.strftime('%H:%M:%S')}  tagged: '{row.get('target_name')}' cleared by "
                  f"{row.get('from_name')}", flush=True)
        self.relays.append(row)
        self.relays = self.relays[-200:]
        self.record("_relays", row, row["receivedAt"])

    def relay_chains(self, now: float) -> list[dict]:
        """Newest relay per signal: its full chain of hops, for drawing."""
        latest: dict[str, dict] = {}
        for r in self.relays:
            if r.get("kind") in ("dispatch", "cleared"):
                continue
            latest[r.get("target_name", "?")] = r
        # a tagged target's relay chain is done: drop it from the map
        latest = {k: r for k, r in latest.items()
                  if not self.is_cleared({"label": k, "names": r.get("target_names") or [k],
                                          "x": r.get("target_x"), "y": r.get("target_y")})}
        return [{"target": k, "kind": r.get("kind", "relay"), "x": r.get("target_x"), "y": r.get("target_y"), "radius": r.get("target_radius"),
                 "chain": r.get("chain") or [], "hops": r.get("hop", 0), "ago": round(now - r["receivedAt"], 1)}
                for k, r in latest.items()]

    def state(self) -> dict:
        now = time.time()
        return {
            "relays": [r for r in self.relay_chains(now) if r.get("kind", "relay") != "dispatch"],
            "dispatches": [{**d, "ago": round(now - d["at"])} for d in self.dispatches.values() if not self.is_cleared(d)],
            "cleared": [{**c, "ago": round(now - c["at"])} for c in self.cleared],
            "heldSpots": [{**h, "rescued": bool(self.is_cleared(h))} for h in self.held_spots],
            "cloud": bool(self.team),
            "url": self.url,
            "team": self.team,
            "sessionDir": str(self.session_dir),
            "uptime": round(now - self.started),
            "phones": [p.summary(now) for p in self.phones.values()],
        }

    def reset(self) -> None:
        self.phones = {}
        self.relays = []
        self.dispatches = {}
        self.cleared = []
        self.held_spots = []
        self.session_dir = self.data_dir / time.strftime("session-%Y%m%d-%H%M%S")


def build_app(station: Station) -> web.Application:
    routes = web.RouteTableDef()

    @routes.get("/")
    async def dashboard(_):
        return web.FileResponse(STATIC / "dashboard.html")

    @routes.get("/api/ping")
    async def ping(_):
        return web.json_response({"ok": True, "service": "blescout-groundstation", "v": 1})

    @routes.get("/api/state")
    async def state(_):
        return web.json_response(station.state())

    @routes.post("/api/phone/{pid}/batch")
    async def batch(req):
        try:
            body = await req.json()
        except json.JSONDecodeError:
            raise web.HTTPBadRequest(text="invalid JSON")
        body.setdefault("phoneId", req.match_info["pid"])
        phone = station.ingest(body)
        return web.json_response({"ok": True, "color": phone.color, "phones": len(station.phones)})

    @routes.post("/api/dispatch")
    async def dispatch(req):
        """Send one phone (the rescuer) to a target: written to Supabase for that phone to pick up."""
        cfg = req.app.get("cloud_cfg")
        if cfg is None:
            raise web.HTTPServiceUnavailable(text="Dispatch needs the cloud relay (groundstation/.env).")
        b = await req.json()
        phone = station.phones.get(str(b.get("phoneId", "")))
        t = b.get("target") or {}
        if phone is None or "x" not in t or "y" not in t:
            raise web.HTTPBadRequest(text="need phoneId and target {x, y, names}")
        names = [str(n) for n in (t.get("names") or [])][:12] or ["Target"]
        row = {"team": cfg.team, "from_phone": "ground-station", "from_name": "Ground station",
               "target_name": names[0][:80], "target_names": names,
               "target_x": float(t["x"]), "target_y": float(t["y"]),
               "target_radius": float(t.get("radius") or 1.5), "hop": 0, "chain": [],
               "kind": "dispatch", "to_phone": phone.id}
        from .cloud import insert_relay  # local import: cloud imports this module
        try:
            await insert_relay(cfg, row)
        except Exception as e:
            raise web.HTTPBadGateway(text=f"{e}. Has the dispatch SQL (kind/to_phone/target_names) been run?")
        station.dispatches[phone.id] = {"phoneId": phone.id, "phone": phone.name, "x": row["target_x"],
                                        "y": row["target_y"], "names": names, "at": time.time()}
        print(f"  {time.strftime('%H:%M:%S')}  dispatch: '{phone.name}' sent to {', '.join(names[:3])}", flush=True)
        return web.json_response({"ok": True})

    @routes.post("/api/reset")
    async def reset(_):
        station.reset()
        return web.json_response({"ok": True})

    seen_clients: set[str] = set()

    @web.middleware
    async def log_requests(req, handler):
        # Show phone traffic in the terminal so connection problems are easy to spot.
        # (Dashboard polling from this Mac is left out to keep the log readable.)
        ip = req.remote or "?"
        local = ip in ("127.0.0.1", "::1")
        try:
            resp = await handler(req)
        except web.HTTPException as e:
            if not local:
                print(f"  {time.strftime('%H:%M:%S')}  {ip}  {req.method} {req.path} -> {e.status}", flush=True)
            raise
        if not local:
            if req.path.endswith("/batch"):
                pid = req.match_info.get("pid", "")
                phone = station.phones.get(pid)
                if ip not in seen_clients or (phone and phone.batches % 15 == 1):
                    print(f"  {time.strftime('%H:%M:%S')}  {ip}  batch from '{phone.name if phone else pid}'"
                          f" (#{phone.batches if phone else '?'}, {phone.samples_received if phone else 0} readings so far)", flush=True)
            else:
                print(f"  {time.strftime('%H:%M:%S')}  {ip}  {req.method} {req.path}", flush=True)
            seen_clients.add(ip)
        return resp

    app = web.Application(client_max_size=8 * 1024 * 1024, middlewares=[log_requests])
    app.add_routes(routes)
    return app

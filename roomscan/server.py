"""Web server: operator console (this laptop) + team pages (rescuers' phones)."""

from __future__ import annotations

import asyncio
import json
import secrets
import time
from dataclasses import asdict
from pathlib import Path

from aiohttp import web

from .analysis import Params, analyze
from .pacer import Pacer
from .sensing import Sample, SimDevice, Track, ble_scan, serpentine, sim_devices, sim_follow

STATIC = Path(__file__).with_name("static")
MEMBER_STATES = {"available", "en_route", "arrived", "cleared", "need_help"}


class Session:
    def __init__(self, simulate: bool, sim_speed: float, save_dir: Path):
        self.simulate, self.save_dir = simulate, save_dir
        self.speed = sim_speed  # pacer walking speed, m/s
        self.pacer: Pacer | None = None
        self.params = Params()
        self.width, self.length, self.lane = 8.0, 6.0, 1.5
        self.waypoints = serpentine(self.width, self.length, self.lane)
        self.phase = "setup"  # setup -> scanning -> done
        self.track = Track()
        self.samples: list[Sample] = []
        self.result: dict | None = None
        self.started_at: float | None = None
        self.saved_to: str | None = None
        self._stop = asyncio.Event()
        self._tasks: list[asyncio.Task] = []
        self.sim_truth: list[SimDevice] = []
        self.scan_error: str | None = None
        self.team: dict[str, dict] = {}
        self.cluster_state: dict[str, str] = {}  # cluster id -> "open" | "assigned" | "cleared"

    # -- survey ---------------------------------------------------------------- #

    def setup(self, width: float, length: float, lane: float) -> None:
        if self.phase == "scanning":
            raise web.HTTPConflict(text="stop the scan first")
        self.width, self.length, self.lane = width, length, lane
        self.waypoints = serpentine(width, length, lane)
        self.phase, self.track, self.samples, self.result = "setup", Track(), [], None
        self.cluster_state = {}
        for m in self.team.values():
            m.update(assigned=None, status="available")

    async def start(self) -> None:
        if self.phase == "scanning":
            return
        self.track, self.samples, self.result, self.saved_to, self.scan_error = Track(), [], None, None, None
        self._stop = asyncio.Event()
        self.phase, self.started_at = "scanning", time.time()
        self.pacer = Pacer(self.waypoints, self.track, speed=self.speed)
        self.pacer.start(time.time())
        if self.simulate:
            self.sim_truth = sim_devices(self.width, self.length)
            scanner = sim_follow(self.pacer._live_d, self.pacer.path.point_at, self.sim_truth,
                                 self.samples.append, self._stop)
        else:
            scanner = self._ble()
        self._tasks = [asyncio.create_task(c) for c in (scanner, self._pace(), self._live_analysis())]

    async def _ble(self) -> None:
        try:
            await ble_scan(self.samples.append, self._stop)
        except Exception as e:  # e.g. Bluetooth permission denied
            self.scan_error = f"{type(e).__name__}: {e}"

    async def _pace(self) -> None:
        while not self._stop.is_set():
            await asyncio.sleep(0.2)
            self.pacer.tick(time.time())
            if self.pacer.done:
                await self.finish()

    async def _live_analysis(self) -> None:
        while not self._stop.is_set():
            await asyncio.sleep(2.0)
            await self.run_analysis()

    async def run_analysis(self) -> None:
        if len(self.track.times) < 2:
            return
        # snapshot: the pacer keeps editing the live track while analysis runs in a thread
        samples, track = list(self.samples), Track()
        track.times, track.points = list(self.track.times), list(self.track.points)
        self.result = await asyncio.get_running_loop().run_in_executor(
            None, analyze, samples, track, self.width, self.length, self.params)
        for c in self.result["clusters"]:
            self.cluster_state.setdefault(c["id"], "open")

    def pacer_action(self, action: str, x: float | None = None, y: float | None = None,
                     speed: float | None = None) -> None:
        if self.phase != "scanning" or self.pacer is None:
            raise web.HTTPConflict(text="not scanning")
        now = time.time()
        if action == "at_waypoint":
            self.pacer.at_waypoint(now)
        elif action == "at_point" and x is not None and y is not None:
            self.pacer.at_point(now, x, y)
        elif action == "pause":
            self.pacer.pause(now)
        elif action == "resume":
            self.pacer.resume(now)
        elif action == "speed" and speed is not None:
            self.pacer.set_speed(speed)
            self.speed = self.pacer.speed
        else:
            raise web.HTTPBadRequest(text=f"bad pacer action {action!r}")

    async def finish(self) -> None:
        if self.phase != "scanning":
            return
        if self.pacer and not self.pacer.done:
            self.pacer.pause(time.time())  # pin the last stretch of the walk with an anchor
        self._stop.set()
        self.phase = "done"
        await self.run_analysis()
        self.cluster_state = {c["id"]: "open" for c in (self.result or {}).get("clusters", [])}
        self.saved_to = str(self.save())

    def save(self) -> Path:
        self.save_dir.mkdir(parents=True, exist_ok=True)
        path = self.save_dir / time.strftime("scan-%Y%m%d-%H%M%S.json")
        path.write_text(json.dumps({
            "room": {"width": self.width, "length": self.length, "lane": self.lane},
            "simulated": self.simulate,
            "track": self.track.to_json(),
            "samples": [asdict(s) for s in self.samples],
        }))
        return path

    def load(self, path: Path) -> None:
        data = json.loads(path.read_text())
        r = data["room"]
        self.setup(r["width"], r["length"], r.get("lane", 1.5))
        for m in data["track"]:
            self.track.mark(m["t"], m["x"], m["y"])
        self.samples = [Sample(**s) for s in data["samples"]]
        self.phase, self.saved_to = "done", str(path)
        self.result = analyze(self.samples, self.track, self.width, self.length, self.params)
        self.cluster_state = {c["id"]: "open" for c in self.result["clusters"]}

    # -- team ------------------------------------------------------------------ #

    def clusters(self) -> list[dict]:
        return [{**c, "state": self.cluster_state.get(c["id"], "open"),
                 "assignee": next((m["name"] for m in self.team.values() if m["assigned"] == c["id"]), None)}
                for c in (self.result or {}).get("clusters", [])]

    def assign(self, member_id: str, cluster_id: str | None) -> None:
        m = self.team.get(member_id)
        if m is None:
            raise web.HTTPNotFound(text="unknown team member")
        if m["assigned"] and self.cluster_state.get(m["assigned"]) == "assigned":
            self.cluster_state[m["assigned"]] = "open"
        m["assigned"], m["status"] = cluster_id, "en_route" if cluster_id else "available"
        m["assigned_at"] = time.time()
        if cluster_id:
            self.cluster_state[cluster_id] = "assigned"

    def auto_assign(self) -> None:
        """Biggest open clusters first, to whoever is free."""
        open_clusters = [c["id"] for c in self.clusters() if c["state"] == "open"]
        free = [mid for mid, m in self.team.items() if not m["assigned"] and m["status"] != "need_help"]
        for mid, cid in zip(free, open_clusters):
            self.assign(mid, cid)

    def member_status(self, member_id: str, status: str) -> None:
        m = self.team.get(member_id)
        if m is None or status not in MEMBER_STATES:
            raise web.HTTPBadRequest(text="bad member or status")
        m["status"], m["seen"] = status, time.time()
        if status == "cleared" and m["assigned"]:
            self.cluster_state[m["assigned"]] = "cleared"
            m["assigned"], m["status"] = None, "available"
            self.auto_assign()  # hand them the next cluster straight away

    # -- snapshot -------------------------------------------------------------- #

    def nearby(self, window_s: float = 3.0) -> list[dict]:
        """Loudest devices in the last few seconds, i.e. what's close to you right now."""
        if self.phase != "scanning":
            return []
        cutoff, best = time.time() - window_s, {}
        for s in reversed(self.samples):
            if s.t < cutoff:
                break
            if s.device not in best or s.rssi > best[s.device]["rssi"]:
                best[s.device] = {"id": s.device, "name": s.name, "rssi": s.rssi}
        return sorted(best.values(), key=lambda d: -d["rssi"])[:6]

    def state(self) -> dict:
        devs = {s.device for s in self.samples}
        return {
            "phase": self.phase, "simulate": self.simulate, "scan_error": self.scan_error,
            "room": {"width": self.width, "length": self.length, "lane": self.lane},
            "waypoints": self.waypoints,
            "marks": self.track.to_json() if self.phase != "scanning" else self.track.to_json()[-400:],
            "anchors": [{"x": round(a.xy[0], 2), "y": round(a.xy[1], 2)}
                        for a in (self.pacer.anchors if self.pacer else [])],
            "pacer": self.pacer.state(time.time()) if self.pacer and self.phase == "scanning" else None,
            "speed": self.speed,
            "nearby": self.nearby(),
            "elapsed": round(time.time() - self.started_at, 1) if self.started_at and self.phase == "scanning" else None,
            "samples": len(self.samples), "devices_heard": len(devs),
            "result": self.result and {k: v for k, v in self.result.items() if k != "clusters"},
            "clusters": self.clusters(),
            "team": [{"id": k, **v} for k, v in self.team.items()],
            "saved_to": self.saved_to,
            "sim_truth": [asdict(d) for d in self.sim_truth if not d.carried] if self.simulate else [],
        }


def build_app(session: Session, team_url: str) -> web.Application:
    routes = web.RouteTableDef()

    async def body(req) -> dict:
        try:
            return await req.json()
        except json.JSONDecodeError:
            return {}

    @routes.get("/")
    async def operator(_):
        return web.FileResponse(STATIC / "operator.html")

    @routes.get("/team")
    async def team_page(_):
        return web.FileResponse(STATIC / "team.html")

    @routes.get("/api/state")
    async def state(_):
        return web.json_response({**session.state(), "team_url": team_url})

    @routes.get("/api/qr.svg")
    async def qr(_):
        import segno

        return web.Response(text=segno.make(team_url).svg_inline(scale=5, dark="#111", light="#fff", omitsize=True),
                            content_type="image/svg+xml")

    @routes.post("/api/setup")
    async def setup(req):
        b = await body(req)
        session.setup(float(b["width"]), float(b["length"]), float(b.get("lane", 1.5)))
        if b.get("speed"):
            session.speed = min(max(float(b["speed"]), 0.1), 2.0)
        return web.json_response({"ok": True})

    @routes.post("/api/start")
    async def start(_):
        await session.start()
        return web.json_response({"ok": True})

    @routes.post("/api/pacer")
    async def pacer(req):
        b = await body(req)
        f = lambda k: float(b[k]) if b.get(k) is not None else None  # noqa: E731
        session.pacer_action(str(b.get("action")), f("x"), f("y"), f("speed"))
        return web.json_response({"ok": True})

    @routes.post("/api/finish")
    async def finish(_):
        await session.finish()
        return web.json_response({"ok": True})

    @routes.post("/api/params")
    async def params(req):
        b = await body(req)
        for k in ("n", "link_m"):
            if k in b:
                setattr(session.params, k, float(b[k]))
        if session.phase == "done":
            await session.run_analysis()
        return web.json_response({"ok": True})

    @routes.post("/api/assign")
    async def assign(req):
        b = await body(req)
        session.assign(b["member"], b.get("cluster") or None)
        return web.json_response({"ok": True})

    @routes.post("/api/auto-assign")
    async def auto(_):
        session.auto_assign()
        return web.json_response({"ok": True})

    @routes.post("/api/team/join")
    async def join(req):
        name = str((await body(req)).get("name", "")).strip()[:40] or "Rescuer"
        mid = secrets.token_urlsafe(6)
        session.team[mid] = {"name": name, "status": "available", "assigned": None, "seen": time.time()}
        return web.json_response({"id": mid})

    @routes.get("/api/team/{mid}")
    async def me(req):
        m = session.team.get(req.match_info["mid"])
        if m is None:
            raise web.HTTPNotFound(text="unknown team member")
        m["seen"] = time.time()
        cluster = next((c for c in session.clusters() if c["id"] == m["assigned"]), None)
        return web.json_response({"me": m, "cluster": cluster, "room": session.state()["room"],
                                  "clusters": session.clusters()})

    @routes.post("/api/team/{mid}/status")
    async def status(req):
        session.member_status(req.match_info["mid"], (await body(req)).get("status", ""))
        return web.json_response({"ok": True})

    app = web.Application()
    app.add_routes(routes)
    return app

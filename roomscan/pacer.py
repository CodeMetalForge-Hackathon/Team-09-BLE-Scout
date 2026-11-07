"""Pacer: a dot that moves along the walk path at a set speed. You keep up
with it, and its position is taken as yours, so you can walk without pressing
anything.

Corrections ("I'm at point 7", or a click on the map) become *anchors*. When
one arrives, the positions recorded since the previous anchor are rewritten
as if you'd walked steadily along the path between the two anchors. So if
you fell behind the dot, the map fixes itself once you correct.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from .sensing import Track


class PathGeom:
    def __init__(self, waypoints: list[tuple[float, float]]):
        self.pts = waypoints
        self.cum = [0.0]
        for a, b in zip(waypoints, waypoints[1:]):
            self.cum.append(self.cum[-1] + math.dist(a, b))
        self.total = self.cum[-1]

    def point_at(self, d: float) -> tuple[float, float]:
        d = min(max(d, 0.0), self.total)
        for i in range(1, len(self.pts)):
            if d <= self.cum[i] or i == len(self.pts) - 1:
                seg = self.cum[i] - self.cum[i - 1]
                f = 0.0 if seg == 0 else (d - self.cum[i - 1]) / seg
                (x0, y0), (x1, y1) = self.pts[i - 1], self.pts[i]
                return (x0 + f * (x1 - x0), y0 + f * (y1 - y0))
        return self.pts[0]

    def project(self, x: float, y: float) -> float:
        """Path distance of the point on the path closest to (x, y)."""
        best, best_d = math.inf, 0.0
        for i in range(1, len(self.pts)):
            (x0, y0), (x1, y1) = self.pts[i - 1], self.pts[i]
            dx, dy = x1 - x0, y1 - y0
            seg2 = dx * dx + dy * dy
            f = 0.0 if seg2 == 0 else max(0.0, min(1.0, ((x - x0) * dx + (y - y0) * dy) / seg2))
            px, py = x0 + f * dx, y0 + f * dy
            dist = math.hypot(x - px, y - py)
            if dist < best:
                best, best_d = dist, self.cum[i - 1] + f * math.sqrt(seg2)
        return best_d

    def nearest_waypoint(self, d: float) -> int:
        return min(range(len(self.cum)), key=lambda i: abs(self.cum[i] - d))

    def waypoints_passed(self, d: float) -> int:
        return sum(1 for c in self.cum if c <= d + 1e-9)


@dataclass
class Anchor:
    t: float
    d: float  # path distance
    xy: tuple[float, float]


class Pacer:
    TICK_MARK_S = 0.5  # how often a provisional position is recorded

    def __init__(self, waypoints, track: Track, speed: float = 0.5, countdown: float = 3.0):
        self.path = PathGeom(waypoints)
        self.track = track
        self.speed = speed
        self.countdown = countdown
        self.t_go = 0.0
        self.d = 0.0
        self.paused = False
        self.done = False
        self.anchors: list[Anchor] = []
        self.provisional: list[float] = []  # times of marks recorded since the last anchor
        self._last_tick = 0.0
        self._last_mark = -math.inf

    # -- lifecycle --------------------------------------------------------- #

    def start(self, t: float) -> None:
        self.t_go = t + self.countdown
        self._last_tick = self.t_go
        self._anchor(t, 0.0, self.path.pts[0])
        self._anchor(self.t_go, 0.0, self.path.pts[0])  # you wait at point 1 during the countdown

    def tick(self, t: float) -> None:
        if self.done or t < self.t_go:
            return
        if not self.paused:
            self.d = min(self.d + self.speed * (t - self._last_tick), self.path.total)
        self._last_tick = t
        if t - self._last_mark >= self.TICK_MARK_S:
            self.track.mark(t, *self.path.point_at(self.d))
            self.provisional.append(t)
            self._last_mark = t
        if self.d >= self.path.total:
            self._anchor(t, self.d, self.path.point_at(self.d))
            self.done = True

    # -- user input -------------------------------------------------------- #

    def at_waypoint(self, t: float) -> int:
        """'I'm at a waypoint right now': snap to the one nearest the dot."""
        if t < self.t_go:
            return 0
        i = self.path.nearest_waypoint(self._live_d(t))
        self._anchor(t, self.path.cum[i], self.path.pts[i])
        return i

    def at_point(self, t: float, x: float, y: float) -> None:
        """'I'm here' (clicked on the map); the dot continues from the nearest path spot."""
        if t < self.t_go:
            return
        self._anchor(t, self.path.project(x, y), (x, y))

    def pause(self, t: float) -> None:
        if not self.paused and t >= self.t_go:
            self._anchor(t, self._live_d(t), self.path.point_at(self._live_d(t)))
            self.paused = True

    def resume(self, t: float) -> None:
        if self.paused:
            self._anchor(t, self.d, self.path.point_at(self.d))
            self.paused = False

    def set_speed(self, speed: float) -> None:
        self.speed = min(max(speed, 0.1), 2.0)

    # -- internals --------------------------------------------------------- #

    def _live_d(self, t: float) -> float:
        if self.paused or t < self.t_go:
            return self.d
        return min(self.d + self.speed * max(0.0, t - self._last_tick), self.path.total)

    def _anchor(self, t: float, d: float, xy: tuple[float, float]) -> None:
        prev = self.anchors[-1] if self.anchors else None
        if prev is not None:
            # Rewrite everything since the previous anchor as steady progress along the path.
            self.track.remove_after(prev.t)
            span = t - prev.t
            for tp in self.provisional:
                if prev.t < tp < t and span > 0:
                    dp = prev.d + (d - prev.d) * (tp - prev.t) / span
                    self.track.mark(tp, *self.path.point_at(dp))
        self.track.mark(t, *xy)
        self.anchors.append(Anchor(t, d, xy))
        self.provisional = []
        self.d = d
        self._last_tick = max(t, self.t_go)
        self._last_mark = t

    def state(self, t: float) -> dict:
        d = self._live_d(t)
        x, y = self.path.point_at(d)
        return {
            "x": round(x, 2), "y": round(y, 2), "d": round(d, 2), "total": round(self.path.total, 2),
            "speed": self.speed, "paused": self.paused, "done": self.done,
            "countdown": max(0.0, round(self.t_go - t, 1)),
            "next_waypoint": min(self.path.waypoints_passed(d), len(self.path.pts) - 1),
            "eta_s": round((self.path.total - d) / self.speed) if self.speed else None,
        }

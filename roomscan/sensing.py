"""Where the laptop was (walk path) and what it heard (Bluetooth samples).

Room coordinates, in metres: the origin is the corner by the door, x runs
along the wall to your right, y runs straight into the room.
"""

from __future__ import annotations

import asyncio
import bisect
import math
import random
import time
from dataclasses import dataclass
from typing import Callable


@dataclass
class Sample:
    t: float
    device: str  # MAC (Linux/Windows) or per-Mac UUID (macOS)
    name: str | None
    rssi: int


# --------------------------------------------------------------------------- #
# Walk path
# --------------------------------------------------------------------------- #


def serpentine(width: float, length: float, lane: float = 1.5, step: float = 2.5) -> list[tuple[float, float]]:
    """Lawn-mower path covering the room. Extra waypoints every `step` metres
    along each lane keep the position estimate honest if your pace varies."""
    margin = min(0.5, width / 4, length / 4)
    n_lanes = max(1, math.ceil((width - 2 * margin) / lane) + 1)
    xs = [margin + i * (width - 2 * margin) / max(n_lanes - 1, 1) for i in range(n_lanes)]
    y0, y1 = margin, length - margin
    n_steps = max(1, math.ceil((y1 - y0) / step))
    ys = [y0 + i * (y1 - y0) / n_steps for i in range(n_steps + 1)]
    pts = []
    for i, x in enumerate(xs):
        for y in ys if i % 2 == 0 else reversed(ys):
            pts.append((round(x, 2), round(y, 2)))
    return pts


class Track:
    """Timestamped 'I am here' marks. Position at any moment in between is
    linearly interpolated, which assumes you walk steadily between marks."""

    def __init__(self) -> None:
        self.times: list[float] = []
        self.points: list[tuple[float, float]] = []

    def mark(self, t: float, x: float, y: float) -> None:
        i = bisect.bisect(self.times, t)
        self.times.insert(i, t)
        self.points.insert(i, (x, y))

    def position_at(self, t: float) -> tuple[float, float] | None:
        if len(self.times) < 2 or t < self.times[0] or t > self.times[-1]:
            return None
        i = max(1, bisect.bisect_left(self.times, t))
        t0, t1 = self.times[i - 1], self.times[i]
        (x0, y0), (x1, y1) = self.points[i - 1], self.points[i]
        f = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
        return (x0 + f * (x1 - x0), y0 + f * (y1 - y0))

    def remove_after(self, t: float) -> None:
        """Drop every mark later than t (used when a correction rewrites history)."""
        i = bisect.bisect_right(self.times, t)
        del self.times[i:], self.points[i:]

    def to_json(self) -> list[dict]:
        return [{"t": t, "x": p[0], "y": p[1]} for t, p in zip(self.times, self.points)]


# --------------------------------------------------------------------------- #
# Real Bluetooth
# --------------------------------------------------------------------------- #


async def ble_scan(on_sample: Callable[[Sample], None], stop: asyncio.Event) -> None:
    from bleak import BleakScanner

    def on_advert(device, adv) -> None:
        on_sample(Sample(time.time(), device.address, adv.local_name or device.name, adv.rssi))

    async with BleakScanner(detection_callback=on_advert):
        await stop.wait()


# --------------------------------------------------------------------------- #
# Simulation: fake room, fake devices, a fake walker following the path
# --------------------------------------------------------------------------- #

P0 = -59.0  # typical RSSI at 1 m
PATH_LOSS_N = 2.5


def rssi_at(d: float, p0: float = P0, n: float = PATH_LOSS_N) -> float:
    return p0 - 10 * n * math.log10(max(d, 0.3))


@dataclass
class SimDevice:
    id: str
    name: str | None
    x: float
    y: float
    p0: float
    carried: bool = False  # moves with the walker (e.g. your own earbuds)


def sim_devices(width: float, length: float, seed: int = 7) -> list[SimDevice]:
    """Three groups of people-with-devices, one loner, plus your own earbuds."""
    rng = random.Random(seed)
    groups = [  # (centre as fraction of room, number of devices, spread m)
        ((0.25, 0.75), 6, 0.6),
        ((0.75, 0.25), 3, 0.4),
        ((0.8, 0.85), 1, 0.0),
    ]
    devs = []
    for g, ((fx, fy), count, spread) in enumerate(groups):
        for i in range(count):
            devs.append(SimDevice(
                f"SIM-{g}{i}", rng.choice(["iPhone", "Watch", "AirPods", None, None]),
                fx * width + rng.gauss(0, spread), fy * length + rng.gauss(0, spread),
                rng.uniform(-64, -54),
            ))
    devs.append(SimDevice("SIM-ME", "My Earbuds", 0, 0, -50, carried=True))
    return devs


async def sim_follow(
    dot_distance: Callable[[float], float],
    point_at: Callable[[float], tuple[float, float]],
    devices: list[SimDevice],
    on_sample: Callable[[Sample], None],
    stop: asyncio.Event,
    noise_db: float = 4.0,
    adv_hz: float = 3.0,
) -> None:
    """A simulated person trying to keep up with the pacer dot: their lag
    drifts between slightly ahead and ~1 m behind, so the map has realistic
    position error. Emits noisy RSSI from where they *really* are."""
    rng = random.Random(1)
    lag = 0.0
    while not stop.is_set():
        await asyncio.sleep(1.0 / adv_hz)
        now = time.time()
        lag = min(max(lag + rng.gauss(0, 0.08), -0.3), 1.0)
        x, y = point_at(max(dot_distance(now) - lag, 0.0))
        pos = (x + rng.gauss(0, 0.1), y + rng.gauss(0, 0.1))  # people don't walk perfectly straight
        for d in devices:
            dist_d = 0.4 if d.carried else math.dist(pos, (d.x, d.y))
            r = rssi_at(dist_d, d.p0) + rng.gauss(0, noise_db)
            if r > -95 and rng.random() < 0.85:  # some adverts get missed
                on_sample(Sample(now, d.id, d.name, int(round(r))))

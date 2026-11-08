"""Hot-spot localisation for the headless Raspberry Pi.

This is a Python port of the phone's path-loss fit (ios/BLEScout/Model/Localizer.swift):

    bin readings per device into 0.5 m cells along the path
    on a 0.5 m grid, fit  rssi = P0 - 10*n*log10(distance)
    take the best grid cell, convert the fit to a confidence radius
    cluster devices within 1.5 m

The grid search is numpy-vectorised so it runs in well under a second on a Pi 5.
Readings weaker than `min_rssi` are uploaded but not used for placement. Devices
seen in only one 0.5 m cell are not placed (their position would be meaningless).
"""

from __future__ import annotations

import math
from bisect import bisect_right
from dataclasses import dataclass, field

import numpy as np

PENDING_CAP = 5_000        # samples waiting for a matching camera pose
MAX_BIN_READINGS = 50      # keep a bin's median robust but memory bounded


@dataclass
class LocalizerParams:
    bin_m: float = 0.5              # spatial bin along the walked path
    link_m: float = 1.5             # devices closer than this form a hot spot
    warmup_m: float = 3.0           # don't place anything until we've walked this far
    min_bins: int = 3               # enough readings for a proper fit
    min_span_m: float = 1.0         # ...spread over at least this distance
    min_rough_bins: int = 2         # don't place a device heard in only one cell
    min_rssi: float = -90.0         # ignore weak readings for placement
    cell_m: float = 0.5             # grid resolution
    margin_m: float = 3.0           # search this far beyond the walked area
    max_obs: int = 80               # cap bins per device (keeps numpy fast)
    path_loss_n: float = 2.5        # path-loss exponent
    sigma_db: float = 4.0           # expected RSSI noise
    max_independent: int = 12       # temper over-confidence
    max_radius_m: float = 2.5       # fits less certain than this are "uncertain"
    p0_min: float = -80.0
    p0_max: float = -35.0
    rough_p0: float = -59.0         # RSSI at 1 m for rough distance estimate
    rough_max_radius_m: float = 8.0
    gap_s: float = 1.5              # don't interpolate across camera tracking gaps


@dataclass
class _Bin:
    """Readings for one device in one 0.5 m cell."""

    sx: float = 0.0
    sy: float = 0.0
    n: int = 0
    rssi_values: list[float] = field(default_factory=list)

    def add(self, x: float, y: float, rssi: float) -> None:
        self.sx += x
        self.sy += y
        self.n += 1
        self.rssi_values.append(rssi)
        if len(self.rssi_values) > MAX_BIN_READINGS:
            del self.rssi_values[: len(self.rssi_values) - MAX_BIN_READINGS]

    @property
    def x(self) -> float:
        return self.sx / self.n

    @property
    def y(self) -> float:
        return self.sy / self.n

    @property
    def rssi(self) -> float:
        return _median(self.rssi_values)


@dataclass
class _Fix:
    id: str
    name: str
    x: float
    y: float
    radius: float
    status: str  # "located", "uncertain" or "rough"


class Localizer:
    """Accumulates named-device readings and turns them into hot spots."""

    def __init__(self, params: LocalizerParams | None = None):
        self.p = params or LocalizerParams()
        self._pose_t: list[float] = []
        self._pose_x: list[float] = []
        self._pose_y: list[float] = []
        self._walked = 0.0
        self._bins: dict[str, dict[tuple[int, int], _Bin]] = {}
        self._names: dict[str, str] = {}
        self._pending: list[dict] = []

    # ---------- inputs ----------

    def add(self, samples: list[dict], poses: list[dict]) -> None:
        """Add new samples and camera poses. Safe to call every upload cycle."""
        self._add_poses(poses)

        # Old samples may have been waiting for a pose; retry them first.
        pending, self._pending = self._pending + list(samples), []
        for sample in pending:
            t = float(sample.get("t") or 0.0)
            position = self._position_at(t)
            if position is None:
                # Too old to place (before the first pose) or in a tracking gap:
                # drop it. If it is newer than every pose, keep it for next time.
                if not self._pose_t or t > self._pose_t[-1]:
                    self._pending.append(sample)
                continue
            self._add_sample(sample, position)

        if len(self._pending) > PENDING_CAP:
            del self._pending[: len(self._pending) - PENDING_CAP]

    def _add_poses(self, poses: list[dict]) -> None:
        for pose in poses:
            t = float(pose["t"])
            if self._pose_t and t <= self._pose_t[-1]:
                continue  # restored after a failed upload: already recorded
            if self._pose_t:
                self._walked += math.hypot(pose["x"] - self._pose_x[-1],
                                           pose["y"] - self._pose_y[-1])
            self._pose_t.append(t)
            self._pose_x.append(float(pose["x"]))
            self._pose_y.append(float(pose["y"]))

    def _position_at(self, t: float) -> tuple[float, float] | None:
        if not self._pose_t or t < self._pose_t[0] or t > self._pose_t[-1]:
            return None
        if t == self._pose_t[-1]:
            return self._pose_x[-1], self._pose_y[-1]
        i = bisect_right(self._pose_t, t) - 1
        if i >= len(self._pose_t) - 1:
            return None
        t0, t1 = self._pose_t[i], self._pose_t[i + 1]
        if t1 - t0 > self.p.gap_s:
            return None
        f = (t - t0) / (t1 - t0)
        return (self._pose_x[i] + f * (self._pose_x[i + 1] - self._pose_x[i]),
                self._pose_y[i] + f * (self._pose_y[i + 1] - self._pose_y[i]))

    def _add_sample(self, sample: dict, position: tuple[float, float]) -> None:
        name = str(sample.get("name") or "").strip()
        if not name:
            return  # unnamed devices are counted but not localised
        rssi = float(sample.get("rssi") or -95)
        if rssi < self.p.min_rssi:
            return  # weak readings are uploaded but not used for placement
        device_id = str(sample.get("id") or "").strip()
        if not device_id:
            return
        x, y = position
        key = (math.floor(x / self.p.bin_m), math.floor(y / self.p.bin_m))
        cells = self._bins.setdefault(device_id, {})
        cells.setdefault(key, _Bin()).add(x, y, rssi)
        self._names[device_id] = name

    # ---------- analysis ----------

    def analyze(self) -> list[dict]:
        """Return hot spots in the phone's payload format."""
        if not self._bins or not self._pose_t:
            return []

        grid = None
        fixes: list[_Fix] = []
        for device_id, cells in self._bins.items():
            obs = [(b.x, b.y, b.rssi) for b in cells.values() if b.n]
            if not obs:
                continue
            xs = [o[0] for o in obs]
            ys = [o[1] for o in obs]
            span = max(max(xs) - min(xs), max(ys) - min(ys))
            rssis = sorted(o[2] for o in obs)
            med = _median(rssis)
            p10, p90 = _percentile(rssis, 0.1), _percentile(rssis, 0.9)
            name = self._names.get(device_id, device_id)

            # Stays loud wherever the Pi walks: carried by the operator.
            if ((p10 > -58 and span > 1.5)
                    or (p90 - p10 < 7 and med > -65 and span > 2)):
                continue

            if len(obs) < self.p.min_bins or span < self.p.min_span_m:
                if self._walked < self.p.warmup_m:
                    continue  # too early to tell "carried" from "nearby"
                if len(obs) < self.p.min_rough_bins:
                    continue  # one cell isn't enough to place anything useful
                fixes.append(self._rough_fix(device_id, name, obs))
                continue

            if grid is None:
                grid = self._make_grid()
            fixes.append(self._grid_fix(device_id, name, obs, grid))

        return self._cluster(fixes)

    def _make_grid(self):
        """Row-major grid of candidate positions over the walked area + margin."""
        min_x = min(self._pose_x) - self.p.margin_m
        max_x = max(self._pose_x) + self.p.margin_m
        min_y = min(self._pose_y) - self.p.margin_m
        max_y = max(self._pose_y) + self.p.margin_m
        nx = max(1, int(math.ceil((max_x - min_x) / self.p.cell_m)))
        ny = max(1, int(math.ceil((max_y - min_y) / self.p.cell_m)))
        gx = min_x + (np.arange(nx) + 0.5) * self.p.cell_m
        gy = min_y + (np.arange(ny) + 0.5) * self.p.cell_m
        xx, yy = np.meshgrid(gx, gy)  # row-major: ny rows of nx
        return (np.column_stack((xx.ravel(), yy.ravel())).astype(np.float32),
                nx, ny, min_x, min_y)

    def _grid_fix(self, device_id: str, name: str, obs: list[tuple[float, float, float]],
                  grid) -> _Fix:
        grid_xy, nx, ny, min_x, min_y = grid

        # Keep the fit cheap without losing path coverage.
        if len(obs) > self.p.max_obs:
            idx = np.linspace(0, len(obs) - 1, self.p.max_obs).astype(int)
            obs = [obs[i] for i in idx]

        obs_xy = np.array([(o[0], o[1]) for o in obs], dtype=np.float32)
        obs_r = np.array([o[2] for o in obs], dtype=np.float32)
        d = np.linalg.norm(grid_xy[:, None, :] - obs_xy[None, :, :], axis=2)
        loss = 10.0 * self.p.path_loss_n * np.log10(np.maximum(d, 0.3))
        p0 = np.clip(np.mean(obs_r[None, :] + loss, axis=1),
                     self.p.p0_min, self.p.p0_max)
        mse = np.mean((obs_r[None, :] - (p0[:, None] - loss)) ** 2, axis=1)

        min_mse = float(mse.min())
        k_eff = min(len(obs), self.p.max_independent)
        prob = np.exp(-0.5 * k_eff * (mse - min_mse) / (self.p.sigma_db ** 2))
        total = float(prob.sum())
        if total <= 0:
            return self._rough_fix(device_id, name, obs)
        prob /= total

        best = int(np.argmax(prob))
        order = np.argsort(prob)[::-1]
        cumulative = np.cumsum(prob[order])
        cells = int(np.searchsorted(cumulative, 0.68) + 1)
        # Don't let a fit from very few spots look precise.
        radius = max(math.sqrt(cells * self.p.cell_m ** 2 / math.pi),
                     2.0 * math.sqrt(3.0 / len(obs)))
        status = "located" if radius <= self.p.max_radius_m else "uncertain"
        return _Fix(device_id, name, float(grid_xy[best, 0]),
                    float(grid_xy[best, 1]), radius, status)

    def _rough_fix(self, device_id: str, name: str,
                   obs: list[tuple[float, float, float]]) -> _Fix:
        top = sorted(obs, key=lambda o: -o[2])[:3]
        weights = [10 ** (o[2] / 10.0) for o in top]
        total = sum(weights)
        x = sum(o[0] * w for o, w in zip(top, weights)) / total
        y = sum(o[1] * w for o, w in zip(top, weights)) / total
        loudest = top[0][2]
        radius = _clamp(10 ** ((self.p.rough_p0 - loudest)
                               / (10 * self.p.path_loss_n)),
                        1.0, self.p.rough_max_radius_m)
        return _Fix(device_id, name, x, y, radius, "rough")

    def _cluster(self, fixes: list[_Fix]) -> list[dict]:
        if not fixes:
            return []

        # Single-linkage grouping: any two devices within link_m end up together.
        parent = list(range(len(fixes)))

        def find(i: int) -> int:
            while parent[i] != i:
                parent[i] = parent[parent[i]]
                i = parent[i]
            return i

        for a in range(len(fixes)):
            for b in range(a + 1, len(fixes)):
                if math.hypot(fixes[a].x - fixes[b].x,
                              fixes[a].y - fixes[b].y) <= self.p.link_m:
                    parent[find(a)] = find(b)

        groups: dict[int, list[_Fix]] = {}
        for i, fix in enumerate(fixes):
            groups.setdefault(find(i), []).append(fix)

        spots: list[dict] = []
        for members in groups.values():
            cx = sum(f.x for f in members) / len(members)
            cy = sum(f.y for f in members) / len(members)
            reach = max(math.hypot(f.x - cx, f.y - cy) for f in members)
            rough = sum(1 for f in members if f.status != "located")
            score = (len(members) - rough) + 0.5 * rough
            spots.append({
                "x": round(cx, 2),
                "y": round(cy, 2),
                "count": len(members),
                "roughCount": rough,
                "names": sorted({f.name for f in members}),
                "spread": round(max(reach + 0.3, 0.6), 2),
                "uncertainty": round(_median([f.radius for f in members]), 2),
                "_score": score,
            })

        spots.sort(key=lambda s: (-s["_score"], math.hypot(s["x"], s["y"])))
        for i, spot in enumerate(spots):
            spot["id"] = chr(65 + i) if i < 26 else f"Z{i}"
            del spot["_score"]
        return spots


def _median(values: list[float]) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    m = len(s) // 2
    return s[m] if len(s) % 2 else (s[m - 1] + s[m]) / 2


def _percentile(sorted_values: list[float], q: float) -> float:
    if not sorted_values:
        return 0.0
    pos = q * (len(sorted_values) - 1)
    lo = int(math.floor(pos))
    hi = min(lo + 1, len(sorted_values) - 1)
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * (pos - lo)


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))

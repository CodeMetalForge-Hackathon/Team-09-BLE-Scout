"""Approximate hot-spot localisation for the headless Raspberry Pi.

The phone runs a full grid fit of a path-loss model. The Pi has the same kind of
data (BLE readings + camera poses) but we keep this deliberately cheap:

    bin readings into 0.5 m cells along the path
    -> place each device at the RSSI-weighted centroid of its 3 loudest cells
    -> cluster devices within 1.5 m

That is rough, but it puts sensible hot spots on the ground station map without
re-binning tens of thousands of readings every two seconds. The placement step is
isolated so it can be replaced by the phone's full localizer later.
"""

from __future__ import annotations

import math
from bisect import bisect_right
from dataclasses import dataclass

PENDING_CAP = 5_000  # samples waiting for a matching camera pose


@dataclass
class LocalizerParams:
    bin_m: float = 0.5          # spatial bin along the walked path
    link_m: float = 1.5         # devices closer than this form a hot spot
    warmup_m: float = 3.0       # don't place anything until we've walked this far
    min_bins: int = 3           # "enough" readings for a placement
    min_span_m: float = 1.0     # ...spread over at least this distance
    path_loss_n: float = 2.5    # used only to estimate a rough radius
    p0_loud: float = -59.0      # RSSI at 1 m (rough)
    max_radius_m: float = 8.0
    gap_s: float = 1.5          # don't interpolate across camera tracking gaps


@dataclass
class _Bin:
    """Running average position and RSSI for one 0.5 m cell of one device."""

    sx: float = 0.0
    sy: float = 0.0
    rssi_sum: float = 0.0
    n: int = 0

    def add(self, x: float, y: float, rssi: float) -> None:
        self.sx += x
        self.sy += y
        self.rssi_sum += rssi
        self.n += 1

    @property
    def x(self) -> float:
        return self.sx / self.n

    @property
    def y(self) -> float:
        return self.sy / self.n

    @property
    def rssi(self) -> float:
        return self.rssi_sum / self.n


@dataclass
class _Fix:
    id: str
    name: str
    x: float
    y: float
    radius: float


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
        device_id = str(sample.get("id") or "").strip()
        if not device_id:
            return
        x, y = position
        key = (math.floor(x / self.p.bin_m), math.floor(y / self.p.bin_m))
        cells = self._bins.setdefault(device_id, {})
        cells.setdefault(key, _Bin()).add(x, y, float(sample.get("rssi") or -95))
        self._names[device_id] = name

    # ---------- analysis ----------

    def analyze(self) -> list[dict]:
        """Return hot spots in the phone's payload format."""
        fixes: list[_Fix] = []
        for device_id, cells in self._bins.items():
            observations = [(b.x, b.y, b.rssi) for b in cells.values() if b.n]
            if not observations:
                continue
            xs = [o[0] for o in observations]
            ys = [o[1] for o in observations]
            span = max(max(xs) - min(xs), max(ys) - min(ys))
            rssis = sorted(o[2] for o in observations)
            med = _median(rssis)
            p10, p90 = _percentile(rssis, 0.1), _percentile(rssis, 0.9)

            # Stays loud wherever the Pi walks: carried by the operator.
            if ((p10 > -58 and span > 1.5)
                    or (p90 - p10 < 7 and med > -65 and span > 2)):
                continue

            if (len(observations) < self.p.min_bins or span < self.p.min_span_m):
                if self._walked < self.p.warmup_m:
                    continue  # too early to tell "carried" from "nearby"
                # Still place it from the loudest cells (rough).
                pass

            # RSSI-weighted centroid of the strongest few cells. Strong readings
            # are much more informative than weak ones far away.
            top = sorted(observations, key=lambda o: -o[2])[:3]
            weights = [10 ** (o[2] / 10.0) for o in top]
            total = sum(weights)
            x = sum(o[0] * w for o, w in zip(top, weights)) / total
            y = sum(o[1] * w for o, w in zip(top, weights)) / total
            loudest = top[0][2]
            radius = _clamp(10 ** ((self.p.p0_loud - loudest) / (10 * self.p.path_loss_n)),
                            1.0, self.p.max_radius_m)
            fixes.append(_Fix(device_id, self._names.get(device_id, device_id),
                              x, y, radius))

        return self._cluster(fixes)

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
                if math.hypot(fixes[a].x - fixes[b].x, fixes[a].y - fixes[b].y) <= self.p.link_m:
                    parent[find(a)] = find(b)

        groups: dict[int, list[_Fix]] = {}
        for i, fix in enumerate(fixes):
            groups.setdefault(find(i), []).append(fix)

        spots: list[dict] = []
        for members in groups.values():
            cx = sum(f.x for f in members) / len(members)
            cy = sum(f.y for f in members) / len(members)
            reach = max(math.hypot(f.x - cx, f.y - cy) for f in members)
            spots.append({
                "x": round(cx, 2),
                "y": round(cy, 2),
                "count": len(members),
                # The Pi's placement is approximate, so every member is rough.
                "roughCount": len(members),
                "names": sorted({f.name for f in members}),
                "spread": round(max(reach + 0.3, 0.6), 2),
                "uncertainty": round(_median([f.radius for f in members]), 2),
            })

        spots.sort(key=lambda s: (-s["count"], math.hypot(s["x"], s["y"])))
        for i, spot in enumerate(spots):
            spot["id"] = chr(65 + i) if i < 26 else f"Z{i}"
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

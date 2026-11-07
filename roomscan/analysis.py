"""Turn (where I was, what I heard) into device positions, a heat map, and clusters.

Per device, fit the log-distance path-loss model
    rssi = P0 - 10 * n * log10(distance)
on a grid over the room. P0 (signal at 1 m) has a closed form per cell, so
only (x, y) is searched. Each device's fit becomes a probability map. The
heat map is the sum of those maps, i.e. "expected number of devices per cell".
Clusters are groups of device positions within `link_m` of each other.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass

import numpy as np
from scipy.cluster.hierarchy import fcluster, linkage
from scipy.ndimage import gaussian_filter

from .sensing import Sample, Track

P0_RANGE = (-80.0, -35.0)
MIN_DIST = 0.3


@dataclass
class Params:
    n: float = 2.5  # path-loss exponent: ~2 open space, 2.5-3.5 cluttered indoors
    sigma_db: float = 4.0  # expected RSSI noise per window
    cell_m: float = 0.2
    window_s: float = 1.0  # samples are averaged over this long
    min_windows: int = 6  # need this many readings along the path
    min_span_m: float = 1.5  # ...spread over at least this much of the path
    max_independent: int = 12  # temper over-confidence: RSSI errors aren't independent
    link_m: float = 1.5  # devices closer than this belong to the same cluster
    max_radius_m: float = 2.0  # less certain than this: shown in the heat map, kept out of clusters


def device_observations(samples: list[Sample], track: Track, window_s: float):
    """Per device: arrays of (x, y) and median RSSI per time window."""
    by_dev: dict[str, dict[int, list]] = defaultdict(lambda: defaultdict(list))
    names: dict[str, str | None] = {}
    for s in samples:
        p = track.position_at(s.t)
        if p is None:
            continue
        by_dev[s.device][int(s.t // window_s)].append((p[0], p[1], s.rssi))
        if s.name:
            names[s.device] = s.name
    out = {}
    for dev, windows in by_dev.items():
        rows = [(np.mean([r[0] for r in w]), np.mean([r[1] for r in w]), np.median([r[2] for r in w]))
                for w in windows.values()]
        arr = np.array(rows)
        out[dev] = (arr[:, :2], arr[:, 2])
    return out, names


def analyze(samples: list[Sample], track: Track, width: float, length: float, p: Params = Params()) -> dict:
    obs, names = device_observations(samples, track, p.window_s)

    xs = np.arange(p.cell_m / 2, width, p.cell_m)
    ys = np.arange(p.cell_m / 2, length, p.cell_m)
    gx, gy = np.meshgrid(xs, ys)  # (ny, nx)
    heat = np.zeros_like(gx)

    devices = []
    for dev, (pos, rssi) in obs.items():
        info = {"id": dev, "name": names.get(dev), "windows": int(len(rssi)),
                "median_rssi": round(float(np.median(rssi)), 1)}
        span = float(np.ptp(pos, axis=0).max()) if len(pos) else 0.0
        spread_db = float(np.percentile(rssi, 90) - np.percentile(rssi, 10)) if len(rssi) else 0.0

        if len(rssi) < p.min_windows or span < p.min_span_m:
            devices.append({**info, "status": "too_few_readings"})
            continue
        loud_everywhere = np.percentile(rssi, 10) > -58 and span > 2.5
        flat_and_loud = spread_db < 7.0 and np.median(rssi) > -65 and span > 3.0
        if loud_everywhere or flat_and_loud:
            # Stays loud however far you walk: it's travelling with you (earbuds, phone in pocket).
            devices.append({**info, "status": "carried_by_you"})
            continue

        d = np.hypot(gx[..., None] - pos[:, 0], gy[..., None] - pos[:, 1])
        loss = 10 * p.n * np.log10(np.maximum(d, MIN_DIST))
        p0 = np.clip((rssi + loss).mean(axis=-1), *P0_RANGE)
        cost = ((rssi - (p0[..., None] - loss)) ** 2).mean(axis=-1)  # mean squared error, dB^2

        k = min(len(rssi), p.max_independent)
        logp = -0.5 * k * (cost - cost.min()) / p.sigma_db**2
        prob = np.exp(logp)
        prob /= prob.sum()
        heat += prob

        iy, ix = np.unravel_index(np.argmax(prob), prob.shape)
        # radius of the smallest region holding 68% of the probability
        cum = np.cumsum(np.sort(prob.ravel())[::-1])
        n_cells = int(np.searchsorted(cum, 0.68)) + 1
        radius = float(np.sqrt(n_cells * p.cell_m**2 / np.pi))
        devices.append({
            **info, "status": "located" if radius <= p.max_radius_m else "uncertain",
            "x": round(float(gx[iy, ix]), 2), "y": round(float(gy[iy, ix]), 2),
            "radius_m": round(radius, 2), "p0": round(float(p0[iy, ix]), 1),
            "fit_rms_db": round(float(np.sqrt(cost[iy, ix])), 1),
        })

    heat = gaussian_filter(heat, sigma=1.0)
    clusters = find_clusters([d for d in devices if d["status"] == "located"], p.link_m)
    return {
        "room": {"width": width, "length": length},
        "heat": {"x0": float(xs[0]) if len(xs) else 0.0, "y0": float(ys[0]) if len(ys) else 0.0,
                 "cell": p.cell_m, "nx": len(xs), "ny": len(ys),
                 "values": np.round(heat, 4).ravel().tolist(), "max": float(heat.max()) if heat.size else 0.0},
        "devices": devices,
        "clusters": clusters,
        "params": p.__dict__,
    }


def find_clusters(located: list[dict], link_m: float) -> list[dict]:
    if not located:
        return []
    pts = np.array([[d["x"], d["y"]] for d in located])
    labels = fcluster(linkage(pts, "single"), t=link_m, criterion="distance") if len(pts) > 1 else np.array([1])
    groups = defaultdict(list)
    for d, lab in zip(located, labels):
        groups[lab].append(d)

    clusters = []
    for members in groups.values():
        m = np.array([[d["x"], d["y"]] for d in members])
        c = m.mean(axis=0)
        reach = float(np.max(np.hypot(*(m - c).T))) if len(m) > 1 else 0.0
        uncertainty = float(np.median([d["radius_m"] for d in members]))
        clusters.append({
            "x": round(float(c[0]), 2), "y": round(float(c[1]), 2),
            "count": len(members),
            # physical size: how far members spread from the centre, never less than ~1 person
            "radius_m": round(max(reach + 0.3, 0.6), 2),
            "uncertainty_m": round(uncertainty, 2),
            "devices": [d["id"] for d in members],
            "names": sorted({d["name"] for d in members if d.get("name")}),
        })
    clusters.sort(key=lambda c: (-c["count"], c["x"], c["y"]))
    for i, c in enumerate(clusters):
        c["id"] = chr(ord("A") + i) if i < 26 else f"Z{i}"
    return clusters

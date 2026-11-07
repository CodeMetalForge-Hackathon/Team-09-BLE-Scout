import math
import random

import numpy as np

from roomscan.analysis import analyze
from roomscan.sensing import Sample, Track, rssi_at, serpentine, sim_devices

W, L = 8.0, 6.0


def simulate_walk(devices, speed=1.0, hz=3.0, noise=4.0, seed=1):
    """Synchronous version of sim_walk with a virtual clock."""
    rng = random.Random(seed)
    track, samples = Track(), []
    wps = serpentine(W, L)
    t, pos = 0.0, wps[0]
    track.mark(t, *pos)
    for target in wps[1:]:
        steps = max(1, int(math.dist(pos, target) / (speed / hz)))
        start = pos
        for s in range(1, steps + 1):
            t += 1 / hz
            f = s / steps
            pos = (start[0] + f * (target[0] - start[0]), start[1] + f * (target[1] - start[1]))
            for d in devices:
                dist = 0.4 if d.carried else math.dist(pos, (d.x, d.y))
                r = rssi_at(dist, d.p0) + rng.gauss(0, noise)
                if r > -95:
                    samples.append(Sample(t, d.id, d.name, int(round(r))))
        pos = target
        track.mark(t, *pos)
    return track, samples


def test_serpentine_covers_room():
    wps = np.array(serpentine(W, L))
    assert wps[:, 0].min() <= 0.6 and wps[:, 0].max() >= W - 0.6
    assert wps[:, 1].min() <= 0.6 and wps[:, 1].max() >= L - 0.6


def test_track_interpolates():
    tr = Track()
    tr.mark(0, 0, 0)
    tr.mark(10, 10, 0)
    assert tr.position_at(5) == (5, 0)
    assert tr.position_at(11) is None


def test_finds_the_three_groups_and_ignores_carried_device():
    devs = sim_devices(W, L)
    track, samples = simulate_walk(devs)
    result = analyze(samples, track, W, L)

    status = {d["id"]: d["status"] for d in result["devices"]}
    assert status["SIM-ME"] == "carried_by_you"

    clusters = result["clusters"]
    # the 6-device group should be the biggest cluster, near its true centre
    true_a = np.mean([[d.x, d.y] for d in devs if d.id.startswith("SIM-0")], axis=0)
    a = clusters[0]
    assert a["count"] >= 4
    assert math.dist((a["x"], a["y"]), true_a) < 1.5

    located = [d for d in result["devices"] if d["status"] == "located"]
    truth = {d.id: (d.x, d.y) for d in devs}
    errs = [math.dist((d["x"], d["y"]), truth[d["id"]]) for d in located]
    assert np.median(errs) < 1.5

import math

from roomscan.pacer import PathGeom, Pacer
from roomscan.sensing import Track

# An L-shaped path: 4 m up, then 4 m right.
WPS = [(0.0, 0.0), (0.0, 4.0), (4.0, 4.0)]


def run(pacer: Pacer, t0: float, t1: float, dt: float = 0.1) -> float:
    t = t0
    while t < t1 - 1e-9:
        t += dt
        pacer.tick(t)
    return t


def test_path_geometry():
    g = PathGeom(WPS)
    assert g.total == 8.0
    assert g.point_at(6.0) == (2.0, 4.0)
    assert math.isclose(g.project(0.3, 2.0), 2.0)  # nearest to the first leg
    assert math.isclose(g.project(1.0, 3.5), 5.0)  # nearer the second leg
    assert g.nearest_waypoint(3.7) == 1


def test_dot_waits_for_countdown_then_moves_at_speed():
    tr = Track()
    p = Pacer(WPS, tr, speed=1.0, countdown=3.0)
    p.start(0.0)
    run(p, 0.0, 3.0)
    assert p.d < 1e-9
    run(p, 3.0, 5.0)
    assert math.isclose(p.d, 2.0, abs_tol=0.05)
    assert tr.position_at(4.0) is not None


def test_correction_rewrites_the_lagging_stretch():
    """Walker fell behind: the dot reached the corner at t=4, the walker at t=6."""
    tr = Track()
    p = Pacer(WPS, tr, speed=1.0, countdown=0.0)
    p.start(0.0)
    run(p, 0.0, 6.0)  # dot is now 2 m past the corner
    assert p.path.nearest_waypoint(p.d) in (1, 2)
    p.at_point(6.0, 0.0, 4.0)  # "I'm at the corner"
    assert math.isclose(p.d, 4.0)
    # history rewritten: at t=3 the walker was half-way along the 4 m stretch (steady pace over 6 s)
    x, y = tr.position_at(3.0)
    assert math.isclose(x, 0.0, abs_tol=1e-6) and math.isclose(y, 2.0, abs_tol=0.05)


def test_pause_holds_position_and_finishes_at_end():
    tr = Track()
    p = Pacer(WPS, tr, speed=2.0, countdown=0.0)
    p.start(0.0)
    run(p, 0.0, 1.0)
    p.pause(1.0)
    held = p.d
    run(p, 1.0, 5.0)
    assert p.d == held
    p.resume(5.0)
    run(p, 5.0, 10.0)
    assert p.done and math.isclose(p.d, 8.0)

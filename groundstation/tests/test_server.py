import asyncio
import json

from aiohttp.test_utils import TestClient, TestServer

from station.server import Station, build_app


def run(coro):
    return asyncio.run(coro)


def batch(pid="p1", start=100.0, poses=None, hot=None, **kw):
    return {"v": 1, "phoneId": pid, "name": kw.get("name", "Alex"), "sessionStart": start,
            "sentAt": 1.0, "uptimeAtSend": 5.0, "running": True, "screen": "scan",
            "pose": (poses or [{"t": 1, "x": 0, "y": 0, "heading": 0}])[-1],
            "poses": poses or [{"t": 1, "x": 0, "y": 0, "heading": 0}],
            "samples": [{"t": 1, "id": "d1", "name": "Speaker", "rssi": -60}],
            "hotSpots": hot if hot is not None else [], "missionTarget": None, "stats": {"named": 1}}


async def client_for(tmp_path):
    station = Station(tmp_path)
    client = TestClient(TestServer(build_app(station)))
    await client.start_server()
    return station, client


def test_ping_and_empty_state(tmp_path):
    async def go():
        _, c = await client_for(tmp_path)
        assert (await (await c.get("/api/ping")).json())["ok"]
        assert (await (await c.get("/api/state")).json())["phones"] == []
        await c.close()
    run(go())


def test_batches_build_path_and_record_raw_data(tmp_path):
    async def go():
        station, c = await client_for(tmp_path)
        r = await c.post("/api/phone/p1/batch", json=batch(poses=[{"t": 1, "x": 0, "y": 0, "heading": 0},
                                                                  {"t": 2, "x": 1, "y": 1, "heading": 0}]))
        assert r.status == 200
        await c.post("/api/phone/p1/batch", json=batch(poses=[{"t": 3, "x": 2, "y": 2, "heading": 0}],
                                                       hot=[{"id": "A", "x": 2, "y": 3, "count": 3, "roughCount": 0,
                                                             "names": ["a", "b", "c"], "spread": 1, "uncertainty": 1}]))
        st = (await (await c.get("/api/state")).json())["phones"][0]
        assert st["name"] == "Alex" and st["online"]
        assert st["path"] == [[0, 0], [1, 1], [2, 2]]
        assert st["hotSpots"][0]["count"] == 3
        assert st["samplesReceived"] == 2
        lines = (station.session_dir / "p1.jsonl").read_text().splitlines()
        assert len(lines) == 2 and json.loads(lines[0])["phoneId"] == "p1"
        await c.close()
    run(go())


def test_new_scan_on_phone_clears_its_path_and_phones_get_distinct_colours(tmp_path):
    async def go():
        _, c = await client_for(tmp_path)
        await c.post("/api/phone/p1/batch", json=batch(start=100))
        await c.post("/api/phone/p2/batch", json=batch(pid="p2", name="Sam"))
        await c.post("/api/phone/p1/batch", json=batch(start=200, poses=[{"t": 9, "x": 5, "y": 5, "heading": 0}]))
        phones = {p["id"]: p for p in (await (await c.get("/api/state")).json())["phones"]}
        assert phones["p1"]["path"] == [[5, 5]]
        assert phones["p1"]["color"] != phones["p2"]["color"]
        await c.close()
    run(go())


def test_rejects_garbage(tmp_path):
    async def go():
        _, c = await client_for(tmp_path)
        r = await c.post("/api/phone/p1/batch", data="not json", headers={"Content-Type": "application/json"})
        assert r.status == 400
        await c.close()
    run(go())


def test_big_hot_spots_are_held_and_tagged_targets_marked(tmp_path):
    async def go():
        station, c = await client_for(tmp_path)
        big = {"id": "A", "x": 4, "y": 4, "count": 8, "roughCount": 0, "names": [f"d{i}" for i in range(8)],
               "spread": 1, "uncertainty": 1}
        await c.post("/api/phone/p1/batch", json=batch(hot=[big]))
        await c.post("/api/phone/p1/batch", json=batch(hot=[]))   # phone's latest view lost it
        st = await (await c.get("/api/state")).json()
        assert len(st["heldSpots"]) == 1 and not st["heldSpots"][0]["rescued"]
        # a relay of a device in it, then a rescuer tags it
        station.add_relay({"kind": "relay", "target_name": "d1", "target_x": 4, "target_y": 4, "chain": [], "hop": 0})
        assert len((await (await c.get("/api/state")).json())["relays"]) == 1
        station.add_relay({"kind": "cleared", "target_name": "d1", "target_names": ["d1", "d2"],
                           "target_x": 4.2, "target_y": 3.9, "from_name": "Sam", "chain": [], "hop": 0})
        st = await (await c.get("/api/state")).json()
        assert st["cleared"][0]["by"] == "Sam"
        assert st["heldSpots"][0]["rescued"] is True
        assert st["relays"] == [], "a tagged target's relay chain is dropped"
        await c.close()
    run(go())


def test_broad_tag_elsewhere_does_not_hide_a_relay(tmp_path):
    async def go():
        station, c = await client_for(tmp_path)
        station.add_relay({"kind": "relay", "target_name": "MacBook", "target_x": 6, "target_y": 6, "chain": [], "hop": 0})
        station.add_relay({"kind": "cleared", "target_name": "big spot", "target_names": [f"d{i}" for i in range(34)] + ["MacBook"],
                           "target_x": -1.3, "target_y": -0.9, "from_name": "Dave", "chain": [], "hop": 0})
        st = await (await c.get("/api/state")).json()
        assert [r["target"] for r in st["relays"]] == ["MacBook"], "a far-away hot-spot tag must not hide it"
        await c.close()
    run(go())

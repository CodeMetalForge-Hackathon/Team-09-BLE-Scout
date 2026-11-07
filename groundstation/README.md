# Ground station

A laptop web app that collects every BLE Scout phone's scan and shows the whole team on
one live map: each phone's position and path, its hot spots, and where it's heading on
a mission. Works on a local Wi-Fi network with no internet (a travel router or the
laptop's own hotspot is fine).

## Run

```bash
cd groundstation
uv sync
uv run groundstation            # opens the dashboard at http://localhost:8765
```

The terminal prints the address phones use (e.g. `http://192.168.1.20:8765`). Phones on
the same Wi-Fi find the station **automatically** (Bonjour). If one doesn't, tap the
📡 line in BLE Scout and type that address.

On first run, macOS may ask whether Python can accept incoming network connections.
Click **Allow**, or phones can't reach it.

**Try it without phones:**
```bash
uv run python fake_phones.py --phones 3     # in a second terminal
```

## Using it with the team

1. Start the ground station and open the dashboard.
2. Mark a spot on the floor (tape an X) at the entrance. **Everyone presses Start standing
   on that mark, facing the same way**, so all phones share one coordinate frame. (Phase 1
   assumes this; automatic alignment comes later.)
3. Each phone shows "Ground station: connected" while it scans. Set your name in the
   📡 settings so the dashboard can label you.
4. **Clear map** on the dashboard starts a fresh session.

## What's stored

Every batch a phone sends is appended to `sessions/session-<time>/<phone>.jsonl` (raw
positions, Bluetooth readings and hot spots). Phase 2 will fuse all phones' readings
into one shared analysis from this data.

## Phone → station protocol

Phones `POST /api/phone/<phoneId>/batch` every ~2 s with JSON: name, session start,
latest pose, new poses and raw readings since the last batch, current hot spots, mission
target and counts. See the docstring in `station/server.py`. Other endpoints:
`GET /api/state` (dashboard), `GET /api/ping`, `POST /api/reset`.

## Develop

```bash
uv run pytest
```

## Roadmap

1. ✅ Phones stream to the station; live dashboard of everyone.
2. Shared analysis: fuse all phones' readings into one set of hot spots and send them back to the phones.
3. Coordination: assign hot spots to people, share cleared status, dispatch from the dashboard.
4. Printed start marker (ARKit image detection) so phones line up without a shared start mark.

# Team 9: Bluetooth search & rescue

Two tools for finding clusters of Bluetooth devices (and so, likely, people) in a room:

- **[`ios/`](ios/): BLE Scout**, an iPhone app. Walk any route; ARKit tracks your position
  and the app maps clusters of *named* Bluetooth devices relative to your start point.
  Also distributed via TestFlight as "BLE Scout SAR".
- **`roomscan/`**, a laptop version (below). Walk a guided path while the map builds,
  then dispatch rescue team members' phones to each cluster.

---

# roomscan: Bluetooth room scan and rescue dispatch

Walk through a room with this laptop. It listens to every Bluetooth device it can hear,
builds a **heat map** of where they are, groups them into **clusters** (each with a
device count and physical size), and sends **rescue team members' phones** to each
cluster.

## Run

```bash
uv sync
uv run roomscan --simulate     # try it: fake room and devices, walks by itself
uv run roomscan                # real scan with this laptop's Bluetooth
```

The operator console opens at http://localhost:8000. Team members join by scanning
the console's QR code with their phone camera. Their phone must be on the **same Wi-Fi**
as the laptop.

On first run, macOS asks to allow **Bluetooth** (to scan) and **Local Network** (so
phones can connect) for your terminal app. Allow both, or enable them later under
System Settings → Privacy & Security.

## Doing a scan

1. **Room:** stand in the corner by the door, facing in. Enter the room's **width**
   (along the wall to your right) and **length** (straight ahead). Pacing it out is
   fine (≈0.75 m per step).
2. **Walk live:** press **Start walking**, stand on point 1 during the 3-second
   countdown, then **keep up with the blue dot** as it moves along the zig-zag path.
   You hear a beep at each numbered point. The heat map and clusters build as you go.
   - **Space:** "I'm at a numbered point." Snaps your position to the point nearest
     the dot, and rewrites the stretch since your last correction, so falling behind
     doesn't ruin the map.
   - **Click the map:** "I'm here" (for when you had to go around something).
   - **P** pauses or resumes; **−** / **+** changes the pace (default 0.5 m/s, or
     `--speed`).

   Keep the laptop at chest height, held the same way the whole time.
3. **Clusters** appear and sharpen as you walk. Devices not pinned down yet (more
   than ±2 m) show in the heat map but stay out of clusters. The scan finishes when
   the dot reaches the end (or press **Finish scan**). Raw data is saved to `scans/`.
4. **Dispatch:** press **Auto-assign team** (biggest clusters first), or pick a person
   per cluster. Each phone shows "walk X m along the right-hand wall, then Y m into
   the room", plus a map. When a rescuer taps **Cleared**, they're automatically sent to
   the next open cluster. **Need help** shows up on the console.

Re-open a saved scan, for example to try different settings:
```bash
uv run roomscan --load scans/scan-YYYYMMDD-HHMMSS.json
```

## How it works

- **Position:** the laptop doesn't know where it is, so it takes the pacer dot's
  position as yours. Each correction is an anchor; between anchors, positions are
  recalculated as steady progress along the path (`pacer.py`).
- **Per device:** readings are averaged over 1 s windows, then a grid search fits
  `rssi = P0 − 10·n·log10(distance)` over the room. This gives a probability map per
  device, plus a best position and a 68% radius (`analysis.py`).
- **Heat map** = sum of all device probability maps, i.e. expected devices per spot.
- **Clusters** = devices whose best positions are within 1.5 m of each other. Size is
  reported as the device count, the spread radius, and the position uncertainty.
- **Ignored devices:** devices that stay loud wherever you walk (your own earbuds,
  the phone in your pocket) and devices heard too briefly to place.
- **Server:** `aiohttp` serves the console, the team pages and a small JSON API (`server.py`).

## Limits

- Bluetooth signal strength is noisy and bodies absorb it. Expect ±1–2 m per device,
  so treat clusters as "search here" areas, not exact spots.
- One person often carries 2–3 devices (phone, watch, earbuds), so device count ≠
  head count.
- Devices outside the room (through walls) are forced inside the room outline and
  usually show up along the walls.
- Phones change their Bluetooth address every ~15 minutes, so keep a scan under ~10
  minutes.
- Indoors with lots of furniture, try a higher path-loss value (`n` 3.0) in the console
  and re-analyse.

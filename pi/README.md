# Raspberry Pi uploader

`upload.py` scans Bluetooth LE and tracks the camera's movement over the ceiling,
then uploads both to the same Supabase relay the iPhone app uses in **Cloud**
mode. It is headless: no map, no screen, just a line in the terminal when a
batch goes out.

The ground station shows the Pi as another device, draws its path, and shows the
rough hot spots it estimates from its own walk. Bluetooth readings are sent
exactly like a phone's.

## Setup on the Pi

```bash
git clone https://github.com/CodeMetalForge-Hackathon/Team-9.git
cd Team-9

# Camera libraries are system packages on Raspberry Pi OS.
sudo apt update && sudo apt full-upgrade
sudo apt install -y python3-picamera2 python3-opencv

python3 -m venv --system-site-packages ~/venv
~/venv/bin/pip install bleak certifi

cp pi/.env.example pi/.env
nano pi/.env          # Supabase values, PI_NAME, PI_ID, camera settings
```

`--system-site-packages` matters: a plain venv cannot see `picamera2`.

If you use [uv](https://docs.astral.sh/uv/) instead:

```bash
uv venv --system-site-packages
uv sync
sudo env "PATH=$PATH" uv run python pi/upload.py
```

Then run it (Bluetooth usually needs root on Raspberry Pi OS):

```bash
sudo ~/venv/bin/python pi/upload.py
```

## Start automatically on boot

Install the systemd service:

```bash
bash pi/install-service.sh
```

It runs the uploader as **root** (Bluetooth scanning needs it), starts after
Bluetooth, and restarts the script if it exits.

This is a system service (`WantedBy=multi-user.target`), so it starts at boot
**without anyone logging in** and does not need a desktop session. The repo can
stay in your home directory (for example `/home/user/Team-9`): systemd uses the
repo path the installer was run from, and root can read it.

If you want it to run as your own user instead:

```bash
SERVICE_USER=user bash pi/install-service.sh
```

BLE scanning may fail without root; root is the recommended default. If you try
a non-root user, add it to the Bluetooth/video groups and check the logs.

```bash
sudo systemctl status pi-upload
sudo journalctl -u pi-upload -f
```

The installer looks for `.venv` in the repo, then `~/venv`, then
`~/.venv`. If it picks the wrong interpreter:

```bash
PYTHON="$HOME/venv/bin/python" bash pi/install-service.sh
```

After changing `pi/.env`, restart it:

```bash
sudo systemctl restart pi-upload
```

Stop and disable it with:

```bash
sudo systemctl disable --now pi-upload
```

## Mount the camera

- Point it **straight up at the ceiling**, rigidly mounted on the pod.
- Put the camera's **top edge towards the front** of the pod.
- The AI Camera has **manual focus**: focus it at the ceiling distance, then
  tape the ring so it cannot move.
- Start the Pi on the team's start mark, facing the same way as the phones.
- The ceiling needs some texture. Tiles, beams, pipes, tape marks or a poster
  all work. A blank white ceiling is the main thing that loses tracking. Avoid
  pointing straight at a bare light fitting.

Facing up is not special: the tracker measures movement against a flat surface.
If you ever flip the camera to face down, set `PI_CAMERA_FACING=down` and use the
distance to the floor instead. No checkerboard calibration is required for a
rough indoor demo: the lens spec gives the focal length, and `PI_CAMERA_SCALE`
trims the distance.

## Configuration

Values are read from `pi/.env` first, then `.env` in the repo root, then
`groundstation/.env` — so you can reuse the Supabase URL/key already there and
only add the `PI_*` settings. If you prefer one file, put `PI_NAME`/`PI_ID` in
the same `groundstation/.env`; the Pi falls back to it. Command-line flags
override the files.

| Key | Default | Meaning |
|---|---|---|
| `SUPABASE_URL` | *(required)* | `https://<project-ref>.supabase.co` |
| `SUPABASE_ANON_KEY` | *(required)* | Public anon / publishable key. **Not** the secret key. |
| `TEAM_CODE` | `TEAM9` | Must match the ground station's team code. |
| `PI_NAME` | same as `PI_ID` | Label shown on the dashboard. |
| `PI_ID` | the Pi's hostname | Stable device id (1–64 chars). Set this explicitly if you run more than one Pi. |
| `PI_INTERVAL` | `2` | Seconds between uploads (0.2–60). |
| `PI_MIN_RSSI` | `-95` | Ignore readings weaker than this (dBm). Hot-spot placement uses -90. |
| `PI_INCLUDE_UNNAMED` | `0` | `1` also places unnamed devices in hot spots (MAC randomization can inflate counts). |
| `PI_CAMERA` | `1` | `1` tracks movement, `0` uploads Bluetooth only. |
| `PI_CAMERA_FACING` | `up` | `up` for a ceiling, `down` for a floor. |
| `PI_CAMERA_DISTANCE_M` | `2.0` | Distance from the lens to the ceiling, in metres. |
| `PI_CAMERA_ROTATE` | `0` | Rotate frames (`90`, `180`, `270`) if the camera is mounted sideways/upside-down. |
| `PI_CAMERA_RES` | `640x480` | Frames used for tracking. `320x240` is lighter on CPU. |
| `PI_CAMERA_FPS` | `15` | Capture rate. 10–15 is plenty. |
| `PI_CAMERA_FOCAL_PX` | `485` | Focal length in pixels at the configured resolution (≈242 at 320×240). |
| `PI_CAMERA_SCALE` | `1.0` | Distance trim: raise if a 1 m walk reports too little. |
| `PI_CAMERA_FLIP_X` / `FLIP_Y` | `0` | Flip left/right or forward/back if the path is reversed. |
| `PI_CAMERA_YAW_SIGN` | `-1` | Flip to `1` if turns go the wrong way. |
| `PI_CAMERA_POSE_HZ` | `5` | How often a pose is recorded for the path. |

Use one Pi per `PI_ID`; if two Pis share an id their readings appear as one device.

## Check it works

```bash
# Send one row without scanning (proves the URL/key/team are right)
sudo ~/venv/bin/python pi/upload.py --test

# Camera poses, no upload
sudo ~/venv/bin/python pi/upload.py --dry-run --seconds 10

# Short live run
sudo ~/venv/bin/python pi/upload.py --seconds 20

# Bluetooth only
sudo ~/venv/bin/python pi/upload.py --no-camera
```

The terminal shows `camera: tracking` while it can see the surface, and
`camera: searching for surface features` when it cannot.

Walk exactly 1 metre forward. If the reported path is much shorter or longer,
adjust `PI_CAMERA_SCALE` (for example, 0.8 m reported means `SCALE=1.25`). If the
path goes backward, set `PI_CAMERA_FLIP_Y=1`; if left/right is reversed, set
`PI_CAMERA_FLIP_X=1`; if turns are reversed, set `PI_CAMERA_YAW_SIGN=1`.
Measure the ceiling distance with a tape; it has the biggest effect on scale.

## Flags

```text
--env PATH        extra/alternate .env file (repeatable; earlier files win)
--name NAME       override PI_NAME
--id ID           override PI_ID
--interval SEC    override PI_INTERVAL
--min-rssi DBM    override PI_MIN_RSSI
--seconds N       stop after N seconds (0 = forever)
--no-camera       upload Bluetooth only
--test            send a single ping row and exit
--dry-run         print the batch JSON instead of uploading
```

## Hot spots

The Pi also estimates hot spots from its own walk, so the ground station has
something to draw without waiting for a phone. It uses the same path-loss model
as the phone (`ios/BLEScout/Model/Localizer.swift`):

- named-device readings are binned into 0.5 m cells along the camera path;
- each device is fitted to `rssi = P0 - 10·n·log10(distance)` on a 0.5 m grid;
- the best cell gives its position, and the fit's spread gives a confidence radius;
- devices within 1.5 m are clustered into a hot spot;
- devices that stay loud everywhere (carried by the operator) are dropped;
- devices heard in only one cell are not placed.

Readings below **-90 dBm** are uploaded but ignored for placement. Placements are
marked `located`, `uncertain` or `rough`; the dashboard draws rough ones dashed.
No camera poses means no hot spots (`--no-camera` sends Bluetooth only).

Like the phone, only **named** devices are placed by default. Set
`PI_INCLUDE_UNNAMED=1` to include unnamed devices too: phones often hide their
name, but their Bluetooth addresses randomize, so counts can be inflated.

## Heat map

The ground station's map has a **Heat map** toggle. It turns every phone/Pi hot
spot into a small density blob; big clusters are compressed so they don't wash
out single-device spots.

## What it sends

The same schema as the phone (see the docstring in
`groundstation/station/server.py`):

- `phoneId`, `name`, `sentAt`, `sessionStart`
- raw `samples` (`t`, device address as `id`, `name`, `rssi`)
- `pose` (latest) and `poses` (new since the last batch), in metres relative to
  where the Pi started, with heading in radians
- `hotSpots` (rough clusters, as above)
- `stats` (named/unnamed devices)

Readings and poses that fail to upload are kept (up to 20,000 readings / 6,000
poses) and sent with the next successful batch, so a short network drop doesn't
lose data.

## Troubleshooting

- **`picamera2` not found**: recreate the venv with `--system-site-packages`, or
  run with the system Python after `sudo apt install python3-picamera2`.
- **Camera missing**: check the ribbon is seated, then run `rpicam-hello -t 0`.
- **`searching for surface features`**: the ceiling is too blank/shiny, too dark, or
  out of focus. Add tape marks or a poster to the ceiling, avoid staring at a bare
  light, or refocus the lens.
- **Path drifts**: expected over long walks. Restart `upload.py` at the start mark
  to reset the pose to zero. A textured ceiling and a rigid distance help most.

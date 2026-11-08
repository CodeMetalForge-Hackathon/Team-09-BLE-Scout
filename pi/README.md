# Raspberry Pi uploader

`upload.py` scans Bluetooth LE on the Pi and uploads the readings to the same
Supabase relay the iPhone app uses in **Cloud** mode. It is headless: no map, no
screen, just a line in the terminal when a batch goes out.

The ground station shows the Pi as another device (its card in the phone list)
once it polls the same `TEAM_CODE`. It has no map dot because a Pi has no
position — it only contributes raw Bluetooth readings for the shared analysis.

## Setup on the Pi

```bash
git clone https://github.com/CodeMetalForge-Hackathon/Team-9.git
cd Team-9
python3 -m venv ~/venv
~/venv/bin/pip install bleak certifi

cp pi/.env.example pi/.env
nano pi/.env          # SUPABASE_URL, SUPABASE_ANON_KEY, PI_NAME, PI_ID
```

Then run it (Bluetooth usually needs root on Raspberry Pi OS):

```bash
sudo ~/venv/bin/python pi/upload.py
```

If you use [uv](https://docs.astral.sh/uv/) on the Pi instead:

```bash
uv sync
sudo env "PATH=$PATH" uv run python pi/upload.py
```

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
| `PI_MIN_RSSI` | `-95` | Ignore readings weaker than this (dBm). |

Use one Pi per `PI_ID`; if two Pis share an id their readings appear as one device.

## Check it works

```bash
# Send one row without scanning Bluetooth (proves the URL/key/team are right)
sudo ~/venv/bin/python pi/upload.py --test

# Run for 20 seconds and watch the upload log
sudo ~/venv/bin/python pi/upload.py --seconds 20
```

The ground station terminal should log a batch from the Pi's name within a few
seconds, or show it in the dashboard's device list.

## Flags

```text
--env PATH        extra/alternate .env file (repeatable; earlier files win)
--name NAME       override PI_NAME
--id ID           override PI_ID
--interval SEC    override PI_INTERVAL
--min-rssi DBM    override PI_MIN_RSSI
--seconds N       stop after N seconds (0 = forever)
--test            send a single ping row and exit
--dry-run         print the batch JSON instead of uploading
```

## What it sends

The same schema as the phone (see the docstring in
`groundstation/station/server.py`): `phoneId`, `name`, `sentAt`, `sessionStart`,
raw `samples` (`t`, device address as `id`, `name`, `rssi`), and
`stats` (named/unnamed devices). `pose` is null, `poses`/`hotSpots` are empty.

Readings that fail to upload are kept (up to 20,000) and sent with the next
successful batch, so a short network drop doesn't lose data.

#!/usr/bin/env bash
# Install the Pi uploader as a systemd service so it starts on boot.
#
#   bash pi/install-service.sh
#
# The service runs as root because Bluetooth LE scanning usually needs it.
# If your Python environment is somewhere unusual:
#   PYTHON="$HOME/venv/bin/python" bash pi/install-service.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_USER="${SUDO_USER:-$(id -un)}"
USER_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6 || true)"
[ -n "$USER_HOME" ] || USER_HOME="$HOME"

# Root by default: BLE scanning usually needs it. Override with SERVICE_USER=user.
SERVICE_USER="${SERVICE_USER:-root}"
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    echo "No such user: $SERVICE_USER" >&2
    exit 1
fi
SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6 || true)"
[ -n "$SERVICE_HOME" ] || SERVICE_HOME="$HOME"

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

if [ -n "${PYTHON:-}" ]; then
    PY="$PYTHON"
else
    PY=""
    for candidate in \
        "$ROOT/.venv/bin/python" \
        "$USER_HOME/venv/bin/python" \
        "$USER_HOME/.venv/bin/python" \
        "$SERVICE_HOME/venv/bin/python" \
        "$SERVICE_HOME/.venv/bin/python"
    do
        if [ -x "$candidate" ]; then PY="$candidate"; break; fi
    done
    [ -n "$PY" ] || PY="$(command -v python3 || true)"
fi

if [ -z "$PY" ] || [ ! -x "$PY" ]; then
    echo "Could not find a Python interpreter." >&2
    echo "Run: PYTHON=\"$HOME/venv/bin/python\" bash pi/install-service.sh" >&2
    exit 1
fi

UNIT="[Unit]
Description=BLE Scout Raspberry Pi uploader
Wants=bluetooth.target
After=bluetooth.target network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
WorkingDirectory=$ROOT
Environment=PYTHONUNBUFFERED=1
Environment=HOME=$SERVICE_HOME
ExecStart=\"$PY\" \"$ROOT/pi/upload.py\"
Restart=always
RestartSec=5
KillSignal=SIGINT
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
"

if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '%s\n' "$UNIT"
    exit 0
fi

echo "==> Installing pi-upload.service"
echo "    repo:   $ROOT"
echo "    python: $PY"
echo "    user:   $SERVICE_USER"
if [ "$SERVICE_USER" != "root" ]; then
    echo "    note: BLE scanning may fail as a non-root user; root is recommended."
fi
printf '%s\n' "$UNIT" | $SUDO tee /etc/systemd/system/pi-upload.service >/dev/null

$SUDO systemctl daemon-reload
$SUDO systemctl enable --now pi-upload.service

echo
echo "Installed and started. It will start automatically on every boot."
echo "  status: sudo systemctl status pi-upload"
echo "  logs:   sudo journalctl -u pi-upload -f"
echo "  stop:   sudo systemctl disable --now pi-upload"

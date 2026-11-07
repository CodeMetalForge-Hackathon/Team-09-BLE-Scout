"""Store the Supabase secret key in .env without it ever appearing on screen.

    uv run python set_secret_key.py

Paste the key when asked (input is hidden) and press Enter. Then it checks the key works.
"""

from __future__ import annotations

import getpass
import json
import re
import urllib.error
import urllib.request
from pathlib import Path

ENV = Path(__file__).with_name(".env")
EXAMPLE = Path(__file__).with_name(".env.example")


def main() -> None:
    if not ENV.exists():
        ENV.write_text(EXAMPLE.read_text())
    text = ENV.read_text()
    url = re.search(r"^SUPABASE_URL=(.*)$", text, re.M)
    url = url.group(1).strip().rstrip("/") if url else ""

    print("Supabase → Project Settings → API Keys → copy the SECRET key (sb_secret_… or the legacy service_role key).")
    key = getpass.getpass("Paste it here (hidden), then press Enter: ").strip().strip('"').strip("'")
    if not key:
        raise SystemExit("Nothing entered; .env unchanged.")
    if key.startswith("sb_publishable_"):
        raise SystemExit("That's the publishable (public) key. The ground station needs the SECRET key. .env unchanged.")
    if not (key.startswith("sb_secret_") or key.startswith("eyJ")):
        print("Warning: that doesn't look like a Supabase secret key (expected sb_secret_… or eyJ…). Saving anyway.")

    line = f"SUPABASE_SERVICE_KEY={key}"
    if re.search(r"^SUPABASE_SERVICE_KEY=.*$", text, re.M):
        text = re.sub(r"^SUPABASE_SERVICE_KEY=.*$", lambda _: line, text, flags=re.M)
    else:
        text += f"\n{line}\n"
    ENV.write_text(text)
    ENV.chmod(0o600)  # readable only by you
    print(f"Saved to {ENV} (key ends …{key[-4:]}).")

    if url:
        headers = {"apikey": key}
        if key.startswith("eyJ"):
            headers["Authorization"] = f"Bearer {key}"
        req = urllib.request.Request(f"{url}/rest/v1/batches?select=id&limit=1", headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=8) as r:
                json.loads(r.read() or b"[]")
            print("✓ Key works: the ground station can read from Supabase.")
        except urllib.error.HTTPError as e:
            print(f"✗ Supabase rejected it (HTTP {e.code}). Check you copied the whole SECRET key and run this again.")
        except OSError as e:
            print(f"Couldn't reach Supabase to check ({e}). The key is saved; we'll check again later.")


if __name__ == "__main__":
    main()

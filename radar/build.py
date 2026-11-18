#!/usr/bin/env python3
"""Build a Radar page.

Offline single file with data embedded (works by double-clicking, saves via "Save a copy"):
    python3 build.py my-data.json radar-2026-11-13.html

Hosted version connected to Supabase (no data inside; people sign in and data loads live):
    python3 build.py --cloud https://<project>.supabase.co <publishable-key> site/index.html

Only ever pass the *publishable* (anon) key, never the secret / service_role key.
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def set_block(html: str, block_id: str, value: str) -> str:
    pattern = re.compile(r'(<script id="' + block_id + r'" type="application/json">)[\s\S]*?(</script>)')
    if not pattern.search(html):
        sys.exit(f"Could not find the {block_id} block in dashboard.html")
    return pattern.sub(lambda m: m.group(1) + value + m.group(2), html, count=1)


def as_json(obj) -> str:
    return json.dumps(obj, separators=(",", ":")).replace("<", "\\u003c")


def main(argv):
    template = (HERE / "dashboard.html").read_text()
    if len(argv) == 4 and argv[0] == "--cloud":
        url, key, out = argv[1:]
        if not re.match(r"^https://[a-z0-9-]+\.supabase\.co/?$", url):
            sys.exit("The Supabase URL should look like https://abcdefgh.supabase.co")
        if key.startswith("sb_secret_") or "service_role" in key:
            sys.exit("That is a SECRET key. Use the publishable (anon) key instead.")
        html = set_block(template, "config", as_json({"supabaseUrl": url.rstrip("/"), "supabaseKey": key}))
        html = set_block(html, "state", "null")
    elif len(argv) == 2:
        data, out = argv
        html = set_block(template, "state", as_json(json.loads(Path(data).read_text())))
        html = set_block(html, "config", "{}")
    else:
        sys.exit(__doc__)
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    Path(out).write_text(html)
    print(f"Wrote {out}")


if __name__ == "__main__":
    main(sys.argv[1:])

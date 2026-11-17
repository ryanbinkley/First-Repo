#!/usr/bin/env python3
"""Build a dashboard file with your own data embedded.

    python3 build.py my-data.json cash-forecast-2026-11-13.html

The data file stays on your computer; only the template (dashboard.html)
lives in this repository. See sample-data.json for the format.
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def build(data_path: str, out_path: str) -> None:
    data = json.loads(Path(data_path).read_text())
    blob = json.dumps(data, separators=(",", ":")).replace("<", "\\u003c")
    template = (HERE / "dashboard.html").read_text()
    pattern = re.compile(r'(<script id="state" type="application/json">)[\s\S]*?(</script>)')
    if not pattern.search(template):
        sys.exit("Could not find the data block in dashboard.html")
    Path(out_path).write_text(pattern.sub(lambda m: m.group(1) + blob + m.group(2), template, count=1))
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    build(sys.argv[1], sys.argv[2])

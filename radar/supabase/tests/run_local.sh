#!/usr/bin/env bash
# Spin up a throwaway PostgreSQL, apply the migrations, load a data file, run the
# security tests, and print radar_state() as JSON.
#
#   radar/supabase/tests/run_local.sh [data.json] > state.json
#
# Needs PostgreSQL 15+ server binaries (initdb, pg_ctl) and psql. Run as a normal user (not root).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; RADAR="$(cd "$HERE/../.." && pwd)"
DATA="${1:-$RADAR/sample-data.json}"
PGBIN="${PGBIN:-$(dirname "$(command -v initdb 2>/dev/null || ls /usr/lib/postgresql/*/bin/initdb | tail -1)")}"
DIR="$(mktemp -d)"; PORT="${PORT:-54329}"
"$PGBIN/initdb" -D "$DIR/db" -U postgres -A trust >/dev/null
"$PGBIN/pg_ctl" -D "$DIR/db" -o "-p $PORT -k $DIR" -l "$DIR/log" -w start >/dev/null
trap '"$PGBIN/pg_ctl" -D "$DIR/db" -m immediate stop >/dev/null 2>&1; rm -rf "$DIR"' EXIT
PSQL=(psql -h "$DIR" -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -q)
"${PSQL[@]}" -f "$HERE/supabase_stub.sql" >&2
for m in "$HERE"/../migrations/*.sql; do "${PSQL[@]}" -f "$m" >&2; done
python3 "$RADAR/tools/seed_from_json.py" "$DATA" | "${PSQL[@]}" >&2
"${PSQL[@]}" -At -c "select jsonb_pretty(public.radar_state())"   # state as loaded, before the tests add test rows
"${PSQL[@]}" -f "$HERE/test_security.sql" >&2

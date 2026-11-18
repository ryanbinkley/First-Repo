#!/usr/bin/env python3
"""Turn a Radar dashboard data file (the JSON embedded in a saved dashboard) into
SQL that loads it into the Supabase schema.

    python3 tools/seed_from_json.py my-data.json > seed.sql
    psql "$DATABASE_URL" -f seed.sql        # or paste into the Supabase SQL editor

Run it once on an empty project. Everything is written in one transaction and is
recorded in change_log with via = 'seed'.
"""
import datetime as dt
import json
import sys


def q(v):
    """SQL literal."""
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(round(v, 2)) if isinstance(v, float) else str(v)
    return "'" + str(v).replace("'", "''") + "'"


def line_id(key):
    return f"(select id from public.forecast_lines where key = {q(key)})"


def schedule_cols(rule):
    freq = rule.get("freq", "none")
    day = rule.get("day")
    return dict(
        freq=freq,
        amount=float(rule.get("amount") or 0),
        anchor=rule.get("anchor") if freq == "biweekly" else None,
        day_of_month=(int(day) if day not in (None, "last") else None) if freq == "monthly" else None,
        last_week=(day == "last") if freq == "monthly" else False,
        months="{" + ",".join(str(m) for m in rule.get("months") or []) + "}",
        shift_weeks=int(rule.get("shift") or 0),
    )


def main(path):
    s = json.load(open(path))
    out = ["begin;", "select set_config('app.via', 'seed', true);"]

    out.append(
        "insert into public.settings (id, company, as_of, starting_cash, min_cash, flag_min, os_checks, weeks) values "
        f"(1, {q(s.get('company', ''))}, {q(s['asOf'])}, {q(s['startingCash'])}, {q(s.get('minCash', 150000))}, "
        f"{q(s.get('flagMin', 10000))}, {q(s.get('osChecks', 0))}, {q(s.get('weeks', 13))});")

    for i, ln in enumerate(s["lines"]):
        out.append(
            "insert into public.forecast_lines (key, name, kind, sort_order, note) values "
            f"({q(ln['id'])}, {q(ln['name'])}, {q(ln['kind'])}, {i * 10}, {q(ln.get('note', ''))});")
        for frm, rule in [(None, ln["rule"])] + [(c["from"], c["rule"]) for c in ln.get("changes", [])]:
            c = schedule_cols(rule)
            out.append(
                "insert into public.line_schedules (line_id, effective_from, freq, amount, anchor, day_of_month, last_week, months, shift_weeks) values "
                f"({line_id(ln['id'])}, {q(frm)}, {q(c['freq'])}, {q(c['amount'])}, {q(c['anchor'])}, {q(c['day_of_month'])}, "
                f"{q(c['last_week'])}, {q(c['months'])}, {c['shift_weeks']});")

    for key, weeks in s.get("overrides", {}).items():
        for w, amt in weeks.items():
            out.append(f"insert into public.week_overrides (line_id, week_ending, amount) values ({line_id(key)}, {q(w)}, {q(float(amt))});")

    for o in s.get("oneTime", []):
        out.append(
            "insert into public.one_time_items (line_id, item_date, description, amount) values "
            f"({line_id(o['lineId'])}, {q(o['date'])}, {q(o.get('description', ''))}, {q(float(o['amount']))});")

    for i, r in enumerate(s.get("importRules", [])):
        ignore = r.get("lineId") == "ignore"
        out.append(
            "insert into public.import_rules (priority, match_text, direction, account_last4, action, line_id) values "
            f"({(i + 1) * 10}, {q(r.get('match', ''))}, {q(r.get('dir', 'any'))}, {q(r.get('account') or None)}, "
            f"{q('ignore' if ignore else 'categorize')}, {'null' if ignore else line_id(r['lineId'])});")

    lw = s.get("lastWeek")
    if lw:
        we = lw["weekEnding"]
        prev = (dt.date.fromisoformat(we) - dt.timedelta(days=7)).isoformat()
        out.append(
            "insert into public.week_closes (week_ending, start_cash, os_checks_start, os_checks_end) values "
            f"({q(we)}, {q(lw['startCash'])}, {q(lw.get('osStart', 0))}, {q(s.get('osChecks', 0))});")
        out.append(
            "with snap as (insert into public.forecast_snapshots (as_of, starting_cash, reason) values "
            f"({q(prev)}, {q(lw['startCash'])}, 'seeded from spreadsheet') returning id) "
            "insert into public.forecast_snapshot_values (snapshot_id, line_id, week_ending, amount) "
            "select snap.id, v.line_id, v.week_ending, v.amount from snap, (values "
            + ", ".join(f"({line_id(k)}, {q(we)}::date, {q(float(r.get('forecast') or 0))})" for k, r in lw["rows"].items())
            + ") as v(line_id, week_ending, amount);")
        for k, r in lw["rows"].items():
            if r.get("actual") is not None:
                out.append(
                    "insert into public.weekly_actuals (week_ending, line_id, amount, source) values "
                    f"({q(we)}, {line_id(k)}, {q(float(r['actual']))}, 'manual');")

    out.append("commit;")
    print("\n".join(out))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])

# Radar ↔ AI hub integration

Radar (13-week cash forecast, on Supabase) exposes its data to the AI hub (Open WebUI / n8n / Open Terminal).
The hub reads, analyzes, and writes back an **analyst report** and **questions** for the finance team.
Radar never calls the hub; the hub's automation decides when to run.

```
hub (scheduled)  ──read──►  reporting.* views          (read-only)
hub              ──write─►  hub_add_report(...)        (append-only reports)
                            hub_add_question(...)      (questions for people; answers come back via the views)
```

## Connecting

* PostgreSQL through Supabase's connection pooler (Project → **Connect** → *Transaction pooler*, port 6543), SSL required.
* Login role **`radar_hub`**. An admin enables it once in the Supabase SQL editor:
  `alter role radar_hub with login password '<strong password>';`
  With the pooler the user name is `radar_hub.<project-ref>`.
* The role can read the `reporting` schema and execute the two hub functions. Nothing else: it cannot read the
  underlying tables, change the forecast, or answer questions.
* Share the password through a password manager, not chat or email.

## What the hub can read (`reporting` schema)

| View | What's in it |
|---|---|
| `current_week` | The week Radar is on (`as_of` = last closed week, Friday), starting cash, minimum cushion |
| `machine_latest` | Latest state of Radar per week: `plan` {line: {week: amount}}, `suggestions` (with reasons, confidence, weekly effect), `cols` (plan vs Radar ending cash), `facts` |
| `weekly_actuals` | Actual cash by line and week since 2021 |
| `forecast_lines` | Lines, kind (in/out), notes; `line_schedules` has the recurring rules |
| `forecast_accuracy` | Every past forecast value vs actual, with `weeks_ahead`, `category` (flow / decision / transfer), `forecast_kind` (plan / machine) |
| `weekly_totals_history` | Weekly totals since 2019 with the finance team's notes and one-off amounts |
| `radar_knowledge` | Notes from people, and questions with their answers (`status` open / answered / dismissed) |
| `suggestion_history` | Suggestions applied or set aside, with reasons |
| `analyst_reports` | Previous reports from the hub |
| `week_summary`, `forecast_publications`, `change_history` | Supporting detail (bank transactions are deliberately not available: their descriptions can name private individuals) |

Line categories: **flow** = recurring business cash (what history can predict), **decision** = amounts management
sets (tax payments, owner distributions, owner transfers in), **transfer** = one-off movements. Don't forecast decisions.

## What the hub writes

```sql
select public.hub_add_report(
  '2026-11-13',                    -- as_of: reporting.current_week.as_of
  'model-name',                    -- shown to users
  'One-paragraph summary.',
  '[{"title": "Advertising", "text": "…", "lines": ["other_in"], "evidence": ["$105,546 avg last 13 wks"]}]'::jsonb);

select public.hub_add_question('Did the October advertiser cancellation affect November too?', 'other_in', 'analyst:ad-cancellation:2026-11');
```

* Reports are append-only; Radar shows the newest one for the current week.
* `qkey` makes questions idempotent: the same key is never asked twice. Use a stable key per topic and month.
* **Radar checks every dollar figure** in the report against its own data and underlines any it can't find, so
  use figures exactly as computed (`$105,546` or `$106k`).

See `SKILL.md` for the analysis procedure.

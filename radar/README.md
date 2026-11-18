# Radar — cash threat detection

Radar is a single-file dashboard for the weekly 13-week cash forecast. It replaces
the Northrim → Forecast tab workflow with:

- **Overview** – cash today, lowest projected point (with a minimum-cushion warning),
  cash in 13 weeks, and last week's actual vs. forecast.
- **13-week forecast grid** – calendar-style: click a number to change it, drag it to another
  week to move it (asks "just this week" or "this and all future weeks"). One-time items are
  amber pills you can drag or click to edit. **+ Add item** adds one-time or recurring items;
  click a line name to edit its schedule. Undo with the button or Ctrl/Cmd+Z.
- **Significant future outflows** – one-time, hand-adjusted, and monthly/quarterly/yearly
  outflows over a threshold (default $10k) in the next 13 weeks.
- **Last week vs. forecast** – enter actuals from the Cash Report.
- **Settings & new week** – starting cash, cushion, and a "Start next week" button that
  rolls everything forward.

Edits are kept in the browser automatically; **Save a copy** downloads a new HTML file
with all changes baked in. Open that file next time.

## Files

| File | Purpose |
|---|---|
| `dashboard.html` | The dashboard (contains made-up sample data so it opens on its own) |
| `sample-data.json` | Example of the data format (fictional numbers) |
| `build.py` | `python3 build.py my-data.json out.html` – builds a dashboard with your data |

Real data files are **not** stored in this repository (see `.gitignore`).

## Roadmap

1. ✅ Dashboard + editable assumptions
2. ✅ Import the weekly Northrim CSV and auto-categorize into actuals
3. Supabase database (schema, change log, security tests in `supabase/`) – next: connect Radar to it
4. Direct bank connection (replaces the CSV download)
5. Open WebUI finance tools; hosting for the team

## Look & feel

Two views, toggled with the button in the top-right:
- **Scope** (default) – WWII radar CRT: phosphor green on dark, amber warnings, faint scanlines.
- **Table** – the ops-room plotting table: map paper and olive-drab ink (good for printing).

Fonts (Press Start 2P, VT323, IBM Plex) load from Google Fonts; offline it falls back to system fonts.
The sweep animation stops when the viewer's system asks for reduced motion.

## Weekly bank import

1. **Settings & new week → Start next week** (rolls the forecast forward).
2. Download the Northrim *Account Activity* CSV for that week, all accounts in one file.
3. **Bank import** tab → drop the file in. Each transaction is sorted by the *sorting rules*
   (first match wins; internal ZBA sweeps are ignored).
4. Enter end-of-week **outstanding checks** from the Cash Report. The bank file only shows what
   cleared, so the change in outstanding checks is added to the AP line to keep cash "net of O/S checks".
5. Review, fix any category, click **Use these as last week's actuals**, then **Use as starting cash**.

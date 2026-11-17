# Radar — cash threat detection

Radar is a single-file dashboard for the weekly 13-week cash forecast. It replaces
the Northrim → Forecast tab workflow with:

- **Overview** – cash today, lowest projected point (with a minimum-cushion warning),
  cash in 13 weeks, and last week's actual vs. forecast.
- **13-week forecast grid** – type over any week's number to adjust it (shown in yellow);
  clear the cell to go back to the rule.
- **Recurring items** – the rules that fill the grid: weekly, every other week, or
  monthly/quarterly/yearly (due on a given day or the last week of the month).
- **One-time items** – known invoices, events, tax bills, big receipts.
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
2. Import bank transactions (Northrim export file or API) and auto-categorize into actuals
3. Scheduled refresh and hosting for the team

## Look & feel

Two views, toggled with the button in the top-right:
- **Scope** (default) – WWII radar CRT: phosphor green on dark, amber warnings, faint scanlines.
- **Table** – the ops-room plotting table: map paper and olive-drab ink (good for printing).

Fonts (Press Start 2P, VT323, IBM Plex) load from Google Fonts; offline it falls back to system fonts.
The sweep animation stops when the viewer's system asks for reduced motion.

# Radar on Supabase — database

This folder holds Radar's database design as migration files. Nothing here contains real data.

| File | What it does |
|---|---|
| `migrations/…01_radar_core.sql` | Tables, change log, append-only rules, row-level security |
| `migrations/…02_app_and_reporting.sql` | `radar_state()` for the app; read-only `reporting` views for Data Studio and the AI assistant |
| `migrations/…03_storage.sql` | Private `bank-files` bucket for the original CSVs |
| `tests/run_local.sh` | Applies everything to a throwaway Postgres, loads a data file, runs the security tests |
| `tests/test_security.sql` | Checks access rules, the change log, append-only history, duplicate protection |
| `../tools/seed_from_json.py` | Loads an existing Radar dashboard's data into the database |

## Design rules

- **Every change is logged.** `change_log` records who, when, how (`radar`, `assistant`, `import`,
  `seed`, `sql`) and the old → new values of every insert, update and delete. It is append-only:
  nobody, not even the database owner, can edit or delete its rows without first removing the
  protection trigger (which is itself a logged schema change in Supabase).
- **Money is exact.** All amounts are `numeric(14,2)`.
- **History is frozen.** Each weekly roll-forward saves a forecast snapshot that can't be edited,
  so forecast accuracy can be measured later (`reporting.forecast_accuracy`).
- **Bank imports can't duplicate.** Each file is stored once (by hash) and each transaction has a
  unique fingerprint, so overlapping downloads are safe.
- **Access by membership.** Only people in `members` see anything: `viewer` reads, `editor` edits
  and imports, `admin` also manages members and can delete an import.
- **Schedules are effective-dated.** "This and all future weeks" adds a new `line_schedules` row with
  `effective_from`; earlier weeks keep the old schedule.

## Setting up ADN's Supabase

1. **Create a company organization** in Supabase, signed up with a company email (ideally a shared
   finance/IT mailbox rather than one person's). Add the developer and the CFO as owners and turn on
   multi-factor authentication for everyone.
2. **Create a project** named `radar`, region **US West** (closest to Alaska).
   The **Pro plan** is recommended: daily backups, and the project never pauses for inactivity.
3. **Sign-in.** The pilot uses emailed sign-in links (on by default). In Authentication → URL Configuration
   set the **Site URL** to where Radar is hosted (e.g. `https://ryanbinkley.github.io/First-Repo/`) and add the
   same address under **Redirect URLs**. Keep **Allow new users to sign up** on so invited people
   can sign in the first time; anyone not invited only sees "No access yet".
   Later: Google sign-in (Providers → Google, OAuth client with user type **Internal** in ADN's Google Cloud).
4. **Apply the migrations** in order, with the Supabase CLI (`supabase link`, then `supabase db push`)
   or by pasting each file into the SQL editor.
5. **Load the current forecast:** `python3 radar/tools/seed_from_json.py data.json > seed.sql`, then run
   `seed.sql` in the SQL editor. (`data.json` is the data from the latest saved Radar file; ask Claude
   to extract it.)
6. **Make yourself admin** (after signing in to Radar once), in the SQL editor:
   ```sql
   insert into public.members (user_id, email, role)
   select id, email, 'admin' from auth.users where email = 'you@…';
   ```
   After that, admins add people from Radar → Settings → Access. Someone who hasn't signed in yet is
   **invited**: they get that role automatically the first time they sign in with that email.
   Or in SQL:
   ```sql
   insert into public.members (user_id, email, role)
   select id, email, 'editor' from auth.users where email = 'angela@…';
   ```
7. **Read-only access for the AI assistant / Data Studio:**
   ```sql
   alter role radar_readonly with login password '<strong password>';
   ```
   Connect with that role through Supabase's connection pooler. It can read the `reporting` views
   and nothing else. **Never** give the `service_role` key to Open WebUI or any browser code.

## Testing locally

```bash
radar/supabase/tests/run_local.sh radar/sample-data.json > state.json   # needs PostgreSQL 15+, run as a non-root user
```

The test uses a small stand-in for Supabase's `auth` and `storage` schemas
(`tests/supabase_stub.sql`). After the real project exists, rerun `test_security.sql` there against a
staging copy to confirm the same behavior.

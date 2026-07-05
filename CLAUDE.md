# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

This is a Phoenix 1.8 / Elixir 1.19 / OTP 28 project. Backend code lives under `lib/gpsview/` and `lib/gpsview_web/`; the React+Leaflet frontend lives under `priv/static/` and is served by `PageController.index/2` at `/`. Persistence is **SQLite** (file at `gpsview_dev.db` in dev) — no DB container is needed. The original design called for PostgreSQL + TimescaleDB + PostGIS; that target is preserved in `project/phoenix-handoff/SCHEMA.md` for the eventual migration when multi-user / write-heavy / spatial-query needs justify it.

Two reference areas remain on disk:
- `project/phoenix-handoff/{CLAUDE,README,API,SCHEMA}.md` — the original backend design docs. Still authoritative for **API contract** and **architecture intent**, but the **DDL in `SCHEMA.md` does not match the live SQLite schema** — see the migrations in `priv/repo/migrations/` for ground truth.
- `project/*.{html,jsx,css,js}` and `project/backend/README.md` — the original prototype and an alternate architecture reference. Kept as historical source; the working copies live in `priv/static/`.

Phoenix 1.8 also generated `AGENTS.md` with Elixir/Phoenix-specific guidelines — read it before writing controllers, schemas, or templates.

## Authoritative reading order

When asked to do backend work, read these in order before touching code:

1. `project/phoenix-handoff/CLAUDE.md` — non-negotiables (per-device GenServer, hypertable indexes, LTTB cap, PubSub topic shape, no N+1).
2. `project/phoenix-handoff/README.md` — architecture diagram and stack rationale.
3. `project/phoenix-handoff/API.md` — REST + Channels contract the React UI expects.
4. `project/phoenix-handoff/SCHEMA.md` — exact DDL for `devices`, `fixes` (hypertable + generated PostGIS `geom`), `tracks`.
5. `AGENTS.md` — Phoenix 1.8 / Elixir guideline reminders (list access, Ecto access, predicate naming, etc.).

When asked to do frontend work, read `priv/static/index.html` first and follow its imports (`/css/styles.css`, `/js/data.js`, then the four `.jsx` files loaded with `type="text/babel"`). The originals in `project/` are kept only for diff/reference.

## Architecture (the parts that span multiple files)

- **One process per device.** `GPSView.Trackers.DeviceServer` (GenServer) holds last-known fix, debounces inserts, broadcasts `{:new_fix, fix}` on `GPSView.PubSub`, supervised by `GPSView.Trackers.DeviceSupervisor` (a `DynamicSupervisor`) and named via `GPSView.Trackers.Registry`. A crash on one device must never affect others.
- **Time-series storage.** `fixes` is a plain SQLite table with composite primary key `(device_id, ts)` and an index on `(device_id, ts)`. Ingest is upsert on the PK via `Repo.insert_all/3` with `on_conflict: :nothing`. `lat`/`lon` are **nullable** — no-GPS-lock entries from tracker logs are kept alongside real fixes (matches `gps_log_viewer.html` behavior); display queries (`fetch_device_fixes/2`) filter `lat IS NOT NULL` so the map only sees plottable points. `cog` and `charge_rate` are stored as `float` (some trackers log decimal precision). The original TimescaleDB hypertable + PostGIS `geom` column are deferred — see `project/phoenix-handoff/SCHEMA.md` for the eventual target. Spatial queries are not supported yet.
- **Server-side decimation is mandatory.** Any track read returns at most ~2000 points unless the caller explicitly raises the cap (max 10000). LTTB lives in `lib/gpsview/decimate.ex`. The browser must never receive a raw multi-thousand-point track.
- **Realtime fan-out.** `Phoenix.PubSub` topic is `"device:#{device_id}"`. The React UI subscribes via Phoenix Channels (`GPSViewWeb.DeviceChannel` mounted on `GPSViewWeb.UserSocket` at `/socket`); server pushes `"new_fix"`, `"status"`. Client may send `"sync_request"` (matches the "Sync from tracker" button in the prototype).
- **Layering.** Web layer (`lib/gpsview_web/`) never touches Ecto schemas directly; all DB access goes through `GPSView.Trackers`.

## Common commands

```bash
mix ecto.setup                                          # create sqlite db + migrate (+ seeds.exs)
mix ecto.reset                                          # drop + recreate + migrate (clears all data)
mix phx.server                                          # http://localhost:4000
mix test                                                # all tests
mix test test/path/to/file_test.exs:42                  # single test at line
mix compile --warnings-as-errors                        # zero-warnings gate
mix precommit                                           # compile-with-warnings + format + test
```

Bulk-import GPS fixes from a CSV (idempotent on `(device_id, ts)`):
```bash
mix gpsview.import_fixes path/to/file.csv --device 7C2A [--name "tracker-7C2A"]
```
- Auto-detects the four common tracker-export layouts (port of the parser in `gps_log_viewer.html`): new-header (14) × old-data (11), old-header (≤11) × new-data (14), or matching widths. The "old" layout has no `cog`/`charge_rate`/`rtc_bat_low`; the "new" layout has all 14.
- Recognised columns map to the `fixes` schema (`datetime, lat, lon, alt_m, speed_kts, cog, satellites, hdop, battery_pct, battery_v, charge_rate, rtc_bat_low, fix, boot`). Unknown columns are ignored; empty cells, `"nan"`, `"NaN"`, `"NAN"` all become NULL.
- `--columns "a,b,..."` overrides the auto-detect for unusual layouts.
- Naive ISO8601 timestamps (no `Z` / no offset, e.g. `2026-03-26T21:28:56`) are auto-treated as UTC.
- No-GPS-lock rows (NULL `lat`/`lon`) are imported — they live in the DB for diagnostic queries, but the display endpoint filters them out so the map only sees plottable points.
- Only truly broken rows are rejected: corrupted timestamps (e.g. `2071-71-71T71:71:71`), out-of-range lat/lon, missing required fields. The first failure is printed for diagnosis.
- The device is auto-created if it doesn't exist (token: `imported`).
- The task prints `parsed / invalid / inserted / duplicates`, plus the first invalid row's errors + payload to help diagnose CSV problems.
- Inserts are batched at 1000 rows to stay under SQLite's 32766-parameter limit.

See `sample_fixes.csv` for a small fixture, `gps_log_viewer.html` for the standalone reference parser, and `lib/mix/tasks/gpsview.import_fixes.ex` for the import source.

The dev DB lives at `gpsview_dev.db` in the repo root. Production reads `DATABASE_PATH` from the environment (see `config/runtime.exs`).

Smoke-test ingest:
```bash
curl -X POST http://localhost:4000/api/ingest \
  -H 'Content-Type: application/json' \
  -H 'x-device-token: <token>' \
  -d @sample-payload.json
```

## Frontend ↔ backend cutover (partial)

The React UI shows real data from the DB **when the URL has `?device=<id>`**, e.g. `http://localhost:4000/?device=Bluey`. With no query param, the page falls back to the deterministic mock track from `priv/static/js/data.js`.

Wiring (medium-path, no track derivation yet):
- `GET /api/fixes?device_id=<id>&decimate=N` returns `{device_id, name, summary, points:[{t, lat, lon, ...}]}`. Server-side LTTB decimation, default 2000, max 10000. See `GPSViewWeb.FixController` and `GPSView.Trackers.fetch_device_fixes/2`.
- `window.GPSData.fetchTrack(deviceId, decimate?)` in `priv/static/js/data.js` wraps the fetch and coerces nullable numeric fields to `0` so existing UI math (`Math.max`, chart axes) doesn't blow up on partial tracker exports.
- `priv/static/js/app.jsx` checks `?device=` on mount and calls `fetchTrack` once. The "Sync from tracker" button still cycles mock seeds — it doesn't refetch real data yet.

Outstanding for the full cutover:
- Derive `tracks` rows from `fixes` (gap ≥ 30 min) so `GET /api/devices/:id/tracks` and `GET /api/tracks/:id` return non-empty.
- Phoenix Channel subscription on `device:<id>` for live `new_fix` pushes (right now the page is one-shot fetch).
- Replace the "Sync from tracker" button's mock cycling with a refetch + Channel reconnect.

## Project-specific rules

- **Zero new compilation warnings** (per global CLAUDE.md). Run `mix compile` after changes; fix any new warnings before reporting a task complete. If an exception is genuinely needed, ask first.
- **Don't run the server yourself after a build.** Tell the user to rebuild and run; they'll exercise it.
- **Don't add LiveView pages in milestone 1.** The frontend is React via Channels. LiveView is a deliberate later option.
- **Don't add Oban or Broadway yet.** Note in code where they'd plug in; ingest volume doesn't justify them.
- **Don't reach for Postgres/Timescale/PostGIS** unless the user explicitly asks. SQLite is the chosen interim store: read-mostly, single-user. If you need a feature SQLite can't give you (concurrent writers, spatial queries, hypertables), surface that to the user before designing around it.
- **Auth is a placeholder** (`x-device-token` header) until milestone 2; don't roll your own crypto scheme — document it in `API.md` if you change it.
- **Migrations are forward-only.** Never edit a committed migration file.
- **Secrets via `config/runtime.exs`** only — never compiled config.

## Workflow (from PLANNING.md)

When the user starts a new piece of work, treat `worklog/` as the source of truth for plan/progress (create the folder on first use). File-naming pattern: `YYMMDD-Innn-type-name_of_task.md` where `YYMMDD` is the date the iteration started, `Innn` is the iteration number (`I001`, `I002`, …, monotonic across the project regardless of date), `type` is one of `prd`, `tasks`, `summary`, or freeform (`architecture`, `research`, …), and `name_of_task` is a snake_case slug.

Iteration shape:
1. **PRD** first (`…-prd-…md`). Sections: Problem Statement, Objective, Goals & Success Criteria, Out of Scope, Acceptance Criteria, Technical Overview (files of interest, suggested steps).
2. **Tasks** doc (`…-tasks-…md`) once the user approves the PRD — hierarchical Markdown checkboxes (`- [ ] Big Task` → `- [ ] Subtask`). Tick items as you finish them; if you can't complete one, leave it unchecked and add a comment explaining why.
3. **Branch** named `YYMMDD-Innn-slug` (type omitted). Reuse the branch if it exists.
4. **Checkpoint commit** when you complete each Big Task. Message format `nn. Big Task Name` where `nn` starts at `01` per branch and increments. List the subtasks completed since the last checkpoint in the body. Don't push.
5. **Summary** doc (`…-summary-…md`) at the end of the iteration — based on the final PRD + tasks state.
6. When (and only when) the user explicitly says "ship": confirm no pending changes, commit any leftovers, squash-merge to main, and tell the user to push.

## Server & completion etiquette

- **Reuse a running server.** If `mix phx.server` is already running, use it instead of spawning a new one.
- **No "shipped" / "production-ready" claims.** When work is done, say "development is complete and ready for your testing." Do not say a feature is "successfully completed and ready for deployment", "fully functional", or "operational" — that's the user's call after they exercise it.

## Command interpretation

- "Create / write a commit message" → output the text only. Do not run `git commit`.
- "Make / create the commit" → run `git commit`.
- Always confirm before destructive or irreversible actions, even if the user asked for the surrounding work.

## File modification approach

When changing config or generated files, **edit the source directly**. If a script applies runtime `sed`/`grep` patches to a file, prefer to bake the change into the source file and remove the runtime patch — direct edits survive regenerations and are easier to review.

## Publishing to GitHub Pages

The app is designed to deploy as a fully static bundle so a small group of friends can view tracker data over the public internet without running a backend service. The Phoenix dev server is for local imports / iteration only; the published version is pre-rendered JSON.

**One-time setup**

1. Push the repo to GitHub with `docs/` tracked (the `.gitignore` already keeps `*.db` out, but `docs/` is not ignored — verify before the first push).
2. In repo Settings → Pages, set source to **Branch: `main` / `docs/`**. Pages auto-publishes on every push to `main`. No GitHub Action needed.

**Per-update workflow**

```bash
mix gpsview.import_fixes path/to/new.csv --device <id>     # add/refresh data
mix gpsview.reconstruct_gaps --device <id>                 # optional: fill flight gaps
mix gpsview.static_export                                  # bake docs/ folder
git add docs/
git commit -m "data update"
git push                                                   # GitHub Pages auto-deploys (~30s)
```

`mix gpsview.static_export` writes `docs/data/devices.json` + `docs/data/<id>.json` (same shapes as `/api/devices` and `/api/fixes`), copies `priv/static/` into `docs/`, and injects `window.GPSDATA_STATIC = true` into the copied `index.html`. The frontend's `data.js` checks that flag and fetches relative `data/*.json` URLs in static mode, falling back to the live `/api/*` endpoints when run under Phoenix.

`--out <dir>` overrides the destination (default `docs`); `--decimate <n>` LTTB-decimates each device to ~`n` points before export (default `0` = full resolution).

**Local preview before pushing**

```bash
cd docs && python3 -m http.server 8765
# open http://localhost:8765/?device=<id>
```

The static bundle uses **relative** paths (`css/...`, `js/...`, `data/...`) so it works on `<user>.github.io/<repo>/` (project Pages) just as well as on a custom domain at the host root. `index.html` is the single file that's safe to edit by hand for both modes.

**Privacy posture**

GitHub Pages on the free tier is publicly accessible. Privacy is by obscurity only:
- Use unguessable device IDs in the URL (`?device=q9x2ma...`) instead of human-readable names.
- Don't link the URL anywhere indexable.

For real auth, put Cloudflare Access in front of a Cloudflare Pages mirror (free up to 50 users) — it can be added later without code changes.

**Storage caveat**

Each device's full-resolution JSON is roughly 16 MB (Bluey-size). They're committed straight to the repo, so the repo grows ~16 MB per data update. Reach for `git lfs` or `mix gpsview.static_export --decimate 5000` if the repo bloats past comfort.

## Rules in PLANNING.md that DO NOT apply here

`PLANNING.md` was lifted from a different project. The following rules in it are intentionally **not** propagated into this CLAUDE.md because they contradict the chosen stack documented in `project/phoenix-handoff/CLAUDE.md`:

- *"Ash Framework First, Phoenix LiveView second, DaisyUI third, Elixir fourth"* — this project is plain Phoenix + Channels; there is no Ash and (per milestone 1) no LiveView or DaisyUI.
- *"Refrain from adding javascript"* — the frontend is React/JSX by design.
- The `FloatingTooltip` LiveView hook pattern and the HEEx confirmation modal pattern — both are LiveView+DaisyUI specific.

If the user asks to revisit any of these, treat it as a stack-pivot decision and confirm before acting.

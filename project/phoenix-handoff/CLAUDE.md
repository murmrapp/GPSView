# CLAUDE.md — GPSView Phoenix Backend

You are continuing work on **GPSView**, a real-time GPS tracker dashboard.

## Context

- **Frontend** is already built: a React SPA at `../GPSView.html` with map (Leaflet), tabbed charts (altitude/speed/battery/satellites), playback, brushing, and a "Sync from tracker" button. It currently uses mock data (`../data.js`).
- **Your job**: build the Elixir/Phoenix backend that replaces the mock data and ingests real tracker telemetry. One device today, many devices in the future — design accordingly.
- **Read first**: `README.md` (architecture), `API.md` (contract), `SCHEMA.md` (DB shape).

## Non-negotiables

1. **Per-device GenServer** under a DynamicSupervisor. One crash must not affect other devices.
2. **TimescaleDB hypertable** on `fixes.ts`. Index `(device_id, ts DESC)`. PostGIS `geom` column generated from lat/lon.
3. **LTTB decimation** server-side. The browser must never receive more than ~2000 points per request unless explicitly asked. See `templates/decimate.ex`.
4. **Phoenix.PubSub** broadcasts on `"device:#{id}"` topic when new fixes arrive. The React UI subscribes via Channels.
5. **No N+1**. Use `Ecto.Query` + preloads correctly.
6. **Tests**: every context function and controller. Use `Phoenix.ChannelTest` for channels.

## Style

- Idiomatic Elixir: pipelines, pattern matching at function heads, tagged tuples, `with` for happy-path control flow.
- Public API only via context modules (`GPSView.Trackers`). Web layer never touches Ecto schemas directly.
- Migrations are forward-only. Never edit a committed migration.
- Configuration via `config/runtime.exs` — no secrets in compiled config.

## What "done" looks like for the first milestone

- [ ] `mix phx.new gpsview --binary-id --no-html --no-assets` generated
- [ ] Postgres + TimescaleDB + PostGIS via `docker-compose.yml`
- [ ] Migrations create `devices`, `fixes` (hypertable), `tracks`
- [ ] `GPSView.Trackers` context with: `list_devices/0`, `get_device/1`, `register_device/1`, `ingest_fix/2`, `list_tracks/1`, `get_track/2`, `decimate/2`
- [ ] `POST /api/ingest` accepts the payload in `sample-payload.json`, validates, persists, broadcasts
- [ ] `GET /api/devices`, `GET /api/devices/:id/tracks`, `GET /api/tracks/:id?decimate=N` return JSON matching `API.md`
- [ ] `DeviceChannel` joinable at `device:<id>`, pushes `"new_fix"` events
- [ ] `DeviceServer` GenServer per device, supervised, crash-tolerant
- [ ] Smoke test: `curl POST /api/ingest` → row in DB → channel event fired → `GET /api/tracks/:id` returns it
- [ ] Update the React frontend's `data.js` to call the real API (last step — flip a `USE_MOCK` flag)

## What NOT to do

- Don't add LiveView pages yet — frontend is React. (LiveView is a future option, not first milestone.)
- Don't roll your own auth — placeholder `device_token` header is fine for now; document it in `API.md`.
- Don't add Oban or Broadway until ingest volume justifies it. Note in code comments where they'd plug in.
- Don't optimize prematurely. Get the schema + API right first.

## Useful starting points

- `templates/device_server.ex` — GenServer skeleton
- `templates/fix.ex` — Ecto schema with `geom` generated column
- `templates/migration_create_fixes.exs` — hypertable + indexes
- `templates/decimate.ex` — LTTB algorithm
- `templates/ingest_controller.ex` — request handler
- `templates/device_channel.ex` — Channel definition
- `templates/router.ex` — pipelines + scopes

## Frontend integration handover

After milestone 1, change `../data.js` to fetch from the API. The expected shape is in `API.md`. Keep the existing client-side caching/decimation off the critical path — server already decimated.

# GPSView — Phoenix Backend Handoff

This is a **starter scaffold** for the Elixir/Phoenix backend that powers the GPSView dashboard. It is intentionally minimal but architecturally complete: device ingestion, time-series storage, real-time fan-out, and a JSON API the existing React UI can talk to.

The frontend prototype lives one folder up (`GPSView.html` + assets). Once this backend is running, swap the mock-data layer in `data.js` for `fetch('/api/...')` calls.

---

## Stack

| Layer            | Choice                   | Why                                             |
| ---------------- | ------------------------ | ----------------------------------------------- |
| Language         | **Elixir 1.16+**         | OTP, soft real-time, fault isolation            |
| Web framework    | **Phoenix 1.7+**         | Channels + LiveView + JSON API in one           |
| Database         | **PostgreSQL 15+**       | Battle-tested, has PostGIS                      |
| Time-series ext  | **TimescaleDB 2.14+**    | Hypertables, compression, continuous aggregates |
| Spatial ext      | **PostGIS 3.4+**         | Bounding-box queries, distance calcs            |
| Data layer       | **Ecto**                 | Standard for Phoenix                            |
| Background jobs  | **Oban**                 | Nightly downsampling, alerting                  |
| Realtime fan-out | **Phoenix.PubSub**       | Built in                                        |
| Per-device state | **GenServer + Registry** | One process per tracker                         |

---

## Architecture

```
   ┌──────────────────────────────────────────────────────────────┐
   │                       GPS TRACKERS                            │
   │   (HTTP POST /ingest  or  MQTT  or  TCP/serial gateway)       │
   └────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
   ┌──────────────────────────────────────────────────────────────┐
   │                   GPSViewWeb.IngestController                 │
   │   • validates payload                                         │
   │   • routes to per-device GenServer via Registry               │
   └────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
   ┌──────────────────────────────────────────────────────────────┐
   │              GPSView.Trackers.DeviceServer (GenServer)        │
   │   • holds last-known fix, online/offline status               │
   │   • debounces / batches inserts                               │
   │   • broadcasts {:new_fix, fix} to PubSub                      │
   │   • supervised → restart on crash, others unaffected          │
   └────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
   ┌──────────────────────────────────────────────────────────────┐
   │                    GPSView.Repo (Ecto + Postgres)             │
   │   fixes  ── hypertable on ts, indexed on (device_id, ts)      │
   │   devices  ── one row per tracker                             │
   │   tracks  ── derived sessions (start/end/distance)            │
   └──────────────────────────────────────────────────────────────┘

   Browser ◄──── Phoenix.PubSub ──── DeviceServer
       │            (websocket via Channels OR LiveView)
       │
       ▼
   GET  /api/devices                   list devices
   GET  /api/devices/:id/tracks        list tracks for a device
   GET  /api/tracks/:id?decimate=2000  fetch a track (LTTB-decimated)
   POST /api/ingest                    tracker pushes new fix
```

---

## Quick start (after Claude Code generates the project)

```bash
# 1. Generate scaffold (Claude Code will run this if not already done)
mix phx.new gpsview --binary-id --no-html --no-assets
cd gpsview

# 2. Add deps to mix.exs (see snippet in mix.exs.template)
mix deps.get

# 3. Set up DB
docker compose up -d   # see docker-compose.yml — runs postgres + timescaledb
mix ecto.create
mix ecto.migrate

# 4. Run
mix phx.server
# → http://localhost:4000

# 5. Smoke test ingest
curl -X POST http://localhost:4000/api/ingest \
  -H 'Content-Type: application/json' \
  -d @sample-payload.json
```

---

## Project layout (what Claude Code should produce)

```
gpsview/
├── lib/
│   ├── gpsview/
│   │   ├── application.ex              # supervision tree
│   │   ├── repo.ex
│   │   ├── trackers/
│   │   │   ├── device.ex               # Ecto schema
│   │   │   ├── fix.ex                  # Ecto schema (hypertable)
│   │   │   ├── track.ex                # Ecto schema (derived sessions)
│   │   │   ├── device_server.ex        # GenServer per device
│   │   │   ├── device_supervisor.ex    # DynamicSupervisor
│   │   │   └── trackers.ex             # context module — public API
│   │   └── decimate.ex                 # LTTB downsampling
│   └── gpsview_web/
│       ├── endpoint.ex
│       ├── router.ex
│       ├── controllers/
│       │   ├── device_controller.ex
│       │   ├── track_controller.ex
│       │   └── ingest_controller.ex
│       ├── channels/
│       │   └── device_channel.ex       # live updates per device
│       └── live/
│           └── dashboard_live.ex       # optional: pure-LiveView UI
├── priv/repo/migrations/
│   ├── 20260101000000_enable_extensions.exs
│   ├── 20260101000001_create_devices.exs
│   ├── 20260101000002_create_fixes.exs
│   └── 20260101000003_create_tracks.exs
├── config/
├── test/
├── mix.exs
├── docker-compose.yml
└── CLAUDE.md
```

---

## Hand-off checklist

When you open this in Claude Code:

1. Copy `CLAUDE.md` to the new Phoenix project root after `mix phx.new`.
2. Use the templates in `templates/` as starting points — they are **sketches**, not finished code; expect to fill in tests and edge cases.
3. The frontend (`GPSView.html` and assets) lives one folder up. The eventual API contract is documented in `API.md`.
4. The data schema matches the CSV you already have — see `SCHEMA.md`.

Files in this folder:

- `CLAUDE.md` — instructions for Claude Code (read first)
- `API.md` — REST + Channels contract the React UI expects
- `SCHEMA.md` — DB schema, indexes, hypertable setup
- `mix.exs.template` — deps you'll need
- `docker-compose.yml` — Postgres + TimescaleDB + PostGIS
- `templates/` — starter modules: GenServer, schemas, controllers, migrations, decimation
- `sample-payload.json` — example tracker payload

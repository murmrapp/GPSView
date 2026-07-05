# GPSView — Phoenix Backend

Real-time GPS tracker dashboard backed by Elixir/Phoenix, PostgreSQL with
TimescaleDB, and the existing GPSView frontend (React + Leaflet) talking over
Phoenix Channels.

This directory is a starter scaffold — files are intentionally short and
heavily commented so you can hand it to Claude Code and iterate.

## Architecture

```
                    ┌────────────────────────────────────────────┐
                    │  GPS Trackers (1..N)                       │
                    │  push fixes via MQTT or HTTP POST          │
                    └──────────────┬─────────────────────────────┘
                                   │
                          ┌────────▼─────────┐
                          │  GpsView.Ingest  │   ← validates + persists
                          └────────┬─────────┘
                                   │
                  ┌────────────────┼─────────────────┐
                  │                │                 │
         ┌────────▼──────┐  ┌──────▼──────┐  ┌───────▼────────┐
         │ Tracker       │  │ Postgres +  │  │ Phoenix.PubSub │
         │ GenServer     │  │ TimescaleDB │  │ broadcast      │
         │ (1 per device)│  │ (hypertable)│  │ "tracker:7C2A" │
         └───────────────┘  └─────────────┘  └────────┬───────┘
                                                       │
                                              ┌────────▼─────────┐
                                              │ Phoenix Channels │
                                              │  (browser ws)    │
                                              └────────┬─────────┘
                                                       │
                                                ┌──────▼──────┐
                                                │ React UI    │
                                                │ (this repo) │
                                                └─────────────┘
```

## Why these choices

- **Phoenix Channels** over LiveView so the existing React UI keeps its
  interactivity (Leaflet, custom SVG charts, brush/scrub) without rewriting
  in HEEx. LiveView is a great option later if you want collaborative cursors.
- **Tracker GenServer** per device gives crash isolation, last-known-fix
  caching, and a clean place to put per-device logic (geofencing, alerts,
  derived state) without DB round-trips.
- **TimescaleDB hypertable** on `fixes(ts)` for automatic time-partitioning,
  10–20× compression on older chunks, and continuous aggregates that
  precompute hourly/daily summaries for the charts.
- **Postgres + PostGIS** for "points inside this polygon" queries when you
  add geofences or tile-based bounding-box loads.

## Directory layout

```
backend/
├── README.md                          ← you are here
├── HANDOFF.md                         ← read this next, especially for Claude Code
├── mix.exs                            ← deps + project config
├── config/
│   ├── config.exs                     ← shared config
│   ├── dev.exs                        ← dev DB + endpoint
│   └── runtime.exs                    ← prod env vars
├── priv/
│   └── repo/
│       └── migrations/
│           ├── 20260430_000001_enable_extensions.exs
│           ├── 20260430_000002_create_devices.exs
│           ├── 20260430_000003_create_fixes.exs
│           └── 20260430_000004_create_continuous_aggregates.exs
└── lib/
    ├── gps_view/
    │   ├── application.ex             ← supervision tree
    │   ├── repo.ex                    ← Ecto repo
    │   ├── devices/
    │   │   ├── device.ex              ← Ecto schema for trackers
    │   │   └── devices.ex             ← context module
    │   ├── tracks/
    │   │   ├── fix.ex                 ← Ecto schema for one GPS reading
    │   │   ├── tracks.ex              ← query API (windowed, decimated)
    │   │   └── decimate.ex            ← LTTB downsampling
    │   ├── ingest/
    │   │   ├── ingest.ex              ← entry point: validate → persist → broadcast
    │   │   └── tracker_server.ex      ← GenServer, one per device
    │   └── tracker_supervisor.ex      ← DynamicSupervisor for tracker_servers
    └── gps_view_web/
        ├── endpoint.ex                ← Phoenix endpoint
        ├── router.ex                  ← HTTP routes
        ├── controllers/
        │   ├── ingest_controller.ex   ← POST /api/ingest (HTTP fallback)
        │   ├── track_controller.ex    ← GET /api/tracks/:device
        │   └── device_controller.ex   ← GET /api/devices
        ├── channels/
        │   ├── user_socket.ex         ← socket auth
        │   └── tracker_channel.ex     ← "tracker:<device_id>" pubsub
        └── views/  (or /json/)
```

## Running it (once Claude Code finishes)

```bash
# 1. install Elixir 1.17+, Erlang 27+, Postgres 16 with TimescaleDB extension
asdf install elixir 1.17.3-otp-27
asdf install erlang 27.1
brew install postgresql@16 timescaledb            # macOS
# or use the timescaledb docker image

# 2. set up the project
cd backend
mix deps.get
mix ecto.create
mix ecto.migrate

# 3. seed a fake tracker for development
mix run priv/repo/seed_dev_track.exs

# 4. start the server
mix phx.server                                    # http://localhost:4000

# 5. point the React app at it
# In GPSView.html / app.jsx swap the mock data call for:
#   fetch('http://localhost:4000/api/tracks/7C2A?from=...&to=...')
# and connect a socket to ws://localhost:4000/socket
```

## Endpoints (sketch)

| Method | Path                           | Purpose                                             |
|--------|--------------------------------|-----------------------------------------------------|
| GET    | `/api/devices`                 | List trackers + last-seen status                    |
| GET    | `/api/tracks/:device`          | Time-windowed fixes; supports `from`, `to`, `max_points` (server-side LTTB) |
| GET    | `/api/tracks/:device/summary`  | Distance/duration/ascent/maxSpeed for a window      |
| POST   | `/api/ingest`                  | Tracker uploads a batch of fixes (HTTP fallback)    |
| WS     | `/socket` → `tracker:<id>`     | Live fix stream + state changes                     |

## Channel protocol

Client subscribes:

```js
const socket = new Phoenix.Socket("/socket", { params: { token } });
socket.connect();
const channel = socket.channel(`tracker:${deviceId}`, {});
channel.join()
  .receive("ok", ({ last_fix, status }) => { ... });
channel.on("fix", (fix) => { /* append to track */ });
channel.on("status", ({ online, battery_pct, sats }) => { ... });
```

Server pushes (`tracker_channel.ex`):

- `fix` — one new GPS reading, same shape as `Fix.t()`
- `status` — periodic summary (every 30s or on connect/disconnect)
- `synced` — full backfill done (after a tracker reconnects)

## What's mocked vs. real

The starter ships with:
- Real Ecto schemas + migrations
- Real GenServer + supervision tree
- A `seed_dev_track.exs` script that streams the same multi-modal fake data
  the React prototype generates (walk → drive → sail → fly → walk)
- Stubbed ingest controller — you can `curl` JSON at it to simulate a tracker

What's NOT included (Claude Code TODO):
- Auth (the channel currently accepts any token; add a real auth_token table)
- MQTT ingestion (HTTP works; add `tortoise` if your tracker speaks MQTT)
- Frontend integration (the existing React app still uses mock data; the
  `HANDOFF.md` has the exact diff to wire it up)
- Tests (a couple of example tests, but coverage is your call)
- Production deploy config (Fly.io / Gigalixir / your own — see runtime.exs)

See **HANDOFF.md** for the prioritized task list.

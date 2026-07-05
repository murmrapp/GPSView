# API Contract — GPSView

The React frontend talks to this API. Keep this doc in sync with reality.

Base URL: `http://localhost:4000` (dev). All bodies are JSON.

Auth is a placeholder for milestone 1: header `x-device-token: <secret>` for ingest endpoints; reads are unauthenticated locally. Replace with proper auth before deploying.

---

## REST

### `GET /api/devices`
List known trackers.

```json
[
  {
    "id": "7C2A",
    "name": "tracker-7C2A",
    "last_seen": "2026-03-26T21:32:56Z",
    "online": true,
    "battery_pct": 46.9,
    "last_fix": { "lat": -17.482265, "lon": -149.836807, "alt_m": 6.8 }
  }
]
```

### `GET /api/devices/:id`
Single device + connection status.

### `GET /api/devices/:id/tracks?from=&to=&limit=`
List tracks (sessions) for a device. A "track" is a contiguous run of fixes separated by an idle gap (default ≥ 30 min).

```json
[
  {
    "id": "01J...",
    "device_id": "7C2A",
    "started_at": "2026-03-26T07:42:00Z",
    "ended_at":   "2026-03-26T10:18:00Z",
    "point_count": 1247,
    "distance_km": 38.4,
    "max_speed_kts": 112.3,
    "name": "Moorea loop"
  }
]
```

### `GET /api/tracks/:id?decimate=2000&color_by=speed`
Fetch a track, server-side LTTB-decimated to ~`decimate` points (default 2000, max 10000).

```json
{
  "id": "01J...",
  "device_id": "7C2A",
  "summary": {
    "point_count": 1247,
    "decimated_to": 800,
    "distance_km": 38.4,
    "duration_min": 156,
    "max_speed_kts": 112.3,
    "ascent_m": 1820
  },
  "points": [
    { "t": 1742975376000, "lat": -17.481756, "lon": -149.839661,
      "alt_m": 0.9, "speed_kts": 1.28, "cog": 16, "satellites": 6,
      "hdop": 0.6, "battery_pct": 46.9, "battery_v": 3.816,
      "charge_rate": 1, "fix": 1, "boot": 826 }
  ]
}
```

`t` is Unix epoch ms (matches the existing frontend).

### `POST /api/ingest`
Tracker pushes a fix (or a batch).

Headers: `x-device-token: <secret>`

Single:
```json
{
  "device_id": "7C2A",
  "datetime": "2026-03-26T21:28:56Z",
  "lat": -17.481756, "lon": -149.839661,
  "alt_m": 0.9, "speed_kts": 1.28, "cog": 16,
  "satellites": 6, "hdop": 0.6,
  "battery_pct": 46.9, "battery_v": 3.816,
  "charge_rate": 1, "rtc_bat_low": false,
  "fix": 1, "boot": 826
}
```

Batch: send `{"fixes": [ … ]}`. Server upserts on `(device_id, ts)`.

Response: `202 Accepted` with `{"accepted": N}`.

### `PATCH /api/fixes/:id` / `DELETE /api/fixes/:id`
For the "edit data" feature. Audit-logged.

---

## Phoenix Channels

Topic: `device:<device_id>`

Join payload: `{}`. Reply: `{:ok, %{last_fix: ...}}`.

Server-pushed events:

- `"new_fix"` — `%{ point: <point object> }` whenever a fix arrives
- `"track_started"` — `%{ track_id, started_at }`
- `"track_ended"` — `%{ track_id, ended_at, summary }`

Client-sent:

- `"sync_request"` — triggers immediate re-poll of any pending tracker buffers (matches the "Sync from tracker" button in the UI)

---

## Errors

Standard JSON: `{ "error": "...", "code": "..." }` with HTTP 4xx/5xx.

Common codes:
- `unauthorized` — bad/missing token
- `bad_payload` — schema validation failed (include `details`)
- `not_found`
- `rate_limited`

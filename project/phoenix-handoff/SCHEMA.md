# Schema — GPSView

PostgreSQL 15+ with TimescaleDB and PostGIS extensions.

## Extensions

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- for gen_random_uuid()
```

## Tables

### `devices`
One row per physical tracker.

```sql
CREATE TABLE devices (
  id            TEXT PRIMARY KEY,                -- e.g. "7C2A" (tracker hardware id)
  name          TEXT NOT NULL,
  token_hash    TEXT NOT NULL,                   -- bcrypt'd device_token
  notes         TEXT,
  inserted_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### `fixes`  (hypertable)
One row per GPS fix.

```sql
CREATE TABLE fixes (
  device_id     TEXT NOT NULL REFERENCES devices(id),
  ts            TIMESTAMPTZ NOT NULL,
  lat           DOUBLE PRECISION NOT NULL,
  lon           DOUBLE PRECISION NOT NULL,
  alt_m         REAL,
  speed_kts     REAL,
  cog           SMALLINT,
  satellites    SMALLINT,
  hdop          REAL,
  battery_pct   REAL,
  battery_v     REAL,
  charge_rate   SMALLINT,
  rtc_bat_low   BOOLEAN,
  fix           SMALLINT,
  boot          INTEGER,
  geom          GEOGRAPHY(POINT, 4326)
                  GENERATED ALWAYS AS (ST_MakePoint(lon, lat)::geography) STORED,
  PRIMARY KEY (device_id, ts)
);

SELECT create_hypertable('fixes', 'ts', chunk_time_interval => INTERVAL '7 days');

CREATE INDEX fixes_device_ts_idx ON fixes (device_id, ts DESC);
CREATE INDEX fixes_geom_idx     ON fixes USING GIST (geom);
```

### `tracks`
A track is a contiguous session, derived from `fixes`. Maintained by a periodic Oban job (or computed on demand for milestone 1).

```sql
CREATE TABLE tracks (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id     TEXT NOT NULL REFERENCES devices(id),
  started_at    TIMESTAMPTZ NOT NULL,
  ended_at      TIMESTAMPTZ NOT NULL,
  name          TEXT,
  point_count   INTEGER NOT NULL,
  distance_km   DOUBLE PRECISION NOT NULL,
  max_speed_kts REAL,
  ascent_m      REAL,
  inserted_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT track_window UNIQUE (device_id, started_at)
);

CREATE INDEX tracks_device_idx ON tracks (device_id, started_at DESC);
```

## Future optimizations (notes for later)

- **Continuous aggregates** for hourly/daily summaries (avg/max speed, distance) — Timescale feature; precompute for fast chart loads on long tracks.
- **Compression policy** on chunks older than 30 days — typical 10–20× reduction.
- **Retention policy** if you ever want to cap storage.

```sql
-- example, not for milestone 1:
ALTER TABLE fixes SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'device_id'
);
SELECT add_compression_policy('fixes', INTERVAL '30 days');
```

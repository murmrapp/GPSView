# lib/gpsview/trackers.ex
defmodule GPSView.Trackers do
  @moduledoc """
  Public context for tracker data. Web layer calls only this module —
  never the schemas directly.
  """
  import Ecto.Query, warn: false
  alias GPSView.Repo
  alias GPSView.Trackers.{Device, Fix, Track, DeviceSupervisor, DeviceServer}
  alias GPSView.Decimate

  # ── Devices ─────────────────────────────────────────────────────────

  def list_devices, do: Repo.all(from d in Device, order_by: d.id)

  def get_device(id), do: Repo.get(Device, id)
  def get_device!(id), do: Repo.get!(Device, id)

  def register_device(attrs, raw_token) when is_binary(raw_token) do
    %Device{}
    |> Device.changeset(attrs)
    |> Device.put_token(raw_token)
    |> Repo.insert()
  end

  def authenticate_device(device_id, raw_token) do
    case get_device(device_id) do
      nil -> {:error, :unauthorized}
      device ->
        if Device.verify_token(device, raw_token),
          do: {:ok, device},
          else: {:error, :unauthorized}
    end
  end

  # ── Ingest ──────────────────────────────────────────────────────────

  @doc "Hand a payload (or list of payloads) to the device's GenServer."
  def ingest_fix(device_id, payload_or_list) do
    {:ok, _pid} = DeviceSupervisor.ensure_started(device_id)
    case payload_or_list do
      list when is_list(list) -> Enum.each(list, &DeviceServer.ingest(device_id, &1))
      one when is_map(one)    -> DeviceServer.ingest(device_id, one)
    end
    :ok
  end

  @doc "Insert a batch of fixes. Idempotent on (device_id, ts) via upsert."
  def insert_fixes(device_id, payloads) when is_list(payloads) do
    rows =
      payloads
      |> Enum.map(&Fix.from_payload(&1, device_id))
      |> Enum.map(&cast_payload/1)
      |> Enum.reject(&is_nil/1)

    case rows do
      [] -> {:ok, []}
      rows ->
        Repo.insert_all("fixes", rows,
          on_conflict: :nothing,
          conflict_target: [:device_id, :ts],
          returning: false
        )
        {:ok, rows}
    end
  end

  defp cast_payload(p) do
    cs = Fix.changeset(%Fix{}, p)
    if cs.valid?, do: Map.take(Ecto.Changeset.apply_changes(cs), Fix.__schema__(:fields))
  end

  # ── Tracks ──────────────────────────────────────────────────────────

  def list_tracks(device_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    Repo.all(
      from t in Track,
        where: t.device_id == ^device_id,
        order_by: [desc: t.started_at],
        limit: ^limit
    )
  end

  def get_track(track_id), do: Repo.get(Track, track_id)

  def get_track(device_id, track_id) do
    Repo.one(from t in Track, where: t.device_id == ^device_id and t.id == ^track_id)
  end

  @doc "Decimate `points` to ~`target` items via LTTB."
  def decimate(points, target), do: Decimate.lttb(points, target)

  @doc "Fetch all fixes for a track, decimated to ~target points (default 2000)."
  def fetch_track_points(%Track{} = track, target \\ 2000) do
    points =
      Repo.all(
        from f in Fix,
          where: f.device_id == ^track.device_id and
                 f.ts >= ^track.started_at and
                 f.ts <= ^track.ended_at,
          order_by: [asc: f.ts],
          select: %{
            t: f.ts, lat: f.lat, lon: f.lon, alt_m: f.alt_m,
            speed_kts: f.speed_kts, cog: f.cog, satellites: f.satellites,
            hdop: f.hdop, battery_pct: f.battery_pct, battery_v: f.battery_v,
            charge_rate: f.charge_rate, fix: f.fix, boot: f.boot
          }
      )

    Decimate.lttb(points, target)
  end

  # ── Fixes (raw, no track grouping) ──────────────────────────────────

  @doc """
  Fetch GPS-locked fixes for a device, ordered by `ts` ascending. If
  `target` is a positive integer, LTTB-decimate to ~that many points;
  if `nil`, return all points unchanged (full resolution).

  Rows with NULL `lat` or `lon` (tracker on but no GPS lock) are skipped —
  the map can't plot them and including them would yield gaps in the
  polyline. They remain in the DB for analytics; query separately if needed.
  """
  def fetch_device_fixes(device_id, target \\ nil) when is_binary(device_id) do
    points =
      Repo.all(
        from f in Fix,
          where: f.device_id == ^device_id and not is_nil(f.lat) and not is_nil(f.lon),
          order_by: [asc: f.ts],
          select: %{
            t: f.ts, lat: f.lat, lon: f.lon, alt_m: f.alt_m,
            speed_kts: f.speed_kts, cog: f.cog, satellites: f.satellites,
            hdop: f.hdop, battery_pct: f.battery_pct, battery_v: f.battery_v,
            charge_rate: f.charge_rate, fix: f.fix, boot: f.boot
          }
      )

    if target, do: Decimate.lttb(points, target), else: points
  end

  # ── Wire format ─────────────────────────────────────────────────────

  @doc """
  Build the JSON envelope that `/api/fixes` and the static export both
  serve. `device` is a `Device` struct; `points` is the (optionally
  decimated) list of point maps from `fetch_device_fixes/2`.
  """
  def wire_envelope(%Device{} = device, points) do
    first = List.first(points)
    last = List.last(points)

    %{
      device_id: device.id,
      name: device.name,
      summary: %{
        point_count: length(points),
        started_at: first && first.t,
        ended_at: last && last.t
      },
      points: Enum.map(points, &wire_point/1)
    }
  end

  defp wire_point(f) do
    %{
      t: DateTime.to_unix(f.t, :millisecond),
      lat: f.lat,
      lon: f.lon,
      alt_m: f.alt_m,
      speed_kts: f.speed_kts,
      cog: f.cog,
      satellites: f.satellites,
      hdop: f.hdop,
      battery_pct: f.battery_pct,
      battery_v: f.battery_v,
      charge_rate: f.charge_rate,
      fix: f.fix,
      boot: f.boot
    }
  end
end

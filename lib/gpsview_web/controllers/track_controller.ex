# lib/gpsview_web/controllers/track_controller.ex
defmodule GPSViewWeb.TrackController do
  use GPSViewWeb, :controller

  alias GPSView.Trackers

  # GET /api/devices/:id/tracks
  def index(conn, %{"id" => device_id} = params) do
    tracks = Trackers.list_tracks(device_id, limit: parse_limit(params))
    json(conn, tracks)
  end

  # GET /api/tracks/:id?decimate=2000
  def show(conn, %{"id" => id} = params) do
    case Trackers.get_track(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      track ->
        target = (params["decimate"] || "2000") |> String.to_integer() |> min(10_000)
        points = Trackers.fetch_track_points(track)
        decimated = Trackers.decimate(points, target)

        json(conn, %{
          id: track.id,
          device_id: track.device_id,
          summary: %{
            point_count: track.point_count,
            decimated_to: length(decimated),
            distance_km: track.distance_km,
            duration_min: DateTime.diff(track.ended_at, track.started_at) / 60,
            max_speed_kts: track.max_speed_kts,
            ascent_m: track.ascent_m
          },
          points: Enum.map(decimated, &point_to_wire/1)
        })
    end
  end

  defp parse_limit(params),
    do: params["limit"] |> Kernel.||("50") |> String.to_integer() |> min(500)

  # JSON shape matching the React UI's `t` (epoch ms) field
  defp point_to_wire(f) do
    %{
      t: DateTime.to_unix(f.ts, :millisecond),
      lat: f.lat, lon: f.lon, alt_m: f.alt_m,
      speed_kts: f.speed_kts, cog: f.cog,
      satellites: f.satellites, hdop: f.hdop,
      battery_pct: f.battery_pct, battery_v: f.battery_v,
      charge_rate: f.charge_rate, fix: f.fix, boot: f.boot
    }
  end
end

defmodule GPSViewWeb.FixController do
  use GPSViewWeb, :controller

  alias GPSView.Trackers

  # GET /api/fixes?device_id=:id[&decimate=N]
  # decimate=0 (or absent) returns ALL points (no LTTB). Pass a positive
  # integer to LTTB-decimate to ~that many points (capped at 200_000).
  def index(conn, %{"device_id" => device_id} = params) do
    case Trackers.get_device(device_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "device_not_found"})

      device ->
        points = Trackers.fetch_device_fixes(device_id, parse_decimate(params["decimate"]))
        json(conn, Trackers.wire_envelope(device, points))
    end
  end

  def index(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "device_id_required"})
  end

  defp parse_decimate(nil), do: nil
  defp parse_decimate(""), do: nil
  defp parse_decimate("0"), do: nil
  defp parse_decimate(d), do: d |> String.to_integer() |> max(1) |> min(200_000)
end

# lib/gpsview_web/controllers/ingest_controller.ex
defmodule GPSViewWeb.IngestController do
  use GPSViewWeb, :controller

  alias GPSView.Trackers

  # POST /api/ingest
  # Headers: x-device-token: <secret>
  def create(conn, params) do
    with {:ok, device_id} <- fetch_device_id(params),
         {:ok, token}     <- fetch_token(conn),
         {:ok, _device}   <- Trackers.authenticate_device(device_id, token) do
      payloads = params["fixes"] || [params]
      :ok = Trackers.ingest_fix(device_id, payloads)

      conn
      |> put_status(:accepted)
      |> json(%{accepted: length(payloads)})
    else
      :error ->
        conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: "bad_payload", details: reason})
    end
  end

  defp fetch_device_id(%{"device_id" => id}) when is_binary(id), do: {:ok, id}
  defp fetch_device_id(_), do: {:error, "missing device_id"}

  defp fetch_token(conn) do
    case Plug.Conn.get_req_header(conn, "x-device-token") do
      [t | _] when byte_size(t) > 0 -> {:ok, t}
      _ -> :error
    end
  end
end

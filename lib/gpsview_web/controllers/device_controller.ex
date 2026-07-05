defmodule GPSViewWeb.DeviceController do
  use GPSViewWeb, :controller

  alias GPSView.Trackers

  def index(conn, _params), do: json(conn, Trackers.list_devices())

  def show(conn, %{"id" => id}) do
    case Trackers.get_device(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
      device -> json(conn, device)
    end
  end
end

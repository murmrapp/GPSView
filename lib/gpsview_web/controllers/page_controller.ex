defmodule GPSViewWeb.PageController do
  use GPSViewWeb, :controller

  @index_path Application.app_dir(:gpsview, "priv/static/index.html")

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, @index_path)
  end
end

defmodule GPSView.Repo do
  use Ecto.Repo,
    otp_app: :gpsview,
    adapter: Ecto.Adapters.SQLite3
end

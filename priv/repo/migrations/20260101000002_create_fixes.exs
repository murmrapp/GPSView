defmodule GPSView.Repo.Migrations.CreateFixes do
  use Ecto.Migration

  def change do
    create table(:fixes, primary_key: false) do
      add :device_id,    references(:devices, type: :string, on_delete: :delete_all), null: false, primary_key: true
      add :ts,           :utc_datetime_usec, null: false, primary_key: true
      # lat/lon are nullable so we can store "tracker was on but had no GPS lock"
      # rows alongside real fixes (matches what gps_log_viewer.html keeps in memory).
      add :lat,          :float
      add :lon,          :float
      add :alt_m,        :float
      add :speed_kts,    :float
      # cog/charge_rate stored as float — some trackers log decimal precision
      # (e.g. cog "31.0" and charge_rate "-9.6") so int casts would reject them.
      add :cog,          :float
      add :satellites,   :integer
      add :hdop,         :float
      add :battery_pct,  :float
      add :battery_v,    :float
      add :charge_rate,  :float
      add :rtc_bat_low,  :boolean
      add :fix,          :integer
      add :boot,         :integer
    end

    create index(:fixes, [:device_id, :ts])
  end
end

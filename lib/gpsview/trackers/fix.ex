# lib/gpsview/trackers/fix.ex
defmodule GPSView.Trackers.Fix do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @derive {Jason.Encoder, only: ~w(device_id ts lat lon alt_m speed_kts cog satellites
           hdop battery_pct battery_v charge_rate rtc_bat_low fix boot reconstructed)a}
  schema "fixes" do
    field :device_id,    :string,  primary_key: true
    field :ts,           :utc_datetime_usec, primary_key: true
    field :lat,          :float
    field :lon,          :float
    field :alt_m,        :float
    field :speed_kts,    :float
    field :cog,          :float
    field :satellites,   :integer
    field :hdop,         :float
    field :battery_pct,  :float
    field :battery_v,    :float
    field :charge_rate,  :float
    field :rtc_bat_low,  :boolean
    field :fix,          :integer
    field :boot,         :integer
    # True for rows whose lat/lon were filled in by reconstruct_gaps, not by
    # the tracker. Default false; never cast from import payloads.
    field :reconstructed, :boolean, default: false
  end

  @required ~w(device_id ts)a
  @optional ~w(lat lon alt_m speed_kts cog satellites hdop battery_pct battery_v
               charge_rate rtc_bat_low fix boot)a

  def changeset(fix, attrs) do
    fix
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:lat, greater_than_or_equal_to: -90,  less_than_or_equal_to: 90)
    |> validate_number(:lon, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> validate_number(:satellites, greater_than_or_equal_to: 0, less_than_or_equal_to: 64)
  end

  @doc "Map an incoming JSON payload onto our column names."
  def from_payload(%{"datetime" => dt} = p, device_id) do
    %{
      "device_id"   => device_id,
      "ts"          => dt,
      "lat"         => p["lat"],
      "lon"         => p["lon"],
      "alt_m"       => p["alt_m"],
      "speed_kts"   => p["speed_kts"],
      "cog"         => p["cog"],
      "satellites"  => p["satellites"],
      "hdop"        => p["hdop"],
      "battery_pct" => p["battery_pct"],
      "battery_v"   => p["battery_v"],
      "charge_rate" => p["charge_rate"],
      "rtc_bat_low" => p["rtc_bat_low"],
      "fix"         => p["fix"],
      "boot"        => p["boot"]
    }
  end
end

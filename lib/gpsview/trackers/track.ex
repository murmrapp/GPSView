# lib/gpsview/trackers/track.ex
defmodule GPSView.Trackers.Track do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @derive {Jason.Encoder, only: ~w(id device_id name started_at ended_at
           point_count distance_km max_speed_kts ascent_m)a}
  schema "tracks" do
    field :device_id,     :string
    field :name,          :string
    field :started_at,    :utc_datetime_usec
    field :ended_at,      :utc_datetime_usec
    field :point_count,   :integer, default: 0
    field :distance_km,   :float,   default: 0.0
    field :max_speed_kts, :float
    field :ascent_m,      :float

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @cast_fields ~w(device_id name started_at ended_at point_count
                  distance_km max_speed_kts ascent_m)a

  def changeset(track, attrs) do
    track
    |> cast(attrs, @cast_fields)
    |> validate_required([:device_id, :started_at, :ended_at, :point_count, :distance_km])
    |> unique_constraint([:device_id, :started_at])
  end
end

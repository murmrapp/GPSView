defmodule GPSView.Repo.Migrations.CreateTracks do
  use Ecto.Migration

  def change do
    create table(:tracks, primary_key: false) do
      add :id,            :binary_id, primary_key: true
      add :device_id,     references(:devices, type: :string, on_delete: :delete_all), null: false
      add :name,          :string
      add :started_at,    :utc_datetime_usec, null: false
      add :ended_at,      :utc_datetime_usec, null: false
      add :point_count,   :integer, null: false
      add :distance_km,   :float,   null: false
      add :max_speed_kts, :float
      add :ascent_m,      :float

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:tracks, [:device_id, :started_at])
  end
end

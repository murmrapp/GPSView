defmodule GPSView.Repo.Migrations.CreateDevices do
  use Ecto.Migration

  def change do
    create table(:devices, primary_key: false) do
      add :id,         :string, primary_key: true
      add :name,       :string, null: false
      add :token_hash, :string, null: false
      add :notes,      :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:devices, [:name])
  end
end

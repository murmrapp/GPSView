# lib/gpsview/trackers/device.ex
defmodule GPSView.Trackers.Device do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @derive {Jason.Encoder, only: [:id, :name, :notes, :inserted_at, :updated_at]}
  schema "devices" do
    field :name,       :string
    field :token_hash, :string
    field :notes,      :string

    has_many :fixes, GPSView.Trackers.Fix, foreign_key: :device_id
    has_many :tracks, GPSView.Trackers.Track, foreign_key: :device_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, [:id, :name, :notes])
    |> validate_required([:id, :name])
    |> validate_length(:id, min: 2, max: 32)
    |> unique_constraint(:id, name: :devices_pkey)
  end

  def put_token(changeset, raw_token) do
    put_change(changeset, :token_hash, Bcrypt.hash_pwd_salt(raw_token))
  end

  def verify_token(%__MODULE__{token_hash: hash}, raw_token) when is_binary(raw_token) do
    Bcrypt.verify_pass(raw_token, hash)
  end
end

defmodule GPSView.Repo.Migrations.AddReconstructedToFixes do
  use Ecto.Migration

  def change do
    alter table(:fixes) do
      # Marks rows whose lat/lon were not actually measured by the tracker
      # but were great-circle-interpolated by mix gpsview.reconstruct_gaps.
      # Lets the UI / analytics tell real fixes apart from synthesised ones.
      add :reconstructed, :boolean, default: false, null: false
    end
  end
end

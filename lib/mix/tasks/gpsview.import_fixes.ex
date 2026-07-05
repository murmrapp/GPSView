defmodule Mix.Tasks.Gpsview.ImportFixes do
  @shortdoc "Import a CSV of GPS fixes (idempotent on device_id+ts)"

  @moduledoc """
  Import a CSV of GPS fixes into the local SQLite DB.

      mix gpsview.import_fixes path/to/file.csv --device 7C2A

  Options:

    * `--device`   Device ID to attach the fixes to (required).
    * `--name`     Display name when the device has to be auto-created
      (defaults to the device id).
    * `--columns`  Comma-separated list of column names that overrides the
      CSV header. Only needed when auto-detection can't pick the layout.

  Auto-detects four common tracker-export layouts (matches the logic in
  `gps_log_viewer.html`):

    * **New header (14) + new data (14)** — direct mapping by header.
    * **New header (14) + old data (11)** — header advertises columns the
      tracker doesn't actually emit; data is mapped by the *old* positional
      layout: `datetime, lat, lon, alt_m, speed_kts, satellites, hdop,
      battery_pct, battery_v, fix, boot` (no `cog`/`charge_rate`/`rtc_bat_low`).
    * **Old header (≤11) + new data (14)** — data is mapped by the *new*
      positional layout: `datetime, lat, lon, alt_m, speed_kts, cog,
      satellites, hdop, battery_pct, battery_v, charge_rate, rtc_bat_low,
      fix, boot`.
    * **Otherwise** — direct mapping by header (zip).

  Recognised column names map to the `fixes` schema. Extra columns are
  ignored. Empty cells are treated as NULL. Naive ISO8601 timestamps (no
  `Z` / no offset) are assumed to be UTC.

  Inserts use `ON CONFLICT (device_id, ts) DO NOTHING`, so re-running the
  same file or a partially overlapping one is idempotent — only new rows
  are added.
  """
  use Mix.Task

  alias GPSView.{Repo, Trackers}
  alias GPSView.Trackers.Fix

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} =
      OptionParser.parse(argv, strict: [device: :string, name: :string, columns: :string])

    csv_path =
      case args do
        [path] -> path
        _ -> Mix.raise("usage: mix gpsview.import_fixes <csv_path> --device <id>")
      end

    device_id = opts[:device] || Mix.raise("--device is required")
    name = opts[:name] || device_id
    column_override = opts[:columns] && String.split(opts[:columns], ",", trim: true)

    File.exists?(csv_path) || Mix.raise("file not found: #{csv_path}")

    Mix.Task.run("app.start")

    ensure_device(device_id, name)

    {parsed, payloads} = parse_csv(csv_path, device_id, column_override)

    {valid_rows, invalid_count, first_invalid} =
      Enum.reduce(payloads, {[], 0, nil}, fn payload, {acc, bad, first} ->
        cs = Fix.changeset(%Fix{}, payload)

        if cs.valid? do
          row = Map.take(Ecto.Changeset.apply_changes(cs), Fix.__schema__(:fields))
          {[row | acc], bad, first}
        else
          {acc, bad + 1, first || {payload, changeset_errors(cs)}}
        end
      end)

    rows = Enum.reverse(valid_rows)

    # SQLite caps prepared-statement parameters at 32766. With 15 columns per row
    # we stay well under by chunking at 1000.
    inserted =
      rows
      |> Enum.chunk_every(1000)
      |> Enum.reduce(0, fn chunk, acc ->
        {n, _} =
          Repo.insert_all("fixes", chunk,
            on_conflict: :nothing,
            conflict_target: [:device_id, :ts]
          )

        acc + n
      end)

    Mix.shell().info("""
    parsed:     #{parsed}
    invalid:    #{invalid_count}
    inserted:   #{inserted}
    duplicates: #{length(rows) - inserted}
    """)

    if first_invalid do
      {payload, errs} = first_invalid
      Mix.shell().info("first invalid row errors:  #{inspect(errs)}")
      Mix.shell().info("first invalid row payload: #{inspect(payload)}")
    end
  end

  defp ensure_device(id, name) do
    case Trackers.get_device(id) do
      nil ->
        {:ok, _} = Trackers.register_device(%{"id" => id, "name" => name}, "imported")
        Mix.shell().info("created device #{id}")

      _ ->
        :ok
    end
  end

  # Positional layouts the auto-detector falls back to when the header
  # advertises a different column count than the data rows actually emit.
  # Mirror of the format detection in gps_log_viewer.html.
  @old_columns ~w(datetime lat lon alt_m speed_kts satellites hdop battery_pct battery_v fix boot)
  @new_columns ~w(datetime lat lon alt_m speed_kts cog satellites hdop battery_pct battery_v charge_rate rtc_bat_low fix boot)

  defp parse_csv(path, device_id, column_override) do
    [file_header | rows] =
      path
      |> File.stream!()
      |> NimbleCSV.RFC4180.parse_stream(skip_headers: false)
      |> Enum.to_list()

    # Trackers sometimes append a fresh log session into the same file and
    # re-emit the column header. Drop any row that exactly matches the
    # leading header so it isn't treated as data.
    rows = Enum.reject(rows, &(&1 == file_header))

    header_for_each = fn row -> pick_header(column_override || file_header, row) end

    payloads =
      Enum.map(rows, fn row ->
        header_for_each.(row)
        |> Enum.zip(row)
        |> Map.new(fn
          {k, ""} -> {k, nil}
          {k, v} when v in ["nan", "NaN", "NAN"] -> {k, nil}
          {"datetime", v} -> {"datetime", normalize_iso8601(v)}
          {k, v} -> {k, v}
        end)
        |> Fix.from_payload(device_id)
      end)

    {length(rows), payloads}
  end

  # If --columns was explicit, trust it. Otherwise pick a layout that matches
  # the data row width — covers the four header/data-width combinations the
  # standalone viewer handles.
  defp pick_header(header, row) do
    h = length(header)
    r = length(row)

    cond do
      h >= 14 and r >= 14 -> header
      h >= 14 and r >= 11 and r < 14 -> @old_columns
      h <= 11 and r >= 14 -> @new_columns
      true -> header
    end
  end

  # Append "Z" if the value looks like ISO8601 with no timezone marker
  # (e.g. "2026-03-26T21:28:56"). Tracker CSV exports often omit the suffix.
  defp normalize_iso8601(nil), do: nil

  defp normalize_iso8601(v) when is_binary(v) do
    if String.ends_with?(v, "Z") or Regex.match?(~r/[+\-]\d{2}:?\d{2}$/, v),
      do: v,
      else: v <> "Z"
  end

  defp normalize_iso8601(other), do: other

  defp changeset_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end

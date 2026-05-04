defmodule Mix.Tasks.Gpsview.StaticExport do
  @shortdoc "Bake the React UI + a JSON snapshot of every device into a static folder for GitHub Pages"

  @moduledoc """
  Pre-renders what the live Phoenix endpoints `/api/devices` and
  `/api/fixes?device_id=...` would return into static JSON files, and
  copies the React/Leaflet UI alongside them. The result is a fully
  self-contained directory that any static host (GitHub Pages, S3,
  Cloudflare Pages, etc.) can serve.

      mix gpsview.static_export                # writes to ./docs (GitHub Pages default)
      mix gpsview.static_export --out _site
      mix gpsview.static_export --decimate 5000

  Options:

    * `--out`       Output directory (default `docs`).
    * `--decimate`  LTTB target per device (default `0` = full resolution,
      matching the live API default). Use a smaller number to keep the
      committed JSON small if the repo is bloating.

  Output layout:

      <out>/
        index.html              ← copy of priv/static/index.html with
                                  window.GPSDATA_STATIC = true injected
        css/, js/, favicon.ico, robots.txt
        data/devices.json       ← list of trackers
        data/<id>.json          ← per-tracker dump (same shape as /api/fixes)

  Idempotent: re-runs overwrite the managed files. Files in the output
  directory that this task didn't write (e.g. a `CNAME` for a custom
  domain) are left alone.
  """
  use Mix.Task

  alias GPSView.Trackers

  @priv_static "priv/static"

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [out: :string, decimate: :integer])

    out_dir = opts[:out] || "docs"
    decimate = opts[:decimate] || 0
    target = if decimate > 0, do: decimate, else: nil

    Mix.Task.run("app.start")

    File.mkdir_p!(out_dir)
    File.mkdir_p!(Path.join(out_dir, "data"))

    copy_ui_tree(out_dir)
    inject_static_flag(out_dir)

    devices = Trackers.list_devices()
    write_devices_index(out_dir, devices)

    Enum.each(devices, fn device ->
      write_device_dump(out_dir, device, target)
    end)

    Mix.shell().info("""

    Static export complete → #{out_dir}/
      devices: #{length(devices)}
      decimate: #{if target, do: "~#{target} pts/device", else: "full resolution"}

    To publish on GitHub Pages:
      git add #{out_dir}/
      git commit -m "data update"
      git push
    """)
  end

  # Copy the entire priv/static/ tree into <out>/, mirroring directory
  # structure. Files are overwritten if they already exist.
  defp copy_ui_tree(out_dir) do
    src = Application.app_dir(:gpsview, @priv_static)
    File.cp_r!(src, out_dir)
  end

  # Add `<script>window.GPSDATA_STATIC = true; window.GPSDATA_VERSION = "...";</script>`
  # just before the data.js script tag in index.html. The frontend uses
  # GPSDATA_STATIC to switch from /api/* to data/* fetches, and appends
  # GPSDATA_VERSION as `?v=` to bust the GitHub Pages CDN cache when
  # `mix gpsview.static_export` re-bakes the bundle.
  #
  # Re-injects on every run: if the flag is already present, the whole
  # script tag is replaced so the version stamp refreshes.
  defp inject_static_flag(out_dir) do
    path = Path.join(out_dir, "index.html")
    html = File.read!(path)

    version = DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()
    flag = ~s|<script>window.GPSDATA_STATIC = true; window.GPSDATA_VERSION = "#{version}";</script>|

    new =
      cond do
        String.contains?(html, "GPSDATA_STATIC") ->
          String.replace(
            html,
            ~r|<script>window\.GPSDATA_STATIC[^<]*</script>|,
            flag,
            global: false
          )

        String.contains?(html, ~s|<script src="js/data.js">|) ->
          String.replace(
            html,
            ~s|<script src="js/data.js">|,
            "#{flag}\n  <script src=\"js/data.js\">",
            global: false
          )

        true ->
          Mix.raise("could not find js/data.js script tag in #{path} — index.html may have been edited")
      end

    File.write!(path, new)
  end

  defp write_devices_index(out_dir, devices) do
    json =
      devices
      |> Enum.map(fn d ->
        %{
          id: d.id,
          name: d.name,
          notes: d.notes,
          inserted_at: d.inserted_at,
          updated_at: d.updated_at
        }
      end)
      |> Jason.encode!()

    File.write!(Path.join([out_dir, "data", "devices.json"]), json)
    Mix.shell().info("wrote data/devices.json (#{length(devices)} devices)")
  end

  defp write_device_dump(out_dir, device, target) do
    points = Trackers.fetch_device_fixes(device.id, target)
    payload = Trackers.wire_envelope(device, points)
    json = Jason.encode!(payload)

    path = Path.join([out_dir, "data", "#{device.id}.json"])
    File.write!(path, json)

    size_mb = byte_size(json) / 1_048_576
    Mix.shell().info(
      "wrote data/#{device.id}.json (#{length(points)} pts, #{:erlang.float_to_binary(size_mb, decimals: 2)} MB)"
    )
  end
end

defmodule Mix.Tasks.Gpsview.ReconstructGaps do
  @shortdoc "Fill in flight-gap rows with great-circle interpolated positions"

  @moduledoc """
  Two passes, both gated by the same flight heuristic (gap > 1h,
  dist > 100 km, implied speed > 100 km/h):

  1. **Gap UPDATE pass.** Walks `fixes` ordered by `ts`, finds runs of
     rows with NULL `lat`/`lon` bracketed by GPS-locked rows, and fills
     them in place with great-circle interpolated `lat`/`lon`, a
     synthetic flight altitude profile (climb / cruise at 10668 m /
     descent), and per-segment haversine speeds.

  2. **Empty-window INSERT pass.** Walks consecutive non-NULL fixes,
     finds pairs with **zero rows between them** that still look like a
     flight, and inserts synthesised rows at a 5-minute cadence.

  Both passes mark the affected rows with `reconstructed = 1`.

      mix gpsview.reconstruct_gaps --device Bluey

  Without `--device`, reconstructs gaps for every device in the DB.

  **Per-leg overrides** for the empty-window pass — repeatable. Useful
  when the bracketing fixes are imprecise (tracker last seen at hotel,
  not airport) or when the desired cruise altitude differs from the
  default. A leg matches an empty window when its `depart` falls
  between the bracketing fixes' timestamps.

      mix gpsview.reconstruct_gaps --device Bluey \\
        --leg "depart=2026-05-19T19:20:00Z,arrive=2026-05-19T20:55:00Z,\\
               from=36.6749,-4.4991,to=41.2974,2.0833,cruise=10973"

  Idempotent: UPDATE pass skips already-filled rows; INSERT pass uses
  `ON CONFLICT (device_id, ts) DO NOTHING`.

  Port of `reconstructFlightGaps` in `gps_log_viewer.html` (lines 925-1008),
  extended for the empty-window case the standalone viewer doesn't cover.
  """
  use Mix.Task

  alias GPSView.{Repo, Trackers}
  alias GPSView.Trackers.Fix
  import Ecto.Query

  @cruise_alt_m 10_668
  @min_gap_ms 60 * 60 * 1000
  @min_gap_m 100_000
  @min_speed_kmh 100
  @empty_step_ms 5 * 60 * 1000

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [device: :string, leg: [:string, :keep]])

    Mix.Task.run("app.start")

    legs = opts |> Keyword.get_values(:leg) |> Enum.map(&parse_leg/1)

    device_ids =
      case opts[:device] do
        nil -> Enum.map(Trackers.list_devices(), & &1.id)
        id -> [id]
      end

    Enum.each(device_ids, &reconstruct_for_device(&1, legs))
  end

  defp reconstruct_for_device(device_id, legs) do
    rows =
      Repo.all(
        from f in Fix,
          where: f.device_id == ^device_id,
          order_by: [asc: f.ts],
          select: %{ts: f.ts, lat: f.lat, lon: f.lon, alt_m: f.alt_m}
      )
      |> Enum.with_index()

    gaps = find_gaps(rows)
    qualifying = Enum.filter(gaps, &flight_gap?/1)

    empty_windows = find_empty_windows(rows)

    Mix.shell().info("""
    [#{device_id}] NULL-lat gaps found:      #{length(gaps)}
                 NULL-lat gaps qualifying: #{length(qualifying)}
                 empty windows found:      #{length(empty_windows)}
    """)

    # Use raw SQL because ecto_sqlite3 serialises DateTime parameters as
    # "YYYY-MM-DD HH:MM:SS.ffffffZ" while the stored column format is
    # "YYYY-MM-DDTHH:MM:SS.ffffff" — string equality on the WHERE side
    # silently misses every row when going through the Ecto.Query DSL.
    {recon_count, total} =
      Enum.reduce(qualifying, {0, 0}, fn gap, {ok_acc, total_acc} ->
        rows = synthesize(gap)
        ok =
          Repo.transaction(fn ->
            Enum.reduce(rows, 0, fn row, n ->
              ts_str = row.ts |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()

              %{num_rows: count} =
                Ecto.Adapters.SQL.query!(
                  Repo,
                  "UPDATE fixes SET lat = ?, lon = ?, alt_m = ?, speed_kts = ?, reconstructed = 1 WHERE device_id = ? AND ts = ?",
                  [row.lat, row.lon, row.alt_m, row.speed_kts, device_id, ts_str]
                )

              n + count
            end)
          end)

        case ok do
          {:ok, n} -> {ok_acc + n, total_acc + length(rows)}
          _ -> {ok_acc, total_acc + length(rows)}
        end
      end)

    Mix.shell().info("[#{device_id}] gap points reconstructed: #{recon_count} of #{total}")

    {empty_inserted, empty_attempted} =
      Enum.reduce(empty_windows, {0, 0}, fn window, {ok_acc, total_acc} ->
        leg = match_leg(window, legs)
        rows = synthesize_empty(window, leg)

        ok =
          Repo.transaction(fn ->
            Enum.reduce(rows, 0, fn row, n ->
              ts_str = format_ts(row.ts)

              %{num_rows: count} =
                Ecto.Adapters.SQL.query!(
                  Repo,
                  "INSERT INTO fixes (device_id, ts, lat, lon, alt_m, speed_kts, reconstructed) VALUES (?, ?, ?, ?, ?, ?, 1) ON CONFLICT (device_id, ts) DO NOTHING",
                  [device_id, ts_str, row.lat, row.lon, row.alt_m, row.speed_kts]
                )

              n + count
            end)
          end)

        case ok do
          {:ok, n} -> {ok_acc + n, total_acc + length(rows)}
          _ -> {ok_acc, total_acc + length(rows)}
        end
      end)

    Mix.shell().info("[#{device_id}] empty-window rows inserted: #{empty_inserted} of #{empty_attempted}")
  end

  # Returns a list of %{gap_start_idx, gap_end_idx, before, after, gap_rows}
  # for each run of NULL-lat rows bracketed by non-NULL rows.
  defp find_gaps(indexed_rows) do
    rows = Enum.map(indexed_rows, fn {r, _i} -> r end)
    n = length(rows)
    arr = List.to_tuple(rows)

    do_find_gaps(arr, 0, n, [])
    |> Enum.reverse()
  end

  defp do_find_gaps(_arr, i, n, acc) when i >= n, do: acc
  defp do_find_gaps(arr, i, n, acc) do
    row = elem(arr, i)
    if is_nil(row.lat) do
      gap_start = i
      gap_end = scan_to_fix(arr, i, n)

      before = scan_back_for_fix(arr, gap_start - 1)
      after_ = scan_forward_for_fix(arr, gap_end, n)
      gap_rows = for k <- gap_start..(gap_end - 1), do: elem(arr, k)

      gap = %{
        before: before,
        after: after_,
        gap_rows: gap_rows
      }

      do_find_gaps(arr, gap_end, n, [gap | acc])
    else
      do_find_gaps(arr, i + 1, n, acc)
    end
  end

  defp scan_to_fix(arr, i, n) do
    if i >= n or not is_nil(elem(arr, i).lat), do: i, else: scan_to_fix(arr, i + 1, n)
  end

  defp scan_back_for_fix(_arr, j) when j < 0, do: nil
  defp scan_back_for_fix(arr, j) do
    row = elem(arr, j)
    if is_nil(row.lat), do: scan_back_for_fix(arr, j - 1), else: row
  end

  defp scan_forward_for_fix(_arr, j, n) when j >= n, do: nil
  defp scan_forward_for_fix(arr, j, n) do
    row = elem(arr, j)
    if is_nil(row.lat), do: scan_forward_for_fix(arr, j + 1, n), else: row
  end

  defp flight_gap?(%{before: nil}), do: false
  defp flight_gap?(%{after: nil}), do: false

  defp flight_gap?(%{before: b, after: a}) do
    duration_ms = DateTime.diff(a.ts, b.ts, :millisecond)
    dist_m = haversine(b.lat, b.lon, a.lat, a.lon)
    speed_kmh = dist_m / 1000 / (duration_ms / 3_600_000)

    duration_ms > @min_gap_ms and dist_m > @min_gap_m and speed_kmh > @min_speed_kmh
  end

  # Build the synthesised rows for one gap. Returns a list of maps with
  # :ts, :lat, :lon, :alt_m, :speed_kts (speed filled in via a second pass).
  defp synthesize(%{before: b, after: a, gap_rows: gap_rows}) do
    dep_ts_ms = DateTime.to_unix(b.ts, :millisecond)
    arr_ts_ms = DateTime.to_unix(a.ts, :millisecond)
    duration_ms = arr_ts_ms - dep_ts_ms

    lon_diff = a.lon - b.lon
    crosses_anti = abs(lon_diff) > 180

    base_rows =
      Enum.map(gap_rows, fn r ->
        row_ts_ms = DateTime.to_unix(r.ts, :millisecond)
        t = (row_ts_ms - dep_ts_ms) / duration_ms
        {lat, lon} = interpolate_great_circle(b.lat, b.lon, a.lat, a.lon, t)

        lon =
          if crosses_anti and b.lon > 0 and a.lon < 0 and lon < b.lon - 90,
            do: lon + 360,
            else: lon

        alt = flight_altitude(t, @cruise_alt_m, duration_ms)
        %{ts: r.ts, lat: lat, lon: lon, alt_m: alt}
      end)

    # Second pass: fill in speed_kts from haversine between consecutive
    # reconstructed rows (mirrors lines 993-1006 of the viewer).
    [first | rest] = base_rows
    {with_speed, _} =
      Enum.map_reduce(rest, first, fn cur, prev ->
        d = haversine(prev.lat, prev.lon, cur.lat, cur.lon)
        dt = DateTime.diff(cur.ts, prev.ts, :second)
        speed = if dt > 0, do: d / dt / 0.5144, else: 0.0
        {Map.put(cur, :speed_kts, speed), cur}
      end)

    # First row inherits the second row's speed (or 0 if no rest).
    first_speed =
      case with_speed do
        [next | _] -> next.speed_kts
        [] -> 0.0
      end

    [Map.put(first, :speed_kts, first_speed) | with_speed]
  end

  # ── Math helpers ──────────────────────────────────────────────────────

  defp haversine(lat1, lon1, lat2, lon2) do
    r = 6_371_000
    p1 = lat1 * :math.pi() / 180
    p2 = lat2 * :math.pi() / 180
    dp = (lat2 - lat1) * :math.pi() / 180
    dl = (lon2 - lon1) * :math.pi() / 180

    a =
      :math.sin(dp / 2) * :math.sin(dp / 2) +
        :math.cos(p1) * :math.cos(p2) * :math.sin(dl / 2) * :math.sin(dl / 2)

    2 * r * :math.asin(:math.sqrt(a))
  end

  defp interpolate_great_circle(lat1, lon1, lat2, lon2, t) do
    p1 = lat1 * :math.pi() / 180
    l1 = lon1 * :math.pi() / 180
    p2 = lat2 * :math.pi() / 180
    l2 = lon2 * :math.pi() / 180

    d =
      2 *
        :math.asin(
          :math.sqrt(
            :math.sin((p2 - p1) / 2) * :math.sin((p2 - p1) / 2) +
              :math.cos(p1) * :math.cos(p2) * :math.sin((l2 - l1) / 2) * :math.sin((l2 - l1) / 2)
          )
        )

    if d < 1.0e-10 do
      {lat1, lon1}
    else
      a = :math.sin((1 - t) * d) / :math.sin(d)
      b = :math.sin(t * d) / :math.sin(d)
      x = a * :math.cos(p1) * :math.cos(l1) + b * :math.cos(p2) * :math.cos(l2)
      y = a * :math.cos(p1) * :math.sin(l1) + b * :math.cos(p2) * :math.sin(l2)
      z = a * :math.sin(p1) + b * :math.sin(p2)

      lat = :math.atan2(z, :math.sqrt(x * x + y * y)) * 180 / :math.pi()
      lon = :math.atan2(y, x) * 180 / :math.pi()
      {lat, lon}
    end
  end

  defp flight_altitude(t, cruise_alt, duration_ms) do
    climb_ms = min(20 * 60_000, duration_ms * 0.1)
    descent_ms = min(30 * 60_000, duration_ms * 0.15)
    climb_frac = climb_ms / duration_ms
    descent_frac = descent_ms / duration_ms

    cond do
      t < climb_frac -> cruise_alt * (t / climb_frac)
      t > 1 - descent_frac -> cruise_alt * ((1 - t) / descent_frac)
      true -> cruise_alt
    end
  end

  # ── Empty-window pass ─────────────────────────────────────────────────
  #
  # Looks for pairs of consecutive non-NULL fixes (i.e. no rows at all
  # between them in the DB) that still qualify as a flight via the same
  # heuristic as the NULL-lat gap pass. These windows are where the
  # tracker was off and we have nothing to UPDATE, only INSERT.

  defp find_empty_windows(indexed_rows) do
    indexed_rows
    |> Enum.map(fn {r, _i} -> r end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [a, b] -> not is_nil(a.lat) and not is_nil(b.lat) end)
    |> Enum.map(fn [a, b] -> %{before: a, after: b} end)
    |> Enum.filter(&flight_gap?/1)
  end

  # A leg matches an empty window iff its `depart` falls between the
  # bracketing fixes' timestamps. If matched, the leg's coords / times /
  # cruise altitude override the values derived from the bracketing fixes.
  defp match_leg(_window, []), do: nil

  defp match_leg(%{before: b, after: a}, legs) do
    Enum.find(legs, fn leg ->
      DateTime.compare(leg.depart, b.ts) in [:gt, :eq] and
        DateTime.compare(leg.depart, a.ts) in [:lt, :eq]
    end)
  end

  # Build synthetic rows for an empty window at @empty_step_ms cadence.
  # Mirrors `synthesize/1` for the gap pass but generates its own
  # timestamps instead of mapping over `gap_rows`.
  defp synthesize_empty(window, leg) do
    {dep_ts, arr_ts, from_lat, from_lon, to_lat, to_lon, cruise} = leg_or_bracket(window, leg)

    dep_ms = DateTime.to_unix(dep_ts, :millisecond)
    arr_ms = DateTime.to_unix(arr_ts, :millisecond)
    duration_ms = arr_ms - dep_ms

    lon_diff = to_lon - from_lon
    crosses_anti = abs(lon_diff) > 180

    steps = max(2, div(duration_ms, @empty_step_ms))

    base_rows =
      for i <- 0..steps do
        row_ms = dep_ms + div(i * duration_ms, steps)
        ts = DateTime.from_unix!(row_ms, :millisecond)
        t = (row_ms - dep_ms) / duration_ms
        {lat, lon} = interpolate_great_circle(from_lat, from_lon, to_lat, to_lon, t)

        lon =
          if crosses_anti and from_lon > 0 and to_lon < 0 and lon < from_lon - 90,
            do: lon + 360,
            else: lon

        alt = flight_altitude(t, cruise, duration_ms)
        %{ts: ts, lat: lat, lon: lon, alt_m: alt}
      end

    [first | rest] = base_rows

    {with_speed, _} =
      Enum.map_reduce(rest, first, fn cur, prev ->
        d = haversine(prev.lat, prev.lon, cur.lat, cur.lon)
        dt = DateTime.diff(cur.ts, prev.ts, :second)
        speed = if dt > 0, do: d / dt / 0.5144, else: 0.0
        {Map.put(cur, :speed_kts, speed), cur}
      end)

    first_speed =
      case with_speed do
        [next | _] -> next.speed_kts
        [] -> 0.0
      end

    [Map.put(first, :speed_kts, first_speed) | with_speed]
  end

  defp leg_or_bracket(%{before: b, after: a}, nil),
    do: {b.ts, a.ts, b.lat, b.lon, a.lat, a.lon, @cruise_alt_m * 1.0}

  defp leg_or_bracket(_window, leg),
    do: {leg.depart, leg.arrive, leg.from_lat, leg.from_lon, leg.to_lat, leg.to_lon, leg.cruise}

  # Format a DateTime as "YYYY-MM-DDTHH:MM:SS.ffffff" — matches what
  # ecto_sqlite3 stores when `gpsview.import_fixes` inserts rows. Same
  # quirk forces the raw-SQL UPDATE path above to format ts itself.
  defp format_ts(%DateTime{} = ts) do
    ts
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601()
    |> pad_microseconds()
  end

  defp pad_microseconds(s) do
    case String.split(s, ".", parts: 2) do
      [whole, frac] ->
        padded = frac |> String.pad_trailing(6, "0") |> String.slice(0, 6)
        "#{whole}.#{padded}"

      [whole] ->
        "#{whole}.000000"
    end
  end

  # ── --leg parsing ─────────────────────────────────────────────────────
  #
  # Syntax: "depart=<iso>,arrive=<iso>,from=<lat>,<lon>,to=<lat>,<lon>,cruise=<m>"
  # The `from`/`to` values each consume the next comma-separated token
  # as the longitude, so commas inside coordinates are handled cleanly.

  defp parse_leg(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> parse_leg_tokens(%{})
    |> validate_leg!()
  end

  defp parse_leg_tokens([], acc), do: acc

  defp parse_leg_tokens([token | rest], acc) do
    case String.split(token, "=", parts: 2) do
      ["depart", v] ->
        parse_leg_tokens(rest, Map.put(acc, :depart, parse_iso!(v)))

      ["arrive", v] ->
        parse_leg_tokens(rest, Map.put(acc, :arrive, parse_iso!(v)))

      ["cruise", v] ->
        parse_leg_tokens(rest, Map.put(acc, :cruise, parse_float!(v)))

      ["from", lat_str] ->
        [lon_str | rest2] = rest

        acc =
          acc
          |> Map.put(:from_lat, parse_float!(lat_str))
          |> Map.put(:from_lon, parse_float!(lon_str))

        parse_leg_tokens(rest2, acc)

      ["to", lat_str] ->
        [lon_str | rest2] = rest

        acc =
          acc
          |> Map.put(:to_lat, parse_float!(lat_str))
          |> Map.put(:to_lon, parse_float!(lon_str))

        parse_leg_tokens(rest2, acc)

      _ ->
        Mix.raise("unrecognised --leg token: #{token}")
    end
  end

  defp validate_leg!(leg) do
    required = [:depart, :arrive, :from_lat, :from_lon, :to_lat, :to_lon, :cruise]

    case Enum.reject(required, &Map.has_key?(leg, &1)) do
      [] -> leg
      missing -> Mix.raise("--leg missing required keys: #{Enum.join(missing, ", ")}")
    end
  end

  defp parse_iso!(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      err -> Mix.raise("invalid ISO8601 in --leg: #{s} (#{inspect(err)})")
    end
  end

  defp parse_float!(s) do
    case Float.parse(s) do
      {f, ""} -> f
      _ -> Mix.raise("invalid float in --leg: #{s}")
    end
  end
end

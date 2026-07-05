# lib/gpsview/decimate.ex
defmodule GPSView.Decimate do
  @moduledoc """
  Largest-Triangle-Three-Buckets downsampling.
  Preserves visual shape much better than naive stride sampling.

  Reference: Sveinn Steinarsson, "Downsampling Time Series for Visual
  Representation" (2013).

  Operates on a list of maps with a numeric `:t` and the y-axis field
  used to preserve shape (default `:speed_kts` — switch to whichever
  metric matters most for your use case, or run twice and merge).
  """

  @doc """
  Decimate `points` to roughly `target` items.
  Returns input unchanged when `length(points) <= target`.
  """
  def lttb(points, target) when target < 3, do: Enum.take(points, target)
  def lttb(points, target) do
    n = length(points)
    if n <= target do
      points
    else
      do_lttb(points, n, target, &point_y/1)
    end
  end

  # Use altitude as the shape-preserving metric for GPS tracks; speed/battery
  # tend to be smoother. Override by passing a different y-fun if needed.
  defp point_y(%{alt_m: a}) when is_number(a), do: a
  defp point_y(%{speed_kts: s}) when is_number(s), do: s
  defp point_y(_), do: 0.0

  defp do_lttb(points, n, target, y_fun) do
    bucket_size = (n - 2) / (target - 2)
    points_arr = :array.from_list(points)

    {first, last} = {:array.get(0, points_arr), :array.get(n - 1, points_arr)}

    {result_rev, _} =
      Enum.reduce(0..(target - 3), {[first], 0}, fn i, {acc, a_idx} ->
        # next bucket range
        next_lo = trunc((i + 1) * bucket_size) + 1
        next_hi = min(trunc((i + 2) * bucket_size) + 1, n)

        avg = bucket_avg(points_arr, next_lo, next_hi, y_fun)

        # current bucket range
        cur_lo = trunc(i * bucket_size) + 1
        cur_hi = trunc((i + 1) * bucket_size) + 1

        a = :array.get(a_idx, points_arr)
        ax = ts_to_num(a.t)
        ay = y_fun.(a)

        {best, best_idx, _} =
          Enum.reduce(cur_lo..(cur_hi - 1), {nil, cur_lo, -1.0}, fn idx, {best, best_i, best_area} ->
            p = :array.get(idx, points_arr)
            area = triangle_area(ax, ay, ts_to_num(p.t), y_fun.(p), avg.t, avg.y)
            if area > best_area, do: {p, idx, area}, else: {best, best_i, best_area}
          end)

        {[best | acc], best_idx}
      end)

    Enum.reverse([last | result_rev])
  end

  defp bucket_avg(points_arr, lo, hi, y_fun) do
    range = lo..(hi - 1)
    {tx, ty, count} =
      Enum.reduce(range, {0.0, 0.0, 0}, fn i, {sx, sy, c} ->
        p = :array.get(i, points_arr)
        {sx + ts_to_num(p.t), sy + y_fun.(p), c + 1}
      end)
    %{t: tx / max(count, 1), y: ty / max(count, 1)}
  end

  defp triangle_area(ax, ay, bx, by, cx, cy) do
    abs((ax - cx) * (by - ay) - (ax - bx) * (cy - ay)) / 2.0
  end

  defp ts_to_num(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)
  defp ts_to_num(t) when is_number(t), do: t
end

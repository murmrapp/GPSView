# lib/gpsview/trackers/device_server.ex
defmodule GPSView.Trackers.DeviceServer do
  @moduledoc """
  One GenServer per tracker device. Holds last-known fix and online status,
  persists incoming fixes via the Trackers context, and broadcasts updates
  on the device PubSub topic.

  Started lazily by `DeviceSupervisor.ensure_started/1` on first ingest.
  Crashes are isolated: one bad device does not affect others.
  """
  use GenServer

  alias GPSView.Trackers
  alias Phoenix.PubSub

  @idle_after_ms 60_000          # mark offline after this idle period
  @batch_flush_ms 200            # batch DB inserts for high-rate trackers

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(device_id) when is_binary(device_id) do
    GenServer.start_link(__MODULE__, device_id, name: via(device_id))
  end

  def ingest(device_id, payload) when is_map(payload) do
    GenServer.cast(via(device_id), {:ingest, payload})
  end

  def state(device_id), do: GenServer.call(via(device_id), :state)

  def last_fix(device_id), do: GenServer.call(via(device_id), :last_fix)

  defp via(id), do: {:via, Registry, {GPSView.Trackers.Registry, id}}

  # ── Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(device_id) do
    state = %{
      device_id: device_id,
      last_fix: nil,
      online: false,
      buffer: [],
      flush_ref: nil,
      idle_ref: nil
    }
    {:ok, state}
  end

  @impl true
  def handle_cast({:ingest, payload}, state) do
    state =
      state
      |> Map.update!(:buffer, &[payload | &1])
      |> mark_online()
      |> reset_idle_timer()
      |> ensure_flush_timer()

    {:noreply, state}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, Map.take(state, [:device_id, :last_fix, :online]), state}
  end

  def handle_call(:last_fix, _from, state) do
    {:reply, state.last_fix, state}
  end

  @impl true
  def handle_info(:flush, state) do
    case state.buffer do
      [] -> {:noreply, %{state | flush_ref: nil}}
      buffer ->
        # buffer is reverse-order; restore chronologically
        fixes = Enum.reverse(buffer)

        {:ok, inserted} = Trackers.insert_fixes(state.device_id, fixes)
        last = List.last(inserted)
        Enum.each(inserted, &broadcast(state.device_id, {:new_fix, &1}))
        {:noreply, %{state | buffer: [], flush_ref: nil, last_fix: last}}
    end
  end

  def handle_info(:idle, state) do
    broadcast(state.device_id, {:status, :offline})
    {:noreply, %{state | online: false, idle_ref: nil}}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp ensure_flush_timer(%{flush_ref: nil} = s) do
    %{s | flush_ref: Process.send_after(self(), :flush, @batch_flush_ms)}
  end
  defp ensure_flush_timer(s), do: s

  defp reset_idle_timer(%{idle_ref: ref} = s) do
    if ref, do: Process.cancel_timer(ref)
    %{s | idle_ref: Process.send_after(self(), :idle, @idle_after_ms)}
  end

  defp mark_online(%{online: true} = s), do: s
  defp mark_online(s) do
    broadcast(s.device_id, {:status, :online})
    %{s | online: true}
  end

  defp broadcast(device_id, msg) do
    PubSub.broadcast(GPSView.PubSub, "device:#{device_id}", msg)
  end
end

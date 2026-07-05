# lib/gpsview/trackers/device_supervisor.ex
defmodule GPSView.Trackers.DeviceSupervisor do
  @moduledoc """
  DynamicSupervisor that owns one DeviceServer per tracker.
  Use `ensure_started/1` to start a child on first contact.
  """
  use DynamicSupervisor

  alias GPSView.Trackers.DeviceServer

  def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  def ensure_started(device_id) when is_binary(device_id) do
    case Registry.lookup(GPSView.Trackers.Registry, device_id) do
      [{pid, _}] -> {:ok, pid}
      [] ->
        DynamicSupervisor.start_child(__MODULE__, {DeviceServer, device_id})
    end
  end
end

defmodule GPSViewWeb.DeviceChannel do
  @moduledoc """
  Live updates for one tracker. Topic: "device:<device_id>".
  Subscribe; receive "new_fix" pushes whenever the tracker reports.
  """
  use GPSViewWeb, :channel

  alias GPSView.Trackers
  alias GPSView.Trackers.DeviceServer

  @impl true
  def join("device:" <> device_id, _payload, socket) do
    case Trackers.get_device(device_id) do
      nil ->
        {:error, %{reason: "not_found"}}

      device ->
        Phoenix.PubSub.subscribe(GPSView.PubSub, "device:#{device_id}")

        last =
          try do
            DeviceServer.last_fix(device_id)
          catch
            :exit, _ -> nil
          end

        {:ok, %{device: device, last_fix: last},
         assign(socket, :device_id, device_id)}
    end
  end

  @impl true
  def handle_in("sync_request", _payload, socket) do
    # Future: trigger a pull from the tracker. For now, ack.
    {:reply, {:ok, %{queued: true}}, socket}
  end

  @impl true
  def handle_info({:new_fix, fix}, socket) do
    push(socket, "new_fix", %{point: fix})
    {:noreply, socket}
  end

  def handle_info({:status, status}, socket) do
    push(socket, "status", %{status: status})
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end

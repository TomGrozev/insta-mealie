defmodule InstaMealie.Pipeline.Sweeper do
  @moduledoc "Owns the ETS job table and runs the periodic TTL sweep."
  use GenServer

  alias InstaMealie.Pipeline.JobStore

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    JobStore.create_table()
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    JobStore.sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    interval =
      Application.get_env(:insta_mealie, InstaMealie.Pipeline, [])[:sweep_interval_ms] ||
        5 * 60 * 1000

    Process.send_after(self(), :sweep, interval)
  end
end

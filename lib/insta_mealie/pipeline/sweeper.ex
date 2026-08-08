defmodule InstaMealie.Pipeline.Sweeper do
  @moduledoc "Owns the SQLite job store and runs the periodic TTL sweep."
  use GenServer

  alias InstaMealie.Pipeline.JobStore

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    JobStore.init_db()

    interval =
      Application.get_env(:insta_mealie, InstaMealie.Pipeline, [])[:sweep_interval_ms] ||
        5 * 60 * 1000

    :timer.apply_interval(interval, JobStore, :sweep, [])
    {:ok, :ok}
  end
end

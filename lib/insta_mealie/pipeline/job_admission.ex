defmodule InstaMealie.Pipeline.JobAdmission do
  @moduledoc """
  FIFO admission queue for job concurrency control (issue #47).

  Jobs request admission before their GenServer starts. Up to
  `max_concurrency` jobs may be "active" at once; the rest sit in a FIFO
  queue. When an active slot is released, the next queued job is
  admitted and its GenServer is started via the pipeline's
  `DynamicSupervisor`.

  Slots are released explicitly on import completion, on user cancel,
  and on GenServer `terminate/2` (crash, supervisor shutdown, or normal
  stop). Releasing a non-active job is a no-op (idempotent).
  """
  use GenServer

  require Logger

  alias InstaMealie.Pipeline.{Job, JobStore, JobSupervisor}

  defstruct [:queue, :active, :max]

  # -- public API --

  def start_link(opts) do
    max = Keyword.get(opts, :max, max_concurrency())
    GenServer.start_link(__MODULE__, max, name: __MODULE__)
  end

  @doc """
  Request admission for a job. Returns `:admitted` if within the
  concurrency limit, or `{:queued, position}` (1-indexed) if the job
  must wait. When a slot opens, the next queued job is automatically
  started — the caller does not need to poll.
  """
  def request(job_id) do
    GenServer.call(__MODULE__, {:request, job_id})
  end

  @doc """
  Release a slot after a job completes or crashes. Idempotent — calling
  on a non-active job is a no-op. Triggers admission of the next queued
  job, if any.
  """
  def release(job_id) do
    GenServer.cast(__MODULE__, {:release, job_id})
  end

  @doc """
  Cancel a queued (not-yet-started) job. Returns `:ok` if the job was
  removed from the queue, or `:not_queued`.
  """
  def cancel(job_id) do
    GenServer.call(__MODULE__, {:cancel, job_id})
  end

  @doc """
  Get the queue position for a waiting job. Returns `{:queued, pos}` or
  `:not_queued`.
  """
  def position(job_id) do
    GenServer.call(__MODULE__, {:position, job_id})
  end

  @doc """
  Clear the active set and queue. Intended for tests; do not call from
  production code paths.
  """
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # -- GenServer --

  @impl true
  def init(max) do
    {:ok, %__MODULE__{queue: :queue.new(), active: MapSet.new(), max: max}}
  end

  @impl true
  def handle_call({:request, job_id}, _from, state) do
    if MapSet.size(state.active) < state.max do
      state = %{state | active: MapSet.put(state.active, job_id)}
      {:reply, :admitted, state}
    else
      state = %{state | queue: :queue.in(job_id, state.queue)}
      pos = :queue.len(state.queue)
      {:reply, {:queued, pos}, state}
    end
  end

  @impl true
  def handle_call({:cancel, job_id}, _from, state) do
    {removed, new_queue} = :queue.filter(fn id -> id != job_id end, state.queue)
    state = %{state | queue: new_queue}
    {:reply, if(removed, do: :ok, else: :not_queued), state}
  end

  @impl true
  def handle_call({:position, job_id}, _from, state) do
    pos =
      state.queue
      |> :queue.to_list()
      |> Enum.find_index(fn id -> id == job_id end)

    reply = if pos, do: {:queued, pos + 1}, else: :not_queued
    {:reply, reply, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | queue: :queue.new(), active: MapSet.new()}}
  end

  @impl true
  def handle_cast({:release, job_id}, state) do
    state = %{state | active: MapSet.delete(state.active, job_id)}
    state = admit_next(state)
    {:noreply, state}
  end

  # -- private --

  # Pop the next queued job (if any), add it to the active set, and
  # start its GenServer. Called from the release handler so a freed
  # slot immediately unblocks the FIFO head.
  defp admit_next(state) do
    case :queue.out(state.queue) do
      {{:value, job_id}, new_queue} ->
        state = %{state | queue: new_queue, active: MapSet.put(state.active, job_id)}
        start_queued_job(job_id)
        state

      {:empty, _} ->
        state
    end
  end

  # The Job struct lives in JobStore. Look it up and start its
  # GenServer. If the row has gone (TTL sweep, manual delete, etc.)
  # we log and move on — the slot was reserved and the row is gone.
  defp start_queued_job(job_id) do
    case JobStore.get(job_id) do
      nil ->
        Logger.warning("[admission] queued job #{job_id} not found in store; skipping start")

      job ->
        spec = Supervisor.child_spec({Job, job}, restart: :temporary)

        case DynamicSupervisor.start_child(JobSupervisor, spec) do
          {:ok, _pid} ->
            :ok

          {:ok, _pid, _info} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, _reason} = err ->
            Logger.error("[admission] failed to start queued job #{job_id}: #{inspect(err)}")
            err
        end
    end
  end

  defp max_concurrency do
    Application.get_env(:insta_mealie, :insta_mealie, [])[:max_concurrency] || 3
  end
end

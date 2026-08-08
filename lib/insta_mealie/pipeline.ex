defmodule InstaMealie.Pipeline do
  @moduledoc """
  Public API and supervision tree for the InstaMealie job pipeline.

  This is the single high seam for tests and the LiveView: create a job,
  watch it progress through the five-stage FSM, and read results.

  Supervision tree:
    - a Registry (unique) for per-job GenServer lookup
    - a DynamicSupervisor running one GenServer per job
    - a table-owning Sweeper that holds the ETS job store and runs the
      ~5 minute TTL sweep
  """
  use Supervisor

  alias InstaMealie.Pipeline.{Job, JobStore, JobSupervisor, Sweeper, Clients}
  alias InstaMealie.PubSub

  @doc false
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, [keys: :unique, name: __MODULE__.Registry]},
      {DynamicSupervisor, [strategy: :one_for_one, name: __MODULE__.JobSupervisor]},
      {Sweeper, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Create a job from an input map (for example `%{url: "https://..."}`).
  Returns `{:ok, job_id}`.
  """
  def create_job(input) when is_map(input) do
    id = generate_id()
    now = DateTime.utc_now()

    job = %Job{
      id: id,
      input: input,
      url: input[:url] || input["url"],
      caption: input[:caption] || input["caption"],
      state: :created,
      stage: nil,
      stages: %{},
      recipe: nil,
      verdict: nil,
      missing_fields: nil,
      slug: nil,
      deep_link: nil,
      error_stage: nil,
      error_class: nil,
      error_summary: nil,
      retry_count: %{},
      output_language: output_language(),
      inserted_at: now,
      updated_at: now
    }

    JobStore.put(job)
    broadcast(job)

    case DynamicSupervisor.start_child(JobSupervisor, {Job, job}) do
      {:ok, _pid} -> {:ok, id}
      {:ok, _pid, _info} -> {:ok, id}
      {:error, {:already_started, _pid}} -> {:ok, id}
      other -> other
    end
  end

  @doc "Fetch a single job snapshot, or `nil` if unknown."
  def get_job(id), do: JobStore.get(id)

  @doc "List recent jobs, newest first."
  def list_recent_jobs, do: JobStore.list()

  @doc """
  Retry a job from the start, preserving its `job_id`. Full retry semantics
  (per-stage cap, CTA matrix) land in a later ticket; this resets and re-runs.
  """
  def retry(job_id) when is_binary(job_id) do
    case JobStore.get(job_id) do
      nil ->
        {:error, :not_found}

      job ->
        stop_job(job_id)

        reset =
          %{
            job
            | state: :created,
              stage: nil,
              stages: %{},
              recipe: nil,
              verdict: nil,
              missing_fields: nil,
              slug: nil,
              deep_link: nil,
              error_stage: nil,
              error_class: nil,
              error_summary: nil,
              updated_at: DateTime.utc_now()
          }

        JobStore.put(reset)
        broadcast(reset)
        DynamicSupervisor.start_child(JobSupervisor, {Job, reset})
        {:ok, job_id}
    end
  end

  @doc """
  Manually import a job that already has a recipe draft. The happy path
  auto-imports; this is the seam for the post-review import.
  """
  def import(job_id) when is_binary(job_id) do
    case JobStore.get(job_id) do
      nil ->
        {:error, :not_found}

      %{state: :succeeded} = job ->
        {:ok, job}

      %{recipe: nil} ->
        {:error, :no_recipe}

      job ->
        run_import_inline(job)
    end
  end

  @doc """
  Seam for the paste-caption recovery path (full flow in #25). Persists the
  supplied caption and marks the job as awaiting paste.
  """
  def submit_caption(job_id, caption) when is_binary(job_id) and is_binary(caption) do
    case JobStore.get(job_id) do
      nil ->
        {:error, :not_found}

      job ->
        updated = %{
          job
          | caption: caption,
            state: :caption_pasting,
            updated_at: DateTime.utc_now()
        }

        JobStore.put(updated)
        broadcast(updated)
        {:ok, job_id}
    end
  end

  @doc """
  Seam for the transcribe-anyway override (full flow in #26). Returns the job
  id; the override re-run lands in a later ticket.
  """
  def apply_transcribe_anyway(job_id) when is_binary(job_id) do
    case JobStore.get(job_id) do
      nil -> {:error, :not_found}
      _job -> {:ok, job_id}
    end
  end

  @doc """
  Seam for the unknown-ingredient review resolution (full flow in #27).
  Returns the job id; applying resolutions before import lands later.
  """
  def apply_ingredient_resolutions(job_id, _resolutions) when is_binary(job_id) do
    case JobStore.get(job_id) do
      nil -> {:error, :not_found}
      _job -> {:ok, job_id}
    end
  end

  # ---- internals ----

  defp run_import_inline(job) do
    recipe = job.recipe || %{}

    case Clients.import_recipe(recipe) do
      {:ok, slug, deep_link} ->
        updated =
          %{
            job
            | state: :succeeded,
              slug: slug,
              deep_link: deep_link,
              stages: Map.put(job.stages, :mealie_import, :done),
              updated_at: DateTime.utc_now()
          }

        JobStore.put(updated)
        broadcast(updated)
        {:ok, updated}

      {:error, class, reason} ->
        updated =
          %{
            job
            | state: :failed,
              error_stage: :mealie_import,
              error_class: class,
              error_summary: to_string(reason),
              updated_at: DateTime.utc_now()
          }

        JobStore.put(updated)
        broadcast(updated)
        {:error, class, reason}
    end
  end

  defp stop_job(job_id) do
    case Registry.lookup(__MODULE__.Registry, job_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(JobSupervisor, pid)
      [] -> :ok
    end
  end

  defp generate_id do
    "jm_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
  end

  defp output_language do
    Application.get_env(:insta_mealie, :insta_mealie, [])[:output_language] || "en"
  end

  defp broadcast(job) do
    Phoenix.PubSub.broadcast(PubSub, "jobs", {:job_updated, job})
  end
end

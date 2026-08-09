defmodule InstaMealie.Pipeline do
  @moduledoc """
  Public API and supervision tree for the InstaMealie job pipeline.

  This is the single high seam for tests and the LiveView: create a job,
  watch it progress through the five-stage FSM, and read results.

  Supervision tree:
    - a Registry (unique) for per-job GenServer lookup
    - a DynamicSupervisor running one GenServer per job
    - a Task.Supervisor for the per-stage blocking work (Phase 6)
    - a table-owning Sweeper that holds the ETS job store and runs the
      ~5 minute TTL sweep
  """
  use Supervisor

  require Logger

  alias InstaMealie.Error
  alias InstaMealie.Pipeline.{Job, JobAdmission, JobStore, JobSupervisor, Sweeper}
  alias InstaMealie.PubSub
  alias InstaMealie.Recipe

  @doc false
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, [keys: :unique, name: __MODULE__.Registry]},
      {DynamicSupervisor, [strategy: :one_for_one, name: __MODULE__.JobSupervisor]},
      {Task.Supervisor, [name: __MODULE__.TaskSupervisor]},
      {JobAdmission, []},
      {Sweeper, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Create a job from an input map (for example `%{url: "https://..."}`).
  Returns `{:ok, job_id}`.
  """
  def create_job(input) when is_map(input) do
    url = input[:url] || input["url"]
    caption = input[:caption] || input["caption"]
    normalized_url = normalize_url(url)
    force = input[:force] || input["force"] || false

    with :ok <- check_duplicate_url(normalized_url, force) do
      id = generate_id()
      now = DateTime.utc_now()

      mode = if(is_binary(caption) and url == nil, do: :caption_only, else: :url)

      Logger.info(
        "[pipeline] job created #{id} (mode: #{mode})"
      )

      job = %Job{
        id: id,
        input: input,
        url: url,
        caption: caption,
        mode: mode,
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
        stage_started_at: nil,
        inserted_at: now,
        updated_at: now
      }

      job = transition(job, [])

      case JobAdmission.request(id) do
        :admitted ->
          spec = Supervisor.child_spec({Job, job}, restart: :temporary)

          case DynamicSupervisor.start_child(JobSupervisor, spec) do
            {:ok, _pid} -> {:ok, id}
            {:ok, _pid, _info} -> {:ok, id}
            {:error, {:already_started, _pid}} -> {:ok, id}
            other -> other
          end

        {:queued, position} ->
          transition(job, [{:state, :queued}])
          {:ok, id, position}
      end
    end
  end

  @doc "Fetch a single job snapshot, or `nil` if unknown."
  def get_job(id), do: JobStore.get(id)

  @doc "List recent jobs, newest first."
  def list_recent_jobs, do: JobStore.list()

  @doc """
  Whether a pipeline error represents a retryable failure (vs. a dead
  row). `validation` is terminal; `network` / `auth` and the other transient
  classes are retryable. Consumed by the retry UI (later ticket).
  """
  def error_retryable?(%Error{} = error), do: Error.retryable?(error)

  @doc """
  Retry a job from the start, preserving its `job_id`. Each retry is counted
  per failing stage (capped at 2 in the UI — see `InstaMealieWeb.JobsLive`);
  once a stage's retry budget is exhausted, the Retry CTA is hidden.

  Thin facade: forwards to the job's GenServer, which owns the mutation and
  re-runs the FSM. A mealie_import-only retry re-runs the import on the same
  job without resetting the recipe; all other retries re-run from `:created`.
  """
  def retry(job_id) when is_binary(job_id) do
    case JobStore.get(job_id) do
      nil -> {:error, :not_found}
      _job -> wrap_job_id(call_job(job_id, :retry), job_id)
    end
  end

  @doc """
  Paste-caption recovery path (T6). Persists the supplied caption, transitions
  a fetch-failed job to `:caption_pasting`, and re-runs the routing LLM call on
  the same ETS row via the caption-only pipeline path. Also used by the degraded
  mode create path. Only valid from a fetch-failed state (or an already
  caption-only job); otherwise returns `{:error, :invalid_state}`.

  Thin facade: validates the pre-condition locally, then forwards to the
  job's GenServer for the mutation and pipeline re-run.
  """
  def submit_caption(job_id, caption) when is_binary(job_id) and is_binary(caption) do
    case JobStore.get(job_id) do
      nil ->
        {:error, :not_found}

      job ->
        if job.error_stage == :fetch or job.mode == :caption_only do
          Logger.info("[pipeline] job #{job_id} pasting caption recovery")
          wrap_job_id(call_job(job_id, {:submit_caption, caption}), job_id)
        else
          {:error, :invalid_state}
        end
    end
  end

  @doc """
  Transcribe-anyway override (T7). For a job that failed at the `:transcribe` or
  `:llm_merge` stage, skip the failed audio and import the caption-only (routing)
  recipe already on the job, reusing the same `job_id`. This is a one-shot,
  in-place re-run: the row is reset to `:created` (keeping its `recipe`,
  `caption`, `verdict`, and `retry_count`), and the GenServer takes the
  skip-audio FSM branch.
  Returns `{:error, :invalid_state}` when the job is not in a transcribe/merge
  failure state, and `{:error, :not_found}` when unknown.

  Thin facade: validates the pre-condition locally, then forwards to the
  job's GenServer for the mutation and pipeline re-run.
  """
  def apply_transcribe_anyway(job_id) when is_binary(job_id) do
    case JobStore.get(job_id) do
      nil ->
        {:error, :not_found}

      %{error_stage: stage} = _job when stage in [:transcribe, :llm_merge] ->
        Logger.info(
          "[pipeline] job #{job_id} applying transcribe-anyway override (failed at #{stage})"
        )

        wrap_job_id(call_job(job_id, :transcribe_anyway), job_id)

      _other ->
        {:error, :invalid_state}
    end
  end

  @doc """
  Apply ingredient resolutions from the review screen (T8). Merges the user's
  picks into the job's recipe ingredients and fires the import.

  Thin facade: forwards to the job's GenServer, which owns the recipe merge
  and the import. No other process mutates the recipe or calls the importer.
  Returns the import result directly: `{:ok, updated_job}` on success or
  `{:error, %Error{}}` on failure.
  """
  def apply_ingredient_resolutions(job_id, resolutions) when is_binary(job_id) do
    case JobStore.get(job_id) do
      nil -> {:error, :not_found}
      _job -> call_job(job_id, {:resolve_ingredients, resolutions})
    end
  end

  @doc """
  Cancel a job. Queued jobs are removed from the admission queue; running
  jobs receive a `:cancel` cast on their GenServer. Terminal jobs return
  `{:error, :already_terminal}`.
  """
  def cancel_job(job_id) when is_binary(job_id) do
    case JobStore.get(job_id) do
      nil ->
        {:error, :not_found}

      %{state: :queued} = job ->
        JobAdmission.cancel(job_id)
        transition(job, [{:state, :cancelled}])
        {:ok, job_id}

      %{state: state} = _job when state in [:succeeded, :failed, :cancelled] ->
        {:error, :already_terminal}

      _job ->
        case ensure_job_process(job_id) do
          {:ok, pid} ->
            GenServer.cast(pid, :cancel)
            {:ok, job_id}

          {:error, _} = error ->
            error
        end
      end
  end

  @doc """
  Ensure a job GenServer is alive for the given `job_id`.

  If the process is already registered, returns `{:ok, pid}`. If the process
  is gone but the ETS row exists and the job is non-terminal, restarts the
  GenServer from the snapshot (revive path) and returns `{:ok, pid}`.
  Otherwise returns `{:error, :not_found}` (no row) or `{:error, :terminal}`
  (row exists but the job is already in a final state).
  """
  def ensure_job_process(job_id) do
    case Registry.lookup(__MODULE__.Registry, job_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case JobStore.get(job_id) do
          nil ->
            {:error, :not_found}

          %{state: state} when state in [:succeeded, :failed, :cancelled] ->
            {:error, :terminal}

          job ->
            # Restart from snapshot — revive path.
            case DynamicSupervisor.start_child(
                   JobSupervisor,
                   {Job, {:revive, job}}
                 ) do
              {:ok, pid} -> {:ok, pid}
              {:error, reason} -> {:error, reason}
            end
        end
    end
  end

  # Look up the job's GenServer pid in the registry and forward the command.
  # `ensure_job_process/1` handles the revive-from-store case, so by the time
  # we get a pid the GenServer is definitely running. A failed lookup surfaces
  # as `{:error, :not_found}` (no row) or `{:error, :terminal}` (terminal).
  defp call_job(job_id, message) do
    case ensure_job_process(job_id) do
      {:ok, pid} -> GenServer.call(pid, message, 60_000)
      {:error, _} = error -> error
    end
  end

  # Wrap a successful GenServer reply as `{:ok, job_id}` for the public
  # facade contract. The GenServer replies with `:ok` for fire-and-forget
  # commands, but callers historically expect `{:ok, job_id}`. Errors and
  # already-shaped `{:ok, _}` tuples pass through unchanged.
  defp wrap_job_id(:ok, job_id), do: {:ok, job_id}
  defp wrap_job_id({:ok, _} = ok, _job_id), do: ok
  defp wrap_job_id(other, _job_id), do: other

  @doc """
  Apply one or more changes to a job. Persists to JobStore and broadcasts
  exactly once after all changes are applied. Rejects illegal state
  transitions.

  This is the ONLY place where job state is mutated, persisted, and broadcast.
  All GenServer helpers and inline mutation blocks elsewhere in the codebase
  must funnel through this function.

  Valid changes (each a 2- or 3-tuple):

    * `{:state, atom}` — set job state
    * `{:stage, atom, atom}` — set {stage, status} in stages map (also sets `job.stage`)
    * `{:recipe, map | nil}` — set recipe
    * `{:verdict, atom | nil}` — set verdict
    * `{:missing_fields, list | nil}` — set missing_fields
    * `{:slug, binary | nil}` — set slug
    * `{:deep_link, binary | nil}` — set deep_link
    * `{:error, %Error{}}` — set error_stage/class/summary from the struct
    * `{:clear_error}` — clear all error fields
    * `{:retry_count, map}` — set retry_count
    * `{:caption, binary}` — set caption
    * `{:mode, atom}` — set mode
    * `{:reset}` — clear stage, stages, recipe, verdict, missing_fields, slug, deep_link
  """
  def transition(job, changes) when is_list(changes) do
    job =
      Enum.reduce(changes, job, fn change, acc ->
        validate_change!(acc, change)
        apply_change(acc, change)
      end)

    job = %{job | updated_at: DateTime.utc_now()}
    JobStore.put(job)
    broadcast(job)
    job
  end

  # Reject transitions that are obviously illegal — for example, leaving a
  # terminal state. We log the violation but still apply the change so the
  # retry / corruption-recovery paths keep working; loud logging is enough
  # to catch programming mistakes during development.
  defp validate_change!(job, {:state, new_state}) do
    cond do
      job.state == new_state ->
        :ok

      terminal?(job.state) and not terminal?(new_state) ->
        Logger.error(
          "[pipeline] job #{job.id} illegal state transition: leaving terminal #{job.state} -> #{new_state}"
        )

      true ->
        :ok
    end
  end

  defp validate_change!(_job, _change), do: :ok

  defp terminal?(:succeeded), do: true
  defp terminal?(:failed), do: true
  defp terminal?(:cancelled), do: true
  defp terminal?(_), do: false

  # Compute the wall-clock duration of a stage in milliseconds, or `nil` if
  # the stage never started (e.g. `:skipped` or `:pending` without a prior
  # `:running` transition).
  defp stage_duration(job, stage) do
    case Map.get(job.stage_started_at || %{}, stage) do
      nil -> nil
      started -> System.monotonic_time() - started
    end
  end

  # Private change applicators
  defp apply_change(job, {:state, new_state}) do
    if job.state != new_state do
      Logger.info("[pipeline] job #{job.id} state #{job.state || "nil"} -> #{new_state}")
    end

    if new_state in [:succeeded, :failed] do
      :telemetry.execute(
        [:insta_mealie, :pipeline, :job, :stop],
        %{system_time: System.system_time()},
        %{job_id: job.id, terminal_state: new_state, error_class: job.error_class}
      )
    end

    %{job | state: new_state}
  end

  defp apply_change(job, {:stage, stage, :running}) do
    old = Map.get(job.stages, stage)

    if old != :running do
      Logger.info("[pipeline] job #{job.id} #{stage} #{old || "nil"} -> running")
    end

    started_at =
      (job.stage_started_at || %{})
      |> Map.put(stage, System.monotonic_time())

    :telemetry.execute(
      [:insta_mealie, :pipeline, :stage, :start],
      %{system_time: System.system_time()},
      %{job_id: job.id, stage: stage}
    )

    %{
      job
      | stage: stage,
        stages: Map.put(job.stages, stage, :running),
        stage_started_at: started_at
    }
  end

  defp apply_change(job, {:stage, stage, :failed}) do
    old = Map.get(job.stages, stage)

    if old != :failed do
      Logger.info("[pipeline] job #{job.id} #{stage} #{old || "nil"} -> failed")
    end

    duration = stage_duration(job, stage)

    :telemetry.execute(
      [:insta_mealie, :pipeline, :stage, :exception],
      %{duration: duration, system_time: System.system_time()},
      %{job_id: job.id, stage: stage, error_class: job.error_class}
    )

    %{job | stage: stage, stages: Map.put(job.stages, stage, :failed)}
  end

  defp apply_change(job, {:stage, stage, status}) when status in [:done, :skipped, :pending] do
    old = Map.get(job.stages, stage)

    if old != status do
      Logger.info("[pipeline] job #{job.id} #{stage} #{old || "nil"} -> #{status}")
    end

    duration = stage_duration(job, stage)

    :telemetry.execute(
      [:insta_mealie, :pipeline, :stage, :stop],
      %{duration: duration, system_time: System.system_time()},
      %{job_id: job.id, stage: stage, status: status}
    )

    %{job | stage: stage, stages: Map.put(job.stages, stage, status)}
  end

  defp apply_change(job, {:recipe, recipe}), do: %{job | recipe: recipe}
  defp apply_change(job, {:verdict, verdict}), do: %{job | verdict: verdict}
  defp apply_change(job, {:missing_fields, fields}), do: %{job | missing_fields: fields}
  defp apply_change(job, {:slug, slug}), do: %{job | slug: slug}
  defp apply_change(job, {:deep_link, link}), do: %{job | deep_link: link}
  defp apply_change(job, {:retry_count, count}), do: %{job | retry_count: count}
  defp apply_change(job, {:caption, caption}), do: %{job | caption: caption}
  defp apply_change(job, {:mode, mode}), do: %{job | mode: mode}

  defp apply_change(job, {:error, %Error{} = error}) do
    Logger.error(
      "[pipeline] job #{job.id} failed at #{error.stage} (#{error.class}: #{error.summary})"
    )

    :telemetry.execute(
      [:insta_mealie, :pipeline, :failure],
      %{count: 1},
      %{job_id: job.id, stage: error.stage, error_class: error.class}
    )

    job
    |> Map.put(:error_stage, error.stage)
    |> Map.put(:error_class, error.class)
    |> Map.put(:error_summary, error.summary)
  end

  defp apply_change(job, {:clear_error}) do
    %{job | error_stage: nil, error_class: nil, error_summary: nil}
  end

  defp apply_change(job, {:reset}) do
    %{
      job
      | stage: nil,
        stages: %{},
        recipe: nil,
        verdict: nil,
        missing_fields: nil,
        slug: nil,
        deep_link: nil
    }
  end

  # ---- internals ----

  @doc """
  Execute the Mealie import for a job whose recipe is ready, persisting the
  result to ETS and broadcasting the update. Returns `{:ok, updated_job}` on
  success or `{:error, %Error{}}` on failure.

  This is the canonical import entrypoint. The GenServer (via
  `InstaMealie.Pipeline.Job.run_import/1`) delegates here after setting the
  `:mealie_import` stage to `:running`. The post-review path
  (`apply_ingredient_resolutions/2`) also calls this function after
  pre-setting the stage. Callers MUST set the stage to `:running` before
  calling; this function sets `:done` on success or `:failed` on error.
  """
  @spec run_import_inline(Job.t()) :: {:ok, Job.t()} | {:error, Error.t()}
  def run_import_inline(job) do
    recipe = job.recipe || Recipe.empty()

    case InstaMealie.Mealie.import_recipe(recipe, job.slug) do
      {:ok, slug, deep_link} ->
        updated =
          transition(job, [
            {:state, :succeeded},
            {:slug, slug},
            {:deep_link, deep_link},
            {:clear_error},
            {:stage, :mealie_import, :done}
          ])

        {:ok, updated}

      {:error, %Error{} = error} ->
        error = %Error{error | stage: :mealie_import}

        transition(job, [
          {:state, :failed},
          {:error, error},
          {:stage, :mealie_import, :failed}
        ])

        {:error, error}
    end
  end

  defp normalize_url(nil), do: nil

  defp normalize_url(url) when is_binary(url) do
    uri = URI.parse(url)
    # Strip query string and fragment
    normalized = %{uri | query: nil, fragment: nil}
    # Strip trailing slash from path
    path = String.trim_trailing(normalized.path || "", "/")
    normalized = %{normalized | path: if(path == "", do: "/", else: path)}
    URI.to_string(normalized) |> String.trim_trailing("/")
  end

  defp check_duplicate_url(nil, _force), do: :ok
  defp check_duplicate_url(_url, true), do: :ok

  defp check_duplicate_url(normalized_url, false) do
    existing =
      JobStore.list()
      |> Enum.find(fn job ->
        job.url &&
          job.state not in [:failed, :cancelled] &&
          normalize_url(job.url) == normalized_url
      end)

    if existing do
      Logger.warning(
        "[pipeline] duplicate URL detected, existing job #{existing.id}"
      )

      {:error, :duplicate_url, existing.id}
    else
      :ok
    end
  end

  defp generate_id do
    "jm_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
  end

  defp output_language do
    Application.get_env(:insta_mealie, :insta_mealie, [])[:output_language] || "en"
  end

  def broadcast(job) do
    Phoenix.PubSub.broadcast(PubSub, "jobs", {:job_updated, job})
  end
end

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

    caption_only =
      is_binary(input[:caption] || input["caption"]) and (input[:url] || input["url"]) == nil

    job = %Job{
      id: id,
      input: input,
      url: input[:url] || input["url"],
      caption: input[:caption] || input["caption"],
      caption_only: caption_only,
      transcribe_anyway: false,
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
      review: nil,
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
  Whether a pipeline error class represents a retryable failure (vs. a dead
  row). `validation` is terminal; `network` / `auth` and the other transient
  classes are retryable. Consumed by the retry UI (later ticket).
  """
  def error_retryable?(class)
      when class in [
             :network,
             :auth,
             :timeout,
             :rate_limited,
             :ip_banned,
             :cookie_expired,
             :api_error
           ],
      do: true

  def error_retryable?(:validation), do: false
  def error_retryable?(:incomplete_caption), do: false
  def error_retryable?(_), do: false

  @doc """
  Retry a job from the start, preserving its `job_id`. Each retry is counted
  per failing stage (capped at 2 in the UI — see `InstaMealieWeb.JobsLive`);
  once a stage's retry budget is exhausted, the Retry CTA is hidden.
  """
  def retry(job_id) when is_binary(job_id) do
    case JobStore.get(job_id) do
      nil ->
        {:error, :not_found}

      %{error_stage: :mealie_import} = job when not is_nil(job.recipe) ->
        stop_job(job_id)
        run_import_inline(job)

      job ->
        stop_job(job_id)

        old_stage = job.error_stage

        retry_count =
          if old_stage do
            Map.put(job.retry_count, old_stage, Map.get(job.retry_count, old_stage, 0) + 1)
          else
            job.retry_count
          end

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
              transcribe_anyway: false,
              retry_count: retry_count,
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
  Paste-caption recovery path (T6). Persists the supplied caption, transitions
  a fetch-failed job to `:caption_pasting`, and re-runs the routing LLM call on
  the same ETS row via the caption-only pipeline path. Also used by the degraded
  mode create path. Only valid from a fetch-failed state (or an already
  caption-only job); otherwise returns `{:error, :invalid_state}`.
  """
  def submit_caption(job_id, caption) when is_binary(job_id) and is_binary(caption) do
    case JobStore.get(job_id) do
      nil ->
        {:error, :not_found}

      job ->
        if job.error_stage == :fetch or job.caption_only do
          stop_job(job_id)

          updated = %{
            job
            | caption: caption,
              state: :caption_pasting,
              caption_only: true,
              transcribe_anyway: false,
              stage: nil,
              stages: %{},
              error_stage: nil,
              error_class: nil,
              error_summary: nil,
              updated_at: DateTime.utc_now()
          }

          JobStore.put(updated)
          broadcast(updated)
          DynamicSupervisor.start_child(JobSupervisor, {Job, updated})
          {:ok, job_id}
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
  `caption`, `verdict`, and `retry_count`), the `transcribe_anyway` flag is set so
  the GenServer takes the skip-audio FSM branch, and a fresh GenServer is started.
  Returns `{:error, :invalid_state}` when the job is not in a transcribe/merge
  failure state, and `{:error, :not_found}` when unknown.
  """
  def apply_transcribe_anyway(job_id) when is_binary(job_id) do
    case JobStore.get(job_id) do
      nil ->
        {:error, :not_found}

      %{error_stage: stage} = job when stage in [:transcribe, :llm_merge] ->
        stop_job(job_id)

        updated = %{
          job
          | state: :created,
            stage: nil,
            stages: %{},
            error_stage: nil,
            error_class: nil,
            error_summary: nil,
            transcribe_anyway: true,
            caption_only: false,
            updated_at: DateTime.utc_now()
        }

        JobStore.put(updated)
        broadcast(updated)
        DynamicSupervisor.start_child(JobSupervisor, {Job, updated})
        {:ok, job_id}

      _other ->
        {:error, :invalid_state}
    end
  end

  @doc """
  Apply ingredient resolutions from the review screen (T8). Replaces the raw
  ingredient strings in the recipe with the user's picks, then fires the import.
  """
  def apply_ingredient_resolutions(job_id, resolutions) when is_binary(job_id) do
    case JobStore.get(job_id) do
      nil ->
        {:error, :not_found}

      job ->
        ingredients = get_in(job.review, [:ingredients])
        raw_list = job.recipe["recipeIngredient"] || []

        if ingredients == nil do
          run_import_inline(job)
        else
          new_list =
            Enum.with_index(raw_list)
            |> Enum.map(fn {raw, i} ->
              resolution =
                Map.get(resolutions, i) || Map.get(resolutions, to_string(i))

              case resolution do
                nil ->
                  raw

                %{"food" => food, "unit" => unit} ->
                  ing = Enum.find(ingredients, fn ing -> ing.index == i end)
                  ing_quantity = if ing, do: ing.quantity, else: nil
                  ing_note = if ing, do: ing.note, else: nil

                  obj = %{"quantity" => ing_quantity, "food" => food}

                  obj =
                    if unit && unit != "",
                      do: Map.put(obj, "unit", unit),
                      else: obj

                  obj =
                    if ing_note,
                      do: Map.put(obj, "note", ing_note),
                      else: obj

                  obj

                _ ->
                  raw
              end
            end)

          resolved_recipe = put_in(job.recipe, ["recipeIngredient"], new_list)

          updated_job = %{
            job
            | recipe: resolved_recipe,
              review: nil,
              state: :created,
              stage: :mealie_import,
              stages: Map.put(job.stages, :mealie_import, :running)
          }

          JobStore.put(updated_job)
          broadcast(updated_job)
          run_import_inline(updated_job)
        end
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

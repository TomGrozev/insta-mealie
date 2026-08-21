defmodule InstaMealie.Pipeline.Job do
  @moduledoc """
  A single pipeline run, implemented as a GenServer that executes the
  fetch -> llm_format -> transcribe -> llm_merge -> mealie_import FSM.

  The GenServer is the live runner; durable state is mirrored into the
  ETS job store and broadcast over PubSub after every transition so the
  Jobs LiveView can render progress without polling.

  All state mutations route through `InstaMealie.Pipeline.transition/2`,
  which is the only function that mutates the job struct, writes to
  `JobStore`, and broadcasts on `PubSub`.

  ## Pipeline dispatch (issue #44)

  Each pipeline stage runs as its own `handle_info/2` clause. Between
  stages, a `:pipeline_advance` message would be sent — but in practice
  each stage's last action is to transition the *next* stage to `:running`
  (or `:skipped`) and call `advance/1`, which routes the next message via
  `next_stage/1`. This gives the process a chance to handle other mailbox
  messages between stages (cancel, timeout — issue #48).

  ## Stage execution model (issue #48 / Phase 6)

  Blocking work for each stage runs inside a `Task.Supervisor.async_nolink/2`
  against `InstaMealie.Pipeline.TaskSupervisor`. The GenServer owns a
  state map with the shape:

      %{
        job: %Job{},                # the canonical, durable job
        fetch_data: map|nil,        # stash from :fetch, used by llm_format/transcribe/llm_merge
        transcript: any|nil,        # stash from :transcribe, used by llm_merge
        link_candidates: [String.t()], # link candidates extracted from caption/OP comments
        consult_link: boolean(),    # router's recommendation to scrape a link (ADR-0006)
        linked_recipe: %Recipe{} | nil, # recipe scraped from the best candidate URL
        linked_recipe_url: String.t() | nil, # URL the linked_recipe was scraped from
        stage_task: {%Task{}, atom, atom} | nil  # current async task + disambiguating tag + canonical pipeline stage it belongs to
      }

  When a task finishes the GenServer receives `{ref, result}` and matches
  it against `state.stage_task`. On match it `Process.demonitor/2` with
  `:flush` (to drop the pending `:DOWN`), transitions the stage to `:done`
  (or fails the job on error), and advances. The `:DOWN` message handler
  catches genuine task crashes that never produced a result.

  Stage timeouts (`{:stage_timeout, stage}`) and cancels (`:cancel` cast)
  kill the running task explicitly with `Process.exit(task.pid, :kill)`
  before failing the job and stopping — this is the whole reason the
  blocking work was moved off the GenServer's main loop.
  """
  use GenServer

  require Logger

  alias InstaMealie.Error
  alias InstaMealie.Ingredient
  alias InstaMealie.Mealie
  alias InstaMealie.Pipeline
  alias InstaMealie.Pipeline.{JobAdmission, JobStore}
  alias InstaMealie.Recipe

  defstruct [
    :id,
    :input,
    :url,
    :caption,
    :mode,
    :state,
    :stage,
    :stages,
    :recipe,
    :verdict,
    :missing_fields,
    :slug,
    :deep_link,
    :error_stage,
    :error_class,
    :error_summary,
    :retry_count,
    :output_language,
    :stage_started_at,
    :stage_generations,
    :inserted_at,
    :updated_at
  ]

  @type stage ::
          :fetch | :llm_format | :scrape_link | :transcribe | :llm_merge | :mealie_import

  @type t :: %__MODULE__{
          id: binary() | nil,
          input: String.t() | nil,
          url: String.t() | nil,
          caption: String.t() | nil,
          mode: :caption_only | :url | nil,
          state: atom() | nil,
          stage: stage() | nil,
          stages: [atom()] | nil,
          recipe: InstaMealie.Recipe.t() | nil,
          verdict: term(),
          missing_fields: [atom()] | nil,
          slug: String.t() | nil,
          deep_link: String.t() | nil,
          error_stage: atom() | nil,
          error_class: atom() | nil,
          error_summary: String.t() | nil,
          retry_count: map() | nil,
          output_language: String.t() | nil,
          stage_started_at: DateTime.t() | nil,
          stage_generations: map() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  # ---- GenServer lifecycle ----

  # Revive entrypoint: `Pipeline.ensure_job_process/1` restarts a job from its
  # ETS snapshot when the GenServer is gone but the row still exists. The
  # `start_link/1` arg carries `{:revive, job}` so `init/1` can take the idle
  # path below instead of kicking off the pipeline. Must precede the generic
  # clause below so the tuple shape matches before the catch-all.
  def start_link({:revive, job}) do
    GenServer.start_link(__MODULE__, {:revive, job},
      name: {:via, Registry, {InstaMealie.Pipeline.Registry, job.id}}
    )
  end

  def start_link(job) do
    GenServer.start_link(__MODULE__, job,
      name: {:via, Registry, {InstaMealie.Pipeline.Registry, job.id}}
    )
  end

  # Revive path: re-attach to the Registry with the snapshot's current state
  # as metadata, then idle. Unlike the normal `init/1`, we do NOT return
  # `{:continue, :start_pipeline}` — the caller must issue an explicit command
  # (retry, submit_caption, etc.) before the pipeline resumes. This clause
  # must precede the generic `init/1` below so the tuple shape matches first.
  @impl true
  def init({:revive, job}) do
    Registry.register(InstaMealie.Pipeline.Registry, job.id, %{stage: job.state})

    {:ok,
     %{
       job: job,
       fetch_data: nil,
       transcript: nil,
       link_candidates: [],
       consult_link: false,
       linked_recipe: nil,
       linked_recipe_url: nil,
       stage_task: nil,
       # Per-stage `Process.send_after/3` refs for active timeout timers.
       # Stored on the GenServer state (NOT the durable Job struct) so they
       # can be cancelled on completion, failure, timeout, or terminate.
       stage_timers: %{}
     }}
  end

  @impl true
  def init(job) do
    state = %{
      job: job,
      fetch_data: nil,
      transcript: nil,
      link_candidates: [],
      consult_link: false,
      linked_recipe: nil,
      linked_recipe_url: nil,
      stage_task: nil,
      # Per-stage `Process.send_after/3` refs for active timeout timers.
      # Stored on the GenServer state (NOT the durable Job struct) so they
      # can be cancelled on completion, failure, timeout, or terminate.
      stage_timers: %{}
    }

    {:ok, state, {:continue, :start_pipeline}}
  end

  @impl true
  def terminate(_reason, %{job: job} = state) do
    # Cancel any remaining per-stage timeout timers. After this loop nothing
    # in the scheduler queue targets this GenServer, so a terminate caused
    # by a crash or external shutdown does not leave dangling timers that
    # would fire after the process is gone. `Process.cancel_timer/1` returns
    # `false` for timers that already fired — bind to `_` to discard safely.
    Enum.each(state.stage_timers || %{}, fn {_stage, ref} ->
      _ = Process.cancel_timer(ref)
    end)

    # Kill any in-flight stage task via the existing helper. Idempotent with
    # the explicit kill in the cancel/timeout handlers — covers every other
    # terminate path (crash, supervisor shutdown, parent stop).
    _ = kill_stage_task(state)

    # Idempotent: a release after a successful import, a cancel release, and
    # a crash all funnel here without double-freeing the slot.
    JobAdmission.release(job.id)
    :ok
  end

  @impl true
  def handle_continue(:start_pipeline, %{job: job} = state) do
    # Apply mode-specific initial transitions, then advance. Each mode sets
    # the first stage to `:running` (or `:done` for skip_audio) so `next_stage/1`
    # can route the first stage message.
    job =
      case job.mode do
        :skip_audio ->
          Pipeline.transition(job, [
            {:stage, :fetch, :skipped},
            {:stage, :transcribe, :skipped},
            {:stage, :llm_format, :done},
            {:stage, :scrape_link, :skipped},
            {:stage, :llm_merge, :skipped}
          ])

        :caption_only ->
          Pipeline.transition(job, [
            {:state, :caption_pasting},
            {:stage, :fetch, :skipped},
            {:stage, :llm_format, :running}
          ])

        :url ->
          Pipeline.transition(job, [{:stage, :fetch, :running}])
      end

    advance(%{state | job: job})
  end

  # ---- command handlers ----
  # Every user-issued command (retry, paste-caption, transcribe-anyway, resolve
  # ingredients) lands here. The GenServer is the single owner of every job
  # mutation: handlers route state through `Pipeline.transition/2` (the only
  # writer) and re-enter the FSM either by sending `:start_pipeline` to the
  # continue queue (full reset) or by calling `Pipeline.run_import_inline/1`
  # synchronously (mealie_import-only retry / resolve-ingredients).

  # Specific clause first: a mealie_import-only retry re-runs the import on the
  # same job without resetting the recipe. Pattern matches the old `:retry`
  # behaviour and must precede the general retry clause below.
  @impl true
  def handle_call(
        :retry,
        _from,
        %{job: %{error_stage: :mealie_import, recipe: recipe} = job} = state
      )
      when not is_nil(recipe) do
    retry_count =
      Map.put(
        job.retry_count,
        :mealie_import,
        Map.get(job.retry_count, :mealie_import, 0) + 1
      )

    Logger.info("[pipeline] job #{job.id} retrying import (has recipe)")

    reimport(state, [{:retry_count, retry_count}, {:stage, :mealie_import, :running}])
  end

  @impl true
  def handle_call(:retry, _from, %{job: job} = state) do
    old_stage = job.error_stage

    retry_count =
      if old_stage do
        Map.put(job.retry_count, old_stage, Map.get(job.retry_count, old_stage, 0) + 1)
      else
        job.retry_count
      end

    Logger.info("[pipeline] job #{job.id} retrying from #{old_stage || "start"}")

    reset =
      Pipeline.transition(job, [
        {:retry_count, retry_count},
        {:state, :created},
        {:reset},
        {:clear_error}
      ])

    {:reply, :ok, %{state | job: reset}, {:continue, :start_pipeline}}
  end

  @impl true
  def handle_call({:submit_caption, caption}, _from, %{job: job} = state) do
    updated =
      Pipeline.transition(job, [
        {:caption, caption},
        {:state, :caption_pasting},
        {:mode, :caption_only},
        {:reset},
        {:clear_error}
      ])

    {:reply, :ok, %{state | job: updated}, {:continue, :start_pipeline}}
  end

  @impl true
  def handle_call(:transcribe_anyway, _from, %{job: job} = state) do
    # Capture the routing recipe before the reset so it survives the recovery
    # path. The :skip_audio re-entry skips fetch/transcribe/llm_merge and marks
    # llm_format :done without running it, so the previously extracted recipe,
    # verdict, and missing_fields are the only source of truth for import.
    recipe = job.recipe
    verdict = job.verdict
    missing_fields = job.missing_fields

    updated =
      Pipeline.transition(job, [
        {:state, :created},
        {:mode, :skip_audio},
        {:reset},
        {:clear_error},
        {:recipe, recipe},
        {:verdict, verdict},
        {:missing_fields, missing_fields}
      ])

    {:reply, :ok, %{state | job: updated}, {:continue, :start_pipeline}}
  end

  @impl true
  def handle_call({:resolve_ingredients, resolutions}, _from, %{job: job} = state) do
    case resolve_resolution_ids(resolutions) do
      {:ok, enriched} ->
        ingredients = Ingredient.apply_resolutions(job.recipe.ingredients, enriched)
        updated_recipe = %{job.recipe | ingredients: ingredients}

        reimport(state, [{:recipe, updated_recipe}, {:stage, :mealie_import, :running}])

      {:error, %Error{} = error} ->
        # The resolution step is part of the mealie_import path: the user
        # resolved ingredients and the next step is the Mealie PATCH. Attribute
        # any lookup failure to that stage and let the existing `fail_job/2`
        # convention carry the job to its failure terminal state. The job is
        # now `:failed` so the GenServer stops and deregisters.
        error = %Error{error | stage: :mealie_import}
        failed = fail_job(job, error)
        re_read = JobStore.get(failed.id) || failed
        {:stop, :normal, {:error, error}, %{state | job: re_read}}
    end
  end

  @impl true
  def handle_cast(:cancel, %{job: job} = state) do
    if job.state in [:succeeded, :failed, :cancelled] do
      {:noreply, state}
    else
      # If a stage task is currently running, kill it before we transition.
      # The :DOWN it emits is harmless — the GenServer is about to stop and
      # its mailbox is discarded on `{:stop, :normal, _}`.
      state = kill_stage_task(state)

      stage = job.stage || :fetch
      error = Error.new(:cancelled, "job cancelled by user", stage: stage)

      job =
        Pipeline.transition(job, [
          {:stage, stage, :failed},
          {:state, :cancelled},
          {:error, error}
        ])

      JobAdmission.release(job.id)
      {:stop, :normal, %{state | job: job}}
    end
  end

  # Re-run the Mealie import on a job that already has a recipe, applying
  # `changes` first. Used by the import-only retry and by post-review resolution.
  # Both the success and the failure of `run_import_inline/2` produce a
  # terminal job state (`:succeeded` or `:failed`), so the GenServer stops and
  # deregisters from the Registry instead of lingering.
  defp reimport(%{job: job} = state, changes) do
    updated = Pipeline.transition(job, changes)
    result = Pipeline.run_import_inline(updated, job_fetch_dir(state))
    JobAdmission.release(job.id)
    re_read = JobStore.get(job.id) || updated
    {:stop, :normal, result, %{state | job: re_read}}
  end

  # Walk the resolutions map and merge Mealie ids into each entry that has a
  # nonblank food/unit name without an explicit id. The merge is what makes
  # `Ingredient.apply_resolutions/2` emit a `%Ref{name: name, id: id}`, which
  # `Ingredient.to_payload/1` then renders as the nested `{id, name}` object
  # Mealie's PATCH expects.
  #
  # Resolution rules:
  #   * Explicit `food_id` / `unit_id` in the entry → leave alone, no API call.
  #   * Blank / nil food or unit → leave alone (no empty records created).
  #   * Otherwise → call `Mealie.get_or_create_food/1` / `get_or_create_unit/1`
  #     and merge the returned id into the entry.
  #
  # On the first lookup failure the function short-circuits with the
  # existing `{:error, %Error{}}` convention so the caller can fail the job
  # through `fail_job/2`.
  defp resolve_resolution_ids(resolutions) when is_map(resolutions) do
    Enum.reduce_while(resolutions, {:ok, %{}}, fn {index, res}, {:ok, acc} ->
      case enrich_resolution(res) do
        {:ok, merged} -> {:cont, {:ok, Map.put(acc, index, merged)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp enrich_resolution(res) when is_map(res) do
    with {:ok, food_id} <- resolve_food_id(res),
         {:ok, unit_id} <- resolve_unit_id(res) do
      {:ok,
       res
       |> maybe_put_id("food_id", food_id)
       |> maybe_put_id("unit_id", unit_id)}
    end
  end

  # Returns `{:ok, id}` — `id` is `nil` when no lookup is needed (entry
  # already has an explicit id, or the food value is blank/nil), or the
  # id returned by the Mealie client on success. Errors propagate as-is.
  defp resolve_food_id(res) when is_map(res) do
    cond do
      is_binary(res["food_id"]) ->
        {:ok, res["food_id"]}

      not (is_binary(res["food"]) and res["food"] != "") ->
        {:ok, nil}

      true ->
        Mealie.get_or_create_food(res["food"])
    end
  end

  defp resolve_unit_id(res) when is_map(res) do
    cond do
      is_binary(res["unit_id"]) ->
        {:ok, res["unit_id"]}

      not (is_binary(res["unit"]) and res["unit"] != "") ->
        {:ok, nil}

      true ->
        Mealie.get_or_create_unit(res["unit"])
    end
  end

  # Only set the id key when the lookup produced a non-nil value — preserves
  # any existing key (including explicit `res["food_id"]`) when `nil`.
  defp maybe_put_id(map, _key, nil), do: map
  defp maybe_put_id(map, key, id), do: Map.put(map, key, id)

  # ---- stage handlers (handle_info) ----
  # Each stage runs in its own handle_info/2. The current stage is set to
  # `:running` at the start, the blocking work is spawned as a supervised
  # Task, and the GenServer returns immediately to its mailbox. When the
  # Task finishes the `{ref, result}` clause picks it up, transitions the
  # current stage to `:done` (or fails the job), pre-stages the next stage
  # to `:running` (or `:skipped`), and calls `advance/1` so the next
  # message arrives asynchronously. This lets cancel / timeout be
  # interleaved between stages — the whole point of Phase 6.

  @impl true
  def handle_info(:run_fetch, %{job: job} = state) do
    job = Pipeline.transition(job, [{:stage, :fetch, :running}])
    state = schedule_stage_timeout(:fetch, job, state)

    task =
      Task.Supervisor.async_nolink(InstaMealie.Pipeline.TaskSupervisor, fn ->
        InstaMealie.YtDlp.fetch_metadata(job.url, [])
      end)

    {:noreply, %{state | job: job, stage_task: {task, :fetch, :fetch}}}
  end

  def handle_info({ref, result}, %{stage_task: {%Task{ref: ref}, :fetch, _}} = state) do
    Process.demonitor(ref, [:flush])
    state = cancel_stage_timer(:fetch, state)

    case result do
      {:ok, fetch} ->
        # Stash fetch result for the next stages (llm_format, transcribe, llm_merge).
        changes = [{:stage, :fetch, :done}]

        changes =
          case Map.get(fetch, :thumbnail_path) do
            path when is_binary(path) and path != "" ->
              recipe = state.job.recipe || Recipe.empty()
              changes ++ [{:recipe, %{recipe | image: path}}]

            _ ->
              changes
          end

        job = Pipeline.transition(state.job, changes)
        # Pre-stage the next stage so next_stage/1 routes :run_llm_format.
        job = Pipeline.transition(job, [{:stage, :llm_format, :running}])
        advance(%{state | job: job, fetch_data: fetch, stage_task: nil})

      {:error, %Error{} = error} ->
        # Fetch failure is terminal — the job is now `:failed`, so the
        # GenServer stops and deregisters instead of holding state forever.
        {:stop, :normal, %{state | job: fail_job(state.job, error), stage_task: nil}}
    end
  end

  @impl true
  def handle_info(:run_llm_format, %{job: job} = state) do
    job = Pipeline.transition(job, [{:stage, :llm_format, :running}])
    state = schedule_stage_timeout(:llm_format, job, state)

    case llm_format_input(state) do
      {:ok, caption, comments, links, opts} ->
        task =
          Task.Supervisor.async_nolink(InstaMealie.Pipeline.TaskSupervisor, fn ->
            InstaMealie.LLM.format({caption, comments, links}, opts)
          end)

        {:noreply,
         %{
           state
           | job: job,
             stage_task: {task, :llm_format, :llm_format},
             link_candidates: links
         }}

      {:error, _reason} ->
        # No input for LLM format is terminal — fail the job and stop.
        {:stop, :normal,
         %{
           state
           | job:
               fail_job(
                 job,
                 Error.new(:validation, "no input for LLM format", stage: :llm_format)
               )
         }}
    end
  end

  def handle_info(
        {ref, result},
        %{stage_task: {%Task{ref: ref}, :llm_format, _}} = state
      ) do
    Process.demonitor(ref, [:flush])
    state = cancel_stage_timer(:llm_format, state)

    case result do
      {:ok, envelope} ->
        if envelope.completeness == :unknown do
          # Unknown completeness from llm_format is terminal — stop.
          {:stop, :normal,
           %{
             state
             | job:
                 fail_job(
                   state.job,
                   Error.new(
                     :validation,
                     "unknown LLM completeness verdict",
                     stage: :llm_format
                   )
                 )
           }}
        else
          job =
            Pipeline.transition(state.job, [
              {:stage, :llm_format, :done},
              {:recipe, preserve_recipe_image(envelope.recipe, state.job.recipe)},
              {:verdict, envelope.completeness},
              {:missing_fields, envelope.missing_fields}
            ])

          case Recipe.validate(job.recipe) do
            {:ok, _} ->
              advance_after_llm_format(%{state | job: job, consult_link: envelope.consult_link})

            {:error, field} ->
              # Recipe validation failure from llm_format is terminal — stop.
              {:stop, :normal,
               %{
                 state
                 | job:
                     fail_job(
                       job,
                       Error.new(
                         :validation,
                         "recipe field '#{field}' has wrong type",
                         stage: :llm_format
                       )
                     )
               }}
          end
        end

      {:error, %Error{} = error} ->
        # llm_format task error is terminal — stop.
        {:stop, :normal, %{state | job: fail_job(state.job, error), stage_task: nil}}
    end
  end

  @impl true
  def handle_info(:run_scrape_link, %{job: job} = state) do
    job = Pipeline.transition(job, [{:stage, :scrape_link, :running}])
    state = schedule_stage_timeout(:scrape_link, job, state)

    candidates = Enum.take(state.link_candidates || [], 3)

    task =
      Task.Supervisor.async_nolink(InstaMealie.Pipeline.TaskSupervisor, fn ->
        scrape_first_success(candidates)
      end)

    {:noreply, %{state | job: job, stage_task: {task, :scrape_link, :scrape_link}}}
  end

  def handle_info(
        {ref, result},
        %{stage_task: {%Task{ref: ref}, :scrape_link, _}} = state
      ) do
    Process.demonitor(ref, [:flush])
    state = cancel_stage_timer(:scrape_link, state)

    case result do
      {:ok, {url, recipe}} ->
        job = Pipeline.transition(state.job, [{:stage, :scrape_link, :done}])

        decide_after_scrape_link(%{
          state
          | job: job,
            linked_recipe: recipe,
            linked_recipe_url: url,
            stage_task: nil
        })

      {:error, _reason} ->
        job = Pipeline.transition(state.job, [{:stage, :scrape_link, :unresolved}])

        decide_after_scrape_link(%{
          state
          | job: job,
            linked_recipe: nil,
            linked_recipe_url: nil,
            stage_task: nil
        })
    end
  end

  @impl true
  def handle_info(:run_transcribe, %{job: job, fetch_data: fetch} = state) do
    job = Pipeline.transition(job, [{:stage, :transcribe, :running}])
    state = schedule_stage_timeout(:transcribe, job, state)

    task =
      Task.Supervisor.async_nolink(InstaMealie.Pipeline.TaskSupervisor, fn ->
        case InstaMealie.YtDlp.fetch_audio(job.url, output_dir: Map.get(fetch, :fetch_dir)) do
          {:ok, audio} -> InstaMealie.Whisper.transcribe(audio.audio_path, [])
          other -> other
        end
      end)

    {:noreply, %{state | job: job, stage_task: {task, :transcribe, :transcribe}}}
  end

  def handle_info(
        {ref, result},
        %{stage_task: {%Task{ref: ref}, :transcribe, _}} = state
      ) do
    Process.demonitor(ref, [:flush])
    state = cancel_stage_timer(:transcribe, state)

    case result do
      {:ok, transcript} ->
        # Stash transcript for the llm_merge stage.
        job =
          Pipeline.transition(state.job, [
            {:stage, :transcribe, :done},
            {:stage, :llm_merge, :running}
          ])

        advance(%{state | job: job, transcript: transcript, stage_task: nil})

      {:error, %Error{} = error} ->
        # Transcribe failure is terminal — stop.
        {:stop, :normal, %{state | job: fail_job(state.job, error), stage_task: nil}}
    end
  end

  @impl true
  def handle_info(
        :run_llm_merge,
        %{job: job, fetch_data: fetch, transcript: transcript} = state
      ) do
    job = Pipeline.transition(job, [{:stage, :llm_merge, :running}])
    state = schedule_stage_timeout(:llm_merge, job, state)

    # Resolve the caption based on mode — `:caption_only` jobs now reach
    # llm_merge when the router asks to consult a link (ADR-0006), and those
    # jobs have no fetch_data. `:url` jobs continue to use fetch.caption.
    caption = if job.mode == :caption_only, do: job.caption, else: fetch.caption

    task =
      Task.Supervisor.async_nolink(InstaMealie.Pipeline.TaskSupervisor, fn ->
        InstaMealie.LLM.merge(
          job.recipe,
          {caption, transcript, state.linked_recipe},
          output_language: job.output_language
        )
      end)

    {:noreply, %{state | job: job, stage_task: {task, :llm_merge, :llm_merge}}}
  end

  def handle_info(
        {ref, result},
        %{stage_task: {%Task{ref: ref}, :llm_merge, _}} = state
      ) do
    Process.demonitor(ref, [:flush])
    state = cancel_stage_timer(:llm_merge, state)

    case result do
      {:ok, envelope} ->
        if envelope.completeness == :unknown do
          # Unknown completeness from llm_merge is terminal — stop.
          {:stop, :normal,
           %{
             state
             | job:
                 fail_job(
                   state.job,
                   Error.new(
                     :validation,
                     "unknown LLM completeness verdict",
                     stage: :llm_merge
                   )
                 )
           }}
        else
          job =
            Pipeline.transition(state.job, [
              {:stage, :llm_merge, :done},
              {:recipe, preserve_recipe_image(envelope.recipe, state.job.recipe)}
            ])

          case Recipe.validate(job.recipe) do
            {:ok, _} ->
              advance(%{state | job: job, stage_task: nil})

            {:error, field} ->
              # Recipe validation failure from llm_merge is terminal — stop.
              {:stop, :normal,
               %{
                 state
                 | job:
                     fail_job(
                       job,
                       Error.new(
                         :validation,
                         "recipe field '#{field}' has wrong type",
                         stage: :llm_merge
                       )
                     )
               }}
          end
        end

      {:error, %Error{} = error} ->
        # llm_merge task error is terminal — stop.
        {:stop, :normal, %{state | job: fail_job(state.job, error), stage_task: nil}}
    end
  end

  @impl true
  def handle_info(:run_import_or_review, %{job: job} = state) do
    # Stamp provenance BEFORE the ingredient-parse branch so the recipe
    # PATCHed to Mealie (or held for review) already carries `orgURL` = the
    # reel URL and a "Recipe link" note when scrape_link resolved a linked
    # URL (ADR-0006). Once stamped, `job.recipe` is the source of truth and
    # `recipe` (the local) follows it.
    recipe = (job.recipe || Recipe.empty()) |> stamp_provenance(job, state)
    job = Pipeline.transition(job, [{:recipe, recipe}])

    if recipe.ingredients == [] do
      # No ingredients to parse — go straight to import.
      job = Pipeline.transition(job, [{:stage, :mealie_import, :running}])
      advance(%{state | job: job})
    else
      # Blocking work — wrap in a supervised task so cancel and timeout can
      # interleave (Phase 6). Mark :mealie_import :running so the timeout
      # handler sees a matching stage if the parser over-runs; the result
      # handler below adjusts it to :pending/:running once parsing finishes.
      job = Pipeline.transition(job, [{:stage, :mealie_import, :running}])
      state = schedule_stage_timeout(:mealie_import, job, state)

      # Extract raw strings from Ingredient.note for the Mealie parser API.
      raw_list = Enum.map(recipe.ingredients, fn %Ingredient{note: note} -> note || "" end)

      task =
        Task.Supervisor.async_nolink(InstaMealie.Pipeline.TaskSupervisor, fn ->
          InstaMealie.Mealie.parse_ingredients(raw_list)
        end)

      {:noreply, %{state | job: job, stage_task: {task, :mealie_import_parse, :mealie_import}}}
    end
  end

  def handle_info(
        {ref, result},
        %{
          stage_task: {%Task{ref: ref}, :mealie_import_parse, _},
          job: %{recipe: recipe}
        } = state
      ) do
    Process.demonitor(ref, [:flush])
    state = cancel_stage_timer(:mealie_import, state)

    case result do
      {:ok, parsed} ->
        ingredients = Ingredient.apply_parse(recipe.ingredients, parsed)

        if Enum.any?(ingredients, &(&1.status == :needs_review)) do
          # Persist the parsed ingredients (with :needs_review status) to the
          # recipe so the review screen can read them from job.recipe.ingredients.
          job = Pipeline.transition(state.job, [{:recipe, %{recipe | ingredients: ingredients}}])

          # Stop the pipeline here — the user must resolve ingredients via
          # :resolve_ingredients, which calls run_import_inline synchronously.
          # We do NOT call advance, so next_stage/1 is not re-entered.
          job =
            Pipeline.transition(job, [
              {:state, :needs_review},
              {:stage, :mealie_import, :pending}
            ])

          {:noreply, %{state | job: job, stage_task: nil}}
        else
          # All ingredients known: persist the parsed structured data and import.
          job =
            Pipeline.transition(state.job, [
              {:recipe, %{recipe | ingredients: ingredients}},
              {:stage, :mealie_import, :running}
            ])

          advance(%{state | job: job, stage_task: nil})
        end

      {:error, %Error{} = error} ->
        Logger.warning(
          "[pipeline] job #{state.job.id} ingredient parse failed (#{error.class}: #{error.summary}), importing with raw ingredients"
        )

        job = Pipeline.transition(state.job, [{:stage, :mealie_import, :running}])
        advance(%{state | job: job, stage_task: nil})
    end
  end

  @impl true
  def handle_info(:run_import, %{job: job} = state) do
    job = Pipeline.transition(job, [{:stage, :mealie_import, :running}])
    state = schedule_stage_timeout(:mealie_import, job, state)

    # Extract `fetch_dir` into a local BEFORE building the closure so the
    # async task captures the value at the moment of dispatch, not the
    # live GenServer state. The closure runs in a different process; if
    # we read `state.fetch_data` inside it, we'd be holding the GenServer
    # state across the GenServer's mailbox — a race against concurrent
    # transitions. `job_fetch_dir/1` also normalizes `fetch_data: nil`
    # (caption-only jobs, revived GenServers) to `nil`, so the import
    # fails closed at `Mealie.upload_image/3`.
    fetch_dir = job_fetch_dir(state)

    task =
      Task.Supervisor.async_nolink(InstaMealie.Pipeline.TaskSupervisor, fn ->
        Pipeline.run_import_inline(job, fetch_dir)
      end)

    {:noreply, %{state | job: job, stage_task: {task, :mealie_import, :mealie_import}}}
  end

  def handle_info(
        {ref, result},
        %{stage_task: {%Task{ref: ref}, :mealie_import, _}} = state
      ) do
    Process.demonitor(ref, [:flush])
    state = cancel_stage_timer(:mealie_import, state)

    case result do
      {:ok, updated} ->
        # run_import_inline already transitioned the job to :succeeded; this
        # is a terminal state, so the GenServer stops and deregisters.
        JobAdmission.release(state.job.id)
        {:stop, :normal, %{state | job: updated, stage_task: nil}}

      {:error, %Error{}} ->
        # run_import_inline already transitioned the job to :failed and wrote
        # to JobStore; re-read the canonical failed state. Terminal — stop.
        JobAdmission.release(state.job.id)
        {:stop, :normal, %{state | job: JobStore.get(state.job.id) || state.job, stage_task: nil}}
    end
  end

  # scrape_link failure of any kind (timeout, crash, or scrape failure) is
  # SURVIVABLE — it does NOT fail the job. This specific clause must precede
  # the generic {:stage_timeout, stage, gen} clause below, otherwise Elixir's
  # top-to-bottom matching would route scrape_link timeouts through the
  # generic fail-and-stop path.
  def handle_info({:stage_timeout, :scrape_link, gen}, %{job: job} = state) do
    current_gen = Map.get(job.stage_generations || %{}, :scrape_link, 0)

    if current_gen == gen and Map.get(job.stages, :scrape_link) == :running do
      Logger.warning("[pipeline] job #{job.id} scrape_link timed out — marking unresolved")
      state = cancel_stage_timer(:scrape_link, state)
      state = kill_stage_task(state)
      job = Pipeline.transition(job, [{:stage, :scrape_link, :unresolved}])

      decide_after_scrape_link(%{
        state
        | job: job,
          linked_recipe: nil,
          linked_recipe_url: nil
      })
    else
      # Stale timer from a previous attempt (or stage already finished) —
      # drop silently. Only drop the active ref when the generation in
      # this message matches the live generation; otherwise the ref in
      # state belongs to a different (newer) attempt and must survive.
      state =
        if current_gen == gen, do: cancel_stage_timer(:scrape_link, state), else: state

      {:noreply, state}
    end
  end

  # scrape_link task crash is SURVIVABLE — same reasoning as the timeout
  # clause above. Must precede the generic {:DOWN, ...} clause below.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{stage_task: {%Task{ref: ref}, :scrape_link, _}} = state
      ) do
    Logger.warning(
      "[pipeline] job #{state.job.id} scrape_link task crashed: #{inspect(reason)} — marking unresolved"
    )

    state = cancel_stage_timer(:scrape_link, state)
    job = Pipeline.transition(state.job, [{:stage, :scrape_link, :unresolved}])

    decide_after_scrape_link(%{
      state
      | job: job,
        linked_recipe: nil,
        linked_recipe_url: nil,
        stage_task: nil
    })
  end

  @impl true
  def handle_info({:stage_timeout, stage, gen}, %{job: job} = state) do
    current_gen = Map.get(job.stage_generations || %{}, stage, 0)

    cond do
      # Stale timer from a previous attempt that failed-fast (or whose user
      # retried before the timer fired). Drop silently — the per-stage
      # generation was bumped when the new attempt transitioned to :running,
      # so this timer no longer belongs to the live stage. We also must NOT
      # cancel/drop the active ref in `state.stage_timers[stage]` here,
      # because that ref belongs to the newer generation's live attempt.
      current_gen != gen ->
        {:noreply, state}

      # Stage already completed for this generation — drop silently. The
      # result handler already cancelled and removed the ref, but calling
      # again is a harmless no-op when the ref is gone.
      Map.get(job.stages, stage) != :running ->
        state = cancel_stage_timer(stage, state)
        {:noreply, state}

      true ->
        Logger.error("[pipeline] job #{job.id} timed out at #{stage}")

        # Drop the timer ref for this stage — its scheduled message has
        # already fired (this clause IS the handler for that message).
        state = cancel_stage_timer(stage, state)

        # If a task is still running for the timed-out stage, kill it. We then
        # set stage_task: nil so the pending :DOWN (or any stale result) won't
        # match a stage_task clause. The GenServer stops right after, so the
        # mailbox is discarded anyway — demonitor is belt-and-braces.
        #
        # Pin-match against the canonical stage (3rd tuple element), not the
        # raw tag (2nd). The :mealie_import_parse sub-task carries the
        # disambiguating tag :mealie_import_parse but still belongs to the
        # canonical :mealie_import stage — pin-matching against the tag here
        # would silently skip the explicit kill for that sub-task.
        state =
          case state.stage_task do
            {%Task{pid: pid, ref: ref}, _tag, ^stage} ->
              Process.exit(pid, :kill)
              Process.demonitor(ref, [:flush])
              %{state | stage_task: nil}

            _ ->
              state
          end

        job = fail_job(job, Error.new(:timeout, "#{stage} stage timed out", stage: stage))
        {:stop, :normal, %{state | job: job}}
    end
  end

  # Catch genuine task crashes: the Task raised an exception so no
  # `{ref, result}` message will arrive, only `:DOWN`. (On the success path
  # we `Process.demonitor(ref, [:flush])`, so the `:DOWN` is gone. On the
  # timeout/cancel path we stop the GenServer and the mailbox is dropped.)
  #
  # The 3-tuple `stage_task` carries {task, tag, canonical_stage}. The tag
  # is the disambiguator that lets multiple async sub-steps share one
  # pipeline stage without colliding in `{ref, result}` clauses; the
  # canonical_stage is the actual `@type stage` key the stage map, timer
  # store, retry_count, and telemetry all key off. Use the canonical stage
  # for every error/timer/telemetry reference here — using the raw tag would
  # e.g. attribute a `:mealie_import_parse` (parse-sub-task) crash to the
  # non-canonical `:mealie_import_parse` "stage", write a phantom entry to
  # `job.stages`, and skip the `:mealie_import`-keyed timer cancel.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{stage_task: {%Task{ref: ref}, _tag, canonical_stage}} = state
      ) do
    Logger.error(
      "[pipeline] job #{state.job.id} stage #{canonical_stage} task crashed: #{inspect(reason)}"
    )

    state = cancel_stage_timer(canonical_stage, state)

    job =
      fail_job(
        state.job,
        Error.new(
          :exception,
          "task crashed at #{canonical_stage}: #{inspect(reason)}",
          stage: canonical_stage
        )
      )

    # Task crash leaves the job in `:failed` — terminal — so the GenServer
    # stops and deregisters instead of holding state forever.
    {:stop, :normal, %{state | job: job, stage_task: nil}}
  end

  # ---- pipeline routing ----

  defp advance(%{job: job} = state) do
    case next_stage(job) do
      :idle ->
        # When the FSM reports nothing more to do, only stop the GenServer if
        # the job has actually reached a terminal state. Non-terminal idle
        # states (e.g. `:needs_review`, mid-flight `:created`/`:caption_pasting`)
        # must remain alive so subsequent commands or ingredient resolutions
        # can still be processed.
        if job.state in [:succeeded, :failed, :cancelled] do
          {:stop, :normal, state}
        else
          {:noreply, state}
        end

      msg ->
        send(self(), msg)
        {:noreply, state}
    end
  end

  # Maps the job's current state to the next message. Each stage's handle_info
  # is responsible for setting its own stage to `:running` before calling
  # advance/1, and for setting the next stage to `:running` (or `:skipped`)
  # so the next iteration of this cond can route correctly.
  defp next_stage(job) do
    cond do
      # Terminal states — pipeline is done.
      job.state in [:succeeded, :failed, :cancelled] ->
        :idle

      # Fetch is running → run it.
      Map.get(job.stages, :fetch) == :running ->
        :run_fetch

      # URL mode defensive guard: fetch is in a non-final state — do nothing.
      Map.get(job.stages, :fetch) not in [:done, :skipped, :failed] and job.mode == :url ->
        :idle

      # LLM format is running → run it.
      Map.get(job.stages, :llm_format) == :running ->
        :run_llm_format

      # LLM format is in a non-final state — do nothing.
      Map.get(job.stages, :llm_format) not in [:done, :skipped, :failed] ->
        :idle

      # scrape_link is running → run it.
      Map.get(job.stages, :scrape_link) == :running ->
        :run_scrape_link

      # scrape_link is in a non-final state (`:unresolved` is terminal for
      # this stage and lets the FSM advance, so it's excluded from this
      # "non-final" guard).
      Map.get(job.stages, :scrape_link) not in [:done, :skipped, :failed, :unresolved] ->
        :idle

      # Transcribe is running → run it.
      Map.get(job.stages, :transcribe) == :running ->
        :run_transcribe

      # Transcribe is in a non-final state — do nothing.
      Map.get(job.stages, :transcribe) not in [:done, :skipped, :failed] ->
        :idle

      # LLM merge is running → run it.
      Map.get(job.stages, :llm_merge) == :running ->
        :run_llm_merge

      # LLM merge is in a non-final state — do nothing.
      Map.get(job.stages, :llm_merge) not in [:done, :skipped, :failed] ->
        :idle

      # Mealie import is running → run it.
      Map.get(job.stages, :mealie_import) == :running ->
        :run_import

      # Mealie import has not been started or is pending review → go through
      # the import/review routing, which sets mealie_import to :running or
      # transitions the job to :needs_review.
      Map.get(job.stages, :mealie_import) not in [:done, :failed] ->
        :run_import_or_review

      # All stages in a final state — nothing more to do.
      true ->
        :idle
    end
  end

  # After llm_format succeeds, decide the `scrape_link` stage and dispatch it
  # when the router asked for one (ADR-0006). When scrape_link is skipped,
  # there is no async task to wait for — `decide_after_scrape_link/1` is the
  # single place that decides what runs next (transcribe / llm_merge / fail),
  # for both modes.
  defp advance_after_llm_format(%{job: job} = state) do
    candidates = Enum.take(state.link_candidates || [], 3)

    job =
      if state.consult_link && candidates != [] do
        Pipeline.transition(job, [{:stage, :scrape_link, :running}])
      else
        Pipeline.transition(job, [{:stage, :scrape_link, :skipped}])
      end

    state = %{state | job: job}

    if Map.get(job.stages, :scrape_link) == :running do
      advance(state)
    else
      decide_after_scrape_link(%{state | linked_recipe: nil, linked_recipe_url: nil})
    end
  end

  # Single decision point after scrape_link has resolved (or been skipped).
  # Both `:caption_only` and `:url` modes route through here:
  #
  # * `:recipe_complete` verdict skips both transcribe and llm_merge EXCEPT
  #   when scrape_link actually executed (i.e. `job.stages[:scrape_link]` is
  #   not `:skipped`); then llm_merge runs so the linked recipe can fill in
  #   anything the caption missed (ADR-0006 — completeness and
  #   link-consultation are independent axes; recipe_complete no longer
  #   implies skip-merge). We key the llm_merge decision off scrape_link
  #   execution rather than the raw `state.consult_link` flag, so a router
  #   that asked to consult a link but found zero candidates (correctly
  #   marking scrape_link `:skipped`) falls back to pre-#50 behaviour
  #   exactly.
  # * Linked recipe covers all missing_fields → skip transcribe, run llm_merge
  #   (a structural check, no extra LLM call).
  # * `:caption_only` mode with no covered fallback → `:incomplete_caption`
  #   failure (no audio path is available to recover).
  # * `:url` mode with no covered fallback → proceed to transcription.
  defp decide_after_scrape_link(%{job: job} = state) do
    covered = linked_recipe_covers_missing_fields?(state.linked_recipe, job.missing_fields)

    case job.mode do
      :caption_only ->
        cond do
          job.verdict == :recipe_complete ->
            job =
              Pipeline.transition(job, [
                {:stage, :transcribe, :skipped},
                {:stage, :llm_merge,
                 if(Map.get(job.stages, :scrape_link) != :skipped, do: :running, else: :skipped)}
              ])

            advance(%{state | job: job})

          covered ->
            job =
              Pipeline.transition(job, [
                {:stage, :transcribe, :skipped},
                {:stage, :llm_merge, :running}
              ])

            advance(%{state | job: job})

          true ->
            # Incomplete caption in `:caption_only` mode is terminal — no audio
            # path exists to recover. The job is now `:failed`, so stop.
            {:stop, :normal,
             %{
               state
               | job:
                   fail_job(
                     job,
                     Error.new(
                       :incomplete_caption,
                       "The pasted caption does not contain a complete recipe, and there is no audio to transcribe.",
                       stage: :llm_format
                     )
                   )
             }}
        end

      :url ->
        cond do
          job.verdict == :recipe_complete ->
            job =
              Pipeline.transition(job, [
                {:stage, :transcribe, :skipped},
                {:stage, :llm_merge,
                 if(Map.get(job.stages, :scrape_link) != :skipped, do: :running, else: :skipped)}
              ])

            advance(%{state | job: job})

          covered ->
            job =
              Pipeline.transition(job, [
                {:stage, :transcribe, :skipped},
                {:stage, :llm_merge, :running}
              ])

            advance(%{state | job: job})

          true ->
            job = Pipeline.transition(job, [{:stage, :transcribe, :running}])
            advance(%{state | job: job})
        end
    end
  end

  # Structural check (issue #50, item 4) — no LLM call. A linked recipe
  # "covers" missing_fields only when it actually supplies non-empty content
  # for every entry; an empty missing_fields list or a nil linked recipe
  # never counts as covered (recipe_complete/no_recipe are handled by the
  # branches above it).
  defp linked_recipe_covers_missing_fields?(nil, _missing_fields), do: false
  defp linked_recipe_covers_missing_fields?(_recipe, nil), do: false
  defp linked_recipe_covers_missing_fields?(_recipe, []), do: false

  defp linked_recipe_covers_missing_fields?(%Recipe{} = recipe, missing_fields)
       when is_list(missing_fields) do
    Enum.all?(missing_fields, fn
      :recipeIngredient -> recipe.ingredients not in [nil, []]
      :recipeInstructions -> recipe.instructions not in [nil, []]
      _ -> false
    end)
  end

  # Pick the LLM.format input + opts based on the job's mode. Caption-only
  # uses the pasted caption; URL mode uses the fetch result stashed in the
  # GenServer state by :run_fetch. Both modes compute candidate link URLs
  # via `InstaMealie.LinkExtractor.extract/2` so the router can decide
  # whether `scrape_link` should run (ADR-0006).
  defp llm_format_input(%{job: %{mode: :caption_only} = job}) do
    links = InstaMealie.LinkExtractor.extract(job.caption || "", [])
    {:ok, job.caption, [], links, [output_language: job.output_language]}
  end

  defp llm_format_input(%{job: %{mode: :url} = job, fetch_data: fetch}) do
    case fetch do
      nil ->
        {:error, :no_fetch_data}

      fetch ->
        op_comments = filter_op_comments(Map.get(fetch, :author), Map.get(fetch, :comments))
        links = InstaMealie.LinkExtractor.extract(fetch.caption, op_comments)

        {:ok, fetch.caption, op_comments, links, [output_language: job.output_language]}
    end
  end

  # If a stage task is currently running, kill it and clear the slot.
  # Returns the (possibly updated) state. Used by the timeout and cancel
  # handlers — both of which need to terminate the blocking work before
  # failing the job.
  defp kill_stage_task(%{stage_task: nil} = state), do: state

  defp kill_stage_task(%{stage_task: {%Task{pid: pid, ref: ref}, _tag, _stage}} = state) do
    Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
    %{state | stage_task: nil}
  end

  # Pull `:fetch_dir` out of the GenServer's transient `state.fetch_data`
  # stash (the per-job temp dir `InstaMealie.YtDlp` created for the
  # reel fetch). It's only present in this state map, not on the
  # durable `Job` struct — so the same GenServer state is the only
  # reliable source. Returns `nil` when:
  #   * the fetch stage never ran (`:caption_only` jobs that go
  #     straight to `:llm_format`)
  #   * the GenServer was revived from an ETS snapshot, where
  #     `init({:revive, job})` always sets `fetch_data: nil` so the
  #     snapshot stays self-contained
  #   * the fetch stage ran but the result had no `:fetch_dir` key
  #     (defensive — production code always sets it)
  # `nil` is the fail-closed signal to `Mealie.upload_image/3`: reject
  # any non-URL `recipe.image` (see the security gate there).
  defp job_fetch_dir(%{fetch_data: fetch_data}) when is_map(fetch_data) do
    Map.get(fetch_data, :fetch_dir)
  end

  defp job_fetch_dir(_), do: nil

  defp filter_op_comments(op, comments) when is_binary(op) do
    Enum.filter(comments || [], fn comment ->
      author =
        case comment do
          %{author: a} -> a
          %{"author" => a} -> a
          _ -> nil
        end

      author == op
    end)
  end

  defp filter_op_comments(_op, _comments), do: []

  # Per-stage deadline. Looks up `:insta_mealie[:insta_mealie][:stage_timeouts]`
  # (see config/config.exs). Returns nil when the stage is not configured,
  # so callers can no-op the timer.
  defp stage_timeout(stage) do
    timeouts = Application.get_env(:insta_mealie, :insta_mealie, [])[:stage_timeouts] || %{}
    Map.get(timeouts, stage)
  end

  # Schedules a `{:stage_timeout, stage, gen}` message after the configured
  # deadline. The current per-stage generation is included so the timeout
  # handler can ignore stale timers left over from a previous attempt that
  # failed-fast (or whose user retried before the timer fired). Skipped when
  # the stage has no configured timeout or the timeout is non-positive.
  #
  # Takes the current state, cancels any previously scheduled timer for this
  # stage (cancel-and-replace semantics — the ref is no longer discarded),
  # stores the new ref in `state.stage_timers`, and returns the updated state.
  defp schedule_stage_timeout(stage, job, state) do
    timeout = stage_timeout(stage)
    gen = Map.get(job.stage_generations || %{}, stage, 0)

    if timeout && timeout > 0 do
      # Replace any previous timer for this stage. The previous ref is
      # cancelled so it cannot fire after a retry transitions the stage to
      # a new generation; the matching handle_info clause for
      # `{:stage_timeout, stage, gen}` would still drop it via the
      # generation check, but cancelling avoids the queue round-trip and
      # keeps state consistent.
      state = cancel_stage_timer(stage, state)
      ref = Process.send_after(self(), {:stage_timeout, stage, gen}, timeout)
      put_stage_timer(state, stage, ref)
    else
      state
    end
  end

  # Cancel the active timer for `stage` and remove its ref from state. Safe
  # when no timer is active (no-op) and when the timer has already fired
  # (`Process.cancel_timer/1` returns `false`, which we discard).
  defp cancel_stage_timer(stage, state) do
    case get_stage_timer(state, stage) do
      nil ->
        state

      ref ->
        _ = Process.cancel_timer(ref)
        drop_stage_timer(state, stage)
    end
  end

  defp get_stage_timer(state, stage) do
    case Map.get(state, :stage_timers) do
      timers when is_map(timers) -> Map.get(timers, stage)
      _ -> nil
    end
  end

  defp put_stage_timer(state, stage, ref) do
    timers =
      case Map.get(state, :stage_timers) do
        t when is_map(t) -> t
        _ -> %{}
      end

    %{state | stage_timers: Map.put(timers, stage, ref)}
  end

  defp drop_stage_timer(state, stage) do
    timers =
      case Map.get(state, :stage_timers) do
        t when is_map(t) -> t
        _ -> %{}
      end

    %{state | stage_timers: Map.delete(timers, stage)}
  end

  # ---- provenance stamping (ADR-0006) ----
  # Applied once in `:run_import_or_review`, immediately before the
  # ingredient-parse branch. Always runs — even when scrape_link never ran or
  # never resolved — so `orgURL` is the reel URL on every imported recipe.

  # `:url` mode: stamp `orgURL` to the reel URL (when the recipe hasn't
  # already set one), append a "Recipe link" note for the linked page, and
  # fall back to the linked recipe's image when the reel one is missing.
  defp stamp_provenance(recipe, %{mode: :url, url: url}, state) when is_binary(url) do
    recipe
    |> maybe_set_source_url(url)
    |> maybe_append_linked_note(state.linked_recipe_url)
    |> maybe_fallback_image(state.linked_recipe)
  end

  # `:caption_only` and other modes: no reel URL to stamp, but the linked
  # note and image fallback still apply when scrape_link resolved.
  defp stamp_provenance(recipe, _job, state) do
    recipe
    |> maybe_append_linked_note(state.linked_recipe_url)
    |> maybe_fallback_image(state.linked_recipe)
  end

  defp maybe_set_source_url(%Recipe{source_url: nil} = recipe, url),
    do: %{recipe | source_url: url}

  defp maybe_set_source_url(recipe, _url), do: recipe

  defp maybe_append_linked_note(recipe, nil), do: recipe

  defp maybe_append_linked_note(recipe, url) when is_binary(url) do
    existing = recipe.notes || []
    %{recipe | notes: existing ++ [%{"title" => "Recipe link", "text" => url}]}
  end

  defp maybe_fallback_image(
         %Recipe{image: nil} = recipe,
         %Recipe{image: linked_image}
       )
       when is_binary(linked_image) and linked_image != "" do
    %{recipe | image: linked_image}
  end

  defp maybe_fallback_image(recipe, _linked), do: recipe

  # When a later LLM stage replaces the recipe wholesale with an envelope that
  # doesn't carry an `image` (the LLM prompts don't ask for one), retain a
  # previously captured image — reel thumbnail from :fetch, or the linked-
  # recipe fallback applied by `stamp_provenance/3` — on the new `%Recipe{}`.
  # Mirrors the existing pattern of `maybe_fallback_image/2`: never overwrites
  # an image the newer recipe supplies itself.
  defp preserve_recipe_image(%Recipe{image: nil} = new, %Recipe{image: img})
       when is_binary(img) and img != "" do
    %{new | image: img}
  end

  defp preserve_recipe_image(%Recipe{} = new, _previous), do: new

  # Runs inside the scrape_link Task: try candidates in order, first success wins.
  # Returns `{:ok, {url, recipe}}` for the first candidate that scrapes, or
  # `{:error, :no_candidates}` when the list is empty / all candidates fail.
  defp scrape_first_success([]), do: {:error, :no_candidates}

  defp scrape_first_success([url | rest]) do
    case InstaMealie.Mealie.scrape_url(url) do
      {:ok, recipe} -> {:ok, {url, recipe}}
      {:error, _} -> scrape_first_success(rest)
    end
  end

  # ---- terminal failure ----
  # Funnels through Pipeline.transition/2 so the single transition function
  # owns every mutation, ETS write, and broadcast. Returns the transitioned
  # job so callers can wrap it as `{:noreply, job}` themselves.
  #
  # Normalizes `%Error{stage: nil}` to the current `job.stage` so the
  # stage-failed transition, the failure telemetry, and the job's
  # `error_stage` field all point at the stage that actually handled the
  # failure. Stage adapters (notably `LLM.format`/`LLM.merge`) don't know
  # which stage they're called from and return errors without `:stage` —
  # we attribute those to the stage that was just transitioned to
  # `:running`. Explicitly supplied stages are preserved.
  defp fail_job(job, %Error{} = error) do
    error = if error.stage, do: error, else: %{error | stage: job.stage}

    failed =
      Pipeline.transition(job, [
        {:stage, error.stage, :failed},
        {:state, :failed},
        {:error, error}
      ])

    # Eager release of the concurrency slot — defense in depth, not the only
    # release. Every caller of `fail_job/2` stops the GenServer immediately
    # afterward with `{:stop, :normal, ...}`, which independently runs
    # `terminate/2` and releases the same slot again. That second release is
    # safe ONLY because `JobAdmission.handle_cast({:release, job_id}, state)`
    # guards on membership in the active set and no-ops when the id is already
    # gone. Do not remove that guard treating it as dead code: this call site
    # (and any other double-release path) depends on it for correct slot
    # accounting.
    JobAdmission.release(failed.id)
    failed
  end
end

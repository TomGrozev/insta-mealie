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
        job: %Job{},          # the canonical, durable job
        fetch_data: map|nil,  # stash from :fetch, used by llm_format/transcribe/llm_merge
        transcript: any|nil,  # stash from :transcribe, used by llm_merge
        stage_task: {%Task{}, atom} | nil  # current async task + the stage it belongs to
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

  alias InstaMealie.Pipeline
  alias InstaMealie.Error
  alias InstaMealie.Recipe
  alias InstaMealie.Ingredient
  alias InstaMealie.Pipeline.{JobAdmission, JobStore}

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
    :inserted_at,
    :updated_at
  ]

  @type stage :: :fetch | :llm_format | :transcribe | :llm_merge | :mealie_import

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
    {:ok, %{job: job, fetch_data: nil, transcript: nil, stage_task: nil}}
  end

  @impl true
  def init(job) do
    state = %{
      job: job,
      fetch_data: nil,
      transcript: nil,
      stage_task: nil
    }

    {:ok, state, {:continue, :start_pipeline}}
  end

  @impl true
  def terminate(_reason, %{job: job}) do
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
    updated =
      Pipeline.transition(job, [
        {:state, :created},
        {:mode, :skip_audio},
        {:reset},
        {:clear_error}
      ])

    {:reply, :ok, %{state | job: updated}, {:continue, :start_pipeline}}
  end

  @impl true
  def handle_call({:resolve_ingredients, resolutions}, _from, %{job: job} = state) do
    ingredients = Ingredient.apply_resolutions(job.recipe.ingredients, resolutions)
    updated_recipe = %{job.recipe | ingredients: ingredients}

    reimport(state, [{:recipe, updated_recipe}, {:stage, :mealie_import, :running}])
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

      job =
        Pipeline.transition(job, [
          {:stage, stage, :failed},
          {:state, :cancelled},
          {:error, stage, :cancelled, "job cancelled by user"}
        ])

      JobAdmission.release(job.id)
      {:stop, :normal, %{state | job: job}}
    end
  end

  # Re-run the Mealie import on a job that already has a recipe, applying
  # `changes` first. Used by the import-only retry and by post-review resolution.
  defp reimport(%{job: job} = state, changes) do
    updated = Pipeline.transition(job, changes)
    result = Pipeline.run_import_inline(updated)
    JobAdmission.release(job.id)
    re_read = JobStore.get(job.id) || updated
    {:reply, result, %{state | job: re_read}}
  end

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
    schedule_stage_timeout(:fetch)

    task =
      Task.Supervisor.async_nolink(InstaMealie.Pipeline.TaskSupervisor, fn ->
        InstaMealie.YtDlp.fetch_metadata(job.url, [])
      end)

    {:noreply, %{state | job: job, stage_task: {task, :fetch}}}
  end

  def handle_info({ref, result}, %{stage_task: {%Task{ref: ref}, :fetch}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, fetch} ->
        # Stash fetch result for the next stages (llm_format, transcribe, llm_merge).
        changes = [{:stage, :fetch, :done}]

        changes =
          case Map.get(fetch, :thumbnail) do
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
        {:noreply, %{state | job: fail_job(state.job, error), stage_task: nil}}
    end
  end

  @impl true
  def handle_info(:run_llm_format, %{job: job} = state) do
    job = Pipeline.transition(job, [{:stage, :llm_format, :running}])
    schedule_stage_timeout(:llm_format)

    case llm_format_input(state) do
      {:ok, input, opts} ->
        task =
          Task.Supervisor.async_nolink(InstaMealie.Pipeline.TaskSupervisor, fn ->
            InstaMealie.LLM.format(input, opts)
          end)

        {:noreply, %{state | job: job, stage_task: {task, :llm_format}}}

      {:error, _reason} ->
        {:noreply,
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
        %{stage_task: {%Task{ref: ref}, :llm_format}} = state
      ) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, envelope} ->
        if envelope.completeness == :unknown do
          {:noreply,
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
              {:recipe, envelope.recipe},
              {:verdict, envelope.completeness},
              {:missing_fields, envelope.missing_fields}
            ])

          case Recipe.validate(job.recipe) do
            {:ok, _} ->
              advance_after_llm_format(%{state | job: job})

            {:error, field} ->
              {:noreply,
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
        {:noreply, %{state | job: fail_job(state.job, error), stage_task: nil}}
    end
  end

  @impl true
  def handle_info(:check_caption_completeness, %{job: job} = state) do
    case job.verdict do
      :recipe_complete ->
        job =
          Pipeline.transition(job, [
            {:stage, :transcribe, :skipped},
            {:stage, :llm_merge, :skipped}
          ])

        advance(%{state | job: job})

      _other ->
        {:noreply,
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
  end

  @impl true
  def handle_info(:run_transcribe, %{job: job, fetch_data: fetch} = state) do
    job = Pipeline.transition(job, [{:stage, :transcribe, :running}])
    schedule_stage_timeout(:transcribe)

    task =
      Task.Supervisor.async_nolink(InstaMealie.Pipeline.TaskSupervisor, fn ->
        with {:ok, audio} <-
               InstaMealie.YtDlp.fetch_audio(job.url, output_dir: Map.get(fetch, :fetch_dir)),
             {:ok, transcript} <- InstaMealie.Whisper.transcribe(audio.audio_path, []) do
          {:ok, transcript}
        end
      end)

    {:noreply, %{state | job: job, stage_task: {task, :transcribe}}}
  end

  def handle_info(
        {ref, result},
        %{stage_task: {%Task{ref: ref}, :transcribe}} = state
      ) do
    Process.demonitor(ref, [:flush])

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
        {:noreply, %{state | job: fail_job(state.job, error), stage_task: nil}}
    end
  end

  @impl true
  def handle_info(
        :run_llm_merge,
        %{job: job, fetch_data: fetch, transcript: transcript} = state
      ) do
    job = Pipeline.transition(job, [{:stage, :llm_merge, :running}])
    schedule_stage_timeout(:llm_merge)

    task =
      Task.Supervisor.async_nolink(InstaMealie.Pipeline.TaskSupervisor, fn ->
        InstaMealie.LLM.merge(fetch.caption, transcript,
          output_language: job.output_language,
          draft: job.recipe
        )
      end)

    {:noreply, %{state | job: job, stage_task: {task, :llm_merge}}}
  end

  def handle_info(
        {ref, result},
        %{stage_task: {%Task{ref: ref}, :llm_merge}} = state
      ) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, envelope} ->
        if envelope.completeness == :unknown do
          {:noreply,
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
              {:recipe, envelope.recipe}
            ])

          case Recipe.validate(job.recipe) do
            {:ok, _} ->
              advance(%{state | job: job, stage_task: nil})

            {:error, field} ->
              {:noreply,
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
        {:noreply, %{state | job: fail_job(state.job, error), stage_task: nil}}
    end
  end

  @impl true
  def handle_info(:run_import_or_review, %{job: job} = state) do
    recipe = job.recipe || Recipe.empty()

    if recipe.ingredients == [] do
      # No ingredients to parse — go straight to import.
      job = Pipeline.transition(job, [{:stage, :mealie_import, :running}])
      advance(%{state | job: job})
    else
      # Extract raw strings from Ingredient.note for the Mealie parser API.
      raw_list = Enum.map(recipe.ingredients, fn %Ingredient{note: note} -> note || "" end)

      case InstaMealie.Mealie.parse_ingredients(raw_list) do
        {:ok, parsed} ->
          ingredients = Ingredient.apply_parse(recipe.ingredients, parsed)

          if Enum.any?(ingredients, &(&1.status == :needs_review)) do
            # Persist the parsed ingredients (with :needs_review status) to the
            # recipe so the review screen can read them from job.recipe.ingredients.
            job = Pipeline.transition(job, [{:recipe, %{recipe | ingredients: ingredients}}])

            # Stop the pipeline here — the user must resolve ingredients via
            # :resolve_ingredients, which calls run_import_inline synchronously.
            # We do NOT call advance, so next_stage/1 is not re-entered.
            job =
              Pipeline.transition(job, [
                {:state, :needs_review},
                {:stage, :mealie_import, :pending}
              ])

            {:noreply, %{state | job: job}}
          else
            # All ingredients known: persist the parsed structured data and import.
            job =
              Pipeline.transition(job, [
                {:recipe, %{recipe | ingredients: ingredients}},
                {:stage, :mealie_import, :running}
              ])

            advance(%{state | job: job})
          end

        {:error, %Error{} = error} ->
          Logger.warning(
            "[pipeline] job #{job.id} ingredient parse failed (#{error.class}: #{error.summary}), importing with raw ingredients"
          )

          job = Pipeline.transition(job, [{:stage, :mealie_import, :running}])
          advance(%{state | job: job})
      end
    end
  end

  @impl true
  def handle_info(:run_import, %{job: job} = state) do
    job = Pipeline.transition(job, [{:stage, :mealie_import, :running}])

    task =
      Task.Supervisor.async_nolink(InstaMealie.Pipeline.TaskSupervisor, fn ->
        Pipeline.run_import_inline(job)
      end)

    {:noreply, %{state | job: job, stage_task: {task, :mealie_import}}}
  end

  def handle_info(
        {ref, result},
        %{stage_task: {%Task{ref: ref}, :mealie_import}} = state
      ) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, updated} ->
        JobAdmission.release(state.job.id)
        {:noreply, %{state | job: updated, stage_task: nil}}

      {:error, %Error{}} ->
        # run_import_inline already transitioned the job to :failed and wrote
        # to JobStore; re-read the canonical failed state.
        JobAdmission.release(state.job.id)
        {:noreply, %{state | job: JobStore.get(state.job.id) || state.job, stage_task: nil}}
    end
  end

  @impl true
  def handle_info({:stage_timeout, stage}, %{job: job} = state) do
    current_stage = Map.get(job.stages, stage)

    if current_stage == :running do
      Logger.error("[pipeline] job #{job.id} timed out at #{stage}")

      # If a task is still running for the timed-out stage, kill it. We then
      # set stage_task: nil so the pending :DOWN (or any stale result) won't
      # match a stage_task clause. The GenServer stops right after, so the
      # mailbox is discarded anyway — demonitor is belt-and-braces.
      state =
        case state.stage_task do
          {%Task{pid: pid, ref: ref}, ^stage} ->
            Process.exit(pid, :kill)
            Process.demonitor(ref, [:flush])
            %{state | stage_task: nil}

          _ ->
            state
        end

      job = fail_job(job, Error.new(:timeout, "#{stage} stage timed out", stage: stage))
      JobAdmission.release(job.id)
      {:stop, :normal, %{state | job: job}}
    else
      # Stage already completed — ignore stale timeout
      {:noreply, state}
    end
  end

  # Catch genuine task crashes: the Task raised an exception so no
  # `{ref, result}` message will arrive, only `:DOWN`. (On the success path
  # we `Process.demonitor(ref, [:flush])`, so the `:DOWN` is gone. On the
  # timeout/cancel path we stop the GenServer and the mailbox is dropped.)
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{stage_task: {%Task{ref: ref}, stage}} = state
      ) do
    Logger.error("[pipeline] job #{state.job.id} stage #{stage} task crashed: #{inspect(reason)}")

    job =
      fail_job(
        state.job,
        Error.new(:exception, "task crashed at #{stage}: #{inspect(reason)}", stage: stage)
      )

    {:noreply, %{state | job: job, stage_task: nil}}
  end

  # ---- pipeline routing ----

  defp advance(%{job: job} = state) do
    case next_stage(job) do
      :idle ->
        {:noreply, state}

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
      job.state in [:succeeded, :failed] ->
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

      # Caption-only mode: after llm_format :done and BEFORE transcribe has
      # been routed (transcribe still nil), check the verdict. The
      # `transcribe not in [:done, :skipped, :failed]` guard prevents a
      # re-entry loop once :check_caption_completeness has set transcribe
      # to :skipped.
      job.mode == :caption_only and
          Map.get(job.stages, :transcribe) not in [:done, :skipped, :failed] ->
        :check_caption_completeness

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

  # After llm_format succeeds, branch on (mode, verdict) to set up the next
  # stage transitions before calling advance.
  defp advance_after_llm_format(%{job: job} = state) do
    case job.mode do
      :caption_only ->
        # Always defer to :check_caption_completeness regardless of verdict.
        advance(state)

      :url ->
        case job.verdict do
          :recipe_complete ->
            job =
              Pipeline.transition(job, [
                {:stage, :transcribe, :skipped},
                {:stage, :llm_merge, :skipped}
              ])

            advance(%{state | job: job})

          _other ->
            # :recipe_partial or :no_recipe — proceed to transcription.
            job = Pipeline.transition(job, [{:stage, :transcribe, :running}])
            advance(%{state | job: job})
        end
    end
  end

  # Pick the LLM.format input + opts based on the job's mode. Caption-only
  # uses the pasted caption; URL mode uses the fetch result stashed in the
  # GenServer state by :run_fetch.
  defp llm_format_input(%{job: %{mode: :caption_only} = job}) do
    {:ok, job.caption, [comments: [], output_language: job.output_language]}
  end

  defp llm_format_input(%{job: %{mode: :url} = job, fetch_data: fetch}) do
    case fetch do
      nil ->
        {:error, :no_fetch_data}

      fetch ->
        op_comments = filter_op_comments(Map.get(fetch, :author), Map.get(fetch, :comments))
        {:ok, fetch.caption, [comments: op_comments, output_language: job.output_language]}
    end
  end

  # If a stage task is currently running, kill it and clear the slot.
  # Returns the (possibly updated) state. Used by the timeout and cancel
  # handlers — both of which need to terminate the blocking work before
  # failing the job.
  defp kill_stage_task(%{stage_task: nil} = state), do: state

  defp kill_stage_task(%{stage_task: {%Task{pid: pid, ref: ref}, _stage}} = state) do
    Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
    %{state | stage_task: nil}
  end

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

  # Schedules a `{:stage_timeout, stage}` message after the configured
  # deadline. Skipped when the stage has no configured timeout or the
  # timeout is non-positive.
  defp schedule_stage_timeout(stage) do
    timeout = stage_timeout(stage)

    if timeout && timeout > 0 do
      Process.send_after(self(), {:stage_timeout, stage}, timeout)
    end
  end

  # ---- terminal failure ----
  # Funnels through Pipeline.transition/2 so the single transition function
  # owns every mutation, ETS write, and broadcast. Returns the transitioned
  # job so callers can wrap it as `{:noreply, job}` themselves.
  defp fail_job(job, %Error{} = error) do
    Pipeline.transition(job, [
      {:stage, error.stage, :failed},
      {:state, :failed},
      {:error, error.stage, error.class, error.summary}
    ])
  end
end

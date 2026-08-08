defmodule InstaMealie.Pipeline.Job do
  @moduledoc """
  A single pipeline run, implemented as a GenServer that executes the
  fetch -> llm_format -> transcribe -> llm_merge -> mealie_import FSM.

  The GenServer is the live runner; durable state is mirrored into the
  ETS job store and broadcast over PubSub after every transition so the
  Jobs LiveView can render progress without polling.
  """
  use GenServer

  alias InstaMealie.Pipeline.{JobStore, Clients}
  alias InstaMealie.PubSub

  defstruct [
    :id,
    :input,
    :url,
    :caption,
    :state,
    :stage,
    :stages,
    :recipe,
    :verdict,
    :slug,
    :deep_link,
    :error_stage,
    :error_class,
    :error_summary,
    :retry_count,
    :output_language,
    :inserted_at,
    :updated_at
  ]

  # ---- GenServer lifecycle ----

  def start_link(job) do
    GenServer.start_link(__MODULE__, job,
      name: {:via, Registry, {InstaMealie.Pipeline.Registry, job.id}}
    )
  end

  @impl true
  def init(job) do
    {:ok, job, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, job) do
    {:noreply, run_pipeline(job)}
  end

  # ---- FSM ----

  defp run_pipeline(job) do
    job
    |> set_stage(:fetch, :running)
    |> persist()
    |> run_fetch()
  end

  defp run_fetch(job) do
    case Clients.fetch(job) do
      {:ok, fetch} ->
        job = set_stage(job, :fetch, :done) |> persist()
        run_format(job, fetch)

      {:error, class, reason} ->
        fail(job, :fetch, class, reason)
    end
  end

  defp run_format(job, fetch) do
    job = set_stage(job, :llm_format, :running) |> persist()

    case Clients.format(fetch.caption, output_language: job.output_language) do
      {:ok, envelope} ->
        job =
          job
          |> set_stage(:llm_format, :done)
          |> set_recipe(envelope.recipe)
          |> set_verdict(envelope.completeness)
          |> persist()

        case envelope.completeness do
          :recipe_complete ->
            job
            |> skip_stage(:transcribe)
            |> skip_stage(:llm_merge)
            |> persist()
            |> run_import()

          :recipe_partial ->
            run_transcribe(job, fetch)

          :no_recipe ->
            fail(job, :llm_format, :no_recipe, "The caption does not contain a complete recipe.")
        end

      {:error, class, reason} ->
        fail(job, :llm_format, class, reason)
    end
  end

  defp run_transcribe(job, fetch) do
    job = set_stage(job, :transcribe, :running) |> persist()

    case Clients.transcribe(fetch.video_path, []) do
      {:ok, transcript} ->
        job = set_stage(job, :transcribe, :done) |> persist()
        run_merge(job, fetch, transcript)

      {:error, class, reason} ->
        fail(job, :transcribe, class, reason)
    end
  end

  defp run_merge(job, fetch, transcript) do
    job = set_stage(job, :llm_merge, :running) |> persist()

    case Clients.merge(fetch.caption, transcript, output_language: job.output_language) do
      {:ok, envelope} ->
        job =
          job
          |> set_stage(:llm_merge, :done)
          |> set_recipe(envelope.recipe)
          |> persist()

        run_import(job)

      {:error, class, reason} ->
        fail(job, :llm_merge, class, reason)
    end
  end

  defp run_import(job) do
    job = set_stage(job, :mealie_import, :running) |> persist()
    recipe = job.recipe || %{}

    case Clients.import_recipe(recipe) do
      {:ok, slug, deep_link} ->
        job
        |> set_stage(:mealie_import, :done)
        |> set_slug(slug)
        |> set_deep_link(deep_link)
        |> set_state(:succeeded)
        |> persist()

      {:error, class, reason} ->
        fail(job, :mealie_import, class, reason)
    end
  end

  # ---- state helpers ----

  defp set_stage(job, stage, status) do
    %{job | stage: stage, stages: Map.put(job.stages, stage, status)}
  end

  defp skip_stage(job, stage) do
    %{job | stages: Map.put(job.stages, stage, :skipped)}
  end

  defp set_recipe(job, recipe), do: %{job | recipe: recipe}
  defp set_verdict(job, verdict), do: %{job | verdict: verdict}
  defp set_slug(job, slug), do: %{job | slug: slug}
  defp set_deep_link(job, link), do: %{job | deep_link: link}
  defp set_state(job, state), do: %{job | state: state}

  defp fail(job, stage, class, reason) do
    job
    |> set_stage(stage, :failed)
    |> set_state(:failed)
    |> Map.put(:error_stage, stage)
    |> Map.put(:error_class, class)
    |> Map.put(:error_summary, to_string(reason))
    |> persist()
  end

  defp persist(job) do
    job = %{job | updated_at: DateTime.utc_now()}
    JobStore.put(job)
    broadcast(job)
    job
  end

  defp broadcast(job) do
    Phoenix.PubSub.broadcast(PubSub, "jobs", {:job_updated, job})
  end
end

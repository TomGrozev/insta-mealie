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
  alias InstaMealie.Llm
  alias InstaMealie.PubSub

  defstruct [
    :id,
    :input,
    :url,
    :caption,
    :caption_only,
    :transcribe_anyway,
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
    :review,
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

  # ---- Public helpers (also used by tests) ----

  @doc """
  Keep only the comments authored by the reel's owner (OP).

  `op` is the reel author's username (from the fetch result). Each comment
  is a map with an `:author` (or `"author"`) key. Comments without a
  matching author are dropped. Non-OP comments must never reach the
  routing LLM call.
  """
  def filter_op_comments(op, comments) when is_binary(op) do
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

  def filter_op_comments(_op, _comments), do: []

  # ---- FSM ----

  defp run_pipeline(job) do
    cond do
      job.transcribe_anyway ->
        run_transcribe_anyway(job)

      job.caption_only ->
        run_caption_only(job)

      true ->
        job
        |> set_stage(:fetch, :running)
        |> persist()
        |> run_fetch()
    end
  end

  # ---- caption-only routing (paste-caption / degraded mode) ----

  defp run_caption_only(job) do
    job =
      %{job | state: :caption_pasting}
      |> set_stage(:fetch, :skipped)
      |> persist()

    run_caption_format(job)
  end

  defp run_caption_format(job) do
    job = set_stage(job, :llm_format, :running) |> persist()

    case Clients.format(job.caption, comments: [], output_language: job.output_language) do
      {:ok, envelope} ->
        env = Llm.normalize_envelope(envelope)

        job =
          job
          |> set_stage(:llm_format, :done)
          |> set_recipe(env.recipe)
          |> set_verdict(env.completeness)
          |> set_missing_fields(env.missing_fields)
          |> persist()

        case env.completeness do
          :recipe_complete ->
            job
            |> skip_stage(:transcribe)
            |> skip_stage(:llm_merge)
            |> persist()
            |> run_import_or_review()

          _other ->
            fail_incomplete_caption(job)
        end

      {:error, class, reason} ->
        fail(job, :llm_format, class, reason)
    end
  end

  defp fail_incomplete_caption(job) do
    fail(
      job,
      :llm_format,
      :incomplete_caption,
      "The pasted caption does not contain a complete recipe, and there is no audio to transcribe."
    )
  end

  # ---- transcribe-anyway override (T7) ----
  # Skip the failed audio and import the caption-only (routing) recipe that is
  # already on the job, reusing the same ETS row.

  defp run_transcribe_anyway(job) do
    job
    |> set_stage(:fetch, :skipped)
    |> set_stage(:transcribe, :skipped)
    |> set_stage(:llm_format, :done)
    |> set_stage(:llm_merge, :skipped)
    |> persist()
    |> run_import_or_review()
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
    op_comments = filter_op_comments(Map.get(fetch, :author), Map.get(fetch, :comments))

    job = set_stage(job, :llm_format, :running) |> persist()

    case Clients.format(fetch.caption,
           comments: op_comments,
           output_language: job.output_language
         ) do
      {:ok, envelope} ->
        env = Llm.normalize_envelope(envelope)

        job =
          job
          |> set_stage(:llm_format, :done)
          |> set_recipe(env.recipe)
          |> set_verdict(env.completeness)
          |> set_missing_fields(env.missing_fields)
          |> persist()

        case env.completeness do
          :recipe_complete ->
            job
            |> skip_stage(:transcribe)
            |> skip_stage(:llm_merge)
            |> persist()
            |> run_import_or_review()

          :recipe_partial ->
            run_transcribe(job, fetch)

          :no_recipe ->
            run_transcribe(job, fetch)
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

    case Clients.merge(fetch.caption, transcript,
           output_language: job.output_language,
           draft: job.recipe
         ) do
      {:ok, envelope} ->
        env = Llm.normalize_envelope(envelope)

        job =
          job
          |> set_stage(:llm_merge, :done)
          |> set_recipe(env.recipe)
          |> persist()

        run_import_or_review(job)

      {:error, class, reason} ->
        fail(job, :llm_merge, class, reason)
    end
  end

  defp run_import_or_review(job) do
    recipe = job.recipe || %{}
    raw_list = recipe["recipeIngredient"] || []

    if raw_list == [] do
      run_import(job)
    else
      case Clients.parse_ingredients(raw_list) do
        {:ok, parsed} ->
          ingredients =
            Enum.with_index(parsed)
            |> Enum.map(fn {p, i} ->
              %{
                index: i,
                raw: Enum.at(raw_list, i),
                quantity: p["quantity"],
                unit: p["unit"],
                food: p["food"],
                food_id: p["food_id"],
                food_confidence: p["food_confidence"],
                note: p["note"],
                unknown: unknown?(p)
              }
            end)

          if Enum.any?(ingredients, & &1.unknown) do
            enter_review(job, ingredients)
          else
            run_import(job)
          end

        {:error, _class, _reason} ->
          run_import(job)
      end
    end
  end

  defp unknown?(parsed) do
    confidence = Map.get(parsed, "food_confidence")
    food_id = Map.get(parsed, "food_id")
    confidence == nil or confidence < 0.85 or food_id == nil
  end

  defp enter_review(job, ingredients) do
    job = %{
      job
      | state: :needs_review,
        stages: Map.put(job.stages, :mealie_import, :pending),
        review: %{ingredients: ingredients}
    }

    persist(job)
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
  defp set_missing_fields(job, missing_fields), do: %{job | missing_fields: missing_fields}
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

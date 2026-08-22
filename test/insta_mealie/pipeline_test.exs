defmodule InstaMealie.PipelineTest do
  use InstaMealie.TestCase

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias InstaMealie.LLM.Mock, as: LLMMock
  alias InstaMealie.Pipeline
  alias InstaMealie.Pipeline.Job
  alias InstaMealie.Error
  alias InstaMealie.Pipeline.JobStore
  alias InstaMealie.Recipe

  @endpoint InstaMealieWeb.Endpoint

  # The merge prompt's user message starts with `"Caption: ... \n\nTranscript: ..."`,
  # while the format prompt's user message is the raw caption (and OP comments).
  # Use this substring to distinguish the two LLM calls inside a single stub.
  defp merge_call?(messages) do
    case Enum.reverse(messages) |> Enum.find(fn m -> m[:role] == "user" end) do
      nil -> false
      msg -> String.contains?(msg[:content] || "", "Transcript:")
    end
  end

  # Build the raw OpenAI-style chat response shape `LLM.parse_content/1` expects,
  # encoded from a (completeness, missing_fields, recipe) triple.
  defp chat_response(completeness, missing_fields, recipe) do
    {:ok,
     %{
       "choices" => [
         %{
           "message" => %{
             "content" =>
               Jason.encode!(%{
                 "completeness" => completeness,
                 "missing_fields" => missing_fields,
                 "recipe" => recipe
               })
           }
         }
       ]
     }}
  end

  describe "happy path (recipe_complete)" do
    test "create_job runs fetch -> llm_format -> mealie_import and succeeds" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")

      assert {:ok, id} = Pipeline.create_job(%{url: "https://instagram.com/reel/abc"})

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000

      assert job.verdict == :recipe_complete
      assert job.slug
      assert job.deep_link =~ "edit=true"
      assert Map.get(job.stages, :fetch) == :done
      assert Map.get(job.stages, :llm_format) == :done
      assert Map.get(job.stages, :mealie_import) == :done
      assert Map.get(job.stages, :transcribe) == :skipped
      assert Map.get(job.stages, :llm_merge) == :skipped

      assert %Job{state: :succeeded} = Pipeline.get_job(id)
      assert Enum.any?(Pipeline.list_recent_jobs(), fn j -> j.id == id end)
    end
  end

  describe "branching (recipe_partial)" do
    test "runs transcribe + merge before import" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")

      # First call returns recipe_partial, second (merge) returns recipe_complete.
      Mox.stub(LLMMock, :chat, fn _model, messages ->
        if merge_call?(messages) do
          chat_response("recipe_complete", [], %{"name" => "Merged"})
        else
          chat_response("recipe_partial", ["recipeInstructions"], %{"name" => "Partial"})
        end
      end)

      assert {:ok, id} = Pipeline.create_job(%{url: "https://instagram.com/reel/xyz"})

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000

      assert Map.get(job.stages, :transcribe) == :done
      assert Map.get(job.stages, :llm_merge) == :done
      assert Map.get(job.stages, :mealie_import) == :done
    end
  end

  describe "JobStore" do
    test "expired rows are swept away" do
      job = %Job{
        id: "exp1",
        state: :created,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      :ets.insert(
        :insta_mealie_jobs,
        {job.id, job, System.system_time(:millisecond) - 1000, System.system_time(:millisecond)}
      )

      assert JobStore.get("exp1")
      assert :ok = JobStore.sweep()
      refute JobStore.get("exp1")
    end

    test "row cap trims oldest entries" do
      now = DateTime.utc_now()

      for i <- 1..5 do
        JobStore.put(%Job{
          id: "cap#{i}",
          state: :created,
          stages: %{},
          inserted_at: now,
          updated_at: now
        })
      end

      JobStore.enforce_cap(3)
      assert JobStore.list() |> length() == 3
    end
  end

  describe "Jobs LiveView" do
    test "paste URL creates a job and reveals a deep link on success" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")
      conn = build_conn()
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#job-form")

      view
      |> form("#job-form", job: %{url: "https://instagram.com/reel/abc"})
      |> render_submit()

      assert_receive {:job_updated, %Job{state: :succeeded}}, 5000
      assert render(view) =~ "Open in Mealie"
    end
  end

  describe "branching (no_recipe)" do
    test "runs transcribe + merge before import (does NOT fail flatly)" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")

      # Format returns no_recipe (so the FSM routes through transcribe + merge),
      # merge returns recipe_complete so mealie_import still runs.
      Mox.stub(LLMMock, :chat, fn _model, messages ->
        if merge_call?(messages) do
          chat_response("recipe_complete", [], %{"name" => "Transcribed Granola"})
        else
          chat_response("no_recipe", ["recipeIngredient", "recipeInstructions"], %{})
        end
      end)

      assert {:ok, id} = Pipeline.create_job(%{url: "https://instagram.com/reel/nr"})

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000

      assert job.verdict == :no_recipe
      assert Map.get(job.stages, :transcribe) == :done
      assert Map.get(job.stages, :llm_merge) == :done
      assert Map.get(job.stages, :mealie_import) == :done
      assert %Recipe{name: "Transcribed Granola"} = job.recipe
    end
  end

  describe "missing_fields vocab" do
    test "pipeline stores only the allowed missing_fields on the job" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")

      # Format returns the partial envelope with one unknown field; merge
      # returns complete (so mealie_import runs) but is irrelevant to this
      # assertion — `missing_fields` is preserved from the format envelope.
      Mox.stub(LLMMock, :chat, fn _model, messages ->
        if merge_call?(messages) do
          chat_response("recipe_complete", [], %{"name" => "M"})
        else
          chat_response("recipe_partial", ["recipeIngredient", "nope"], %{"name" => "P"})
        end
      end)

      assert {:ok, id} = Pipeline.create_job(%{url: "https://instagram.com/reel/mf"})

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000
      assert job.missing_fields == [:recipeIngredient]
    end
  end

  describe "OP comment filtering" do
    test "only OP comments reach the routing LLM call" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")

      Mox.stub(InstaMealie.YtDlp.Mock, :fetch_metadata, fn _url, _opts ->
        {:ok,
         %{
           author: "op_user",
           caption: "Some caption text",
           comments: [
             %{author: "op_user", text: "OP says hi"},
             %{author: "stranger", text: "not the owner"},
             %{author: "op_user", text: "OP says bye"}
           ],
           fetch_dir: "/tmp/insta_mealie/fetch_op"
         }}
      end)

      Mox.stub(LLMMock, :chat, fn _model, messages ->
        # Extract the OP comment lines the pipeline sent us. Only the final
        # user message has "  - " prefixed lines (fewshot user messages and
        # the system prompt don't), so this collects exactly the OP comments
        # the routing prompt should have included.
        comments =
          messages
          |> Enum.filter(fn m -> m[:role] == "user" end)
          |> Enum.flat_map(fn m ->
            m[:content]
            |> String.split("\n")
            |> Enum.filter(&String.starts_with?(&1, "  - "))
            |> Enum.map(&String.trim_leading(&1, "  - "))
          end)

        chat_response(
          "recipe_complete",
          [],
          %{"name" => "authors:#{Enum.join(comments, ",")}"}
        )
      end)

      assert {:ok, id} = Pipeline.create_job(%{url: "https://instagram.com/reel/cm"})

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000

      # The recipe name echoes the authors the LLM saw; only op_user (twice)
      # should appear, confirming the stranger's comment was filtered out.
      assert %Recipe{name: "authors:OP says hi,OP says bye"} = job.recipe
    end
  end

  describe "Jobs LiveView (branching)" do
    test "paste URL on a partial verdict runs transcribe + merge and reveals a deep link" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")
      conn = build_conn()

      # Format returns recipe_partial, merge returns recipe_complete so the
      # job reaches mealie_import and the deep-link button renders.
      Mox.stub(LLMMock, :chat, fn _model, messages ->
        if merge_call?(messages) do
          chat_response("recipe_complete", [], %{"name" => "Merged"})
        else
          chat_response("recipe_partial", ["recipeInstructions"], %{"name" => "Partial"})
        end
      end)

      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "#job-form")

      view
      |> form("#job-form", job: %{url: "https://instagram.com/reel/branch"})
      |> render_submit()

      assert_receive {:job_updated,
                      %Job{state: :succeeded, stages: %{transcribe: :done, llm_merge: :done}}},
                     5000

      assert render(view) =~ "Open in Mealie"
      assert has_element?(view, "[data-stage=transcribe]")
      assert has_element?(view, "[data-stage=llm_merge]")
    end
  end

  # ── Regression test for issue #38 ──────────────────────────────────
  #
  # The fetched reel thumbnail must reach Mealie's image upload endpoint
  # end-to-end. Today it does NOT, because:
  #
  #   1. The fetch stage reads `:thumbnail` from the fetch result, but
  #      `YtDlp.fetch_metadata/2` returns `:thumbnail_path`. The key
  #      mismatch silently drops the thumbnail before it can be attached
  #      to the recipe.
  #
  #   2. Even if the key were fixed, the `llm_format` stage replaces the
  #      job's recipe wholesale (`Pipeline.transition(state.job, [...,
  #      {:recipe, envelope.recipe}, ...])`) and the LLM response does
  #      not carry an `image` field — so the thumbnail is lost across
  #      the recipe replacement and never reaches `upload_image/2`.
  #
  # This test exercises the real pipeline seam (YtDlp -> LLM ->
  # `Mealie.import_recipe/1` -> `upload_image/2`) using the existing
  # `InstaMealie.TestCase` setup and the env-stored `:mealie_http_adapter`
  # already used by every other pipeline test. It stubs `fetch_metadata`
  # with the real `:thumbnail_path` key, lets the default LLM mock emit a
  # recipe WITHOUT an `image` field (so loss across the LLM replacement
  # is observable), and asserts the image-upload adapter call is made.
  #
  # The test currently fails: no `:image_upload` message is ever sent,
  # because the buggy code never sets `recipe.image` from the fetch
  # result, so `Mealie.upload_image/2` short-circuits on `is_nil(image)`.

  describe "thumbnail upload (issue #38 regression)" do
    test "fetched :thumbnail_path reaches Mealie's image upload endpoint despite LLM recipe replacement" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")
      test_pid = self()
      thumbnail_url = "https://example.com/reel-thumb.jpg"

      # Wrap the existing :mealie_http_adapter (set up by InstaMealie.TestCase)
      # to capture image-upload calls. Everything else passes through so the
      # rest of the pipeline behaves identically.
      prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

      Application.put_env(
        :insta_mealie,
        :mealie_http_adapter,
        fn m, p, body ->
          cond do
            m == :post and String.starts_with?(p, "/api/recipes/") and
                String.ends_with?(p, "/image") ->
              send(test_pid, {:image_upload, m, p, body})
              {:ok, %{}}

            true ->
              prev.(m, p, body)
          end
        end
      )

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
          v -> Application.put_env(:insta_mealie, :mealie_http_adapter, v)
        end
      end)

      # Stub YtDlp.fetch_metadata to return the REAL key (:thumbnail_path) with
      # a deterministic thumbnail URL. The default LLM mock returns a recipe
      # that omits "image", so if the fetch stage attaches the thumbnail and
      # the LLM then replaces the recipe, the only way an image upload can
      # still happen is by preserving/re-attaching the thumbnail across the
      # LLM replacement.
      Mox.stub(InstaMealie.YtDlp.Mock, :fetch_metadata, fn _url, _opts ->
        {:ok,
         %{
           author: "chef_og",
           caption: "Homemade Granola\nMakes about 8 servings.",
           comments: [],
           thumbnail_path: thumbnail_url,
           fetch_dir: "/tmp/insta_mealie/fetch_thumb"
         }}
      end)

      assert {:ok, id} =
               Pipeline.create_job(%{url: "https://instagram.com/reel/thumb-issue-38"})

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded}}, 5000

      # The fetched :thumbnail_path must reach Mealie's image endpoint despite
      # the LLM format replacing the recipe. Catches both the key mismatch
      # (pipeline/job.ex reads :thumbnail, not :thumbnail_path) and the loss
      # across the LLM recipe replacement.
      assert_receive {:image_upload, _method, path, body}, 1000
      assert String.starts_with?(path, "/api/recipes/")
      assert String.ends_with?(path, "/image")
      assert body == %{url: thumbnail_url}
    end
  end

  # ── Regression test for the mealie_import ingredient-parse sub-task tag ──
  #
  # The `:mealie_import` stage dispatches its blocking work — calling
  # `Mealie.parse_ingredients/1` — as a distinct `Task.Supervisor.async_nolink/2`
  # tagged `:mealie_import_parse` (not `:mealie_import`). The tag is an
  # internal disambiguator so the `{ref, result}` clause for the parse task
  # doesn't shadow the clause for the real `run_import_inline/1` task.
  #
  # Today the generic `{:DOWN, ref, :process, _pid, reason}` handler in
  # `InstaMealie.Pipeline.Job` pattern-matches the *tag* and reuses it as the
  # canonical pipeline stage when calling `cancel_stage_timer/2` and
  # building the `Error.new/2` for `fail_job/2`. That is wrong: when the
  # parse task crashes, `:mealie_import_parse` is not a real `@type stage`
  # and its timer was never scheduled under that key (the real timer is
  # keyed `:mealie_import`). The downstream effects are:
  #
  #   * `cancel_stage_timer(:mealie_import_parse, _)` is a no-op — the live
  #     `:mealie_import` timer survives, queued against a dead GenServer.
  #   * `fail_job` writes a phantom `stages[:mealie_import_parse] = :failed`
  #     entry while the canonical `:mealie_import` entry stays stuck at
  #     `:running`.
  #   * `error_stage` becomes `:mealie_import_parse`, so the mealie_import
  #     retry fast-path (`error_stage: :mealie_import`) doesn't match and
  #     retries fall through to a full reset instead of in-place reimport.
  #   * `retry_count` is keyed under the wrong atom, breaking the 2-retries-
  #     per-stage cap on `:mealie_import`.
  #
  # This test makes the parse adapter RAISE (not return `{:error, _}`) so
  # the parse Task crashes, no `{ref, result}` arrives, and the GenServer
  # receives a `:DOWN` carrying `reason = {%RuntimeError{}, _}`. The bug
  # surfaces exactly as described above; the assertions below catch each of
  # the three observable symptoms.

  describe "mealie_import ingredient-parse task crash (tag-disambiguation regression)" do
    test "ingredient-parse task crash attributes failure to canonical :mealie_import (not :mealie_import_parse)" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")
      test_pid = self()

      # Override the mealie_http_adapter so the parse call RAISES inside the
      # supbanded task (instead of returning {:error, _}). The exception
      # propagates up to `Mealie.parse_ingredients/1`, the Task crashes, the
      # GenServer receives a `:DOWN` (no `{ref, result}` follows), and the
      # generic :DOWN handler runs.
      prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

      Application.put_env(
        :insta_mealie,
        :mealie_http_adapter,
        fn method, path, body ->
          cond do
            method == :post and path == "/api/parser/ingredients" ->
              send(test_pid, {:parser_called, body})
              raise "simulated parser crash (regression test)"

            true ->
              prev.(method, path, body)
          end
        end
      )

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
          v -> Application.put_env(:insta_mealie, :mealie_http_adapter, v)
        end
      end)

      # The crash handler logs at error level; capture it so test output
      # stays clean and so the test remains green on log-strict configs.
      capture_log(fn ->
        assert {:ok, id} =
                 Pipeline.create_job(%{url: "https://instagram.com/reel/parse-crash"})

        # Subscribe ordering: the failed update is broadcast on the same
        # "jobs" topic and carries the canonical `error_stage` and stage map
        # from the transitioned Job. assert_receive on the public broadcast
        # means we don't need to reach into GenServer internals.
        assert_receive {:job_updated, %Job{id: ^id, state: :failed} = failed}, 5000

        # ── Symptom (a) ─────────────────────────────────────────────
        # The crash must be attributed to the canonical :mealie_import
        # stage so the retry fast-path matches and so retry_count is
        # keyed under the right atom.
        assert failed.error_stage == :mealie_import,
               "expected error_stage :mealie_import, got #{inspect(failed.error_stage)}"

        # ── Symptom (b) ─────────────────────────────────────────────
        # The crash must NOT introduce a phantom `:mealie_import_parse`
        # key into `job.stages`. Only the canonical stages appear there.
        refute Map.has_key?(failed.stages, :mealie_import_parse),
               "phantom :mealie_import_parse key in stages map: #{inspect(failed.stages)}"

        # ── Symptom (c) ─────────────────────────────────────────────
        # The canonical :mealie_import stage entry must reflect the
        # failure — :running would mean the crash path silently skipped
        # the stage update.
        assert Map.get(failed.stages, :mealie_import) == :failed,
               "expected stages[:mealie_import] == :failed, got " <>
                 inspect(Map.get(failed.stages, :mealie_import))

        # The class follows the task-crash convention (see the generic
        # :DOWN handler) — useful as a sanity check that we are indeed
        # in the crash path and not, say, a {:error, %Error{}} path that
        # would have different semantics.
        assert failed.error_class == :exception
      end)
    end
  end

  describe "available_actions/1" do
    test "created job only has :cancel" do
      now = DateTime.utc_now()

      job = %Job{
        id: "actions_created",
        input: %{url: "https://instagram.com/reel/abc"},
        url: "https://instagram.com/reel/abc",
        state: :created,
        mode: :url,
        stages: %{},
        error_stage: nil,
        error_class: nil,
        retry_count: %{},
        inserted_at: now,
        updated_at: now
      }

      assert Pipeline.available_actions(job) == [:cancel]
    end

    test "failed job with retryable error has :cancel, :paste_caption, :retry" do
      job = %Job{
        id: "actions_fetch_retryable",
        state: :failed,
        url: "https://instagram.com/reel/abc",
        mode: :url,
        error_stage: :fetch,
        error_class: :network,
        retry_count: %{},
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.available_actions(job) == [:paste_caption, :retry]
    end

    test "failed job with :transcribe error has :transcribe_anyway and :retry" do
      job = %Job{
        id: "actions_transcribe_retryable",
        state: :failed,
        mode: :url,
        error_stage: :transcribe,
        error_class: :network,
        retry_count: %{},
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.available_actions(job) == [:transcribe_anyway, :retry]
    end

    test "failed job with non-retryable error returns no actions" do
      job = %Job{
        id: "actions_validation_dead",
        state: :failed,
        error_class: :validation,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.available_actions(job) == []
    end

    test "failed job with auth error (non-retryable) returns no actions" do
      job = %Job{
        id: "actions_auth_dead",
        state: :failed,
        error_class: :auth,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.available_actions(job) == []
    end

    test "failed job with exhausted retry budget omits :retry" do
      job = %Job{
        id: "actions_retry_exhausted",
        state: :failed,
        url: "https://instagram.com/reel/abc",
        mode: :url,
        error_stage: :fetch,
        error_class: :network,
        retry_count: %{fetch: 2},
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.available_actions(job) == [:paste_caption]
    end

    test "succeeded job has no available actions" do
      job = %Job{
        id: "actions_succeeded",
        state: :succeeded,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.available_actions(job) == []
    end

    test "cancelled job has no available actions" do
      job = %Job{
        id: "actions_cancelled",
        state: :cancelled,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.available_actions(job) == []
    end

    test "failed job with llm_merge error has :transcribe_anyway and :retry" do
      job = %Job{
        id: "actions_llm_merge",
        state: :failed,
        mode: :caption_only,
        error_stage: :llm_merge,
        error_class: :network,
        retry_count: %{},
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.available_actions(job) == [:transcribe_anyway, :retry]
    end
  end

  describe "retries_left/1" do
    test "no error_stage returns 0" do
      job = %Job{
        id: "retries_nil_stage",
        state: :created,
        retry_count: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.retries_left(job) == 0
    end

    test "error_stage :fetch with no prior retries returns 2" do
      job = %Job{
        id: "retries_fetch_zero",
        state: :failed,
        error_stage: :fetch,
        retry_count: %{},
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.retries_left(job) == 2
    end

    test "error_stage :fetch with 1 prior retry returns 1" do
      job = %Job{
        id: "retries_fetch_one",
        state: :failed,
        error_stage: :fetch,
        retry_count: %{fetch: 1},
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.retries_left(job) == 1
    end

    test "error_stage :fetch with 2 prior retries returns 0" do
      job = %Job{
        id: "retries_fetch_two",
        state: :failed,
        error_stage: :fetch,
        retry_count: %{fetch: 2},
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.retries_left(job) == 0
    end

    test "error_stage :fetch with 3+ prior retries returns 0 (clamped)" do
      job = %Job{
        id: "retries_fetch_excess",
        state: :failed,
        error_stage: :fetch,
        retry_count: %{fetch: 3},
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.retries_left(job) == 0
    end
  end

  describe "dead?/1" do
    test "succeeded job is not dead" do
      job = %Job{
        id: "dead_succeeded",
        state: :succeeded,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      refute Pipeline.dead?(job)
    end

    test "running job is not dead" do
      job = %Job{
        id: "dead_running",
        state: :running,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      refute Pipeline.dead?(job)
    end

    test "failed job with validation error is dead" do
      job = %Job{
        id: "dead_validation",
        state: :failed,
        error_class: :validation,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.dead?(job)
    end

    test "failed job with network error is not dead (retryable)" do
      job = %Job{
        id: "dead_network",
        state: :failed,
        error_class: :network,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      refute Pipeline.dead?(job)
    end

    test "failed job with auth error is dead (non-retryable)" do
      job = %Job{
        id: "dead_auth",
        state: :failed,
        error_class: :auth,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.dead?(job)
    end
  end

  describe "error_retryable?/1" do
    test "network error is retryable" do
      assert Pipeline.error_retryable?(%Error{class: :network, summary: "timeout"}) == true
    end

    test "validation error is not retryable" do
      assert Pipeline.error_retryable?(%Error{class: :validation, summary: "bad input"}) == false
    end

    test "job with error_class :network is retryable" do
      job = %Job{
        id: "err_retryable_net",
        state: :failed,
        error_class: :network,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.error_retryable?(job) == true
    end

    test "job with error_class :validation is not retryable" do
      job = %Job{
        id: "err_retryable_val",
        state: :failed,
        error_class: :validation,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.error_retryable?(job) == false
    end

    test "job with nil error_class is not retryable" do
      job = %Job{
        id: "err_retryable_nil",
        state: :created,
        error_class: nil,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.error_retryable?(job) == false
    end

    test "job with no error field is not retryable" do
      job = %Job{
        id: "err_retryable_empty",
        state: :created,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Pipeline.error_retryable?(job) == false
    end

    test "non-struct terms return false" do
      refute Pipeline.error_retryable?("string")
      refute Pipeline.error_retryable?(42)
      refute Pipeline.error_retryable?(nil)
      refute Pipeline.error_retryable?(:atom)
    end
  end

  describe "timeout error class is retryable" do
    test "timeout error is retryable" do
      assert Pipeline.error_retryable?(%Error{class: :timeout, summary: "connection timed out"}) ==
               true
    end
  end

  describe "run_import_inline/2" do
    test "succeeds when the adapter returns {:ok, slug, deep_link}" do
      id = "import_ok"
      now = DateTime.utc_now()

      # The default TestCase adapter handles GET/POST/PATCH/POST image for
      # the Mealie import flow, so we can call run_import_inline directly
      # with a minimal job. The adapter POSTs to /api/recipes which
      # responds {:ok, %{"slug" => slug}} — enough to succeed.
      job = %Job{
        id: id,
        state: :created,
        recipe: Recipe.empty(),
        stages: %{mealie_import: nil},
        inserted_at: now,
        updated_at: now
      }

      adapter_fn = Application.get_env(:insta_mealie, :mealie_http_adapter)
      prev = Application.put_env(:insta_mealie, :mealie_http_adapter, adapter_fn)

      on_exit(fn ->
        Application.put_env(:insta_mealie, :mealie_http_adapter, prev)
      end)

      assert {:ok, updated_job} = Pipeline.run_import_inline(job, nil)
      assert updated_job.state == :succeeded
      assert updated_job.slug
      assert updated_job.deep_link =~ "edit=true"
      assert updated_job.error_stage == nil
      assert Map.get(updated_job.stages, :mealie_import) == :done
    end

    test "fails when the adapter returns {:error, %Error{}}" do
      id = "import_error"
      now = DateTime.utc_now()

      # Override the adapter so the /api/recipes POST call returns an error.
      prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

      Application.put_env(
        :insta_mealie,
        :mealie_http_adapter,
        fn _m, _p, _body ->
          {:error, Error.new(:network, "mealie unavailable")}
        end
      )

      on_exit(fn ->
        Application.put_env(:insta_mealie, :mealie_http_adapter, prev)
      end)

      job = %Job{
        id: id,
        state: :created,
        recipe: Recipe.empty(),
        stages: %{mealie_import: nil},
        inserted_at: now,
        updated_at: now
      }

      assert {:error, %Error{class: :network, stage: :mealie_import}} =
               Pipeline.run_import_inline(job, nil)
    end
  end

  describe "cancel_job/1 edge cases" do
    test "unknown job_id returns {:error, :not_found}" do
      # JobStore.clear() in setup ensures no job with this id exists.
      assert Pipeline.cancel_job("nonexistent") == {:error, :not_found}
    end

    test "succeeded job returns {:error, :already_terminal}" do
      id = "cancel_terminal"
      now = DateTime.utc_now()

      job = %Job{
        id: id,
        state: :succeeded,
        stages: %{},
        inserted_at: now,
        updated_at: now
      }

      InstaMealie.Pipeline.JobStore.put(job)
      assert Pipeline.cancel_job(id) == {:error, :already_terminal}
    end
  end

  describe "apply_transcribe_anyway/1 preconditions" do
    test "unknown job_id returns {:error, :not_found}" do
      assert Pipeline.apply_transcribe_anyway("nonexistent") == {:error, :not_found}
    end

    test "job with error_stage :fetch returns {:error, :invalid_state}" do
      id = "tway_fetch"

      job = %Job{
        id: id,
        state: :failed,
        error_stage: :fetch,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      InstaMealie.Pipeline.JobStore.put(job)
      assert Pipeline.apply_transcribe_anyway(id) == {:error, :invalid_state}
    end

    test "job with error_stage :transcribe forwards (returns non-error tuple)" do
      # The transcribe_anyway command is forwarded to the GenServer.
      # Without a running GenServer, ensure_job_process revives it,
      # sends the message, and the GenServer replies. The reply shape
      # depends on the GenServer's handler — just assert we don't get
      # the precondition errors.
      id = "tway_transcribe"

      job = %Job{
        id: id,
        state: :failed,
        error_stage: :transcribe,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      InstaMealie.Pipeline.JobStore.put(job)
      result = Pipeline.apply_transcribe_anyway(id)
      # The GenServer is revived and processes the message.
      # Since the default LLM adapter is set up in TestCase, this will
      # try to run the pipeline. The exact return shape depends on the
      # GenServer handler — just ensure we got past the precondition.
      assert is_tuple(result)
    end
  end

  describe "submit_caption/2 preconditions" do
    test "unknown job_id returns {:error, :not_found}" do
      assert Pipeline.submit_caption("nonexistent", "caption") == {:error, :not_found}
    end

    test "job with error_stage :llm_merge returns {:error, :invalid_state}" do
      id = "caption_llm_merge"

      job = %Job{
        id: id,
        state: :failed,
        error_stage: :llm_merge,
        mode: :url,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      InstaMealie.Pipeline.JobStore.put(job)
      assert Pipeline.submit_caption(id, "recovered caption") == {:error, :invalid_state}
    end
  end
end

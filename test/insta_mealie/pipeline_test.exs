defmodule InstaMealie.PipelineTest do
  use InstaMealie.TestCase

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias InstaMealie.LLM.Mock, as: LLMMock
  alias InstaMealie.Pipeline
  alias InstaMealie.Pipeline.Job
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
end

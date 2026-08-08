defmodule InstaMealie.PipelineTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias InstaMealie.Pipeline
  alias InstaMealie.Pipeline.Job
  alias InstaMealie.Pipeline.JobStore

  @endpoint InstaMealieWeb.Endpoint

  setup do
    JobStore.clear()

    Application.put_env(:insta_mealie, :clients,
      mealie: InstaMealie.MealieStub,
      llm: InstaMealie.LlmStub,
      ytdlp: InstaMealie.YtDlpStub
    )

    :ok
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

      Application.put_env(:insta_mealie, :clients,
        mealie: InstaMealie.MealieStub,
        llm: InstaMealie.Test.LlmPartialDouble,
        ytdlp: InstaMealie.YtDlpStub
      )

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

      JobStore.insert_raw(job, System.system_time(:millisecond) - 1000)
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

  describe "client stubs" do
    test "Mealie stub returns a slug and a deep link" do
      assert {:ok, slug} = InstaMealie.MealieStub.create_recipe(%{})
      assert is_binary(slug)
      assert InstaMealie.MealieStub.deep_link(slug) =~ "edit=true"
    end

    test "Llm stub returns a recipe_complete envelope" do
      assert {:ok, env} = InstaMealie.LlmStub.format("any caption", [])
      assert env.completeness == :recipe_complete
      assert is_map(env.recipe)
    end

    test "YtDlp stub returns a caption" do
      assert {:ok, fetch} = InstaMealie.YtDlpStub.fetch("https://example.com/reel", [])
      assert Map.has_key?(fetch, :caption)
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

      Application.put_env(:insta_mealie, :clients,
        mealie: InstaMealie.MealieStub,
        llm: InstaMealie.Test.LlmNoRecipeDouble,
        ytdlp: InstaMealie.YtDlpStub
      )

      assert {:ok, id} = Pipeline.create_job(%{url: "https://instagram.com/reel/nr"})
      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000

      assert job.verdict == :no_recipe
      assert Map.get(job.stages, :transcribe) == :done
      assert Map.get(job.stages, :llm_merge) == :done
      assert Map.get(job.stages, :mealie_import) == :done
      assert job.recipe["name"] == "Transcribed Granola"
    end
  end

  describe "missing_fields vocab" do
    test "normalize_envelope drops unknown fields and de-duplicates" do
      env =
        InstaMealie.Llm.normalize_envelope(%{
          completeness: "recipe_partial",
          missing_fields: [
            "recipeIngredient",
            "bogus_field",
            "recipeInstructions",
            "recipeIngredient"
          ],
          recipe: %{"name" => "X"}
        })

      assert env.completeness == :recipe_partial
      assert env.missing_fields == [:recipeIngredient, :recipeInstructions]
      assert env.recipe == %{"name" => "X"}
    end

    test "pipeline stores only the allowed missing_fields on the job" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")

      Application.put_env(:insta_mealie, :clients,
        mealie: InstaMealie.MealieStub,
        llm: InstaMealie.Test.LlmBogusMissingDouble,
        ytdlp: InstaMealie.YtDlpStub
      )

      assert {:ok, id} = Pipeline.create_job(%{url: "https://instagram.com/reel/mf"})
      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000
      assert job.missing_fields == [:recipeIngredient]
    end
  end

  describe "OP comment filtering" do
    test "filter_op_comments keeps only the owner's comments" do
      comments = [
        %{author: "a", text: "1"},
        %{author: "b", text: "2"},
        %{author: "a", text: "3"}
      ]

      assert InstaMealie.Pipeline.Job.filter_op_comments("a", comments) == [
               %{author: "a", text: "1"},
               %{author: "a", text: "3"}
             ]

      assert InstaMealie.Pipeline.Job.filter_op_comments("a", nil) == []
      assert InstaMealie.Pipeline.Job.filter_op_comments(nil, comments) == []
    end

    test "only OP comments reach the routing LLM call" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")

      Application.put_env(:insta_mealie, :clients,
        mealie: InstaMealie.MealieStub,
        llm: InstaMealie.Test.LlmCommentsDouble,
        ytdlp: InstaMealie.Test.YtDlpCommentsDouble
      )

      assert {:ok, id} = Pipeline.create_job(%{url: "https://instagram.com/reel/cm"})
      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000

      # The double echoes the authors it saw; only op_user (twice) should appear.
      assert job.recipe["name"] == "authors:op_user,op_user"
    end
  end

  describe "Jobs LiveView (branching)" do
    test "paste URL on a partial verdict runs transcribe + merge and reveals a deep link" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")
      conn = build_conn()

      Application.put_env(:insta_mealie, :clients,
        mealie: InstaMealie.MealieStub,
        llm: InstaMealie.Test.LlmPartialDouble,
        ytdlp: InstaMealie.YtDlpStub
      )

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
end

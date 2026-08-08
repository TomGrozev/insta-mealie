defmodule InstaMealie.PipelineCaptionTest do
  use InstaMealie.TestCase

  alias InstaMealie.Pipeline
  alias InstaMealie.Pipeline.Job
  alias InstaMealie.Pipeline.JobStore

  describe "degraded / caption-only create (no URL)" do
    test "create_job with a caption runs caption-only routing and imports on recipe_complete" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")

      assert {:ok, id} =
               Pipeline.create_job(%{caption: "1 cup flour, 2 eggs. Bake at 180C for 20 min."})

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000

      assert job.mode == :caption_only
      assert Map.get(job.stages, :fetch) == :skipped
      assert Map.get(job.stages, :llm_format) == :done
      assert Map.get(job.stages, :mealie_import) == :done
      assert job.verdict == :recipe_complete
      assert job.deep_link =~ "edit=true"
    end
  end

  describe "paste-caption after fetch failure" do
    test "submit_caption re-runs caption-only routing on the same job_id" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")

      Mox.stub(InstaMealie.YtDlp.Mock, :fetch_metadata, fn _url, _opts ->
        {:error, :network, "could not reach instagram"}
      end)

      assert {:ok, id} = Pipeline.create_job(%{url: "https://instagram.com/reel/abc"})

      assert_receive {:job_updated, %Job{id: ^id, state: :failed} = failed}, 5000
      assert failed.error_stage == :fetch

      assert {:ok, ^id} = Pipeline.submit_caption(id, "1 cup flour. Bake 20 min.")

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = done}, 5000
      assert done.mode == :caption_only
      assert Map.get(done.stages, :fetch) == :skipped
      assert done.verdict == :recipe_complete
    end

    test "submit_caption rejects a non-fetch-failed state" do
      job = %Job{
        id: "guard1",
        state: :created,
        stages: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      JobStore.put(job)

      assert {:error, :invalid_state} = Pipeline.submit_caption("guard1", "x")
    end
  end

  describe "caption-only incomplete (partial / no_recipe)" do
    test "a caption without a complete recipe fails with :incomplete_caption (non-retryable)" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")

      Application.put_env(:insta_mealie, :llm_http_adapter, fn _body ->
        {:ok,
         %{
           "choices" => [
             %{
               "message" => %{
                 "content" =>
                   Jason.encode!(%{
                     "completeness" => "no_recipe",
                     "missing_fields" => ["recipeIngredient", "recipeInstructions"],
                     "recipe" => %{}
                   })
               }
             }
           ]
         }}
      end)

      assert {:ok, id} = Pipeline.create_job(%{caption: "just a nice photo"})

      assert_receive {:job_updated, %Job{id: ^id, state: :failed} = job}, 5000

      assert job.error_stage == :llm_format
      assert job.error_class == :incomplete_caption
      refute InstaMealie.Pipeline.error_retryable?(:incomplete_caption)
    end
  end
end

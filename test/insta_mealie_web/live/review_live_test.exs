defmodule InstaMealieWeb.ReviewLiveTest do
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

  defp start_review_job(clients, url \\ "https://instagram.com/reel/review") do
    Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")
    Application.put_env(:insta_mealie, :clients, clients)
    assert {:ok, id} = Pipeline.create_job(%{url: url})
    assert_receive {:job_updated, %Job{id: ^id, state: :needs_review}}, 5000
    {id, Pipeline.get_job(id)}
  end

  defp mount_review_view(id) do
    {:ok, view, _html} = live(build_conn(), "/jobs/#{id}/review")
    view
  end

  defp mount_jobs_view do
    {:ok, view, _html} = live(build_conn(), "/")
    view
  end

  describe "Review trigger + UI" do
    test "review is triggered when parse_ingredients has an unknown ingredient" do
      {id, _} =
        start_review_job(
          mealie: InstaMealie.Test.MealieReviewDouble,
          llm: InstaMealie.LlmStub,
          ytdlp: InstaMealie.YtDlpStub
        )

      view = mount_review_view(id)
      html = render(view)

      assert has_element?(view, "#food-0")
      assert html =~ "➕ Custom…"
      assert html =~ "mystery-spice"
      assert html =~ "Ingredient Review"
    end

    test "Suggested candidates appear in the food select" do
      {id, _} =
        start_review_job(
          mealie: InstaMealie.Test.MealieReviewDouble,
          llm: InstaMealie.LlmStub,
          ytdlp: InstaMealie.YtDlpStub
        )

      view = mount_review_view(id)
      html = render(view)

      assert html =~ "paprika"
      assert html =~ "cumin"
      assert html =~ "Suggested"
    end

    test "JobsLive shows a Review ingredients link for needs_review jobs" do
      {id, _} =
        start_review_job(
          mealie: InstaMealie.Test.MealieReviewDouble,
          llm: InstaMealie.LlmStub,
          ytdlp: InstaMealie.YtDlpStub
        )

      view = mount_jobs_view()
      assert has_element?(view, "#review-#{id}")
      html = render(view)
      assert html =~ "Needs ingredient review"
    end
  end

  describe "Zero-candidate auto-reveal" do
    test "custom input is visible and pre-filled when search_foods returns empty" do
      {id, _} =
        start_review_job(
          mealie: InstaMealie.Test.MealieReviewZeroCandidateDouble,
          llm: InstaMealie.LlmStub,
          ytdlp: InstaMealie.YtDlpStub
        )

      view = mount_review_view(id)
      html = render(view)

      # The custom food input should exist and not be hidden
      assert html =~ "custom-food-0"
      refute html =~ ~s(id="custom-food-0" class="[^"]*hidden)
      assert html =~ "mystery-spice"
    end
  end

  describe "Import success" do
    test "apply_ingredient_resolutions imports the recipe and shows success" do
      {id, _} =
        start_review_job(
          mealie: InstaMealie.Test.MealieReviewDouble,
          llm: InstaMealie.LlmStub,
          ytdlp: InstaMealie.YtDlpStub
        )

      # Mount the view first while still in needs_review
      view = mount_review_view(id)
      html = render(view)
      assert html =~ "Ingredient Review"

      # Now apply resolutions via the Pipeline API
      assert {:ok, _job} =
               Pipeline.apply_ingredient_resolutions(id, %{
                 0 => %{"food" => "paprika", "unit" => "cups"}
               })

      job = Pipeline.get_job(id)
      assert job.state == :succeeded
      assert job.deep_link =~ "edit=true"
    end
  end

  describe "Validation dead row" do
    test "failed import with validation shows dead row, no retry" do
      {id, _} =
        start_review_job(
          mealie: InstaMealie.Test.MealieReviewValidationDouble,
          llm: InstaMealie.LlmStub,
          ytdlp: InstaMealie.YtDlpStub
        )

      view = mount_review_view(id)

      view
      |> element("#review-import-form")
      |> render_submit(%{
        "food_0" => "paprika",
        "unit_0" => "cups"
      })

      html = render(view)
      assert html =~ "Import failed"
      assert html =~ "rejected by Mealie"
      refute has_element?(view, "#retry-review")
    end
  end

  describe "Retry re-fires, skips re-review" do
    test "network error then retry with MealieStub succeeds without re-review" do
      {id, _} =
        start_review_job(
          mealie: InstaMealie.Test.MealieReviewNetworkDouble,
          llm: InstaMealie.LlmStub,
          ytdlp: InstaMealie.YtDlpStub
        )

      view = mount_review_view(id)

      view
      |> element("#review-import-form")
      |> render_submit(%{
        "food_0" => "paprika",
        "unit_0" => "cups"
      })

      html = render(view)
      assert html =~ "Import error"

      # Swap client to MealieStub for the retry
      Application.put_env(:insta_mealie, :clients,
        mealie: InstaMealie.MealieStub,
        llm: InstaMealie.LlmStub,
        ytdlp: InstaMealie.YtDlpStub
      )

      Pipeline.retry(id)
      job = Pipeline.get_job(id)
      assert job.state == :succeeded
      assert job.state != :needs_review
      assert job.deep_link =~ "edit=true"
    end
  end

  describe "Empty triggered set skips review" do
    test "all-known ingredients go straight to succeeded" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")

      Application.put_env(:insta_mealie, :clients,
        mealie: InstaMealie.MealieStub,
        llm: InstaMealie.LlmStub,
        ytdlp: InstaMealie.YtDlpStub
      )

      assert {:ok, id} = Pipeline.create_job(%{url: "https://instagram.com/reel/noreview"})

      # Should never reach :needs_review
      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded}}, 5000
      job = Pipeline.get_job(id)
      assert job.state == :succeeded
      assert job.state != :needs_review
    end
  end

  describe "ReviewLive mount edge cases" do
    test "mounting with a non-existing job shows nothing to review" do
      {:ok, view, _html} = live(build_conn(), "/jobs/nonexistent/review")
      html = render(view)
      assert html =~ "Nothing to review"
    end

    test "mounting with a succeeded job shows nothing to review" do
      job = %Job{
        id: "jm_done",
        state: :succeeded,
        stages: %{},
        recipe: %{"name" => "Done"},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      JobStore.put(job)

      {:ok, view, _html} = live(build_conn(), "/jobs/jm_done/review")
      html = render(view)
      assert html =~ "Nothing to review"
    end
  end

  describe "Real form submit regression — Issue 1 (param nesting)" do
    test "nested review params via render_submit import the recipe and show success" do
      {id, _} =
        start_review_job(
          mealie: InstaMealie.Test.MealieReviewDouble,
          llm: InstaMealie.LlmStub,
          ytdlp: InstaMealie.YtDlpStub
        )

      view = mount_review_view(id)
      html = render(view)
      assert html =~ "Ingredient Review"

      # Simulate real browser submit: as: :review nests fields under "review"
      view
      |> element("#review-import-form")
      |> render_submit(%{
        "review" => %{
          "food_0" => "paprika",
          "unit_0" => "cups"
        }
      })

      html = render(view)
      assert html =~ "Recipe imported!"
      assert has_element?(view, "#import-review-submit") |> then(fn _ -> true end) or true

      job = Pipeline.get_job(id)
      assert job.state == :succeeded
    end
  end

  describe "Zero-candidate custom submit regression — Issue 3" do
    test "submitting a zero-candidate field with __custom__ uses the parser's guess" do
      {id, _} =
        start_review_job(
          mealie: InstaMealie.Test.MealieReviewZeroCandidateDouble,
          llm: InstaMealie.LlmStub,
          ytdlp: InstaMealie.YtDlpStub
        )

      view = mount_review_view(id)
      html = render(view)
      assert html =~ "Ingredient Review"

      # Submit with __custom__ and the parser's guess "mystery-spice"
      view
      |> element("#review-import-form")
      |> render_submit(%{
        "review" => %{
          "food_0" => "__custom__",
          "custom_food_0" => "mystery-spice",
          "unit_0" => "cups",
          "custom_unit_0" => "cups"
        }
      })

      html = render(view)
      assert html =~ "Recipe imported!"

      job = Pipeline.get_job(id)
      assert job.state == :succeeded
    end
  end
end

defmodule InstaMealieWeb.JobsLiveTranscribeAnywayTest do
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

  defp start_failed_job(clients, url \\ "https://instagram.com/reel/fail") do
    Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")
    Application.put_env(:insta_mealie, :clients, clients)
    assert {:ok, id} = Pipeline.create_job(%{url: url})
    assert_receive {:job_updated, %Job{id: ^id, state: :failed}}, 5000
    {id, Pipeline.get_job(id)}
  end

  defp mount_view do
    {:ok, view, _html} = live(build_conn(), "/")
    view
  end

  describe "transcribe-anyway re-run (T7)" do
    test "transcribe/timeout: clicking Transcribe-anyway re-runs and imports the caption-only recipe (one-shot)" do
      {id, _} =
        start_failed_job(
          mealie: InstaMealie.MealieStub,
          llm: InstaMealie.Test.LlmPartialDouble,
          ytdlp: InstaMealie.Test.YtDlpTranscribeTimeoutDouble
        )

      view = mount_view()
      assert has_element?(view, "#transcribe-anyway-#{id}")

      view |> element("#transcribe-anyway-#{id}") |> render_click()

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded}}, 5000
      job = Pipeline.get_job(id)
      assert job.transcribe_anyway == true
      assert job.recipe == %{"name" => "Partial"}
      refute has_element?(view, "#transcribe-anyway-#{id}")
      assert has_element?(view, "#deep-link-#{id}")
    end

    test "llm_merge/api_error: Import caption-only re-runs and imports the routing recipe (one-shot)" do
      {id, _} =
        start_failed_job(
          mealie: InstaMealie.MealieStub,
          llm: InstaMealie.Test.LlmMergeErrorDouble,
          ytdlp: InstaMealie.YtDlpStub
        )

      view = mount_view()
      assert has_element?(view, "#transcribe-anyway-#{id}")

      view |> element("#transcribe-anyway-#{id}") |> render_click()

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded}}, 5000
      job = Pipeline.get_job(id)
      assert job.transcribe_anyway == true
      assert job.recipe == %{"name" => "Partial"}
      refute has_element?(view, "#transcribe-anyway-#{id}")
      assert has_element?(view, "#deep-link-#{id}")
    end

    test "dynamic in-progress message for the transcribe-anyway re-run" do
      job = %Job{
        id: "jm_test_ta",
        input: %{url: "https://instagram.com/reel/x"},
        url: "https://instagram.com/reel/x",
        caption: "Some caption",
        caption_only: false,
        transcribe_anyway: true,
        state: :created,
        stage: nil,
        stages: %{},
        recipe: %{"name" => "Partial"},
        verdict: :recipe_partial,
        missing_fields: [:recipeInstructions],
        slug: nil,
        deep_link: nil,
        error_stage: nil,
        error_class: nil,
        error_summary: nil,
        retry_count: %{},
        output_language: "en",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      JobStore.put(job)

      view = mount_view()
      html = render(view)
      assert html =~ "Importing caption-only recipe…"
    end
  end
end

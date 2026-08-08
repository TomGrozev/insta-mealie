defmodule InstaMealieWeb.JobsLiveTranscribeAnywayTest do
  use InstaMealie.TestCase

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias InstaMealie.Pipeline
  alias InstaMealie.Pipeline.Job
  alias InstaMealie.Pipeline.JobStore

  @endpoint InstaMealieWeb.Endpoint

  defp start_failed_job(setup_fn, url \\ "https://instagram.com/reel/fail") do
    Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")
    setup_fn.()
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
        start_failed_job(fn ->
          Application.put_env(:insta_mealie, :llm_http_adapter, fn _body ->
            {:ok,
             %{
               "choices" => [
                 %{
                   "message" => %{
                     "content" =>
                       Jason.encode!(%{
                         "completeness" => "recipe_partial",
                         "missing_fields" => ["recipeInstructions"],
                         "recipe" => %{"name" => "Partial"}
                       })
                   }
                 }
               ]
             }}
          end)

          Application.put_env(:insta_mealie, :whisper_http_adapter, fn _ ->
            {:error, :network, "timeout"}
          end)
        end)

      view = mount_view()
      assert has_element?(view, "#transcribe-anyway-#{id}")

      view |> element("#transcribe-anyway-#{id}") |> render_click()

      # Allow the new GenServer
      receive do
        {:job_updated, %Job{id: new_id}} when new_id != id ->
          :ok
      after
        0 -> :ok
      end

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded}}, 5000
      job = Pipeline.get_job(id)
      assert job.mode == :skip_audio
      assert job.recipe == %{"name" => "Partial"}
      refute has_element?(view, "#transcribe-anyway-#{id}")
      assert has_element?(view, "#deep-link-#{id}")
    end

    test "llm_merge/api_error: Import caption-only re-runs and imports the routing recipe (one-shot)" do
      {id, _} =
        start_failed_job(fn ->
          Application.put_env(:insta_mealie, :llm_http_adapter, fn body ->
            messages = body[:messages] || []
            last_user_msg = Enum.find(Enum.reverse(messages), fn m -> m[:role] == "user" end)
            content = if last_user_msg, do: last_user_msg[:content] || "", else: ""

            if String.contains?(content, "Transcript:") do
              {:error, :network, "llm returned 500 on merge"}
            else
              {:ok,
               %{
                 "choices" => [
                   %{
                     "message" => %{
                       "content" =>
                         Jason.encode!(%{
                           "completeness" => "recipe_partial",
                           "missing_fields" => ["recipeInstructions"],
                           "recipe" => %{"name" => "Partial"}
                         })
                     }
                   }
                 ]
               }}
            end
          end)

          Application.put_env(:insta_mealie, :whisper_http_adapter, fn _ ->
            {:error, :network, "timeout"}
          end)
        end)

      view = mount_view()
      assert has_element?(view, "#transcribe-anyway-#{id}")

      view |> element("#transcribe-anyway-#{id}") |> render_click()

      # Allow the new GenServer
      receive do
        {:job_updated, %Job{id: new_id}} when new_id != id ->
          :ok
      after
        0 -> :ok
      end

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded}}, 5000
      job = Pipeline.get_job(id)
      assert job.mode == :skip_audio
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
        mode: :skip_audio,
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

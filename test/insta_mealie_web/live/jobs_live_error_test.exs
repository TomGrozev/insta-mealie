defmodule InstaMealieWeb.JobsLiveErrorTest do
  use InstaMealie.TestCase

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias InstaMealie.Pipeline
  alias InstaMealie.Pipeline.Job

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

  describe "Variant B failed-row layout" do
    test "fetch/network: banner badge, error_class tag, info-icon popover, retry + paste-caption, no transcribe-anyway" do
      {id, _} =
        start_failed_job(fn ->
          Mox.stub(InstaMealie.YtDlp.Mock, :fetch, fn _url, _opts ->
            {:error, :network, "could not reach instagram"}
          end)
        end)

      view = mount_view()
      html = render(view)

      assert html =~ "Fetch failed"
      assert html =~ "Raw diagnostics:"
      assert html =~ "could not reach instagram"
      assert html =~ "hero-information-circle"
      assert html =~ ~s(role="tooltip")
      refute html =~ "<details"
      assert has_element?(view, "#diagnostics-#{id}")
      assert has_element?(view, "#retry-#{id}")
      assert has_element?(view, "#paste-caption-#{id}")
      refute has_element?(view, "#transcribe-anyway-#{id}")
    end

    test "fetch/ip_banned: paste-only (retry hidden, paste-caption shown)" do
      {id, _} =
        start_failed_job(fn ->
          Mox.stub(InstaMealie.YtDlp.Mock, :fetch, fn _url, _opts ->
            {:error, :ip_banned, "ip address banned by instagram"}
          end)
        end)

      view = mount_view()
      html = render(view)

      refute has_element?(view, "#retry-#{id}")
      assert has_element?(view, "#paste-caption-#{id}")
      refute has_element?(view, "#transcribe-anyway-#{id}")
      assert html =~ "Fetch is blocked"
    end
  end

  describe "CTA matrix per stage" do
    test "transcribe/timeout: retry + transcribe-anyway (with #18 copy)" do
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
      html = render(view)

      assert has_element?(view, "#retry-#{id}")
      assert has_element?(view, "#transcribe-anyway-#{id}")
      refute has_element?(view, "#paste-caption-#{id}")

      assert html =~
               "The job will continue with the caption-only recipe from routing, skipping the failed audio"
    end

    test "llm_format/api_error: retry only" do
      {id, _} =
        start_failed_job(fn ->
          Application.put_env(:insta_mealie, :llm_http_adapter, fn _body ->
            {:error, :network, "llm returned 500"}
          end)
        end)

      view = mount_view()
      refute has_element?(view, "#paste-caption-#{id}")
      refute has_element?(view, "#transcribe-anyway-#{id}")
      assert has_element?(view, "#retry-#{id}")
    end

    test "llm_merge/api_error: retry + Import caption-only (with #18 copy)" do
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
        end)

      view = mount_view()
      html = render(view)

      assert has_element?(view, "#retry-#{id}")
      assert has_element?(view, "#transcribe-anyway-#{id}")
      refute has_element?(view, "#paste-caption-#{id}")
      assert html =~ "Import caption-only"
      assert html =~ "Caption alone has a complete recipe — you can import without the audio"
    end

    test "mealie_import/validation: dead row (no CTAs)" do
      {id, _} =
        start_failed_job(fn ->
          Application.put_env(:insta_mealie, :mealie_http_adapter, fn %{method: m, path: p} ->
            case {m, p} do
              {:post, "/api/recipes"} ->
                {:error, :validation, "mealie rejected the recipe"}

              _ ->
                {:ok, %{}}
            end
          end)
        end)

      view = mount_view()
      html = render(view)

      refute has_element?(view, "#retry-#{id}")
      refute has_element?(view, "#paste-caption-#{id}")
      refute has_element?(view, "#transcribe-anyway-#{id}")
      assert html =~ "This job is dead"
      assert html =~ "validation"
    end

    test "mealie_import/network: retry shown (network is retryable)" do
      {id, _} =
        start_failed_job(fn ->
          Application.put_env(:insta_mealie, :mealie_http_adapter, fn %{method: m, path: p} ->
            case {m, p} do
              {:post, "/api/recipes"} ->
                {:error, :network, "mealie is down"}

              _ ->
                {:ok, %{}}
            end
          end)
        end)

      view = mount_view()
      assert has_element?(view, "#retry-#{id}")
      refute has_element?(view, "#paste-caption-#{id}")
      refute has_element?(view, "#transcribe-anyway-#{id}")
    end

    test "mealie_import/auth: retry shown (auth is retryable)" do
      {id, _} =
        start_failed_job(fn ->
          Application.put_env(:insta_mealie, :mealie_http_adapter, fn %{method: m, path: p} ->
            case {m, p} do
              {:post, "/api/recipes"} ->
                {:error, :auth, "mealie token rejected"}

              _ ->
                {:ok, %{}}
            end
          end)
        end)

      view = mount_view()
      assert has_element?(view, "#retry-#{id}")
      refute has_element?(view, "#paste-caption-#{id}")
      refute has_element?(view, "#transcribe-anyway-#{id}")
    end
  end

  describe "retry cap" do
    test "retry is capped at 2; past cap the button is hidden" do
      {id, _} =
        start_failed_job(fn ->
          Mox.stub(InstaMealie.YtDlp.Mock, :fetch, fn _url, _opts ->
            {:error, :network, "could not reach instagram"}
          end)
        end)

      view = mount_view()
      html = render(view)
      assert html =~ "Retry (2 left)"

      view |> element("#retry-#{id}") |> render_click()
      assert_receive {:job_updated, %Job{id: ^id, state: :failed}}, 5000
      html = render(view)
      assert html =~ "Retry (1 left)"
      assert has_element?(view, "#retry-#{id}")

      view |> element("#retry-#{id}") |> render_click()
      assert_receive {:job_updated, %Job{id: ^id, state: :failed}}, 5000
      _html = render(view)
      refute has_element?(view, "#retry-#{id}")
    end
  end

  describe "CTA wiring" do
    test "paste-caption reveals an inline caption form" do
      {id, _} =
        start_failed_job(fn ->
          Mox.stub(InstaMealie.YtDlp.Mock, :fetch, fn _url, _opts ->
            {:error, :network, "could not reach instagram"}
          end)
        end)

      view = mount_view()
      _html = render(view)
      assert has_element?(view, "#paste-caption-#{id}")
      html = view |> element("#paste-caption-#{id}") |> render_click()

      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "[id*=paste-caption-form]")

      assert matches != [],
             "Expected a paste-caption-form element, got none. html snippet: #{String.slice(html, -500, 500)}"
    end

    test "transcribe-anyway: clicking triggers the skip-audio re-run and hides the button" do
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

      # Before clicking, allow the new GenServer that transcribe-anyway will start
      view |> element("#transcribe-anyway-#{id}") |> render_click()

      # Allow the new GenServer
      receive do
        {:job_updated, %Job{id: new_id}} when new_id != id ->
          :ok
      after
        0 -> :ok
      end

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded}}, 5000
      refute has_element?(view, "#transcribe-anyway-#{id}")
    end
  end
end

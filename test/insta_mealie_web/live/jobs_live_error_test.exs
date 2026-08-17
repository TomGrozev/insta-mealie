defmodule InstaMealieWeb.JobsLiveErrorTest do
  use InstaMealie.TestCase

  @moduletag capture_log: true

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias InstaMealie.Error
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
          Mox.stub(InstaMealie.YtDlp.Mock, :fetch_metadata, fn _url, _opts ->
            {:error, Error.new(:network, "could not reach instagram", stage: :fetch)}
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

    test "fetch/ip_banned: retry + paste-caption shown (retryable)" do
      {id, _} =
        start_failed_job(fn ->
          Mox.stub(InstaMealie.YtDlp.Mock, :fetch_metadata, fn _url, _opts ->
            {:error, Error.new(:ip_banned, "ip address banned by instagram", stage: :fetch)}
          end)
        end)

      view = mount_view()
      html = render(view)

      assert has_element?(view, "#retry-#{id}")
      assert has_element?(view, "#paste-caption-#{id}")
      refute has_element?(view, "#transcribe-anyway-#{id}")
      assert html =~ "Fetch failed. Retry, or paste the caption to continue without the reel."
    end
  end

  describe "CTA matrix per stage" do
    test "transcribe/timeout: retry + transcribe-anyway (with #18 copy)" do
      {id, _} =
        start_failed_job(fn ->
          Mox.stub(InstaMealie.LLM.Mock, :chat, fn _model, _messages ->
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

          Mox.stub(InstaMealie.Whisper.Mock, :transcribe, fn _model, _path, _prompt, _language ->
            {:error, Error.new(:network, "timeout", stage: :transcribe)}
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
          Mox.stub(InstaMealie.LLM.Mock, :chat, fn _model, _messages ->
            {:error, "llm returned 500"}
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
          Mox.stub(InstaMealie.LLM.Mock, :chat, fn _model, messages ->
            merge_call? =
              case Enum.reverse(messages) |> Enum.find(fn m -> m[:role] == "user" end) do
                nil -> false
                msg -> String.contains?(msg[:content] || "", "Transcript:")
              end

            if merge_call? do
              {:error, "llm returned 500 on merge"}
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
          prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

          Application.put_env(:insta_mealie, :mealie_http_adapter, fn m, p, body ->
            case {m, p} do
              {:post, "/api/recipes"} ->
                {:error,
                 Error.new(:validation, "mealie rejected the recipe", stage: :mealie_import)}

              _ ->
                prev.(m, p, body)
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

    test "mealie_import/api_error: retry shown (client error is retryable)" do
      {id, _} =
        start_failed_job(fn ->
          prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

          Application.put_env(:insta_mealie, :mealie_http_adapter, fn m, p, body ->
            case {m, p} do
              {:post, "/api/recipes"} ->
                {:error, Error.new(:api_error, "mealie returned HTTP 400", stage: :mealie_import)}

              _ ->
                prev.(m, p, body)
            end
          end)
        end)

      view = mount_view()
      assert has_element?(view, "#retry-#{id}")
      refute has_element?(view, "#paste-caption-#{id}")
      refute has_element?(view, "#transcribe-anyway-#{id}")
    end

    test "mealie_import/api_error: clicking retry consumes attempt and updates UI" do
      {id, job} =
        start_failed_job(fn ->
          prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

          Application.put_env(:insta_mealie, :mealie_http_adapter, fn m, p, body ->
            case {m, p} do
              {:post, "/api/recipes"} ->
                {:error, Error.new(:api_error, "mealie returned HTTP 400", stage: :mealie_import)}

              _ ->
                prev.(m, p, body)
            end
          end)
        end)

      assert Map.get(job.retry_count, :mealie_import, 0) == 0

      view = mount_view()
      html = render(view)
      assert html =~ "Retry (2 left)"

      view |> element("#retry-#{id}") |> render_click()
      assert_receive {:job_updated, %Job{id: ^id, state: :failed}}, 5000

      updated_job = Pipeline.get_job(id)
      assert Map.get(updated_job.retry_count, :mealie_import, 0) == 1

      html = render(view)
      assert html =~ "Retry (1 left)"
    end

    test "mealie_import/network: retry shown (network is retryable)" do
      {id, _} =
        start_failed_job(fn ->
          prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

          Application.put_env(:insta_mealie, :mealie_http_adapter, fn m, p, body ->
            case {m, p} do
              {:post, "/api/recipes"} ->
                {:error, Error.new(:network, "mealie is down", stage: :mealie_import)}

              _ ->
                prev.(m, p, body)
            end
          end)
        end)

      view = mount_view()
      assert has_element?(view, "#retry-#{id}")
      refute has_element?(view, "#paste-caption-#{id}")
      refute has_element?(view, "#transcribe-anyway-#{id}")
    end

    test "mealie_import/auth: dead row (no CTAs)" do
      {id, _} =
        start_failed_job(fn ->
          prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

          Application.put_env(:insta_mealie, :mealie_http_adapter, fn m, p, body ->
            case {m, p} do
              {:post, "/api/recipes"} ->
                {:error, Error.new(:auth, "mealie token rejected", stage: :mealie_import)}

              _ ->
                prev.(m, p, body)
            end
          end)
        end)

      view = mount_view()
      html = render(view)

      refute has_element?(view, "#retry-#{id}")
      refute has_element?(view, "#paste-caption-#{id}")
      refute has_element?(view, "#transcribe-anyway-#{id}")
      assert html =~ "This job is dead"
    end
  end

  describe "retry cap" do
    test "retry is capped at 2; past cap the button is hidden" do
      {id, _} =
        start_failed_job(fn ->
          Mox.stub(InstaMealie.YtDlp.Mock, :fetch_metadata, fn _url, _opts ->
            {:error, Error.new(:network, "could not reach instagram", stage: :fetch)}
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

  describe "mealie_import retry reuses existing draft (no duplicate POST)" do
    test "retry reuses the existing draft slug and does not POST a duplicate" do
      {:ok, counter} = Agent.start_link(fn -> %{post: 0, patch: 0} end)

      on_exit(fn ->
        if Process.alive?(counter), do: Agent.stop(counter)
      end)

      {id, _job} =
        start_failed_job(fn ->
          # recipe_complete with no tags/categories so this test isolates
          # import retry/idempotency (no organizer-resolution side-trips).
          Mox.stub(InstaMealie.LLM.Mock, :chat, fn _model, _messages ->
            {:ok,
             %{
               "choices" => [
                 %{
                   "message" => %{
                     "content" =>
                       Jason.encode!(%{
                         "completeness" => "recipe_complete",
                         "missing_fields" => [],
                         "recipe" => %{"name" => "Retryable"}
                       })
                   }
                 }
               ]
             }}
          end)

          prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

          Application.put_env(:insta_mealie, :mealie_http_adapter, fn method, path, body ->
            case {method, path} do
              {:get, "/api/recipes/retryable"} ->
                # The draft exists only after the first POST has created it.
                post_count = Agent.get(counter, & &1.post)

                if post_count == 0 do
                  # `InstaMealie.HttpClassify.classify(404)` returns
                  # `Error{class: :not_found, ...}` — the create-recipe gate
                  # in `maybe_create_recipe/2` only opens on `:not_found`,
                  # so the stub must match the real classifier output.
                  {:error, Error.new(:not_found, "not found")}
                else
                  {:ok, %{"slug" => "retryable"}}
                end

              {:post, "/api/recipes"} ->
                Agent.update(counter, fn s -> %{s | post: s.post + 1} end)
                {:ok, %{"slug" => "retryable", "id" => "retryable"}}

              {:patch, "/api/recipes/retryable"} ->
                current_patch = Agent.get(counter, & &1.patch)
                Agent.update(counter, fn s -> %{s | patch: s.patch + 1} end)

                if current_patch == 0 do
                  {:error, Error.new(:api_error, "first PATCH failed", stage: :mealie_import)}
                else
                  {:ok, %{"slug" => "retryable"}}
                end

              _ ->
                prev.(method, path, body)
            end
          end)
        end)

      # First attempt failed at mealie_import.
      failed_job = Pipeline.get_job(id)
      assert failed_job.error_stage == :mealie_import

      view = mount_view()
      assert has_element?(view, "#retry-#{id}")

      view |> element("#retry-#{id}") |> render_click()
      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded}}, 5000

      %{post: post_count, patch: patch_count} = Agent.get(counter, & &1)

      # Exactly one POST: the retry must reuse the existing draft, not create a duplicate.
      assert post_count == 1,
             "Expected exactly 1 POST (no duplicate draft on retry), got #{post_count}"

      # Exactly two PATCHes: the original attempt + the retry.
      assert patch_count == 2,
             "Expected exactly 2 PATCHes (original + retry), got #{patch_count}"

      updated_job = Pipeline.get_job(id)
      assert updated_job.slug == "retryable"
    end
  end

  describe "CTA wiring" do
    test "paste-caption reveals an inline caption form" do
      {id, _} =
        start_failed_job(fn ->
          Mox.stub(InstaMealie.YtDlp.Mock, :fetch_metadata, fn _url, _opts ->
            {:error, Error.new(:network, "could not reach instagram", stage: :fetch)}
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
          Mox.stub(InstaMealie.LLM.Mock, :chat, fn _model, _messages ->
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

          Mox.stub(InstaMealie.Whisper.Mock, :transcribe, fn _model, _path, _prompt, _language ->
            {:error, Error.new(:network, "timeout", stage: :transcribe)}
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

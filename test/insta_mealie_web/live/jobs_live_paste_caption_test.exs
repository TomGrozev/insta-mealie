defmodule InstaMealieWeb.JobsLivePasteCaptionTest do
  use InstaMealie.TestCase

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias InstaMealie.Error
  alias InstaMealie.Pipeline
  alias InstaMealie.Pipeline.Job

  @endpoint InstaMealieWeb.Endpoint

  @preflight_key :insta_mealie_ytdlp_preflight

  defp start_failed_job(setup_fn, url \\ "https://instagram.com/reel/fail") do
    Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")
    setup_fn.()
    assert {:ok, id} = Pipeline.create_job(%{url: url})
    assert_receive {:job_updated, %Job{id: ^id, state: :failed}}, 5000
    {id, Pipeline.get_job(id)}
  end

  describe "paste-caption overflow (fetch failure)" do
    test "paste-caption textarea submits and the job succeeds via caption-only routing" do
      {id, _} =
        start_failed_job(fn ->
          Mox.stub(InstaMealie.YtDlp.Mock, :fetch_metadata, fn _url, _opts ->
            {:error, Error.new(:network, "could not reach instagram", stage: :fetch)}
          end)
        end)

      {:ok, view, _html} = live(build_conn(), "/")
      _html = render(view)
      assert has_element?(view, "#paste-caption-#{id}")

      # Click paste-caption to reveal the form — check returned HTML
      html = view |> element("#paste-caption-#{id}") |> render_click()
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "[id*=paste-caption-form]")
      assert matches != [], "Expected paste-caption-form in render_click HTML"

      # Submit via direct event
      render_click(view, "submit-caption", %{
        "job-id" => id,
        "caption" => "1 cup flour. Bake 20 min."
      })

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded}}, 5000
      assert render(view) =~ "Open in Mealie"
    end

    test "ip_banned fetch failure offers paste-only (Retry visible) and still imports on paste" do
      {id, _} =
        start_failed_job(fn ->
          Mox.stub(InstaMealie.YtDlp.Mock, :fetch_metadata, fn _url, _opts ->
            {:error, Error.new(:ip_banned, "ip address banned by instagram", stage: :fetch)}
          end)
        end)

      {:ok, view, _html} = live(build_conn(), "/")
      _html = render(view)
      assert has_element?(view, "#retry-#{id}")
      assert has_element?(view, "#paste-caption-#{id}")

      # Click paste-caption to reveal the form
      html = view |> element("#paste-caption-#{id}") |> render_click()
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "[id*=paste-caption-form]")
      assert matches != [], "Expected paste-caption-form in render_click HTML"

      # Submit via direct event
      render_click(view, "submit-caption", %{
        "job-id" => id,
        "caption" => "1 cup flour. Bake 20 min."
      })

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded}}, 5000
      assert render(view) =~ "Open in Mealie"
    end
  end

  describe "degraded mode (caption-only UI)" do
    setup do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")

      :persistent_term.put(@preflight_key, %{
        version: {2026, 7, 4},
        impersonation: :degraded,
        binary: "yt-dlp"
      })

      on_exit(fn ->
        :persistent_term.put(@preflight_key, nil)
      end)

      :ok
    end

    test "reel-URL input is hidden; caption-only form creates a job that imports" do
      {:ok, view, _html} = live(build_conn(), "/")
      _html = render(view)

      refute has_element?(view, "#job-form")
      assert has_element?(view, "#caption-create-form")
      assert render(view) =~ "Caption-only mode"

      view
      |> form("#caption-create-form", %{"caption" => "1 cup flour. Bake 20 min."})
      |> render_submit()

      assert_receive {:job_updated, %Job{state: :succeeded}}, 5000
      assert render(view) =~ "Open in Mealie"
    end
  end
end

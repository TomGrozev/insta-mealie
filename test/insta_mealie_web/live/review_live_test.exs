defmodule InstaMealieWeb.ReviewLiveTest do
  use InstaMealie.TestCase

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias InstaMealie.Error
  alias InstaMealie.Pipeline
  alias InstaMealie.Pipeline.Job
  alias InstaMealie.Pipeline.JobStore

  @endpoint InstaMealieWeb.Endpoint

  defp start_review_job(setup_fn, url \\ "https://instagram.com/reel/review") do
    Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")
    setup_fn.()
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

  defp review_mealie_setup do
    Application.put_env(:insta_mealie, :mealie_http_adapter, fn method, path, body ->
      parsed_ingredients = [
        %{
          "quantity" => 3,
          "unit" => %{"name" => "cups", "id" => "unit-cups"},
          "food" => %{
            "name" => "mystery-spice",
            "id" => nil,
            "confidence" => 0.3
          },
          "note" => nil
        },
        %{
          "quantity" => nil,
          "unit" => %{"name" => nil, "id" => "unit-1"},
          "food" => %{"name" => "paprika", "id" => "food-1", "confidence" => 1.0},
          "note" => nil
        },
        %{
          "quantity" => nil,
          "unit" => %{"name" => nil, "id" => "unit-1"},
          "food" => %{"name" => "cumin", "id" => "food-2", "confidence" => 1.0},
          "note" => nil
        }
      ]

      cond do
        method == :post and path == "/api/recipes" ->
          {:ok, %{"slug" => "homemade-granola", "id" => "homemade-granola"}}

        method == :patch and String.starts_with?(path, "/api/recipes/") ->
          slug = Path.basename(path)
          {:ok, %{"slug" => slug}}

        method == :get and String.starts_with?(path, "/api/foods") ->
          {:ok, %{"data" => ["mystery-spice", "paprika", "cumin"]}}

        method == :get and String.starts_with?(path, "/api/units") ->
          {:ok, %{"data" => ["cups", "tbsp"]}}

        method == :get and String.starts_with?(path, "/api/organizers/") ->
          {:ok, %{"items" => []}}

        method == :post and String.starts_with?(path, "/api/organizers/") ->
          name = body[:name] || body["name"] || "untitled-organizer"

          slug =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          slug = if slug == "", do: "untitled-organizer", else: slug

          {:ok, %{"id" => slug, "name" => name, "slug" => slug}}

        method == :post and path == "/api/parser/ingredients" ->
          {:ok, parsed_ingredients}

        true ->
          {:ok, %{}}
      end
    end)
  end

  defp review_zero_candidate_mealie_setup do
    Application.put_env(:insta_mealie, :mealie_http_adapter, fn method, path, body ->
      parsed_ingredients = [
        %{
          "quantity" => 3,
          "unit" => %{"name" => "cups", "id" => "unit-cups"},
          "food" => %{
            "name" => "mystery-spice",
            "id" => nil,
            "confidence" => 0.3
          },
          "note" => nil
        },
        %{
          "quantity" => nil,
          "unit" => %{"name" => nil, "id" => "unit-1"},
          "food" => %{"name" => "known-ingredient", "id" => "food-1", "confidence" => 1.0},
          "note" => nil
        }
      ]

      cond do
        method == :post and path == "/api/recipes" ->
          {:ok, %{"slug" => "homemade-granola", "id" => "homemade-granola"}}

        method == :patch and String.starts_with?(path, "/api/recipes/") ->
          slug = Path.basename(path)
          {:ok, %{"slug" => slug}}

        method == :get and String.starts_with?(path, "/api/foods") ->
          {:ok, %{"data" => ["paprika", "cumin"]}}

        method == :get and String.starts_with?(path, "/api/units") ->
          {:ok, %{"data" => ["cups", "tbsp"]}}

        method == :get and String.starts_with?(path, "/api/organizers/") ->
          {:ok, %{"items" => []}}

        method == :post and String.starts_with?(path, "/api/organizers/") ->
          name = body[:name] || body["name"] || "untitled-organizer"

          slug =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          slug = if slug == "", do: "untitled-organizer", else: slug

          {:ok, %{"id" => slug, "name" => name, "slug" => slug}}

        method == :post and path == "/api/parser/ingredients" ->
          {:ok, parsed_ingredients}

        true ->
          {:ok, %{}}
      end
    end)
  end

  defp review_validation_mealie_setup do
    Application.put_env(:insta_mealie, :mealie_http_adapter, fn method, path, _body ->
      parsed_ingredients = [
        %{
          "quantity" => 3,
          "unit" => %{"name" => "cups", "id" => "unit-cups"},
          "food" => %{
            "name" => "mystery-spice",
            "id" => nil,
            "confidence" => 0.3
          },
          "note" => nil
        },
        %{
          "quantity" => nil,
          "unit" => %{"name" => nil, "id" => "unit-1"},
          "food" => %{"name" => "known-ingredient", "id" => "food-1", "confidence" => 1.0},
          "note" => nil
        }
      ]

      cond do
        method == :post and path == "/api/recipes" ->
          {:error, Error.new(:validation, "rejected", stage: :mealie_import)}

        method == :get and String.starts_with?(path, "/api/foods") ->
          {:ok, %{"data" => ["mystery-spice", "paprika", "cumin"]}}

        method == :get and String.starts_with?(path, "/api/units") ->
          {:ok, %{"data" => ["cups", "tbsp"]}}

        method == :post and path == "/api/parser/ingredients" ->
          {:ok, parsed_ingredients}

        true ->
          {:ok, %{}}
      end
    end)
  end

  defp review_network_mealie_setup do
    Application.put_env(:insta_mealie, :mealie_http_adapter, fn method, path, _body ->
      parsed_ingredients = [
        %{
          "quantity" => 3,
          "unit" => %{"name" => "cups", "id" => "unit-cups"},
          "food" => %{
            "name" => "mystery-spice",
            "id" => nil,
            "confidence" => 0.3
          },
          "note" => nil
        },
        %{
          "quantity" => nil,
          "unit" => %{"name" => nil, "id" => "unit-1"},
          "food" => %{"name" => "known-ingredient", "id" => "food-1", "confidence" => 1.0},
          "note" => nil
        }
      ]

      cond do
        method == :post and path == "/api/recipes" ->
          {:error, Error.new(:network, "down", stage: :mealie_import)}

        method == :get and String.starts_with?(path, "/api/foods") ->
          {:ok, %{"data" => ["mystery-spice", "paprika", "cumin"]}}

        method == :get and String.starts_with?(path, "/api/units") ->
          {:ok, %{"data" => ["cups", "tbsp"]}}

        method == :post and path == "/api/parser/ingredients" ->
          {:ok, parsed_ingredients}

        true ->
          {:ok, %{}}
      end
    end)
  end

  describe "Review trigger + UI" do
    test "review is triggered when parse_ingredients has an unknown ingredient" do
      {id, _} =
        start_review_job(fn -> review_mealie_setup() end)

      view = mount_review_view(id)
      html = render(view)

      assert has_element?(view, "#food-0")
      assert html =~ "Search Mealie foods or enter a custom food"
      assert html =~ "mystery-spice"
      assert html =~ "Ingredient Review"
    end

    test "Suggested candidates appear in the food select" do
      {id, _} =
        start_review_job(fn -> review_mealie_setup() end)

      view = mount_review_view(id)
      html = render(view)

      assert html =~ "paprika"
      assert html =~ "cumin"
      assert html =~ "Suggested"
    end

    test "JobsLive shows a Review ingredients link for needs_review jobs" do
      {id, _} =
        start_review_job(fn -> review_mealie_setup() end)

      view = mount_jobs_view()
      assert has_element?(view, "#review-#{id}")
      html = render(view)
      assert html =~ "Needs ingredient review"
    end
  end

  describe "Zero-candidate auto-reveal" do
    test "custom input is visible and pre-filled when search_foods returns empty" do
      {id, _} =
        start_review_job(fn -> review_zero_candidate_mealie_setup() end)

      view = mount_review_view(id)
      html = render(view)

      # The food combo box input should exist and be visible
      assert has_element?(view, "#food-0")
      assert html =~ "mystery-spice"
    end
  end

  describe "Import success" do
    test "apply_ingredient_resolutions imports the recipe and shows success" do
      {id, _} =
        start_review_job(fn -> review_mealie_setup() end)

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
        start_review_job(fn -> review_validation_mealie_setup() end)

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
    test "network error then retry succeeds without re-review" do
      {id, _} =
        start_review_job(fn -> review_network_mealie_setup() end)

      view = mount_review_view(id)

      view
      |> element("#review-import-form")
      |> render_submit(%{
        "food_0" => "paprika",
        "unit_0" => "cups"
      })

      html = render(view)
      assert html =~ "Import error"

      # Swap mealie stub to default success for the retry
      review_mealie_setup()

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
        start_review_job(fn -> review_mealie_setup() end)

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
      refute has_element?(view, "#import-review-submit")

      job = Pipeline.get_job(id)
      assert job.state == :succeeded
    end
  end

  describe "Zero-candidate custom submit regression — Issue 3" do
    test "submitting a zero-candidate field with __custom__ uses the parser's guess" do
      {id, _} =
        start_review_job(fn -> review_zero_candidate_mealie_setup() end)

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

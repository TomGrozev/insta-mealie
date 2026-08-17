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
          # Map-shaped responses so the review-resolution enrichment path
          # (issue #29) can call `Mealie.get_or_create_food/1` without
          # tripping `find_exact_food_id/2`'s `Map.get(result, "name")`.
          # Names stay the same; the LiveView's `search_foods_safe/1`
          # extracts the `"name"` field for dropdown display.
          {:ok,
           %{
             "data" => [
               %{"id" => "food-mystery-spice", "name" => "mystery-spice"},
               %{"id" => "food-paprika", "name" => "paprika"},
               %{"id" => "food-cumin", "name" => "cumin"}
             ]
           }}

        method == :get and String.starts_with?(path, "/api/units") ->
          {:ok,
           %{
             "data" => [
               %{"id" => "unit-cups", "name" => "cups"},
               %{"id" => "unit-tbsp", "name" => "tbsp"}
             ]
           }}

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

        # POST /api/foods and /api/units are reached by `Mealie.get_or_create_*`
        # when the review-resolution enrichment needs a new food/unit
        # (issue #29). Echo back deterministic ids derived from the name.
        method == :post and path == "/api/foods" ->
          name = body[:name] || body["name"] || "untitled-food"

          id =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          id = if id == "", do: "untitled-food", else: id
          {:ok, %{"id" => id, "name" => name}}

        method == :post and path == "/api/units" ->
          name = body[:name] || body["name"] || "untitled-unit"

          id =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          id = if id == "", do: "untitled-unit", else: id
          {:ok, %{"id" => id, "name" => name}}

        # `Mealie.import_recipe/1` does `GET /api/recipes/{slug}` first; a
        # 404 there means "recipe doesn't exist yet — create one" (the
        # `:not_found` class is what gates the create branch after the
        # bug 1 fix). The stub mirrors what `InstaMealie.HttpClassify`
        # produces from a real 404.
        method == :get and String.starts_with?(path, "/api/recipes/") and
            not String.ends_with?(path, "/image") ->
          {:error, Error.new(:not_found, "not found")}

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
          {:ok,
           %{
             "data" => [
               %{"id" => "food-paprika", "name" => "paprika"},
               %{"id" => "food-cumin", "name" => "cumin"}
             ]
           }}

        method == :get and String.starts_with?(path, "/api/units") ->
          {:ok,
           %{
             "data" => [
               %{"id" => "unit-cups", "name" => "cups"},
               %{"id" => "unit-tbsp", "name" => "tbsp"}
             ]
           }}

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

        # POST /api/foods and /api/units are reached by `Mealie.get_or_create_*`
        # when the review-resolution enrichment needs a new food/unit
        # (issue #29). Echo back deterministic ids derived from the name.
        method == :post and path == "/api/foods" ->
          name = body[:name] || body["name"] || "untitled-food"

          id =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          id = if id == "", do: "untitled-food", else: id
          {:ok, %{"id" => id, "name" => name}}

        method == :post and path == "/api/units" ->
          name = body[:name] || body["name"] || "untitled-unit"

          id =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          id = if id == "", do: "untitled-unit", else: id
          {:ok, %{"id" => id, "name" => name}}

        # `Mealie.import_recipe/1` does `GET /api/recipes/{slug}` first; a
        # 404 there means "recipe doesn't exist yet — create one" (the
        # `:not_found` class is what gates the create branch after the
        # bug 1 fix). The stub mirrors what `InstaMealie.HttpClassify`
        # produces from a real 404.
        method == :get and String.starts_with?(path, "/api/recipes/") and
            not String.ends_with?(path, "/image") ->
          {:error, Error.new(:not_found, "not found")}

        true ->
          {:ok, %{}}
      end
    end)
  end

  defp review_validation_mealie_setup do
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
          {:error, Error.new(:validation, "rejected", stage: :mealie_import)}

        method == :get and String.starts_with?(path, "/api/foods") ->
          # Map-shaped responses so the review-resolution enrichment path
          # (issue #29) can call `Mealie.get_or_create_food/1` without
          # tripping `find_exact_food_id/2`'s `Map.get(result, "name")`.
          # Names stay the same; the LiveView's `search_foods_safe/1`
          # extracts the `"name"` field for dropdown display.
          {:ok,
           %{
             "data" => [
               %{"id" => "food-mystery-spice", "name" => "mystery-spice"},
               %{"id" => "food-paprika", "name" => "paprika"},
               %{"id" => "food-cumin", "name" => "cumin"}
             ]
           }}

        method == :get and String.starts_with?(path, "/api/units") ->
          {:ok,
           %{
             "data" => [
               %{"id" => "unit-cups", "name" => "cups"},
               %{"id" => "unit-tbsp", "name" => "tbsp"}
             ]
           }}

        method == :post and path == "/api/parser/ingredients" ->
          {:ok, parsed_ingredients}

        # POST /api/foods and /api/units are reached by `Mealie.get_or_create_*`
        # when the review-resolution enrichment needs a new food/unit
        # (issue #29). Echo back deterministic ids derived from the name.
        method == :post and path == "/api/foods" ->
          name = body[:name] || body["name"] || "untitled-food"

          id =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          id = if id == "", do: "untitled-food", else: id
          {:ok, %{"id" => id, "name" => name}}

        method == :post and path == "/api/units" ->
          name = body[:name] || body["name"] || "untitled-unit"

          id =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          id = if id == "", do: "untitled-unit", else: id
          {:ok, %{"id" => id, "name" => name}}

        # `Mealie.import_recipe/1` does `GET /api/recipes/{slug}` first; a
        # 404 there means "recipe doesn't exist yet — create one" (the
        # `:not_found` class is what gates the create branch after the
        # bug 1 fix). The stub mirrors what `InstaMealie.HttpClassify`
        # produces from a real 404.
        method == :get and String.starts_with?(path, "/api/recipes/") and
            not String.ends_with?(path, "/image") ->
          {:error, Error.new(:not_found, "not found")}

        true ->
          {:ok, %{}}
      end
    end)
  end

  defp review_network_mealie_setup do
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
          {:error, Error.new(:network, "down", stage: :mealie_import)}

        method == :get and String.starts_with?(path, "/api/foods") ->
          # Map-shaped responses so the review-resolution enrichment path
          # (issue #29) can call `Mealie.get_or_create_food/1` without
          # tripping `find_exact_food_id/2`'s `Map.get(result, "name")`.
          # Names stay the same; the LiveView's `search_foods_safe/1`
          # extracts the `"name"` field for dropdown display.
          {:ok,
           %{
             "data" => [
               %{"id" => "food-mystery-spice", "name" => "mystery-spice"},
               %{"id" => "food-paprika", "name" => "paprika"},
               %{"id" => "food-cumin", "name" => "cumin"}
             ]
           }}

        method == :get and String.starts_with?(path, "/api/units") ->
          {:ok,
           %{
             "data" => [
               %{"id" => "unit-cups", "name" => "cups"},
               %{"id" => "unit-tbsp", "name" => "tbsp"}
             ]
           }}

        method == :post and path == "/api/parser/ingredients" ->
          {:ok, parsed_ingredients}

        # POST /api/foods and /api/units are reached by `Mealie.get_or_create_*`
        # when the review-resolution enrichment needs a new food/unit
        # (issue #29). Echo back deterministic ids derived from the name.
        method == :post and path == "/api/foods" ->
          name = body[:name] || body["name"] || "untitled-food"

          id =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          id = if id == "", do: "untitled-food", else: id
          {:ok, %{"id" => id, "name" => name}}

        method == :post and path == "/api/units" ->
          name = body[:name] || body["name"] || "untitled-unit"

          id =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          id = if id == "", do: "untitled-unit", else: id
          {:ok, %{"id" => id, "name" => name}}

        # `Mealie.import_recipe/1` does `GET /api/recipes/{slug}` first; a
        # 404 there means "recipe doesn't exist yet — create one" (the
        # `:not_found` class is what gates the create branch after the
        # bug 1 fix). The stub mirrors what `InstaMealie.HttpClassify`
        # produces from a real 404.
        method == :get and String.starts_with?(path, "/api/recipes/") and
            not String.ends_with?(path, "/image") ->
          {:error, Error.new(:not_found, "not found")}

        true ->
          {:ok, %{}}
      end
    end)
  end

  # Setup for bug 1 / bug 2 regression: the Mealie import POST returns
  # `:auth`. `:auth` is NOT in `Error.retryable?/1`'s set, so the review
  # page must route the user to the terminal "no more retries" panel
  # rather than offering a Retry button that would just re-attempt the
  # same doomed import.
  defp review_auth_mealie_setup do
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
          {:error, Error.new(:auth, "mealie token rejected", stage: :mealie_import)}

        method == :get and String.starts_with?(path, "/api/foods") ->
          {:ok,
           %{
             "data" => [
               %{"id" => "food-mystery-spice", "name" => "mystery-spice"},
               %{"id" => "food-paprika", "name" => "paprika"},
               %{"id" => "food-cumin", "name" => "cumin"}
             ]
           }}

        method == :get and String.starts_with?(path, "/api/units") ->
          {:ok,
           %{
             "data" => [
               %{"id" => "unit-cups", "name" => "cups"},
               %{"id" => "unit-tbsp", "name" => "tbsp"}
             ]
           }}

        method == :post and path == "/api/parser/ingredients" ->
          {:ok, parsed_ingredients}

        method == :post and path == "/api/foods" ->
          name = body[:name] || body["name"] || "untitled-food"

          id =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          id = if id == "", do: "untitled-food", else: id
          {:ok, %{"id" => id, "name" => name}}

        method == :post and path == "/api/units" ->
          name = body[:name] || body["name"] || "untitled-unit"

          id =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          id = if id == "", do: "untitled-unit", else: id
          {:ok, %{"id" => id, "name" => name}}

        method == :get and String.starts_with?(path, "/api/recipes/") and
            not String.ends_with?(path, "/image") ->
          {:error, Error.new(:not_found, "not found")}

        true ->
          {:ok, %{}}
      end
    end)
  end

  # Setup for bug 1 regression: the first Mealie POST returns `:network`
  # (retryable), and subsequent POSTs return `:auth` (non-retryable). The
  # `Agent` counter is local to the test process and tracks how many POSTs
  # the adapter has handled so far; the on_exit hook keeps the test
  # supervisor from leaking it between tests.
  defp review_network_then_auth_mealie_setup do
    {:ok, counter} = Agent.start_link(fn -> %{post_count: 0} end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

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
          Agent.update(counter, fn c -> %{c | post_count: c.post_count + 1} end)
          post_count = Agent.get(counter, & &1.post_count)

          if post_count == 1 do
            {:error, Error.new(:network, "down", stage: :mealie_import)}
          else
            {:error, Error.new(:auth, "mealie token rejected", stage: :mealie_import)}
          end

        method == :get and String.starts_with?(path, "/api/foods") ->
          {:ok,
           %{
             "data" => [
               %{"id" => "food-mystery-spice", "name" => "mystery-spice"},
               %{"id" => "food-paprika", "name" => "paprika"},
               %{"id" => "food-cumin", "name" => "cumin"}
             ]
           }}

        method == :get and String.starts_with?(path, "/api/units") ->
          {:ok,
           %{
             "data" => [
               %{"id" => "unit-cups", "name" => "cups"},
               %{"id" => "unit-tbsp", "name" => "tbsp"}
             ]
           }}

        method == :post and path == "/api/parser/ingredients" ->
          {:ok, parsed_ingredients}

        method == :post and path == "/api/foods" ->
          name = body[:name] || body["name"] || "untitled-food"

          id =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          id = if id == "", do: "untitled-food", else: id
          {:ok, %{"id" => id, "name" => name}}

        method == :post and path == "/api/units" ->
          name = body[:name] || body["name"] || "untitled-unit"

          id =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          id = if id == "", do: "untitled-unit", else: id
          {:ok, %{"id" => id, "name" => name}}

        method == :get and String.starts_with?(path, "/api/recipes/") and
            not String.ends_with?(path, "/image") ->
          {:error, Error.new(:not_found, "not found")}

        true ->
          {:ok, %{}}
      end
    end)
  end

  # Minimal stub for the formatted_quantity_unit/2 truth-table regression
  # test below. Only the parser POST, the food search GET, and the unit
  # search GET are exercised — the test mounts the review view and reads
  # the rendered HTML, so no recipe POST/PATCH import flow is needed.
  defp quantity_no_unit_mealie_setup do
    Application.put_env(:insta_mealie, :mealie_http_adapter, fn method, path, _body ->
      case {method, path} do
        {:get, "/api/foods"} ->
          {:ok,
           %{
             "data" => [
               %{"id" => "food-apples", "name" => "apples"},
               %{"id" => "food-bananas", "name" => "bananas"},
               %{"id" => "food-cherries", "name" => "cherries"},
               %{"id" => "food-dates", "name" => "dates"}
             ]
           }}

        {:get, "/api/units"} ->
          {:ok,
           %{
             "data" => [
               %{"id" => "unit-cups", "name" => "cups"},
               %{"id" => "unit-tsp", "name" => "tsp"}
             ]
           }}

        {:post, "/api/parser/ingredients"} ->
          # Four ingredients covering every row of the
          # formatted_quantity_unit/2 truth table:
          #   - quantity=2, unit="cups"  → "2 cups"  (row 1)
          #   - quantity=5, unit=nil     → "5"       (row 2 — the bug)
          #   - quantity=nil, unit="tsp" → "tsp"     (row 3)
          #   - quantity=nil, unit=nil   → ""        (row 4)
          #
          # The "apples" row has a low-confidence / un-resolved food so the
          # pipeline transitions to :needs_review (one unknown ingredient
          # is enough). The preview chip still shows "2 cups" for that row
          # — the bug under test is about the quantity_unit rendering, not
          # the review gate.
          {:ok,
           [
             %{
               "quantity" => 2,
               "unit" => %{"name" => "cups", "id" => "unit-cups"},
               "food" => %{"name" => "apples", "id" => nil, "confidence" => 0.3},
               "note" => nil
             },
             %{
               "quantity" => 5,
               "unit" => nil,
               "food" => %{"name" => "bananas", "id" => "food-bananas", "confidence" => 1.0},
               "note" => nil
             },
             %{
               "quantity" => nil,
               "unit" => %{"name" => "tsp", "id" => "unit-tsp"},
               "food" => %{"name" => "cherries", "id" => "food-cherries", "confidence" => 1.0},
               "note" => nil
             },
             %{
               "quantity" => nil,
               "unit" => nil,
               "food" => %{"name" => "dates", "id" => "food-dates", "confidence" => 1.0},
               "note" => nil
             }
           ]}

        _ ->
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
      assert has_element?(view, "#retry-review")

      # Swap mealie stub to default success for the retry.
      review_mealie_setup()

      # Drive the retry through the LiveView event — exercising the same
      # code path the user does. This is the path bug 1's 3-tuple
      # CaseClauseError used to crash; rendering must succeed.
      view |> element("#retry-review") |> render_click()
      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded}}, 5000

      job = Pipeline.get_job(id)
      assert job.state == :succeeded
      assert job.state != :needs_review
      assert job.deep_link =~ "edit=true"

      html = render(view)
      assert html =~ "Recipe imported!"
      refute has_element?(view, "#retry-review")
    end
  end

  describe "Retry on retryable %Error{} (bug 1)" do
    test "clicking retry when the re-attempt also fails with :network shows the retryable error panel and keeps the CTA" do
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
      assert has_element?(view, "#retry-review")

      # Same network stub is still active — the re-attempt will also fail
      # with {:error, %Error{class: :network}} (retryable). Previously the
      # `{:error, class, _reason}` 3-tuple clause raised CaseClauseError
      # and crashed the LiveView.
      view |> element("#retry-review") |> render_click()
      assert_receive {:job_updated, %Job{id: ^id, state: :failed}}, 5000

      html = render(view)

      # Still in the retryable-error branch: import_error is set, retry
      # button is still present, no terminal panel.
      assert html =~ "Import error"
      assert html =~ "network"
      assert has_element?(view, "#retry-review")
      refute html =~ "Import failed"
    end
  end

  describe "Retry on non-retryable %Error{} (bug 1)" do
    test "clicking retry when the re-attempt fails with :auth routes to the terminal panel without crashing" do
      {id, _} =
        start_review_job(fn -> review_network_then_auth_mealie_setup() end)

      view = mount_review_view(id)

      view
      |> element("#review-import-form")
      |> render_submit(%{
        "food_0" => "paprika",
        "unit_0" => "cups"
      })

      html = render(view)
      assert html =~ "Import error"
      assert has_element?(view, "#retry-review")

      # The adapter returns :network on the first POST and :auth on every
      # subsequent POST. Clicking retry therefore re-attempts with an
      # `:auth` outcome — a non-retryable %Error{} — and the LiveView must
      # route to the terminal panel rather than crashing.
      view |> element("#retry-review") |> render_click()
      assert_receive {:job_updated, %Job{id: ^id, state: :failed}}, 5000

      html = render(view)
      assert html =~ "Import failed"
      refute has_element?(view, "#retry-review")
    end
  end

  describe "Retry cap reached (bug 1)" do
    test "clicking retry past the per-stage cap routes to the terminal panel without crashing" do
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
      assert has_element?(view, "#retry-review")

      # The retry cap is 2 per stage. The mealie_import stage's retry_count
      # is incremented on each `Pipeline.retry/1` call, regardless of the
      # outcome. After two retries (retry_count = 2, retries_left = 0),
      # the next click must surface `{:error, :retry_cap_exceeded}` —
      # previously a `CaseClauseError` crash, now routed to the terminal
      # panel via the `:dead` assign.
      view |> element("#retry-review") |> render_click()
      assert_receive {:job_updated, %Job{id: ^id, state: :failed}}, 5000
      html = render(view)
      assert html =~ "Import error"
      assert has_element?(view, "#retry-review")

      view |> element("#retry-review") |> render_click()
      assert_receive {:job_updated, %Job{id: ^id, state: :failed}}, 5000
      html = render(view)
      assert html =~ "Import error"
      assert has_element?(view, "#retry-review")

      # The cap is now exhausted. Pipeline.retry/1 returns
      # `{:error, :retry_cap_exceeded}`. The LiveView must not crash and
      # must route to the terminal "Import failed" panel.
      view |> element("#retry-review") |> render_click()

      html = render(view)
      assert html =~ "Import failed"
      refute has_element?(view, "#retry-review")

      job = Pipeline.get_job(id)
      assert job.state == :failed
      assert job.error_class == :network
    end
  end

  describe "Initial ingredient submission with :auth (bug 2)" do
    test "submit fails with :auth shows the terminal panel (no Retry CTA)" do
      {id, _} =
        start_review_job(fn -> review_auth_mealie_setup() end)

      view = mount_review_view(id)

      view
      |> element("#review-import-form")
      |> render_submit(%{
        "food_0" => "paprika",
        "unit_0" => "cups"
      })

      html = render(view)
      assert html =~ "Import failed"
      refute has_element?(view, "#retry-review")

      job = Pipeline.get_job(id)
      assert job.state == :failed
      assert job.error_class == :auth
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

  describe "Custom food/unit create + assign regression — Issue 29 (public flow)" do
    test "submitting custom food/unit names creates them via POST and assigns returned ids in PATCH recipeIngredient" do
      # Capture every adapter invocation so the assertions below can inspect
      # what the public review → import path actually emits at the wire
      # boundary. Agent.update/2 from a single producer (the Job GenServer
      # that owns the resolve/import path) arrives in call order; the
      # filters below only need existence/count, not exact ordering.
      {:ok, capture} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(capture), do: Agent.stop(capture) end)

      {id, _} =
        start_review_job(fn ->
          # Reuse review_mealie_setup/0 for the canonical response shapes,
          # then re-wrap the adapter with capture so the existing dispatch
          # logic stays untouched.
          review_mealie_setup()
          original = Application.get_env(:insta_mealie, :mealie_http_adapter)

          Application.put_env(
            :insta_mealie,
            :mealie_http_adapter,
            fn method, path, body ->
              Agent.update(capture, fn calls -> [{method, path, body} | calls] end)
              original.(method, path, body)
            end
          )
        end)

      view = mount_review_view(id)

      # Names absent from the mocked GET /api/foods and /api/units search
      # results, so Mealie.get_or_create_food/1 and get_or_create_unit/1
      # take the POST branch and the resolved ids end up in the PATCH.
      custom_food = "dragonfruit-bread"
      custom_unit = "splash"

      view
      |> element("#review-import-form")
      |> render_submit(%{
        "review" => %{
          "food_0" => custom_food,
          "unit_0" => custom_unit
        }
      })

      html = render(view)
      assert html =~ "Recipe imported!"

      calls = capture |> Agent.get(& &1) |> Enum.reverse()

      # POST /api/foods received the submitted custom food name and was
      # issued exactly once.
      food_posts =
        Enum.filter(calls, fn {m, p, _b} -> m == :post and p == "/api/foods" end)

      assert length(food_posts) == 1
      {_, _, food_body} = hd(food_posts)
      assert food_body["name"] == custom_food

      # POST /api/units received the submitted custom unit name and was
      # issued exactly once.
      unit_posts =
        Enum.filter(calls, fn {m, p, _b} -> m == :post and p == "/api/units" end)

      assert length(unit_posts) == 1
      {_, _, unit_body} = hd(unit_posts)
      assert unit_body["name"] == custom_unit

      # The eventual PATCH /api/recipes/... carried recipeIngredient with
      # the nested food/unit objects that use the ids returned from the
      # create calls above — proving the resolved ids make it onto the
      # wire, not just into the local recipe struct.
      patch_call =
        Enum.find(calls, fn {m, p, _b} ->
          m == :patch and String.starts_with?(p, "/api/recipes/")
        end)

      assert patch_call, "expected a PATCH /api/recipes/... call"

      {_, _, patch_body} = patch_call
      ingredients = patch_body["recipeIngredient"]

      assert is_list(ingredients)
      assert [first_ingredient | _] = ingredients

      assert first_ingredient["food"] == %{
               "id" => custom_food,
               "name" => custom_food
             }

      assert first_ingredient["unit"] == %{
               "id" => custom_unit,
               "name" => custom_unit
             }

      job = Pipeline.get_job(id)
      assert job.state == :succeeded
    end
  end

  describe "Quantity/no-unit preview (regression: formatted_quantity_unit/2)" do
    test "an ingredient with quantity but no unit shows the quantity in the 'Will import as' preview chip" do
      {id, _} = start_review_job(fn -> quantity_no_unit_mealie_setup() end)
      view = mount_review_view(id)
      html = render(view)

      # The preview chip is the <span class="... bg-base-300/40 ..."> that
      # receives `formatted_quantity_unit/2`'s return value. Each row below
      # pins one truth-table cell so the regression stays scoped to the
      # function being fixed.
      chip = "span.bg-base-300\\/40"

      # Row 1: quantity=2, unit="cups" → "2 cups" (unchanged control).
      assert has_element?(view, chip, "2 cups")

      # Row 2: quantity=5, unit=nil → "5" (THE BUG — the old nil-unit guard
      # in `formatted_quantity_unit/2` short-circuited and dropped the
      # quantity entirely, so the chip never rendered).
      assert has_element?(view, chip, "5")

      # Distinguish "5" from a naive fix that produces "5 " (trailing space).
      # The HEEX template wraps the value with leading/trailing whitespace
      # (newlines + spaces), so the rendered text node is "\n  5\n  ".
      # A trailing space in the value would insert an extra space before
      # that trailing newline: "\n  5 \n  ". The regex below requires "5"
      # to be followed immediately by a newline (i.e. the template
      # whitespace), with no space character in between.
      assert html =~
               ~r/<span class="rounded-md bg-base-300\/40 px-1\.5[^"]*">\s*5\n\s*<\/span>/

      # Row 3: quantity=nil, unit="tsp" → "tsp" (unchanged control).
      assert has_element?(view, chip, "tsp")

      # Row 4: quantity=nil, unit=nil → "" (no chip rendered for this row).
      # The food "dates" still appears in the preview, but only inside the
      # food-name span — never inside the quantity_unit chip.
      refute has_element?(view, chip, "dates")
    end
  end
end

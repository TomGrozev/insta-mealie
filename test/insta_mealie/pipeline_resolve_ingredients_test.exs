defmodule InstaMealie.PipelineResolveIngredientsTest do
  @moduledoc """
  Regression tests for the resolution-merge seam: when the review screen
  commits a custom food/unit name, the pipeline must resolve it through
  `Mealie.get_or_create_food/1` / `Mealie.get_or_create_unit/1` so the
  resolved `Ingredient` carries an `id` for the downstream PATCH.

  These tests cover the public pipeline operation
  `Pipeline.apply_ingredient_resolutions/2`. They do not peek at private
  helpers — every assertion is on the observable seam: the resulting
  `job.recipe.ingredients` and the captured PATCH body, plus the public
  return value on the lookup-error path.
  """

  use InstaMealie.TestCase

  alias InstaMealie.Error
  alias InstaMealie.LLM.Mock, as: LLMMock
  alias InstaMealie.Pipeline
  alias InstaMealie.Pipeline.Job

  # A 2-ingredient recipe keeps the parser output, the resolution map, and
  # the assertions aligned without dragging in the default granola's 5
  # lines. Override the LLM chat stub so the format envelope emits exactly
  # these two ingredients.
  defp stub_two_ingredient_recipe do
    recipe = %{
      "name" => "Resolve Test Recipe",
      "description" => "A minimal recipe for resolution tests.",
      "recipeYield" => "1 batch",
      "recipeIngredient" => [
        "2 jiggers mystery-spice",
        "1 pinch paprika"
      ],
      "recipeInstructions" => [
        %{"title" => "Mix", "text" => "Combine and serve."}
      ],
      "tags" => ["test"]
    }

    Mox.stub(LLMMock, :chat, fn _model, _messages ->
      {:ok,
       %{
         "choices" => [
           %{
             "message" => %{
               "content" =>
                 Jason.encode!(%{
                   "completeness" => "recipe_complete",
                   "missing_fields" => [],
                   "recipe" => recipe
                 })
             }
           }
         ]
       }}
    end)
  end

  # Drive a URL-mode job from `needs_review` after installing the test
  # adapter and pinning the LLM recipe to a deterministic 2-ingredient
  # shape. Returns `{job_id, job}` so the caller can fire resolutions.
  defp start_review_job do
    stub_two_ingredient_recipe()
    Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")

    assert {:ok, id} =
             Pipeline.create_job(%{url: "https://instagram.com/reel/resolve-ids"})

    assert_receive {:job_updated, %Job{id: ^id, state: :needs_review} = job}, 5000
    {id, job}
  end

  # Drive a URL-mode job from `needs_review` AFTER installing the test
  # adapter. Splits the setup so callers can layer their own overrides on
  # top of the installed adapter (e.g. capture-extra-calls wrappers in
  # the explicit-id / blank-value tests).
  defp start_review_job_with_adapter(opts) do
    install_adapter(opts)
    start_review_job()
  end

  # Install a `:mealie_http_adapter` that:
  #   * tells the parser to flag ingredient 0 as needs_review (food and unit
  #     without ids) — the canonical case for the review screen.
  #   * captures the PATCH body so the test can assert the resolved IDs.
  #   * leaves /api/foods and /api/units search empty by default and POSTs
  #     to either one return the configured created id.
  #
  # The adapter opts:
  #   * `:food_create_id`   — id returned by POST /api/foods (default: "food-mystery-99")
  #   * `:unit_create_id`   — id returned by POST /api/units (default: "unit-jigger-99")
  #   * `:food_search_error` — when set, GET /api/foods returns this %Error{}
  #   * `:unit_create_error` — when set, POST /api/units returns this %Error{}
  defp install_adapter(opts) do
    test_pid = self()
    food_create_id = Keyword.get(opts, :food_create_id, "food-mystery-99")
    unit_create_id = Keyword.get(opts, :unit_create_id, "unit-jigger-99")
    food_search_error = Keyword.get(opts, :food_search_error)
    unit_create_error = Keyword.get(opts, :unit_create_error)

    parsed_ingredients = [
      %{
        "quantity" => 2,
        "unit" => %{"name" => "jigger", "id" => nil},
        "food" => %{"name" => "mystery-spice", "id" => nil, "confidence" => 0.3},
        "note" => nil
      },
      %{
        "quantity" => nil,
        "unit" => %{"name" => nil, "id" => "unit-known"},
        "food" => %{"name" => "paprika", "id" => "food-known", "confidence" => 1.0},
        "note" => nil
      }
    ]

    prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

    Application.put_env(
      :insta_mealie,
      :mealie_http_adapter,
      fn method, path, body ->
        cond do
          # Capture the PATCH that delivers the resolved recipe — the test
          # asserts the IDs reach the wire here.
          method in [:put, :patch] and
            String.starts_with?(path, "/api/recipes/") and
              not String.ends_with?(path, "/image") ->
            send(test_pid, {:patched_recipe, path, body})
            {:ok, %{"slug" => Path.basename(path)}}

          method == :post and path == "/api/recipes" ->
            # Derive the slug from the name so the response matches the
            # slug the production code computes via `slugify/1`.
            name = body[:name] || body["name"] || "untitled-recipe"

            slug =
              name
              |> String.downcase()
              |> String.normalize(:nfd)
              |> String.replace(~r/[^a-z0-9]+/u, "-")
              |> String.trim("-")

            slug = if slug == "", do: "untitled-recipe", else: slug
            {:ok, %{"slug" => slug, "id" => slug}}

          method == :get and String.starts_with?(path, "/api/foods") ->
            if food_search_error do
              {:error, food_search_error}
            else
              {:ok, %{"items" => []}}
            end

          method == :get and String.starts_with?(path, "/api/units") ->
            {:ok, %{"items" => []}}

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

          method == :post and path == "/api/foods" ->
            {:ok, %{"id" => food_create_id, "name" => body["name"] || "mystery-spice"}}

          method == :post and path == "/api/units" ->
            if unit_create_error do
              {:error, unit_create_error}
            else
              {:ok, %{"id" => unit_create_id, "name" => body["name"] || "jigger"}}
            end

          method == :post and path == "/api/parser/ingredients" ->
            {:ok, parsed_ingredients}

          # `Mealie.import_recipe/1` does `GET /api/recipes/{slug}` first and
          # only proceeds to `POST /api/recipes` on a `:not_found` error (see
          # the bug 1 fix in `maybe_create_recipe/2`). The stub mirrors what
          # `InstaMealie.HttpClassify` produces from a real 404 so the create
          # branch fires. The default catch-all below would otherwise return
          # `{:ok, %{}}`, which the production `get_recipe/1` translates into
          # `Error{class: :api_error, summary: "get response missing slug"}`
          # — NOT a not_found, which would (correctly) fail the import.
          method == :get and String.starts_with?(path, "/api/recipes/") and
              not String.ends_with?(path, "/image") ->
            {:error, Error.new(:not_found, "not found")}

          true ->
            {:ok, %{}}
        end
      end
    )

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
        v -> Application.put_env(:insta_mealie, :mealie_http_adapter, v)
      end
    end)

    :ok
  end

  # Wrap the installed adapter with an additional clause that sends a
  # tagged message on every create POST to /api/foods or /api/units. Lets
  # tests assert the lookup was skipped when the resolution already carries
  # both ids, or when the user-typed values are blank.
  defp wrap_capture_create_calls do
    test_pid = self()
    prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

    Application.put_env(
      :insta_mealie,
      :mealie_http_adapter,
      fn m, p, body ->
        cond do
          m == :post and (p == "/api/foods" or p == "/api/units") ->
            send(test_pid, {:create_called, m, p, body})
            {:ok, %{"id" => "should-not-be-used", "name" => body["name"] || ""}}

          true ->
            prev.(m, p, body)
        end
      end
    )

    on_exit(fn ->
      Application.put_env(:insta_mealie, :mealie_http_adapter, prev)
    end)

    :ok
  end

  describe "apply_ingredient_resolutions/2 — custom food + custom unit" do
    test "custom food and unit names are resolved through Mealie and reach the PATCH with ids" do
      {id, _job} = start_review_job_with_adapter([])

      assert {:ok, %Job{} = imported} =
               Pipeline.apply_ingredient_resolutions(id, %{
                 0 => %{"food" => "mystery-spice", "unit" => "jigger"}
               })

      # The job completed the import and the resolved ingredient carries
      # both the user-typed name AND the id Mealie returned.
      assert imported.state == :succeeded

      [resolved, _other] =
        Enum.sort_by(imported.recipe.ingredients, & &1.index)

      assert resolved.index == 0
      assert resolved.food.name == "mystery-spice"
      assert resolved.food.id == "food-mystery-99"
      assert resolved.unit.name == "jigger"
      assert resolved.unit.id == "unit-jigger-99"

      # The PATCH body sent to Mealie carries the resolved ids — that's the
      # observable wire boundary the brief calls out. We capture it through
      # the adapter rather than reaching into a private helper.
      assert_receive {:patched_recipe, path, patch_body}
      assert String.starts_with?(path, "/api/recipes/")

      assert [%{"food" => food, "unit" => unit} | _] = patch_body["recipeIngredient"]

      assert food["name"] == "mystery-spice"
      assert food["id"] == "food-mystery-99"
      assert unit["name"] == "jigger"
      assert unit["id"] == "unit-jigger-99"
    end

    test "explicit food_id and unit_id in the resolution are preserved (no extra lookup)" do
      install_adapter([])
      wrap_capture_create_calls()

      {id, _job} = start_review_job()

      assert {:ok, %Job{} = imported} =
               Pipeline.apply_ingredient_resolutions(id, %{
                 0 => %{
                   "food" => "explicit-food",
                   "food_id" => "food-explicit",
                   "unit" => "explicit-unit",
                   "unit_id" => "unit-explicit"
                 }
               })

      # No create POSTs — the explicit ids in the resolution short-circuit
      # the lookup. `Ingredient.apply_resolutions/2` already preserves them.
      refute_received {:create_called, :post, "/api/foods", _}
      refute_received {:create_called, :post, "/api/units", _}

      resolved = Enum.find(imported.recipe.ingredients, &(&1.index == 0))

      assert resolved.food.id == "food-explicit"
      assert resolved.unit.id == "unit-explicit"
    end

    test "blank food / unit values do not trigger a lookup and do not create empty records" do
      install_adapter([])
      wrap_capture_create_calls()

      {id, _job} = start_review_job()

      assert {:ok, %Job{} = imported} =
               Pipeline.apply_ingredient_resolutions(id, %{
                 0 => %{"food" => "", "unit" => ""}
               })

      refute_received {:create_called, :post, "/api/foods", _}
      refute_received {:create_called, :post, "/api/units", _}

      resolved = Enum.find(imported.recipe.ingredients, &(&1.index == 0))

      # Both blank values leave the Ref's name nil (per
      # `Ingredient.apply_resolutions/2`'s `%{"food" => "", "unit" => ""}`
      # contract — the user explicitly cleared the field), and the parser's
      # existing ids stay in place because no API call was made.
      assert is_nil(resolved.food.name)
      assert is_nil(resolved.unit.name)
    end
  end

  describe "apply_ingredient_resolutions/2 — lookup / creation errors" do
    test "get_or_create_food search error propagates as {:error, %Error{}} and fails the job" do
      search_error = Error.new(:api_error, "client error 500")
      install_adapter(food_search_error: search_error)

      {id, _job} = start_review_job()

      assert {:error, %Error{} = returned} =
               Pipeline.apply_ingredient_resolutions(id, %{
                 0 => %{"food" => "mystery-spice", "unit" => "jigger"}
               })

      assert returned.class == :api_error
      assert returned.summary =~ "client error 500"

      # The job is taken through the existing failure path. The enrichment
      # happens during the import step (the resolution leads to import), so
      # the error is attributed to :mealie_import — the same stage
      # `run_import_inline/1` uses for its own failures.
      failed = Pipeline.get_job(id)
      assert failed.state == :failed
      assert failed.error_stage == :mealie_import
      assert failed.error_class == :api_error

      # No import attempt was made — the resolution itself failed first,
      # so no PATCH should have been sent to Mealie.
      refute_received {:patched_recipe, _, _}
    end

    test "get_or_create_unit POST error propagates and fails the job" do
      create_error = Error.new(:validation, "unit rejected by Mealie")
      install_adapter(unit_create_error: create_error)

      {id, _job} = start_review_job()

      assert {:error, %Error{} = returned} =
               Pipeline.apply_ingredient_resolutions(id, %{
                 0 => %{"food" => "mystery-spice", "unit" => "jigger"}
               })

      assert returned.class == :validation
      assert returned.summary == "unit rejected by Mealie"

      failed = Pipeline.get_job(id)
      assert failed.state == :failed
      assert failed.error_stage == :mealie_import
      assert failed.error_class == :validation

      refute_received {:patched_recipe, _, _}
    end
  end
end

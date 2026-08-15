defmodule InstaMealie.RecipeTest do
  use ExUnit.Case, async: true

  alias InstaMealie.Recipe

  describe "from_map/1 — source_url (orgURL) mapping" do
    test "builds a Recipe with source_url set from \"orgURL\"" do
      data = %{"orgURL" => "https://instagram.com/reel/abc"}

      assert %Recipe{source_url: "https://instagram.com/reel/abc"} = Recipe.from_map(data)
    end

    test "builds a Recipe with source_url: nil when \"orgURL\" key is absent" do
      data = %{}

      assert %Recipe{source_url: nil} = Recipe.from_map(data)
    end
  end

  describe "to_mealie_payload/1 — source_url (orgURL) projection" do
    test "includes \"orgURL\" when source_url is set" do
      recipe = %Recipe{source_url: "https://instagram.com/reel/abc"}

      payload = Recipe.to_mealie_payload(recipe)

      assert payload["orgURL"] == "https://instagram.com/reel/abc"
    end

    test "drops the \"orgURL\" key when source_url is nil" do
      recipe = %Recipe{source_url: nil}

      payload = Recipe.to_mealie_payload(recipe)

      refute Map.has_key?(payload, "orgURL")
    end
  end

  describe "validate/1 — source_url shape" do
    test "returns {:ok, recipe} when source_url is a string" do
      recipe = %Recipe{source_url: "https://example.com"}

      assert {:ok, %Recipe{source_url: "https://example.com"}} = Recipe.validate(recipe)
    end

    test "returns {:error, :source_url} when source_url is not a string" do
      recipe = %Recipe{source_url: 123}

      assert Recipe.validate(recipe) == {:error, :source_url}
    end
  end

  describe "empty/0 — source_url default" do
    test "produces a Recipe with source_url: nil" do
      assert %Recipe{source_url: nil} = Recipe.empty()
    end
  end

  # ── Yield: clean_yield semantics at the Mealie payload boundary ──────
  #
  # Per the brief, Mealie expects three distinct payload keys for yield:
  # recipeServings (number), recipeYieldQuantity (number), recipeYield (text).
  # The conversion happens at the Mealie payload boundary; the struct's
  # `recipe_yield` field still holds the raw text the LLM or scraper
  # produced. Explicit numeric `recipeServings`/`recipeYieldQuantity`
  # already present in the struct or input map are preserved verbatim.

  describe "to_mealie_payload/1 — recipeYield parsing" do
    test "splits '2 servings' into recipeServings: 2, recipeYieldQuantity: 0, recipeYield: \"\"" do
      recipe = %Recipe{recipe_yield: "2 servings"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["recipeServings"] == 2
      assert payload["recipeYieldQuantity"] == 0
      assert payload["recipeYield"] == ""
    end

    test "splits '4 pies' into recipeServings: 0, recipeYieldQuantity: 4, recipeYield: 'pies'" do
      recipe = %Recipe{recipe_yield: "4 pies"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["recipeServings"] == 0
      assert payload["recipeYieldQuantity"] == 4
      assert payload["recipeYield"] == "pies"
    end

    test "splits '1 batch' into recipeServings: 0, recipeYieldQuantity: 1, recipeYield: 'batch'" do
      recipe = %Recipe{recipe_yield: "1 batch"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["recipeServings"] == 0
      assert payload["recipeYieldQuantity"] == 1
      assert payload["recipeYield"] == "batch"
    end

    test "recognises 'Makes about 8 servings' as a servings-style yield" do
      recipe = %Recipe{recipe_yield: "Makes about 8 servings"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["recipeServings"] == 8
      assert payload["recipeYieldQuantity"] == 0
      assert payload["recipeYield"] == ""
    end

    test "recognises 'Serves 4' as a servings-style yield" do
      recipe = %Recipe{recipe_yield: "Serves 4"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["recipeServings"] == 4
      assert payload["recipeYieldQuantity"] == 0
      assert payload["recipeYield"] == ""
    end

    test "preserves unparseable yield text without fabricating numbers" do
      recipe = %Recipe{recipe_yield: "Some bespoke yield"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["recipeServings"] == 0
      assert payload["recipeYieldQuantity"] == 0
      assert payload["recipeYield"] == "Some bespoke yield"
    end

    test "supports decimal/fraction quantities (e.g. '1/2 cup')" do
      recipe = %Recipe{recipe_yield: "1/2 cup"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["recipeServings"] == 0
      assert payload["recipeYieldQuantity"] == 0.5
      assert payload["recipeYield"] == "cup"
    end

    test "preserves explicit numeric recipeServings/recipeYieldQuantity already on the struct" do
      recipe = %Recipe{
        recipe_yield: "2 servings",
        recipe_servings: 7,
        recipe_yield_quantity: 99
      }

      payload = Recipe.to_mealie_payload(recipe)

      assert payload["recipeServings"] == 7
      assert payload["recipeYieldQuantity"] == 99
    end

    test "reads explicit numeric recipeServings/recipeYieldQuantity from from_map input" do
      recipe =
        Recipe.from_map(%{
          "recipeYield" => "2 servings",
          "recipeServings" => 5,
          "recipeYieldQuantity" => 3
        })

      assert recipe.recipe_servings == 5
      assert recipe.recipe_yield_quantity == 3

      payload = Recipe.to_mealie_payload(recipe)

      assert payload["recipeServings"] == 5
      assert payload["recipeYieldQuantity"] == 3
    end

    test "emits all three keys with numeric defaults when no yield text is present" do
      recipe = %Recipe{}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["recipeServings"] == 0
      assert payload["recipeYieldQuantity"] == 0
      assert payload["recipeYield"] == ""
    end
  end

  # Regression coverage for the numeric-shape contract on the explicit
  # yield fields: when present they must be numbers (`is_number/1`),
  # otherwise `validate/1` returns `{:error, :recipe_servings}` or
  # `{:error, :recipe_yield_quantity}` as the first offending field.

  describe "validate/1 — recipeServings / recipeYieldQuantity shape" do
    test "returns {:ok, recipe} when recipe_servings is a number" do
      recipe = %Recipe{recipe_servings: 4}

      assert {:ok, %Recipe{recipe_servings: 4}} = Recipe.validate(recipe)
    end

    test "returns {:ok, recipe} when recipe_yield_quantity is a number" do
      recipe = %Recipe{recipe_yield_quantity: 3}

      assert {:ok, %Recipe{recipe_yield_quantity: 3}} = Recipe.validate(recipe)
    end

    test "accepts float values (number() covers integers and floats)" do
      recipe = %Recipe{recipe_servings: 0.5, recipe_yield_quantity: 1.25}

      assert {:ok, _} = Recipe.validate(recipe)
    end

    test "returns {:error, :recipe_servings} when recipe_servings is a string" do
      recipe = %Recipe{recipe_servings: "4"}

      assert Recipe.validate(recipe) == {:error, :recipe_servings}
    end

    test "returns {:error, :recipe_yield_quantity} when recipe_yield_quantity is a string" do
      recipe = %Recipe{recipe_yield_quantity: "3"}

      assert Recipe.validate(recipe) == {:error, :recipe_yield_quantity}
    end

    test "returns {:error, :recipe_servings} when recipe_servings is a list" do
      recipe = %Recipe{recipe_servings: [4]}

      assert Recipe.validate(recipe) == {:error, :recipe_servings}
    end

    test "returns {:error, :recipe_yield_quantity} when recipe_yield_quantity is a map" do
      recipe = %Recipe{recipe_yield_quantity: %{}}

      assert Recipe.validate(recipe) == {:error, :recipe_yield_quantity}
    end

    test "returns {:ok, recipe} when both fields are nil" do
      recipe = %Recipe{}

      assert {:ok, %Recipe{recipe_servings: nil, recipe_yield_quantity: nil}} =
               Recipe.validate(recipe)
    end
  end

  # ── Time: ISO-8601 -> canonical text at the Mealie payload boundary ──
  #
  # Mealie displays totalTime/prepTime/cookTime/performTime as text, not as
  # ISO-8601. The conversion happens at the payload boundary so the
  # internal struct (driven by LLM normalisation, see LLM.normalize_durations)
  # keeps its ISO-8601 representation. Already-human-readable or
  # unparseable strings are preserved verbatim.

  describe "to_mealie_payload/1 — ISO-8601 -> canonical text" do
    test "converts 'PT245M' to '4 hours 5 minutes'" do
      recipe = %Recipe{total_time: "PT245M"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["totalTime"] == "4 hours 5 minutes"
    end

    test "converts 'PT5M' to '5 minutes'" do
      recipe = %Recipe{prep_time: "PT5M"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["prepTime"] == "5 minutes"
    end

    test "converts 'PT1H' to '1 hour' (singular)" do
      recipe = %Recipe{total_time: "PT1H"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["totalTime"] == "1 hour"
    end

    test "converts 'PT2H' to '2 hours' (plural)" do
      recipe = %Recipe{total_time: "PT2H"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["totalTime"] == "2 hours"
    end

    test "converts 'PT1H20M' to '1 hour 20 minutes'" do
      recipe = %Recipe{cook_time: "PT1H20M"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["cookTime"] == "1 hour 20 minutes"
    end

    test "converts 'PT1M' to '1 minute' (singular)" do
      recipe = %Recipe{prep_time: "PT1M"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["prepTime"] == "1 minute"
    end

    test "preserves an already-human-readable duration string" do
      recipe = %Recipe{total_time: "40 minutes"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["totalTime"] == "40 minutes"
    end

    test "preserves an unparseable duration string" do
      recipe = %Recipe{total_time: "until done"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["totalTime"] == "until done"
    end

    test "drops an empty duration string (consistent with existing nil-drop contract)" do
      recipe = %Recipe{}
      payload = Recipe.to_mealie_payload(%{recipe | total_time: ""})

      refute Map.has_key?(payload, "totalTime")
    end

    test "converts performTime independently (no derivation)" do
      recipe = %Recipe{perform_time: "PT4H"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["performTime"] == "4 hours"
    end
  end

  describe "to_mealie_payload/1 — derivation of a missing time field" do
    test "derives cook from total + prep when both parse (PT245M + PT5M -> cook '4 hours')" do
      recipe = %Recipe{total_time: "PT245M", prep_time: "PT5M"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["totalTime"] == "4 hours 5 minutes"
      assert payload["prepTime"] == "5 minutes"
      assert payload["cookTime"] == "4 hours"
    end

    test "derives total from prep + cook when both parse" do
      recipe = %Recipe{prep_time: "PT5M", cook_time: "PT10M"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["totalTime"] == "15 minutes"
      assert payload["prepTime"] == "5 minutes"
      assert payload["cookTime"] == "10 minutes"
    end

    test "derives prep from total + cook when total >= cook" do
      recipe = %Recipe{total_time: "PT30M", cook_time: "PT20M"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["totalTime"] == "30 minutes"
      assert payload["cookTime"] == "20 minutes"
      assert payload["prepTime"] == "10 minutes"
    end

    test "leaves cook missing when total < prep (subtraction would be negative)" do
      recipe = %Recipe{total_time: "PT5M", prep_time: "PT30M"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["totalTime"] == "5 minutes"
      assert payload["prepTime"] == "30 minutes"
      refute Map.has_key?(payload, "cookTime")
    end

    test "leaves cook missing when one of the pair is human-readable" do
      recipe = %Recipe{total_time: "PT245M", prep_time: "5 minutes"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["totalTime"] == "4 hours 5 minutes"
      assert payload["prepTime"] == "5 minutes"
      refute Map.has_key?(payload, "cookTime")
    end

    test "leaves cook missing when both inputs are human-readable (no ISO parse)" do
      recipe = %Recipe{total_time: "1 hour", prep_time: "5 minutes"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["totalTime"] == "1 hour"
      assert payload["prepTime"] == "5 minutes"
      refute Map.has_key?(payload, "cookTime")
    end

    test "does not overwrite supplied values when both inputs are present" do
      # All three parseable; nothing should be derived or overwritten.
      recipe = %Recipe{total_time: "PT1H", prep_time: "PT15M", cook_time: "PT45M"}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["totalTime"] == "1 hour"
      assert payload["prepTime"] == "15 minutes"
      assert payload["cookTime"] == "45 minutes"
    end
  end
end

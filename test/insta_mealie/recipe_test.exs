defmodule InstaMealie.RecipeTest do
  use ExUnit.Case, async: true

  alias InstaMealie.Ingredient
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

  describe "from_map/1 — full field mapping" do
    test "maps every source field into the corresponding snake_case struct field" do
      data = %{
        "name" => "Tofu Scramble",
        "description" => "A hearty breakfast",
        "recipeYield" => "2 servings",
        "recipeIngredient" => ["2 eggs", "1 tbsp oil"],
        "recipeInstructions" => [%{"text" => "Whisk eggs"}, %{"text" => "Cook"}],
        "tags" => ["breakfast", "vegan"],
        "categories" => ["Dinner"],
        "notes" => [%{"title" => "note", "text" => "serve hot"}],
        "totalTime" => "PT15M",
        "prepTime" => "PT5M",
        "cookTime" => "PT10M",
        "performTime" => "PT2M",
        "image" => "https://example.com/img.jpg",
        "orgURL" => "https://instagram.com/reel/abc"
      }

      recipe = Recipe.from_map(data)

      assert recipe.name == "Tofu Scramble"
      assert recipe.description == "A hearty breakfast"
      assert recipe.recipe_yield == "2 servings"

      assert recipe.ingredients == [
               Ingredient.from_raw("2 eggs"),
               Ingredient.from_raw("1 tbsp oil")
             ]

      assert recipe.instructions == [%{"text" => "Whisk eggs"}, %{"text" => "Cook"}]
      assert recipe.tags == ["breakfast", "vegan"]
      assert recipe.categories == ["Dinner"]
      assert recipe.notes == [%{"title" => "note", "text" => "serve hot"}]
      assert recipe.total_time == "PT15M"
      assert recipe.prep_time == "PT5M"
      assert recipe.cook_time == "PT10M"
      assert recipe.perform_time == "PT2M"
      assert recipe.image == "https://example.com/img.jpg"
      assert recipe.source_url == "https://instagram.com/reel/abc"
    end

    test "leaves ingredients/instructions empty lists when keys are absent" do
      recipe = Recipe.from_map(%{})

      assert recipe.ingredients == []
      assert recipe.instructions == []
    end

    test "coerces recipeServings and recipeYieldQuantity to numbers" do
      recipe =
        Recipe.from_map(%{
          "recipeServings" => "4",
          "recipeYieldQuantity" => "2.5"
        })

      assert recipe.recipe_servings == 4
      assert recipe.recipe_yield_quantity == 2.5
    end

    test "coerces recipeServings to nil when the string is not parseable" do
      recipe = Recipe.from_map(%{"recipeServings" => "many"})

      assert recipe.recipe_servings == nil
    end

    test "defaults every field to nil / empty when the map has no matching keys" do
      recipe = Recipe.from_map(%{"unrelated" => "value"})

      assert %Recipe{
               name: nil,
               description: nil,
               recipe_yield: nil,
               recipe_servings: nil,
               recipe_yield_quantity: nil,
               ingredients: [],
               instructions: [],
               tags: nil,
               categories: nil,
               notes: nil,
               total_time: nil,
               prep_time: nil,
               cook_time: nil,
               perform_time: nil,
               image: nil,
               source_url: nil
             } = recipe
    end

    test "reads fields from an atom-keyed map (map_get atom fallback)" do
      recipe =
        Recipe.from_map(%{
          name: "Oatmeal",
          recipeYield: "1 bowl",
          recipeIngredient: ["oats"],
          orgURL: "https://example.com"
        })

      assert recipe.name == "Oatmeal"
      assert recipe.recipe_yield == "1 bowl"
      assert recipe.ingredients == [Ingredient.from_raw("oats")]
      assert recipe.source_url == "https://example.com"
    end

    test "handles a fully empty map by producing a default Recipe" do
      recipe = Recipe.from_map(%{})

      assert recipe == Recipe.empty()
    end
  end

  describe "validate/1 — full shape matrix" do
    test "returns {:error, :name} when name is not a string" do
      assert Recipe.validate(%Recipe{name: 123}) == {:error, :name}
      assert Recipe.validate(%Recipe{name: ["x"]}) == {:error, :name}
    end

    test "accepts name when nil or a string" do
      assert {:ok, _} = Recipe.validate(%Recipe{name: nil})
      assert {:ok, _} = Recipe.validate(%Recipe{name: "Soup"})
    end

    test "returns {:error, :description} when description is not a string" do
      assert Recipe.validate(%Recipe{description: 42}) == {:error, :description}
    end

    test "returns {:error, :recipe_yield} when recipe_yield is not a string" do
      assert Recipe.validate(%Recipe{recipe_yield: 8}) == {:error, :recipe_yield}
    end

    test "returns {:error, :ingredients} when ingredients is not a list" do
      assert Recipe.validate(%Recipe{ingredients: "2 eggs"}) == {:error, :ingredients}
      assert Recipe.validate(%Recipe{ingredients: %{}}) == {:error, :ingredients}
    end

    test "accepts an empty or populated ingredients list" do
      assert {:ok, _} = Recipe.validate(%Recipe{ingredients: []})
      assert {:ok, _} = Recipe.validate(%Recipe{ingredients: [Ingredient.from_raw("eggs")]})
    end

    test "accepts nil instructions" do
      assert {:ok, _} = Recipe.validate(%Recipe{instructions: nil})
    end

    test "accepts a list of maps each with a \"text\" key" do
      recipe = %Recipe{instructions: [%{"text" => "Whisk"}, %{"text" => "Cook"}]}

      assert {:ok, _} = Recipe.validate(recipe)
    end

    test "returns {:error, :instructions} when a list element is not a map" do
      recipe = %Recipe{instructions: ["Whisk", 42]}

      assert Recipe.validate(recipe) == {:error, :instructions}
    end

    test "returns {:error, :instructions} when a map is missing \"text\"" do
      recipe = %Recipe{instructions: [%{"text" => "ok"}, %{"text" => nil}]}

      assert Recipe.validate(recipe) == {:error, :instructions}
    end

    test "returns {:error, :instructions} when instructions is not a list" do
      assert Recipe.validate(%Recipe{instructions: "just a string"}) == {:error, :instructions}
    end

    test "returns {:error, :total_time} when total_time is not a string" do
      assert Recipe.validate(%Recipe{total_time: 15}) == {:error, :total_time}
    end

    test "returns {:error, :prep_time} when prep_time is not a string" do
      assert Recipe.validate(%Recipe{prep_time: 5}) == {:error, :prep_time}
    end

    test "returns {:error, :cook_time} when cook_time is not a string" do
      assert Recipe.validate(%Recipe{cook_time: 10}) == {:error, :cook_time}
    end

    test "returns {:error, :perform_time} when perform_time is not a string" do
      assert Recipe.validate(%Recipe{perform_time: 2}) == {:error, :perform_time}
    end

    test "accepts nil or string time fields" do
      recipe = %Recipe{
        total_time: nil,
        prep_time: "PT5M",
        cook_time: "10 minutes",
        perform_time: nil
      }

      assert {:ok, _} = Recipe.validate(recipe)
    end

    test "returns {:error, :tags} when tags is not a list" do
      assert Recipe.validate(%Recipe{tags: "breakfast"}) == {:error, :tags}
    end

    test "returns {:error, :categories} when categories is not a list" do
      assert Recipe.validate(%Recipe{categories: "Dinner"}) == {:error, :categories}
    end

    test "accepts nil or list tags/categories" do
      assert {:ok, _} = Recipe.validate(%Recipe{tags: nil, categories: nil})
      assert {:ok, _} = Recipe.validate(%Recipe{tags: ["a"], categories: ["b"]})
    end

    test "returns {:ok, recipe} for a fully valid recipe" do
      recipe = %Recipe{
        name: "Scramble",
        description: "desc",
        recipe_yield: "2 servings",
        recipe_servings: 2,
        recipe_yield_quantity: 0,
        ingredients: [Ingredient.from_raw("eggs")],
        instructions: [%{"text" => "Cook"}],
        tags: ["breakfast"],
        categories: ["Dinner"],
        notes: [%{"text" => "note"}],
        total_time: "PT15M",
        prep_time: "PT5M",
        cook_time: "PT10M",
        perform_time: "PT2M",
        image: "https://example.com/i.jpg",
        source_url: "https://example.com"
      }

      assert {:ok, ^recipe} = Recipe.validate(recipe)
    end
  end

  describe "to_prompt_projection/1" do
    test "renders recipeIngredient as a list of plain strings" do
      recipe = %Recipe{
        name: "Scramble",
        description: "desc",
        recipe_yield: "2 servings",
        tags: ["breakfast"],
        categories: ["Dinner"],
        notes: [%{"text" => "note"}],
        total_time: "PT15M",
        prep_time: "PT5M",
        cook_time: "PT10M",
        perform_time: "PT2M",
        source_url: "https://example.com",
        ingredients: [Ingredient.from_raw("2 eggs"), Ingredient.from_raw("1 tbsp oil")]
      }

      projected = Recipe.to_prompt_projection(recipe)

      assert projected["recipeIngredient"] == ["2 eggs", "1 tbsp oil"]
      assert projected["name"] == "Scramble"
      assert projected["description"] == "desc"
      assert projected["recipeYield"] == ""
      assert projected["recipeServings"] == 2
      assert projected["recipeYieldQuantity"] == 0
      assert projected["tags"] == ["breakfast"]
      assert projected["recipeCategory"] == ["Dinner"]
      assert projected["notes"] == [%{"text" => "note"}]
      assert projected["totalTime"] == "15 minutes"
      assert projected["prepTime"] == "5 minutes"
      assert projected["cookTime"] == "10 minutes"
      assert projected["performTime"] == "2 minutes"
      assert projected["orgURL"] == "https://example.com"
    end

    test "renders an empty ingredient list when there are no ingredients" do
      recipe = %Recipe{name: "Plain"}

      projected = Recipe.to_prompt_projection(recipe)

      assert projected["recipeIngredient"] == []
      assert projected["name"] == "Plain"
    end

    test "matches to_mealie_payload on every key except recipeIngredient" do
      recipe = %Recipe{
        name: "Scramble",
        description: "desc",
        recipe_yield: "4 pies",
        ingredients: [Ingredient.from_raw("flour")],
        tags: ["baking"],
        total_time: "PT1H"
      }

      projected = Recipe.to_prompt_projection(recipe)
      payload = Recipe.to_mealie_payload(recipe)

      assert Map.delete(projected, "recipeIngredient") == Map.delete(payload, "recipeIngredient")
      assert projected["recipeIngredient"] == ["flour"]
    end
  end

  describe "to_mealie_payload/1 — ingredients/instructions/tags projection" do
    test "projects ingredients through Ingredient.to_payload_list" do
      flour = Ingredient.from_raw("2 cups flour")
      eggs = Ingredient.from_raw("3 eggs")

      recipe = %Recipe{ingredients: [flour, eggs]}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["recipeIngredient"] == Ingredient.to_payload_list([flour, eggs])

      assert payload["recipeIngredient"] == [
               %{"note" => "2 cups flour", "originalText" => "2 cups flour"},
               %{"note" => "3 eggs", "originalText" => "3 eggs"}
             ]
    end

    test "adds the RecipeInstruction type to instruction maps that lack it" do
      recipe = %Recipe{instructions: [%{"text" => "Whisk"}, %{"text" => "Cook", "type" => "X"}]}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["recipeInstructions"] == [
               %{"text" => "Whisk", "type" => "RecipeInstruction"},
               %{"text" => "Cook", "type" => "X"}
             ]
    end

    test "turns instruction strings into text+type maps" do
      recipe = %Recipe{instructions: ["Whisk", 42]}
      payload = Recipe.to_mealie_payload(recipe)

      assert payload["recipeInstructions"] == [
               %{"text" => "Whisk", "type" => "RecipeInstruction"},
               %{"text" => "42", "type" => "RecipeInstruction"}
             ]
    end

    test "passes tags through and omits them when nil" do
      assert Recipe.to_mealie_payload(%Recipe{tags: ["a", "b"]})["tags"] == ["a", "b"]

      payload = Recipe.to_mealie_payload(%Recipe{tags: nil})
      refute Map.has_key?(payload, "tags")
    end

    test "passes categories through as recipeCategory and omits nil" do
      assert Recipe.to_mealie_payload(%Recipe{categories: ["Dinner"]})["recipeCategory"] == [
               "Dinner"
             ]

      payload = Recipe.to_mealie_payload(%Recipe{categories: nil})
      refute Map.has_key?(payload, "recipeCategory")
    end

    test "passes notes through and omits nil" do
      notes = [%{"title" => "n", "text" => "serve hot"}]
      assert Recipe.to_mealie_payload(%Recipe{notes: notes})["notes"] == notes

      payload = Recipe.to_mealie_payload(%Recipe{notes: nil})
      refute Map.has_key?(payload, "notes")
    end

    test "passes name and description through and omits nil" do
      assert Recipe.to_mealie_payload(%Recipe{name: "Soup", description: "warm"})["name"] ==
               "Soup"

      assert Recipe.to_mealie_payload(%Recipe{name: "Soup", description: "warm"})["description"] ==
               "warm"

      payload = Recipe.to_mealie_payload(%Recipe{name: nil, description: nil})
      refute Map.has_key?(payload, "name")
      refute Map.has_key?(payload, "description")
    end
  end

  describe "to_mealie_payload/1 — clean_yield edge cases" do
    test "empty-string yield emits 0 / 0 / \"\"" do
      payload = Recipe.to_mealie_payload(%Recipe{recipe_yield: ""})

      assert payload["recipeServings"] == 0
      assert payload["recipeYieldQuantity"] == 0
      assert payload["recipeYield"] == ""
    end

    test "nil yield emits 0 / 0 / \"\"" do
      payload = Recipe.to_mealie_payload(%Recipe{recipe_yield: nil})

      assert payload["recipeServings"] == 0
      assert payload["recipeYieldQuantity"] == 0
      assert payload["recipeYield"] == ""
    end

    test "fraction ('1/2 servings') yields servings 0.5" do
      payload = Recipe.to_mealie_payload(%Recipe{recipe_yield: "1/2 servings"})

      assert payload["recipeServings"] == 0.5
      assert payload["recipeYieldQuantity"] == 0
      assert payload["recipeYield"] == ""
    end

    test "decimal ('2.5 servings') yields servings 2.5" do
      payload = Recipe.to_mealie_payload(%Recipe{recipe_yield: "2.5 servings"})

      assert payload["recipeServings"] == 2.5
      assert payload["recipeYield"] == ""
    end

    test "whole-number float ('8.0') normalises to integer 8" do
      payload = Recipe.to_mealie_payload(%Recipe{recipe_yield: "8.0"})

      assert payload["recipeServings"] == 8
      assert is_integer(payload["recipeServings"])
    end

    test "bare number ('8') yields servings 8" do
      payload = Recipe.to_mealie_payload(%Recipe{recipe_yield: "8"})

      assert payload["recipeServings"] == 8
      assert payload["recipeYieldQuantity"] == 0
      assert payload["recipeYield"] == ""
    end

    test "servings-verb prefix without unit ('Makes about 8') yields servings 8" do
      payload = Recipe.to_mealie_payload(%Recipe{recipe_yield: "Makes about 8"})

      assert payload["recipeServings"] == 8
      assert payload["recipeYield"] == ""
    end

    test "'Servings of 4' yields servings 4" do
      payload = Recipe.to_mealie_payload(%Recipe{recipe_yield: "Servings of 4"})

      assert payload["recipeServings"] == 4
      assert payload["recipeYield"] == ""
    end

    test "unparseable text with special chars is preserved verbatim" do
      payload = Recipe.to_mealie_payload(%Recipe{recipe_yield: "approx. 8-10 people"})

      assert payload["recipeServings"] == 0
      assert payload["recipeYieldQuantity"] == 0
      assert payload["recipeYield"] == "approx. 8-10 people"
    end
  end

  describe "to_mealie_payload/1 — canonicalise_times edge cases" do
    test "'PT0H0M0S' renders as '0 minutes'" do
      assert Recipe.to_mealie_payload(%Recipe{total_time: "PT0H0M0S"})["totalTime"] == "0 minutes"
    end

    test "'PT0M' renders as '0 minutes'" do
      assert Recipe.to_mealie_payload(%Recipe{total_time: "PT0M"})["totalTime"] == "0 minutes"
    end

    test "empty-string time is dropped from the payload" do
      payload = Recipe.to_mealie_payload(%Recipe{total_time: ""})

      refute Map.has_key?(payload, "totalTime")
    end

    test "nil time is dropped from the payload" do
      payload = Recipe.to_mealie_payload(%Recipe{total_time: nil})

      refute Map.has_key?(payload, "totalTime")
    end

    test "human-readable time is preserved verbatim" do
      assert Recipe.to_mealie_payload(%Recipe{cook_time: "1 hour 20 minutes"})["cookTime"] ==
               "1 hour 20 minutes"
    end

    test "performTime is converted independently (never derived nor dropped unexpectedly)" do
      payload = Recipe.to_mealie_payload(%Recipe{perform_time: "PT1H30M"})

      assert payload["performTime"] == "1 hour 30 minutes"
    end
  end
end

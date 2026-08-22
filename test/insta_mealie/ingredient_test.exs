defmodule InstaMealie.IngredientTest do
  use ExUnit.Case, async: true

  alias InstaMealie.Ingredient
  alias InstaMealie.Ingredient.Ref

  describe "needs_review?/1 — unit-less ingredients (e.g. \"3 eggs\")" do
    test "resolves cleanly when food is resolved with high confidence" do
      ing = %Ingredient{
        quantity: 3,
        food: %Ref{name: "eggs", id: "food-eggs", confidence: 0.99},
        unit: %Ref{name: nil, id: nil, confidence: nil},
        status: :parsed
      }

      refute Ingredient.needs_review?(ing)
    end

    test "needs review when food is unresolved (no id)" do
      ing = %Ingredient{
        quantity: 3,
        food: %Ref{name: "eggs", id: nil, confidence: 0.99},
        unit: %Ref{name: nil, id: nil, confidence: nil},
        status: :parsed
      }

      assert Ingredient.needs_review?(ing)
    end

    test "needs review when food confidence is below the 0.85 threshold" do
      ing = %Ingredient{
        quantity: 3,
        food: %Ref{name: "eggs", id: "food-eggs", confidence: 0.5},
        unit: %Ref{name: nil, id: nil, confidence: nil},
        status: :parsed
      }

      assert Ingredient.needs_review?(ing)
    end

    test "treats a blank-string unit.name the same as a missing unit" do
      ing = %Ingredient{
        quantity: 3,
        food: %Ref{name: "eggs", id: "food-eggs", confidence: 0.99},
        unit: %Ref{name: "   ", id: nil, confidence: nil},
        status: :parsed
      }

      refute Ingredient.needs_review?(ing)
    end
  end

  describe "needs_review?/1 — ingredients that do have a unit" do
    test "resolves cleanly when both food and unit are resolved with high confidence" do
      ing = %Ingredient{
        quantity: 1,
        food: %Ref{name: "rolled oats", id: "food-oats", confidence: 0.97},
        unit: %Ref{name: "cup", id: "unit-cup", confidence: 0.98},
        status: :parsed
      }

      refute Ingredient.needs_review?(ing)
    end

    test "needs review when the unit is present (has a name) but unresolved (no id)" do
      ing = %Ingredient{
        quantity: 1,
        food: %Ref{name: "rolled oats", id: "food-oats", confidence: 0.97},
        unit: %Ref{name: "cup", id: nil, confidence: 0.98},
        status: :parsed
      }

      assert Ingredient.needs_review?(ing)
    end

    test "needs review when the unit is present but its confidence is below 0.85" do
      ing = %Ingredient{
        quantity: 1,
        food: %Ref{name: "rolled oats", id: "food-oats", confidence: 0.97},
        unit: %Ref{name: "cup", id: "unit-cup", confidence: 0.5},
        status: :parsed
      }

      assert Ingredient.needs_review?(ing)
    end
  end

  describe "to_prompt_string/1 — parsed ingredients with a parser-supplied note" do
    test "renders the structured quantity/unit/food join, NOT the note (regression: status must gate the raw-note fallback)" do
      # The Mealie parser emits a per-ingredient "note" (e.g. "sifted",
      # "room temperature") even when it has fully classified the line.
      # `to_prompt_string/1` must NOT treat a populated note as a signal to
      # skip the structured join — that would silently drop quantity/unit/food
      # from the `llm_merge` prompt projection.
      ing = %Ingredient{
        quantity: 2,
        food: %Ref{name: "flour", id: "food-flour", confidence: 0.97},
        unit: %Ref{name: "cup", id: "unit-cup", confidence: 0.98},
        note: "sifted",
        raw: "2 cups flour, sifted",
        status: :parsed
      }

      assert Ingredient.to_prompt_string(ing) == "2 cup flour"
    end

    test "renders the structured join when status is :needs_review even with a non-empty note" do
      ing = %Ingredient{
        quantity: 1,
        food: %Ref{name: "butter", id: nil, confidence: 0.5},
        unit: %Ref{name: "cup", id: "unit-cup", confidence: 0.9},
        note: "room temperature",
        status: :needs_review
      }

      assert Ingredient.to_prompt_string(ing) == "1 cup butter"
    end

    test "renders the structured join when status is :resolved even with a non-empty note" do
      ing = %Ingredient{
        quantity: 3,
        food: %Ref{name: "eggs", id: "food-eggs", confidence: nil},
        unit: %Ref{name: nil, id: nil, confidence: nil},
        note: "large",
        status: :resolved
      }

      assert Ingredient.to_prompt_string(ing) == "3 eggs"
    end
  end

  describe "to_prompt_string/1 — :unparsed ingredients" do
    test "renders the raw note text as-is when status is :unparsed" do
      ing = %Ingredient{
        note: "a pinch of something the parser refused to classify",
        raw: "a pinch of something the parser refused to classify",
        status: :unparsed
      }

      assert Ingredient.to_prompt_string(ing) ==
               "a pinch of something the parser refused to classify"
    end

    test "renders the empty string when an :unparsed ingredient has no note" do
      ing = %Ingredient{status: :unparsed}

      assert Ingredient.to_prompt_string(ing) == ""
    end
  end

  describe "from_raw/1" do
    test "builds an unparsed ingredient from a binary, mirroring raw into note" do
      assert Ingredient.from_raw("2 cups flour") == %Ingredient{
               note: "2 cups flour",
               raw: "2 cups flour",
               status: :unparsed
             }
    end

    test "stringifies a non-binary term (atom) into note and raw" do
      assert Ingredient.from_raw(:foo) == %Ingredient{
               note: "foo",
               raw: "foo",
               status: :unparsed
             }
    end

    test "stringifies an integer into note and raw" do
      assert Ingredient.from_raw(42) == %Ingredient{note: "42", raw: "42", status: :unparsed}
    end
  end

  describe "from_parsed_map/1" do
    test "builds a parsed ingredient from a fully string-keyed map" do
      map = %{
        "quantity" => 2,
        "food" => "flour",
        "food_id" => "food-flour",
        "food_confidence" => 0.97,
        "unit" => "cup",
        "unit_id" => "unit-cup",
        "unit_confidence" => 0.98,
        "note" => "sifted",
        "raw" => "2 cups flour, sifted",
        "average_confidence" => 0.97
      }

      assert Ingredient.from_parsed_map(map) == %Ingredient{
               quantity: 2,
               food: %Ref{name: "flour", id: "food-flour", confidence: 0.97},
               unit: %Ref{name: "cup", id: "unit-cup", confidence: 0.98},
               note: "sifted",
               raw: "2 cups flour, sifted",
               average_confidence: 0.97,
               status: :parsed
             }
    end

    test "builds a parsed ingredient from an atom-keyed map" do
      map = %{
        quantity: 3,
        food: "eggs",
        food_id: "food-eggs",
        food_confidence: 0.99,
        unit: "count",
        unit_id: "unit-count",
        unit_confidence: 0.95,
        note: "large",
        raw: "3 large eggs",
        average_confidence: 0.97
      }

      assert Ingredient.from_parsed_map(map) == %Ingredient{
               quantity: 3,
               food: %Ref{name: "eggs", id: "food-eggs", confidence: 0.99},
               unit: %Ref{name: "count", id: "unit-count", confidence: 0.95},
               note: "large",
               raw: "3 large eggs",
               average_confidence: 0.97,
               status: :parsed
             }
    end

    test "prefers the string key when a map has both string and atom keys" do
      map = %{"food" => "string-flour", food: "atom-flour"}

      assert Ingredient.from_parsed_map(map).food == %Ref{name: "string-flour"}
    end

    test "falls back to note for raw when the raw key is absent" do
      map = %{"food" => "flour", "note" => "2 cups flour"}

      assert Ingredient.from_parsed_map(map) == %Ingredient{
               food: %Ref{name: "flour"},
               note: "2 cups flour",
               raw: "2 cups flour",
               status: :parsed
             }
    end

    test "defaults missing fields to nil and preserves status :parsed" do
      assert Ingredient.from_parsed_map(%{}) == %Ingredient{status: :parsed}
    end
  end

  describe "from_value/1" do
    test "treats a binary as a raw ingredient" do
      assert Ingredient.from_value("2 cups flour") == Ingredient.from_raw("2 cups flour")
    end

    test "treats a map as parsed parser output" do
      map = %{"food" => "flour", "note" => "2 cups flour"}

      assert Ingredient.from_value(map) == Ingredient.from_parsed_map(map)
    end

    test "coerces an integer through to_string as a raw ingredient" do
      assert Ingredient.from_value(42) == Ingredient.from_raw(42)
    end
  end

  describe "from_list/1" do
    test "maps a mixed list of strings and maps into ingredients" do
      result = Ingredient.from_list(["2 cups flour", %{"food" => "eggs", "note" => "3 eggs"}])

      assert length(result) == 2

      assert Enum.at(result, 0) == %Ingredient{
               note: "2 cups flour",
               raw: "2 cups flour",
               status: :unparsed
             }

      assert Enum.at(result, 1) == %Ingredient{
               food: %Ref{name: "eggs"},
               note: "3 eggs",
               raw: "3 eggs",
               status: :parsed
             }
    end

    test "returns an empty list for an empty list" do
      assert Ingredient.from_list([]) == []
    end
  end

  describe "apply_parse/2" do
    test "applies parser results to ingredients of equal count" do
      ingredients = [
        %Ingredient{note: "2 cups flour", raw: "2 cups flour", status: :unparsed},
        %Ingredient{note: "3 eggs", raw: "3 eggs", status: :unparsed}
      ]

      parsed = [
        %{
          "quantity" => 2,
          "food" => "flour",
          "food_id" => "food-flour",
          "food_confidence" => 0.97,
          "unit" => "cup",
          "unit_id" => "unit-cup",
          "unit_confidence" => 0.98,
          "average_confidence" => 0.97
        },
        %{
          "quantity" => 3,
          "food" => "eggs",
          "food_id" => "food-eggs",
          "food_confidence" => 0.99,
          "average_confidence" => 0.99
        }
      ]

      [first, second] = Ingredient.apply_parse(ingredients, parsed)

      assert first == %Ingredient{
               quantity: 2,
               food: %Ref{name: "flour", id: "food-flour", confidence: 0.97},
               unit: %Ref{name: "cup", id: "unit-cup", confidence: 0.98},
               note: nil,
               raw: "2 cups flour",
               index: 0,
               average_confidence: 0.97,
               status: :parsed
             }

      assert second.status == :parsed
      assert second.index == 1
      assert second.raw == "3 eggs"
    end

    test "leaves trailing ingredients unchanged but indexed when parser returns fewer entries" do
      ingredients = [
        %Ingredient{note: "2 cups flour", status: :unparsed},
        %Ingredient{note: "3 eggs", status: :unparsed}
      ]

      parsed = [
        %{
          "quantity" => 2,
          "food" => "flour",
          "food_id" => "food-flour",
          "food_confidence" => 0.97,
          "average_confidence" => 0.97
        }
      ]

      [first, second] = Ingredient.apply_parse(ingredients, parsed)

      assert first.status == :parsed
      assert first.index == 0

      # trailing ingredient is left unchanged except for its index
      assert second == %Ingredient{note: "3 eggs", status: :unparsed, index: 1}
    end

    test "drops extra parsed entries when parser returns more than ingredients" do
      ingredients = [%Ingredient{note: "2 cups flour", status: :unparsed}]

      parsed = [
        %{"food" => "flour", "food_id" => "food-flour", "food_confidence" => 0.97},
        %{"food" => "eggs", "food_id" => "food-eggs", "food_confidence" => 0.99}
      ]

      assert length(Ingredient.apply_parse(ingredients, parsed)) == 1
    end

    test "marks :needs_review when food confidence is below the 0.85 threshold" do
      ingredients = [%Ingredient{note: "2 cups flour", status: :unparsed}]

      parsed = [
        %{
          "quantity" => 2,
          "food" => "flour",
          "food_id" => "food-flour",
          "food_confidence" => 0.5,
          "unit" => "cup",
          "unit_id" => "unit-cup",
          "unit_confidence" => 0.98,
          "average_confidence" => 0.5
        }
      ]

      assert [ing] = Ingredient.apply_parse(ingredients, parsed)
      assert ing.status == :needs_review
    end

    test "marks :needs_review when a present unit is unresolved" do
      ingredients = [%Ingredient{note: "1 cup oats", status: :unparsed}]

      parsed = [
        %{
          "quantity" => 1,
          "food" => "oats",
          "food_id" => "food-oats",
          "food_confidence" => 0.97,
          "unit" => "cup",
          "unit_confidence" => 0.98,
          "average_confidence" => 0.97
        }
      ]

      assert [ing] = Ingredient.apply_parse(ingredients, parsed)
      assert ing.status == :needs_review
    end
  end

  describe "apply_resolutions/2" do
    test "applies a resolution keyed by integer index" do
      ing = %Ingredient{
        food: %Ref{name: "flour", id: nil, confidence: 0.5},
        unit: %Ref{name: "cup", id: nil, confidence: 0.5},
        status: :needs_review
      }

      resolutions = %{0 => %{"food" => "all-purpose flour", "unit" => "cup"}}

      assert [resolved] = Ingredient.apply_resolutions([ing], resolutions)

      assert resolved == %Ingredient{
               food: %Ref{name: "all-purpose flour", id: nil},
               unit: %Ref{name: "cup", id: nil},
               status: :resolved
             }
    end

    test "applies a resolution keyed by string index" do
      ing = %Ingredient{status: :needs_review}

      resolutions = %{"0" => %{"food" => "flour", "unit" => "cup"}}

      assert [resolved] = Ingredient.apply_resolutions([ing], resolutions)
      assert resolved.status == :resolved
      assert resolved.food.name == "flour"
      assert resolved.unit.name == "cup"
    end

    test "leaves ingredients without a matching resolution unchanged" do
      ing = %Ingredient{status: :needs_review}

      resolutions = %{1 => %{"food" => "flour", "unit" => "cup"}}

      assert [out] = Ingredient.apply_resolutions([ing], resolutions)
      assert out == ing
    end

    test "clears the unit when the resolution unit is an empty string" do
      ing = %Ingredient{status: :needs_review}

      resolutions = %{0 => %{"food" => "flour", "unit" => ""}}

      assert [resolved] = Ingredient.apply_resolutions([ing], resolutions)
      assert resolved.unit.name == nil
      assert resolved.status == :resolved
    end

    test "preserves food_id when the resolution food name matches the existing food" do
      ing = %Ingredient{
        food: %Ref{name: "flour", id: "food-flour", confidence: 0.5},
        status: :needs_review
      }

      resolutions = %{0 => %{"food" => "flour", "unit" => "cup"}}

      assert [resolved] = Ingredient.apply_resolutions([ing], resolutions)
      assert resolved.food.id == "food-flour"
    end

    test "drops food_id when the resolution food name differs from the existing food" do
      ing = %Ingredient{
        food: %Ref{name: "flour", id: "food-flour", confidence: 0.5},
        status: :needs_review
      }

      resolutions = %{0 => %{"food" => "all-purpose flour", "unit" => "cup"}}

      assert [resolved] = Ingredient.apply_resolutions([ing], resolutions)
      assert resolved.food.id == nil
    end
  end

  describe "confidence_band/1" do
    test "returns :high when food and unit are both resolved with high confidence" do
      ing = %Ingredient{
        food: %Ref{name: "flour", id: "food-flour", confidence: 0.97},
        unit: %Ref{name: "cup", id: "unit-cup", confidence: 0.98}
      }

      assert Ingredient.confidence_band(ing) == :high
    end

    test "returns :medium when only a medium-confidence food and no unit are present" do
      ing = %Ingredient{
        food: %Ref{name: "eggs", id: "food-eggs", confidence: 0.9},
        unit: %Ref{name: nil}
      }

      assert Ingredient.confidence_band(ing) == :medium
    end

    test "returns :low when food confidence is below 0.85 even with a high-confidence unit" do
      ing = %Ingredient{
        food: %Ref{name: "flour", id: "food-flour", confidence: 0.5},
        unit: %Ref{name: "cup", id: "unit-cup", confidence: 0.98}
      }

      assert Ingredient.confidence_band(ing) == :low
    end

    test "returns :unknown when there is no id or confidence and no unit" do
      ing = %Ingredient{
        food: %Ref{name: "flour", id: nil, confidence: nil},
        unit: %Ref{name: nil}
      }

      assert Ingredient.confidence_band(ing) == :unknown
    end

    test "treats an unknown unit present in the ingredient as the worst band" do
      ing = %Ingredient{
        food: %Ref{name: "flour", id: "food-flour", confidence: 0.97},
        unit: %Ref{name: "cup", id: nil, confidence: nil}
      }

      assert Ingredient.confidence_band(ing) == :unknown
    end

    test "returns :low when a high-confidence food pairs with an unresolvable unit that has confidence but no id" do
      ing = %Ingredient{
        food: %Ref{name: "flour", id: "food-flour", confidence: 0.97},
        unit: %Ref{name: "cup", id: nil, confidence: 0.98}
      }

      assert Ingredient.confidence_band(ing) == :low
    end
  end

  describe "to_payload/1" do
    test "projects a fully-populated ingredient including food, unit, note and originalText" do
      ing = %Ingredient{
        quantity: 2,
        food: %Ref{name: "flour", id: "food-flour"},
        unit: %Ref{name: "cup", id: "unit-cup"},
        note: "sifted",
        raw: "2 cups flour, sifted"
      }

      assert Ingredient.to_payload(ing) == %{
               "quantity" => 2,
               "food" => %{"id" => "food-flour", "name" => "flour"},
               "unit" => %{"id" => "unit-cup", "name" => "cup"},
               "note" => "sifted",
               "originalText" => "2 cups flour, sifted"
             }
    end

    test "omits food and unit when they have no id" do
      ing = %Ingredient{
        quantity: 2,
        food: %Ref{name: "flour", id: nil},
        unit: %Ref{name: "cup", id: nil},
        raw: "2 cups flour"
      }

      payload = Ingredient.to_payload(ing)

      refute Map.has_key?(payload, "food")
      refute Map.has_key?(payload, "unit")
      assert payload["quantity"] == 2
      assert payload["originalText"] == "2 cups flour"
    end

    test "omits quantity when nil" do
      ing = %Ingredient{
        food: %Ref{name: "flour", id: "food-flour"},
        unit: %Ref{name: "cup", id: "unit-cup"},
        raw: "2 cups flour"
      }

      payload = Ingredient.to_payload(ing)
      refute Map.has_key?(payload, "quantity")
    end

    test "omits note when empty string" do
      ing = %Ingredient{
        food: %Ref{name: "flour", id: "food-flour"},
        unit: %Ref{name: "cup", id: "unit-cup"},
        note: "",
        raw: "2 cups flour"
      }

      payload = Ingredient.to_payload(ing)
      refute Map.has_key?(payload, "note")
      assert payload["originalText"] == "2 cups flour"
    end

    test "uses raw for originalText" do
      ing = %Ingredient{
        food: %Ref{name: "flour", id: "food-flour"},
        unit: %Ref{name: "cup", id: "unit-cup"},
        note: "sifted",
        raw: "2 cups flour"
      }

      assert Ingredient.to_payload(ing)["originalText"] == "2 cups flour"
    end

    test "falls back to note for originalText when raw is nil" do
      ing = %Ingredient{
        food: %Ref{name: "flour", id: "food-flour"},
        unit: %Ref{name: "cup", id: "unit-cup"},
        note: "2 cups flour",
        raw: nil
      }

      assert Ingredient.to_payload(ing)["originalText"] == "2 cups flour"
    end
  end

  describe "to_payload_list/1" do
    test "projects a list of ingredients into payload maps" do
      ings = [
        %Ingredient{food: %Ref{name: "flour", id: "food-flour"}, raw: "2 cups flour"},
        %Ingredient{food: %Ref{name: "eggs", id: "food-eggs"}, raw: "3 eggs"}
      ]

      assert Ingredient.to_payload_list(ings) ==
               [
                 %{
                   "food" => %{"id" => "food-flour", "name" => "flour"},
                   "originalText" => "2 cups flour"
                 },
                 %{"food" => %{"id" => "food-eggs", "name" => "eggs"}, "originalText" => "3 eggs"}
               ]
    end

    test "returns an empty list for an empty list" do
      assert Ingredient.to_payload_list([]) == []
    end
  end

  describe "to_prompt_string_list/1" do
    test "maps a mixed list of ingredients to prompt strings" do
      ings = [
        %Ingredient{note: "unparsed line", raw: "unparsed line", status: :unparsed},
        %Ingredient{
          quantity: 2,
          food: %Ref{name: "flour", id: "food-flour"},
          unit: %Ref{name: "cup", id: "unit-cup"},
          status: :parsed
        }
      ]

      assert Ingredient.to_prompt_string_list(ings) == ["unparsed line", "2 cup flour"]
    end
  end

  describe "Ref.resolved?/1" do
    test "returns true when the ref has a binary id" do
      assert Ref.resolved?(%Ref{id: "food-flour"})
    end

    test "returns false when the ref has no id" do
      refute Ref.resolved?(%Ref{id: nil})
    end
  end
end

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
end

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
end

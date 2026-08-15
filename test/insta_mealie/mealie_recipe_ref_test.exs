defmodule InstaMealie.Mealie.RecipeRefTest do
  use ExUnit.Case, async: true

  alias InstaMealie.Mealie.RecipeRef

  describe "from_result/1 — string-key input (Mealie JSON shape)" do
    test "builds a RecipeRef from a map with string keys" do
      result = %{"slug" => "foo", "name" => "Foo"}

      assert {:ok, %RecipeRef{slug: "foo", name: "Foo"}} = RecipeRef.from_result(result)
    end
  end

  describe "from_result/1 — atom-key input (internal Elixir shape)" do
    test "builds a RecipeRef from a map with atom keys" do
      result = %{slug: "foo", name: "Foo"}

      assert {:ok, %RecipeRef{slug: "foo", name: "Foo"}} = RecipeRef.from_result(result)
    end
  end

  describe "from_result/1 — slug is required" do
    test "returns :error when slug is missing (string keys)" do
      result = %{"name" => "Foo"}

      assert RecipeRef.from_result(result) == :error
    end

    test "returns :error when slug is missing (atom keys)" do
      result = %{name: "Foo"}

      assert RecipeRef.from_result(result) == :error
    end

    test "returns :error from an empty map" do
      assert RecipeRef.from_result(%{}) == :error
    end
  end

  describe "from_result/1 — name is optional" do
    test "builds a RecipeRef with name: nil when name key is absent (string keys)" do
      result = %{"slug" => "foo"}

      assert {:ok, %RecipeRef{slug: "foo", name: nil}} = RecipeRef.from_result(result)
    end

    test "builds a RecipeRef with name: nil when name key is absent (atom keys)" do
      result = %{slug: "foo"}

      assert {:ok, %RecipeRef{slug: "foo", name: nil}} = RecipeRef.from_result(result)
    end

    test "builds a RecipeRef with name: nil when name is explicit nil (string keys)" do
      result = %{"slug" => "foo", "name" => nil}

      assert {:ok, %RecipeRef{slug: "foo", name: nil}} = RecipeRef.from_result(result)
    end

    test "builds a RecipeRef with name: nil when name is explicit nil (atom keys)" do
      result = %{slug: "foo", name: nil}

      assert {:ok, %RecipeRef{slug: "foo", name: nil}} = RecipeRef.from_result(result)
    end
  end
end

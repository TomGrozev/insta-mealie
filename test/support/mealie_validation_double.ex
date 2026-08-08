defmodule InstaMealie.Test.MealieValidationDouble do
  @moduledoc "Test double: create_recipe fails with a validation error so the UI renders a dead row."
  @behaviour InstaMealie.Mealie

  @impl true
  def create_recipe(_recipe), do: {:error, :validation, "mealie rejected the recipe"}
  @impl true
  def update_recipe(slug, _recipe), do: {:ok, slug}
  @impl true
  def deep_link(slug) do
    base = Application.get_env(:insta_mealie, :mealie, [])[:base_url] || "http://localhost:9000"
    group = Application.get_env(:insta_mealie, :mealie, [])[:group_slug] || "home"
    "#{base}/g/#{group}/r/#{slug}?edit=true"
  end

  @impl true
  def search_foods(_term), do: {:ok, []}
  @impl true
  def search_units(_term), do: {:ok, []}

  @impl true
  def parse_ingredients(list) when is_list(list) do
    parsed =
      Enum.map(list, fn text ->
        %{
          "quantity" => nil,
          "unit" => nil,
          "unit_id" => nil,
          "food" => text,
          "food_id" => "stub-" <> text,
          "food_confidence" => 1.0,
          "note" => nil
        }
      end)

    {:ok, parsed}
  end
end

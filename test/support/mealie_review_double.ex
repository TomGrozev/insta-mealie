defmodule InstaMealie.Test.MealieReviewDouble do
  @moduledoc "Test double: parse_ingredients returns one unknown ingredient so the review screen is triggered."
  @behaviour InstaMealie.Mealie

  @impl true
  def create_recipe(_recipe), do: {:ok, "review-slug"}
  @impl true
  def update_recipe(slug, _recipe), do: {:ok, slug}

  @impl true
  def deep_link(slug) do
    base = Application.get_env(:insta_mealie, :mealie, [])[:base_url] || "http://localhost:9000"
    group = Application.get_env(:insta_mealie, :mealie, [])[:group_slug] || "home"
    "#{base}/g/#{group}/r/#{slug}?edit=true"
  end

  @impl true
  def search_foods(_term), do: {:ok, ["mystery-spice", "paprika", "cumin"]}
  @impl true
  def search_units(_term), do: {:ok, ["cups", "tbsp"]}

  @impl true
  def parse_ingredients(list) when is_list(list) do
    parsed =
      list
      |> Enum.with_index()
      |> Enum.map(fn {text, i} ->
        if i == 0 do
          %{
            "quantity" => 3,
            "unit" => "cups",
            "unit_id" => "unit-cups",
            "food" => "mystery-spice",
            "food_id" => nil,
            "food_confidence" => 0.3,
            "note" => nil
          }
        else
          %{
            "quantity" => nil,
            "unit" => nil,
            "unit_id" => "unit-1",
            "food" => text,
            "food_id" => "food-#{i}",
            "food_confidence" => 1.0,
            "note" => nil
          }
        end
      end)

    {:ok, parsed}
  end
end

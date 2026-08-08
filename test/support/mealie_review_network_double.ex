defmodule InstaMealie.Test.MealieReviewNetworkDouble do
  @moduledoc "Test double: same as ReviewDouble but create_recipe fails with a network error."
  @behaviour InstaMealie.Mealie

  @impl true
  def create_recipe(_recipe), do: {:error, :network, "down"}
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
      |> Enum.map(fn {_text, i} ->
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
            "food" => "known-ingredient",
            "food_id" => "food-1",
            "food_confidence" => 1.0,
            "note" => nil
          }
        end
      end)

    {:ok, parsed}
  end
end

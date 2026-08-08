defmodule InstaMealie.MealieStub do
  @moduledoc "In-memory Mealie stub. Returns canned slugs/links; never touches the network."
  @behaviour InstaMealie.Mealie

  @impl true
  def create_recipe(_recipe) do
    slug = "homemade-granola-" <> (:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower))
    {:ok, slug}
  end

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
      Enum.map(list, fn ingredient ->
        %{
          "quantity" => nil,
          "unit" => nil,
          "unit_id" => nil,
          "food" => ingredient,
          "food_id" => "stub-#{ingredient}",
          "food_confidence" => 1.0,
          "note" => nil
        }
      end)

    {:ok, parsed}
  end
end

defmodule InstaMealie.LlmStub do
  @moduledoc "Canned LLM stub. Defaults to a recipe_complete envelope."
  @behaviour InstaMealie.Llm

  @default_recipe %{
    "name" => "Homemade Granola",
    "description" => "A simple oven-toasted granola.",
    "recipeYield" => "8 servings",
    "recipeIngredient" => [
      "3 cups rolled oats",
      "1 cup raw almonds",
      "1/2 cup maple syrup",
      "1/3 cup coconut oil",
      "1 tsp salt"
    ],
    "recipeInstructions" => [
      %{"title" => "Mix", "text" => "Combine oats, almonds, syrup, oil, and salt."},
      %{"title" => "Bake", "text" => "Bake at 160C for 40 minutes, stirring halfway."}
    ],
    "tags" => ["breakfast", "make-ahead"]
  }

  @impl true
  def format(_caption, _opts) do
    {:ok,
     %{
       completeness: :recipe_complete,
       missing_fields: [],
       recipe: @default_recipe
     }}
  end

  @impl true
  def merge(_caption, _transcript, _opts) do
    {:ok,
     %{
       completeness: :recipe_complete,
       missing_fields: [],
       recipe: @default_recipe
     }}
  end
end

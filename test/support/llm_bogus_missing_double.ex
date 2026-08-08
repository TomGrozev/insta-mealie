defmodule InstaMealie.Test.LlmBogusMissingDouble do
  @moduledoc "Test double: format reports partial with an invalid missing field, to exercise vocab enforcement."
  @behaviour InstaMealie.Llm

  @impl true
  def format(_caption, _opts) do
    {:ok,
     %{
       completeness: :recipe_partial,
       missing_fields: ["recipeIngredient", "nope"],
       recipe: %{"name" => "P"}
     }}
  end

  @impl true
  def merge(_caption, _transcript, _opts) do
    {:ok, %{completeness: :recipe_complete, missing_fields: [], recipe: %{"name" => "M"}}}
  end
end

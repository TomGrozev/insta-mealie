defmodule InstaMealie.Test.LlmNoRecipeDouble do
  @moduledoc "Test double: format reports no_recipe (so the pipeline must transcribe + merge); merge returns a full recipe."
  @behaviour InstaMealie.Llm

  @impl true
  def format(_caption, _opts) do
    {:ok,
     %{
       completeness: :no_recipe,
       missing_fields: ["recipeIngredient", "recipeInstructions"],
       recipe: %{}
     }}
  end

  @impl true
  def merge(_caption, _transcript, _opts) do
    {:ok,
     %{
       completeness: :recipe_complete,
       missing_fields: [],
       recipe: %{"name" => "Transcribed Granola"}
     }}
  end
end

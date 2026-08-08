defmodule InstaMealie.Test.LlmPartialDouble do
  @moduledoc "Test double: format reports a partial recipe so the pipeline exercises transcribe + merge."
  @behaviour InstaMealie.Llm

  @impl true
  def format(_caption, _opts) do
    {:ok,
     %{
       completeness: :recipe_partial,
       missing_fields: ["recipeInstructions"],
       recipe: %{"name" => "Partial"}
     }}
  end

  @impl true
  def merge(_caption, _transcript, _opts) do
    {:ok, %{completeness: :recipe_complete, missing_fields: [], recipe: %{"name" => "Merged"}}}
  end
end

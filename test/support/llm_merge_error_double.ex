defmodule InstaMealie.Test.LlmMergeErrorDouble do
  @moduledoc "Test double: format reports partial (so the pipeline runs transcribe + merge) but merge fails with an api_error."
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
  def merge(_caption, _transcript, _opts), do: {:error, :api_error, "llm returned 500 on merge"}
end

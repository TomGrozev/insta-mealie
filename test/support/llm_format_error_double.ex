defmodule InstaMealie.Test.LlmFormatErrorDouble do
  @moduledoc "Test double: format fails with an api_error so the UI shows a retryable failure at the format stage."
  @behaviour InstaMealie.Llm

  @impl true
  def format(_caption, _opts), do: {:error, :api_error, "llm returned 500"}
  @impl true
  def merge(_caption, _transcript, _opts),
    do:
      {:ok, %{completeness: :recipe_complete, missing_fields: [], recipe: %{"name" => "Merged"}}}
end

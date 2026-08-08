defmodule InstaMealie.Llm do
  @moduledoc """
  Behaviour for the LLM routing/format/merge calls.

  The envelope returned by both calls is:
  `%{completeness: :recipe_complete | :recipe_partial | :no_recipe,
     missing_fields: [String.t()], recipe: map()}`
  """
  @type completeness :: :recipe_complete | :recipe_partial | :no_recipe
  @type envelope :: %{
          completeness: completeness,
          missing_fields: [String.t()],
          recipe: map()
        }

  @callback format(caption :: String.t(), opts :: keyword()) ::
              {:ok, envelope} | {:error, atom(), term()}
  @callback merge(caption :: String.t(), transcript :: String.t(), opts :: keyword()) ::
              {:ok, envelope} | {:error, atom(), term()}
end

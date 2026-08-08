defmodule InstaMealie.Llm do
  @moduledoc """
  Behaviour for the LLM routing/format/merge calls.

  The envelope returned by both calls is:
  `%{completeness: :recipe_complete | :recipe_partial | :no_recipe,
      missing_fields: list(),
      recipe: map()}`

  ## Routing verdict contract

  A single routing call (Prompt 1) returns the verdict plus a (possibly
  partial) recipe. `missing_fields` is limited to the vocabulary
  `[:recipeIngredient, :recipeInstructions]` — anything else is dropped by
  `normalize_envelope/1`.

  The guard against a *spurious* `recipe_complete` verdict lives in the
  prompt (Prompt 1 design, see ticket #8 / T4), **not** in the
  interpreter. The FSM therefore trusts the verdict flatly:
  `recipe_complete` skips transcription, while `recipe_partial` AND
  `no_recipe` both fire transcription + merge. `no_recipe` must never
  cause a fabricated recipe name — that invariant is the prompt's
  responsibility; the interpreter only forwards what it is given.
  """
  @type completeness :: :recipe_complete | :recipe_partial | :no_recipe
  @type envelope :: %{
          completeness: completeness,
          missing_fields: list(),
          recipe: map()
        }

  @allowed_missing_fields [:recipeIngredient, :recipeInstructions]

  @callback format(caption :: String.t(), opts :: keyword()) ::
              {:ok, envelope} | {:error, atom(), term()}
  @callback merge(caption :: String.t(), transcript :: String.t(), opts :: keyword()) ::
              {:ok, envelope} | {:error, atom(), term()}

  @doc """
  Coerce and sanitize an envelope returned by an adapter.

  - `completeness` is coerced from a string to its atom and must be one of
    the three known verdicts (otherwise an `ArgumentError` is raised).
  - `missing_fields` is filtered to `#{inspect(@allowed_missing_fields)}`,
    dropping any unknown field names and de-duplicating.
  - `recipe` must be a map; anything else becomes `%{}`.
  """
  def normalize_envelope(%{
        completeness: completeness,
        missing_fields: missing_fields,
        recipe: recipe
      }) do
    %{
      completeness: to_completeness(completeness),
      missing_fields: to_missing_fields(missing_fields),
      recipe: recipe_or_default(recipe)
    }
  end

  def normalize_envelope(other) when is_map(other) do
    completeness = Map.get(other, :completeness) || Map.get(other, "completeness")
    missing_fields = Map.get(other, :missing_fields) || Map.get(other, "missing_fields") || []
    recipe = Map.get(other, :recipe) || Map.get(other, "recipe")

    %{
      completeness: to_completeness(completeness),
      missing_fields: to_missing_fields(missing_fields),
      recipe: recipe_or_default(recipe)
    }
  end

  defp to_completeness(:recipe_complete), do: :recipe_complete
  defp to_completeness("recipe_complete"), do: :recipe_complete
  defp to_completeness(:recipe_partial), do: :recipe_partial
  defp to_completeness("recipe_partial"), do: :recipe_partial
  defp to_completeness(:no_recipe), do: :no_recipe
  defp to_completeness("no_recipe"), do: :no_recipe

  defp to_completeness(other),
    do: raise(ArgumentError, "invalid LLM completeness verdict: #{inspect(other)}")

  defp to_missing_fields(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      field when field in @allowed_missing_fields -> [field]
      "recipeIngredient" -> [:recipeIngredient]
      "recipeInstructions" -> [:recipeInstructions]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp to_missing_fields(_), do: []

  defp recipe_or_default(recipe) when is_map(recipe), do: recipe
  defp recipe_or_default(_), do: %{}
end

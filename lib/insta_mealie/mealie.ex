defmodule InstaMealie.Mealie do
  @moduledoc """
  Behaviour for pushing a recipe draft into a Mealie instance.

  Implemented by `InstaMealie.MealieStub` (no network) today, and later by a
  Req-backed real adapter. The create flow is POST /api/recipes with a name to
  obtain a slug, then PUT /api/recipes/{slug} with the full recipe.
  """
  @callback create_recipe(recipe :: map()) :: {:ok, String.t()} | {:error, atom(), term()}
  @callback update_recipe(slug :: String.t(), recipe :: map()) ::
              {:ok, String.t()} | {:error, atom(), term()}
  @callback deep_link(slug :: String.t()) :: String.t()
  @callback search_foods(term :: String.t()) :: {:ok, list()} | {:error, atom(), term()}
  @callback search_units(term :: String.t()) :: {:ok, list()} | {:error, atom(), term()}
end

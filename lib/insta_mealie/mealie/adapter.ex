defmodule InstaMealie.Mealie.Adapter do
  @moduledoc """
  Behaviour for the Mealie HTTP client.

  Each callback maps to a single Mealie API operation. The implementation
  module is resolved at call time via `Application.get_env`.
  """

  alias InstaMealie.Error
  alias InstaMealie.Recipe
  alias InstaMealie.Mealie.RecipeRef

  @type method :: :post | :patch | :delete | :get

  @doc "Create a new recipe in Mealie. Returns a RecipeRef on success."
  @callback create_recipe(String.t()) :: {:ok, RecipeRef.t()} | {:error, Error.t()}

  @doc "Update an existing recipe by slug."
  @callback patch_recipe(String.t(), Recipe.t()) :: {:ok, String.t()} | {:error, Error.t()}

  @doc "Delete a recipe by slug."
  @callback delete_recipe(String.t()) :: :ok | {:error, Error.t()}

  @doc "Search a Mealie collection (foods, units, recipes) by term."
  @callback search(String.t(), String.t()) :: {:ok, list()} | {:error, Error.t()}

  @doc "Parse a list of ingredient strings via Mealie's parser."
  @callback parse_ingredients([String.t()]) :: {:ok, [map()]} | {:error, Error.t()}

  @doc "Upload an image for a recipe."
  @callback upload_image(String.t(), String.t()) :: :ok | {:error, Error.t()}
end

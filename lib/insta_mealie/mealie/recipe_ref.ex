defmodule InstaMealie.Mealie.RecipeRef do
  @moduledoc "A reference to a Mealie recipe: its name and its slug."
  @enforce_keys [:slug]
  defstruct [:slug, :name]

  @type t :: %__MODULE__{slug: String.t(), name: String.t() | nil}

  @doc """
  Extract a recipe reference from a Mealie search result map.

  Returns `{:ok, %RecipeRef{}}` if a slug is present, or `:error` otherwise.
  Does NOT fall back to an id field — a slug is required per the domain glossary.
  """
  @spec from_result(map()) :: {:ok, t()} | :error
  def from_result(result) when is_map(result) do
    slug = Map.get(result, "slug") || Map.get(result, :slug)
    name = Map.get(result, "name") || Map.get(result, :name)

    if slug do
      {:ok, %__MODULE__{slug: slug, name: name}}
    else
      :error
    end
  end
end

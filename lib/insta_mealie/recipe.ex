defmodule InstaMealie.Recipe do
  @moduledoc """
  Canonical recipe representation used throughout the pipeline.

  `job.recipe` will hold a `%Recipe{}` after this conversion. Field names
  are Elixir snake_case; conversion to/from Mealie's camelCase strings is
  handled by `from_map/1` and `to_mealie_payload/1`.
  """

  alias InstaMealie.Ingredient

  @type t :: %__MODULE__{
          name: String.t() | nil,
          description: String.t() | nil,
          recipe_yield: String.t() | nil,
          ingredients: [Ingredient.t()],
          instructions: [map()],
          tags: [String.t()] | nil,
          categories: [String.t()] | nil,
          notes: list() | nil,
          total_time: String.t() | nil,
          prep_time: String.t() | nil,
          cook_time: String.t() | nil,
          perform_time: String.t() | nil,
          image: String.t() | nil
        }

  defstruct name: nil,
            description: nil,
            recipe_yield: nil,
            ingredients: [],
            instructions: [],
            tags: nil,
            categories: nil,
            notes: nil,
            total_time: nil,
            prep_time: nil,
            cook_time: nil,
            perform_time: nil,
            image: nil

  @payload_fields [
    {:name, "name"},
    {:description, "description"},
    {:recipe_yield, "recipeYield"},
    {:ingredients, "recipeIngredient"},
    {:instructions, "recipeInstructions"},
    {:tags, "tags"},
    {:categories, "categories"},
    {:notes, "notes"},
    {:total_time, "totalTime"},
    {:prep_time, "prepTime"},
    {:cook_time, "cookTime"},
    {:perform_time, "performTime"}
  ]

  @doc """
  Build a `%Recipe{}` from a string- or atom-keyed map. The map is expected
  to use Mealie's camelCase keys; the resulting struct uses snake_case
  Elixir field names. The `recipeIngredient` list is converted into
  `%Ingredient{}` structs via `Ingredient.from_list/1`.
  """
  @spec from_map(map()) :: t()
  def from_map(data) when is_map(data) do
    %__MODULE__{
      name: InstaMealie.Utils.map_get(data, "name"),
      description: InstaMealie.Utils.map_get(data, "description"),
      recipe_yield: InstaMealie.Utils.map_get(data, "recipeYield"),
      ingredients: (InstaMealie.Utils.map_get(data, "recipeIngredient") || []) |> Ingredient.from_list(),
      instructions: InstaMealie.Utils.map_get(data, "recipeInstructions") || [],
      tags: InstaMealie.Utils.map_get(data, "tags"),
      categories: InstaMealie.Utils.map_get(data, "categories"),
      notes: InstaMealie.Utils.map_get(data, "notes"),
      total_time: InstaMealie.Utils.map_get(data, "totalTime"),
      prep_time: InstaMealie.Utils.map_get(data, "prepTime"),
      cook_time: InstaMealie.Utils.map_get(data, "cookTime"),
      perform_time: InstaMealie.Utils.map_get(data, "performTime")
    }
  end

  @doc """
  Project a `%Recipe{}` into the string-keyed map Mealie's PUT expects.

  Output keys mirror the old `InstaMealie.Mealie.build_payload/1` output;
  `nil` values are dropped. The `:ingredients` list is rendered through
  `Ingredient.to_payload_list/1`.
  """
  @spec to_mealie_payload(t()) :: map()
  def to_mealie_payload(%__MODULE__{} = recipe) do
    Enum.reduce(@payload_fields, %{}, fn {field, key}, acc ->
      value =
        case {field, Map.get(recipe, field)} do
          {:ingredients, list} when is_list(list) -> Ingredient.to_payload_list(list)
          {:tags, list} when is_list(list) -> list
          {:instructions, list} when is_list(list) ->
            Enum.map(list, fn
              inst when is_map(inst) -> Map.put_new(inst, "type", "RecipeInstruction")
              inst -> %{"text" => to_string(inst), "type" => "RecipeInstruction"}
            end)
          {_, v} -> v
        end

      if is_nil(value) do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  @doc """
  Validate a `%Recipe{}` for shape correctness. Returns `{:ok, recipe}` when
  valid, or `{:error, field_name}` naming the first offending field.

  Rules (strict-shape, lenient-presence):
  - `name`, `description`, `recipe_yield` — if present, must be strings
  - `ingredients` — must be a list (empty is OK)
  - `instructions` — must be a list of maps, each with a `"text"` key (string)
  - `total_time`, `prep_time`, `cook_time`, `perform_time` — if present, must be strings (or nil)
  - `tags`, `categories` — if present, must be lists
  - Unknown keys are already dropped by `from_map/1`, so we don't re-check that here.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, atom()}
  def validate(%__MODULE__{} = recipe) do
    with :ok <- validate_string(:name, recipe.name),
         :ok <- validate_string(:description, recipe.description),
         :ok <- validate_string(:recipe_yield, recipe.recipe_yield),
         :ok <- validate_list(:ingredients, recipe.ingredients),
         :ok <- validate_instructions(recipe.instructions),
         :ok <- validate_string(:total_time, recipe.total_time),
         :ok <- validate_string(:prep_time, recipe.prep_time),
         :ok <- validate_string(:cook_time, recipe.cook_time),
         :ok <- validate_string(:perform_time, recipe.perform_time),
         :ok <- validate_list(:tags, recipe.tags),
         :ok <- validate_list(:categories, recipe.categories) do
      {:ok, recipe}
    end
  end

  @doc """
  Returns an empty `%Recipe{}` — useful as a default before any field is
  populated.
  """
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc """
  Project a `%Recipe{}` into the shape the LLM merge prompt asks for.

  Identical to `to_mealie_payload/1` except the `"recipeIngredient"` key
  is replaced with a list of plain strings (via
  `Ingredient.to_prompt_string_list/1`). The merge prompt instructs the
  model that `recipeIngredient` is a list of strings, so we must not
  send the structured Mealie ingredient objects there.
  """
  @spec to_prompt_projection(t()) :: map()
  def to_prompt_projection(%__MODULE__{} = recipe) do
    recipe
    |> to_mealie_payload()
    |> Map.put("recipeIngredient", Ingredient.to_prompt_string_list(recipe.ingredients))
  end

  defp validate_string(_field, nil), do: :ok
  defp validate_string(_field, val) when is_binary(val), do: :ok
  defp validate_string(field, _val), do: {:error, field}

  defp validate_list(_field, nil), do: :ok
  defp validate_list(_field, val) when is_list(val), do: :ok
  defp validate_list(field, _val), do: {:error, field}

  defp validate_instructions(nil), do: :ok
  defp validate_instructions(list) when is_list(list) do
    Enum.reduce_while(list, :ok, fn
      inst, _acc when is_map(inst) ->
        text = Map.get(inst, "text") || Map.get(inst, :text)
        if is_binary(text), do: {:cont, :ok}, else: {:halt, {:error, :instructions}}
      _inst, _acc -> {:halt, {:error, :instructions}}
    end)
  end
  defp validate_instructions(_), do: {:error, :instructions}

end

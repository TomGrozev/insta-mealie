defmodule InstaMealie.Ingredient do
  @moduledoc """
  Canonical ingredient representation used throughout the pipeline.

  A `%Ingredient{}` can hold a fully parsed ingredient — quantity, unit, food
  name, Mealie ids, and the parser's per-field confidence — or just a raw,
  unparsed note. Unparsed lines (e.g. ones the Mealie parser could not
  classify) are stored as `%Ingredient{note: raw_string}` with every other
  field left as `nil`.
  """

  @type status :: :unparsed | :parsed | :needs_review | :resolved

  @type t :: %__MODULE__{
          quantity: number() | String.t() | nil,
          unit: String.t() | nil,
          unit_id: String.t() | nil,
          food: String.t() | nil,
          food_id: String.t() | nil,
          food_confidence: float() | nil,
          unit_confidence: float() | nil,
          note: String.t() | nil,
          index: non_neg_integer() | nil,
          raw: String.t() | nil,
          status: status()
        }

  defstruct quantity: nil,
            unit: nil,
            unit_id: nil,
            food: nil,
            food_id: nil,
            food_confidence: nil,
            unit_confidence: nil,
            note: nil,
            index: nil,
            raw: nil,
            status: :unparsed

  @doc """
  Build an unparsed `%Ingredient{}` from a raw string. Non-binary terms are
  stringified via `to_string/1` before being placed in the `:note` and `:raw`
  fields. The ingredient's `:status` is `:unparsed`.
  """
  @spec from_raw(term()) :: t()
  def from_raw(raw) when is_binary(raw), do: %__MODULE__{note: raw, raw: raw, status: :unparsed}
  def from_raw(raw), do: %__MODULE__{note: to_string(raw), raw: to_string(raw), status: :unparsed}

  @doc """
  Build a parsed `%Ingredient{}` from a string- or atom-keyed map (parser
  output). Missing fields stay `nil`. The `:raw` field is populated from the
  parser's `"raw"` key when present, otherwise from the `"note"` key (the
  parser often returns the source line in `note`). The ingredient's `:status`
  is `:parsed`.
  """
  @spec from_parsed_map(map()) :: t()
  def from_parsed_map(map) when is_map(map) do
    %__MODULE__{
      quantity: get(map, "quantity"),
      unit: get(map, "unit"),
      unit_id: get(map, "unit_id"),
      food: get(map, "food"),
      food_id: get(map, "food_id"),
      food_confidence: get(map, "food_confidence"),
      unit_confidence: get(map, "unit_confidence"),
      note: get(map, "note"),
      raw: get(map, "raw") || get(map, "note"),
      status: :parsed
    }
  end

  @doc """
  Build a `%Ingredient{}` from any term. Binaries are treated as raw
  ingredient lines, maps as parsed parser output, and anything else is
  coerced through `to_string/1` and treated as raw.
  """
  @spec from_value(term()) :: t()
  def from_value(term) when is_binary(term), do: from_raw(term)
  def from_value(term) when is_map(term), do: from_parsed_map(term)
  def from_value(term), do: from_raw(term)

  @doc """
  Build a list of `%Ingredient{}` from a list of raw strings, parsed maps,
  or a mix of both.
  """
  @spec from_list(list()) :: [t()]
  def from_list(list) when is_list(list), do: Enum.map(list, &from_value/1)

  @doc """
  Apply Mealie parser results to a list of ingredients, setting each
  ingredient's status to `:parsed` when the parser is confident about both
  food and unit, or `:needs_review` when either is uncertain. The `:raw`
  field is preserved (only filled in if currently nil, falling back to the
  ingredient's `:note`) and the `:index` field is set to the ingredient's
  position in the list.

  Options:
  - `:food_threshold` (default `0.85`) — minimum food confidence required
    to mark an ingredient `:parsed`.
  - `:unit_threshold` (default `0.85`) — minimum unit confidence required
    to mark an ingredient `:parsed`.

  If the parser returns fewer entries than there are ingredients, the
  trailing ingredients are left unchanged. If the parser returns more
  entries, the extras are dropped.
  """
  @spec apply_parse([t()], [map()], keyword()) :: [t()]
  def apply_parse(ingredients, parsed, opts \\ [])
      when is_list(ingredients) and is_list(parsed) do
    food_threshold = Keyword.get(opts, :food_threshold, 0.85)
    unit_threshold = Keyword.get(opts, :unit_threshold, 0.85)

    ingredients
    |> Enum.with_index()
    |> Enum.map(fn {ing, i} ->
      case Enum.at(parsed, i) do
        nil ->
          %{ing | index: i}

        p ->
          food_conf = Map.get(p, "food_confidence")
          food_id = Map.get(p, "food_id")
          unit_conf = Map.get(p, "unit_confidence")
          unit_id = Map.get(p, "unit_id")

          needs_review =
            food_conf == nil or food_conf < food_threshold or food_id == nil or
              unit_conf == nil or unit_conf < unit_threshold or unit_id == nil

          status = if needs_review, do: :needs_review, else: :parsed

          %{ing |
            index: i,
            raw: ing.raw || ing.note,
            quantity: p["quantity"],
            unit: p["unit"],
            unit_id: p["unit_id"],
            food: p["food"],
            food_id: p["food_id"],
            food_confidence: p["food_confidence"],
            unit_confidence: p["unit_confidence"],
            note: p["note"],
            status: status
          }
      end
    end)
  end

  @doc """
  Apply user resolutions from the review screen. For each index in
  `resolutions`, set the matching ingredient's food/unit/food_id/unit_id
  from the resolution map and mark it `:resolved`. Ingredients without a
  matching resolution are left unchanged.

  Resolutions may be keyed by integer or string index. A resolution of
  `%{"food" => "...", "unit" => ""}` is treated as "user picked a food and
  explicitly cleared the unit" — the unit is set to `nil`.
  """
  @spec apply_resolutions([t()], %{non_neg_integer() => map()} | map()) :: [t()]
  def apply_resolutions(ingredients, resolutions)
      when is_list(ingredients) and is_map(resolutions) do
    ingredients
    |> Enum.with_index()
    |> Enum.map(fn {ing, i} ->
      case Map.get(resolutions, i) || Map.get(resolutions, to_string(i)) do
        nil ->
          ing

        %{"food" => food, "unit" => unit} = res ->
          %{ing |
            food: food,
            food_id: res["food_id"],
            unit: if(unit && unit != "", do: unit),
            unit_id: res["unit_id"],
            status: :resolved
          }

        _ ->
          ing
      end
    end)
  end

  @doc """
  Project a `%Ingredient{}` into the string-keyed map Mealie's PUT expects.

  `food` and `unit` are emitted as nested objects with `id` and `name` keys
  (matching Mealie's Pydantic model) — only `id` when both are known, only
  `name` when name-only, and the whole key is omitted when neither. `note`
  and the original ingredient line (`originalText`) are included when
  non-nil. Flat `food_id` / `unit_id` keys are intentionally NOT emitted:
  Mealie's Pydantic model silently discards them.
  """
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = ing) do
    payload = %{}

    payload =
      if not is_nil(ing.quantity), do: Map.put(payload, "quantity", ing.quantity), else: payload

    food =
      cond do
        ing.food_id && ing.food -> %{"id" => ing.food_id, "name" => ing.food}
        ing.food -> %{"name" => ing.food}
        true -> nil
      end

    payload = if food, do: Map.put(payload, "food", food), else: payload

    unit =
      cond do
        ing.unit_id && ing.unit -> %{"id" => ing.unit_id, "name" => ing.unit}
        ing.unit -> %{"name" => ing.unit}
        true -> nil
      end

    payload = if unit, do: Map.put(payload, "unit", unit), else: payload

    payload =
      if not is_nil(ing.note) and ing.note != "",
        do: Map.put(payload, "note", ing.note),
        else: payload

    original_text = ing.raw || ing.note

    payload =
      if not is_nil(original_text) and original_text != "",
        do: Map.put(payload, "originalText", original_text),
        else: payload

    payload
  end

  @doc """
  Project a list of `%Ingredient{}` into Mealie PUT-ready maps.
  """
  @spec to_payload_list([t()]) :: [map()]
  def to_payload_list(list) when is_list(list), do: Enum.map(list, &to_payload/1)

  @doc """
  Project a `%Ingredient{}` to a single string for LLM prompt consumption.

  If `note` is a non-empty binary, the raw ingredient line is returned as-is
  (unparsed ingredients have no structured fields to render). Otherwise the
  non-nil `quantity`, `unit`, and `food` fields are stringified and joined
  with a single space; if all are nil, the empty string is returned.
  """
  @spec to_prompt_string(t()) :: String.t()
  def to_prompt_string(%__MODULE__{note: note}) when is_binary(note) and note != "" do
    note
  end

  def to_prompt_string(%__MODULE__{} = ing) do
    [ing.quantity, ing.unit, ing.food]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", &to_string/1)
  end

  @doc """
  Project a list of `%Ingredient{}` to a list of prompt-ready strings.
  """
  @spec to_prompt_string_list([t()]) :: [String.t()]
  def to_prompt_string_list(list) when is_list(list), do: Enum.map(list, &to_prompt_string/1)

  defp get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end
end

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
      name: get(data, "name"),
      description: get(data, "description"),
      recipe_yield: get(data, "recipeYield"),
      ingredients: (get(data, "recipeIngredient") || []) |> Ingredient.from_list(),
      instructions: get(data, "recipeInstructions") || [],
      tags: get(data, "tags"),
      categories: get(data, "categories"),
      notes: get(data, "notes"),
      total_time: get(data, "totalTime"),
      prep_time: get(data, "prepTime"),
      cook_time: get(data, "cookTime"),
      perform_time: get(data, "performTime")
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

  defp get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end
end

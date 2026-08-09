defmodule InstaMealie.Ingredient.Ref do
  @moduledoc "A Mealie food or unit as resolved for one ingredient: its name, its Mealie id, and the parser's confidence in the match."
  defstruct [:name, :id, :confidence]

  @doc "Returns true when this ref has a Mealie id (i.e., it has been resolved)."
  def resolved?(%__MODULE__{id: id}) when is_binary(id), do: true
  def resolved?(%__MODULE__{}), do: false
end

defmodule InstaMealie.Ingredient do
  alias InstaMealie.Ingredient.Ref

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
          food: Ref.t(),
          unit: Ref.t(),
          note: String.t() | nil,
          index: non_neg_integer() | nil,
          raw: String.t() | nil,
          status: status()
        }

  defstruct quantity: nil,
            food: %Ref{},
            unit: %Ref{},
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
      quantity: InstaMealie.Utils.map_get(map, "quantity"),
      food: %Ref{
        name: InstaMealie.Utils.map_get(map, "food"),
        id: InstaMealie.Utils.map_get(map, "food_id"),
        confidence: InstaMealie.Utils.map_get(map, "food_confidence")
      },
      unit: %Ref{
        name: InstaMealie.Utils.map_get(map, "unit"),
        id: InstaMealie.Utils.map_get(map, "unit_id"),
        confidence: InstaMealie.Utils.map_get(map, "unit_confidence")
      },
      note: InstaMealie.Utils.map_get(map, "note"),
      raw: InstaMealie.Utils.map_get(map, "raw") || InstaMealie.Utils.map_get(map, "note"),
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
            food: %Ref{
              name: Map.get(p, "food"),
              id: Map.get(p, "food_id"),
              confidence: Map.get(p, "food_confidence")
            },
            unit: %Ref{
              name: Map.get(p, "unit"),
              id: Map.get(p, "unit_id"),
              confidence: Map.get(p, "unit_confidence")
            },
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
            food: %Ref{name: food, id: res["food_id"], confidence: nil},
            unit: %Ref{name: if(unit && unit != "", do: unit), id: res["unit_id"], confidence: nil},
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
        ing.food.id && ing.food.name -> %{"id" => ing.food.id, "name" => ing.food.name}
        ing.food.name -> %{"name" => ing.food.name}
        true -> nil
      end

    payload = if food, do: Map.put(payload, "food", food), else: payload

    unit =
      cond do
        ing.unit.id && ing.unit.name -> %{"id" => ing.unit.id, "name" => ing.unit.name}
        ing.unit.name -> %{"name" => ing.unit.name}
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
    [ing.quantity, ing.unit.name, ing.food.name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", &to_string/1)
  end

  @doc """
  Project a list of `%Ingredient{}` to a list of prompt-ready strings.
  """
  @spec to_prompt_string_list([t()]) :: [String.t()]
  def to_prompt_string_list(list) when is_list(list), do: Enum.map(list, &to_prompt_string/1)
end

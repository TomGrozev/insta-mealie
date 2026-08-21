defmodule InstaMealie.Ingredient.Ref do
  @moduledoc "A Mealie food or unit as resolved for one ingredient: its name, its Mealie id, and the parser's confidence in the match."
  defstruct [:name, :id, :confidence]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          id: String.t() | nil,
          confidence: number() | nil
        }

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
          average_confidence: number() | nil,
          status: status()
        }

  defstruct quantity: nil,
            food: %Ref{},
            unit: %Ref{},
            note: nil,
            index: nil,
            raw: nil,
            average_confidence: nil,
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
      average_confidence: InstaMealie.Utils.map_get(map, "average_confidence"),
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

  The review decision is delegated to `needs_review?/1`, which is the sole
  owner of that policy.

  If the parser returns fewer entries than there are ingredients, the
  trailing ingredients are left unchanged. If the parser returns more
  entries, the extras are dropped.
  """
  @spec apply_parse([t()], [map()]) :: [t()]
  def apply_parse(ingredients, parsed) when is_list(ingredients) and is_list(parsed) do
    ingredients
    |> Enum.with_index()
    |> Enum.map(fn {ing, i} ->
      case Enum.at(parsed, i) do
        nil ->
          %{ing | index: i}

        p ->
          candidate = %{
            ing
            | index: i,
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
              average_confidence: Map.get(p, "average_confidence")
          }

          %{candidate | status: if(needs_review?(candidate), do: :needs_review, else: :parsed)}
      end
    end)
  end

  @threshold 0.85

  @doc """
  Returns true if this ingredient needs human review before import.

  An ingredient needs review when:
  - The food has no Mealie id or its confidence is below 0.85, OR
  - The ingredient has a unit (detected by a non-blank `unit.name`) but
    that unit has no Mealie id or its confidence is below 0.85

  Ingredients that legitimately have no unit at all (e.g. `"3 eggs"` —
  its `unit.name` is nil or blank) are not penalised for missing unit
  resolution: only ingredients that do have a unit require it to be
  resolved before they pass review.

  Falls back to `average_confidence` when a per-field confidence score
  is absent. Treats "no score and no id" as needs-review.
  """
  @spec needs_review?(t()) :: boolean()
  def needs_review?(%__MODULE__{} = ing) do
    food_ok = is_binary(ing.food.id) && food_conf_ok?(ing)
    unit_ok = not has_unit?(ing) or (is_binary(ing.unit.id) && unit_conf_ok?(ing))
    not (food_ok and unit_ok)
  end

  defp food_conf_ok?(ing) do
    conf = ing.food.confidence || ing.average_confidence
    is_number(conf) && conf >= @threshold
  end

  defp unit_conf_ok?(ing) do
    conf = ing.unit.confidence || ing.average_confidence
    is_number(conf) && conf >= @threshold
  end

  @doc """
  Returns the confidence band reflecting the ingredient's overall parse
  confidence across both food and unit.

  Each field is first bucketed into a band, then the worse of the two
  applicable bands is returned. Per-field bands:

  - `:high` — confidence ≥ 0.95
  - `:medium` — confidence ≥ 0.85
  - `:low` — confidence < 0.85
  - `:unknown` — no confidence score available for that field

  A field is only bucketed to `:high` or `:medium` when it is actually
  resolved (has a Mealie id) AND its confidence clears the threshold —
  this stays in lockstep with `needs_review?/1` so the badge never
  claims a field is fine when review is required.

  Severity ordering (worst → best): `:low`/`:unknown` > `:medium` > `:high`.
  `:unknown` is treated as worst-tier **only when the ingredient actually
  has a unit**, so a unit field that is present but unresolvable can never
  be papered over by a strong food confidence.

  Ingredients that legitimately have no unit at all (e.g. `"3 eggs"` — its
  `unit.name` is nil or blank) are not penalised for missing unit
  confidence; only the food confidence is reported for those lines.
  """
  @spec confidence_band(t()) :: :high | :medium | :low | :unknown
  def confidence_band(%__MODULE__{} = ing) do
    food_band = field_band(ing.food.id, ing.food.confidence || ing.average_confidence)

    unit_band =
      if has_unit?(ing),
        do: field_band(ing.unit.id, ing.unit.confidence || ing.average_confidence),
        else: nil

    [food_band, unit_band]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(&worse/2)
  end

  # A field can only be `:high`/`:medium` when it's actually resolved (has an
  # id) AND its confidence clears the threshold — this must stay in lockstep
  # with `food_conf_ok?/1` / `unit_conf_ok?/1` so the badge never claims a
  # field is fine when `needs_review?/1` says otherwise.
  defp field_band(id, conf) when is_binary(id) and is_number(conf) and conf >= 0.95, do: :high
  defp field_band(id, conf) when is_binary(id) and is_number(conf) and conf >= 0.85, do: :medium
  defp field_band(id, conf) when is_binary(id) and is_number(conf), do: :low
  defp field_band(id, _conf) when is_binary(id), do: :unknown
  defp field_band(_id, conf) when is_number(conf), do: :low
  defp field_band(_id, _conf), do: :unknown

  defp has_unit?(%__MODULE__{unit: %Ref{name: name}}) when is_binary(name) do
    String.trim(name) != ""
  end

  defp has_unit?(_), do: false

  # Higher rank = worse. `:unknown` is only ever passed in here from
  # `band_for/1` when `has_unit?/1` was true (the unit exemption in
  # `confidence_band/1` suppresses it otherwise), so it stands in for
  # "an unresolved required field" and ranks alongside `:low`.
  defp worse(a, b) do
    rank = %{high: 1, medium: 2, low: 3, unknown: 3}
    if rank[b] >= rank[a], do: b, else: a
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
          food_name = if(food && food != "", do: food)
          unit_name = if(unit && unit != "", do: unit)

          food_id = res["food_id"] || if food_name == ing.food.name, do: ing.food.id
          unit_id = res["unit_id"] || if unit_name == ing.unit.name, do: ing.unit.id

          %{
            ing
            | food: %Ref{name: food_name, id: food_id, confidence: nil},
              unit: %Ref{name: unit_name, id: unit_id, confidence: nil},
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
  (matching Mealie's Pydantic model) — ONLY when both `id` and `name` are
  present. When `name` is present without an `id`, the key is omitted
  entirely: Mealie's ORM requires an `id` for MANYTOONE relationships, and
  omitting the key lets Mealie's PATCH merge preserve the existing
  relationship. `note` and the original ingredient line (`originalText`)
  are included when non-nil. Flat `food_id` / `unit_id` keys are
  intentionally NOT emitted: Mealie's Pydantic model silently discards them.
  """
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = ing) do
    payload = %{}

    payload =
      if is_nil(ing.quantity), do: payload, else: Map.put(payload, "quantity", ing.quantity)

    # Omit food/unit when there's no ID — Mealie's ORM requires ID for MANYTOONE
    # relationships. Omitting preserves whatever exists in Mealie (PATCH merges).
    food =
      if ing.food.id && ing.food.name do
        %{"id" => ing.food.id, "name" => ing.food.name}
      else
        nil
      end

    payload = if food, do: Map.put(payload, "food", food), else: payload

    unit =
      if ing.unit.id && ing.unit.name do
        %{"id" => ing.unit.id, "name" => ing.unit.name}
      else
        nil
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

  An ingredient is rendered as the raw `note` text (unparsed ingredients have
  no structured fields to render) only when its `status` is `:unparsed`. For
  every other status (`:parsed`, `:needs_review`, `:resolved`) the non-nil
  `quantity`, `unit`, and `food` fields are stringified and joined with a
  single space. If all of those are nil, the empty string is returned.

  Note that a populated `note` alone is NOT sufficient to trigger the raw
  fallback: the Mealie parser also emits a per-ingredient note (e.g.
  "sifted", "room temperature") for fully classified lines, and dropping the
  structured join for those would silently lose quantity/unit/food from the
  downstream prompt projection.
  """
  @spec to_prompt_string(t()) :: String.t()
  def to_prompt_string(%__MODULE__{status: :unparsed, note: note})
      when is_binary(note) and note != "" do
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

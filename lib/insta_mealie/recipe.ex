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
          # Explicit numeric overrides. When present, these are preserved at
          # the payload boundary (see `to_mealie_payload/1`) and the
          # `recipe_yield` text is not reparsed.
          recipe_servings: number() | nil,
          recipe_yield_quantity: number() | nil,
          ingredients: [Ingredient.t()],
          instructions: [map()],
          tags: [String.t()] | nil,
          categories: [String.t()] | nil,
          notes: list() | nil,
          total_time: String.t() | nil,
          prep_time: String.t() | nil,
          cook_time: String.t() | nil,
          perform_time: String.t() | nil,
          image: String.t() | nil,
          source_url: String.t() | nil
        }

  defstruct name: nil,
            description: nil,
            recipe_yield: nil,
            recipe_servings: nil,
            recipe_yield_quantity: nil,
            ingredients: [],
            instructions: [],
            tags: nil,
            categories: nil,
            notes: nil,
            total_time: nil,
            prep_time: nil,
            cook_time: nil,
            perform_time: nil,
            image: nil,
            source_url: nil

  # Yield text patterns. The optional serving verb prefix ("makes",
  # "serves", "yields", "about") lets us recognise
  # "Makes about 8 servings" / "Serves 4" / "About 12" as
  # servings-style yields rather than quantity+unit.
  @yield_pattern_regex ~r/^\s*(?:(?:makes|serves|yield[s]?|about|servings of)\s+(?:about\s+)?)?(\d+(?:\.\d+)?|\d+\s*\/\s*\d+)(?:\s+(.+?))?\s*$/i

  # Bare number fallback, so `"8"` resolves to 8 servings.
  @yield_bare_number_regex ~r/^\s*(\d+(?:\.\d+)?|\d+\s*\/\s*\d+)\s*$/

  # ISO-8601 duration parser — PnYnMnDTnHnMnS, but we only see the time-of-day
  # form PTnHnMnS in practice.
  @iso8601_duration_regex ~r/^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$/

  @payload_fields [
    {:name, "name"},
    {:description, "description"},
    {:recipe_yield, "recipeYield"},
    {:ingredients, "recipeIngredient"},
    {:instructions, "recipeInstructions"},
    {:tags, "tags"},
    {:categories, "recipeCategory"},
    {:notes, "notes"},
    {:total_time, "totalTime"},
    {:prep_time, "prepTime"},
    {:cook_time, "cookTime"},
    {:perform_time, "performTime"},
    {:source_url, "orgURL"}
  ]

  @doc """
  Build a `%Recipe{}` from a string- or atom-keyed map. The map is expected
  to use Mealie's camelCase keys; the resulting struct uses snake_case
  Elixir field names. The `recipeIngredient` list is converted into
  `%Ingredient{}` structs via `Ingredient.from_list/1`.

  When the input carries explicit numeric `recipeServings` /
  `recipeYieldQuantity` fields, those are preserved verbatim on the
  struct so `to_mealie_payload/1` can forward them without reparsing the
  `recipeYield` text.
  """
  @spec from_map(map()) :: t()
  def from_map(data) when is_map(data) do
    %__MODULE__{
      name: InstaMealie.Utils.map_get(data, "name"),
      description: InstaMealie.Utils.map_get(data, "description"),
      recipe_yield: InstaMealie.Utils.map_get(data, "recipeYield"),
      recipe_servings: coerce_number(InstaMealie.Utils.map_get(data, "recipeServings")),
      recipe_yield_quantity:
        coerce_number(InstaMealie.Utils.map_get(data, "recipeYieldQuantity")),
      ingredients:
        (InstaMealie.Utils.map_get(data, "recipeIngredient") || []) |> Ingredient.from_list(),
      instructions: InstaMealie.Utils.map_get(data, "recipeInstructions") || [],
      tags: InstaMealie.Utils.map_get(data, "tags"),
      categories: InstaMealie.Utils.map_get(data, "categories"),
      notes: InstaMealie.Utils.map_get(data, "notes"),
      total_time: InstaMealie.Utils.map_get(data, "totalTime"),
      prep_time: InstaMealie.Utils.map_get(data, "prepTime"),
      cook_time: InstaMealie.Utils.map_get(data, "cookTime"),
      perform_time: InstaMealie.Utils.map_get(data, "performTime"),
      image: InstaMealie.Utils.map_get(data, "image"),
      source_url: InstaMealie.Utils.map_get(data, "orgURL")
    }
  end

  @doc """
  Project a `%Recipe{}` into the string-keyed map Mealie's PUT expects.

  Output keys mirror the old `InstaMealie.Mealie.build_payload/1` output;
  `nil` values are dropped — except for the three yield fields and the
  four time fields, which are translated at this boundary (see below).
  The `:ingredients` list is rendered through
  `Ingredient.to_payload_list/1`.

  Yield boundary:
    Mealie expects three distinct payload keys for yield — `recipeServings`
    (number), `recipeYieldQuantity` (number) and `recipeYield` (text). The
    struct's raw `recipe_yield` text is parsed into those three at this
    boundary:
      - "2 servings" / "Serves 4" / "Makes about 8" -> servings = 2/4/8,
        quantity = 0, text = "".
      - "4 pies" / "1 batch" -> servings = 0, quantity = 4/1,
        text = "pies" / "batch".
      - Unparseable text -> servings = 0, quantity = 0, text preserved.
      - Fractions/decimals are supported ("1/2 cup" -> 0.5).
    Explicit numeric `recipe_servings` / `recipe_yield_quantity` already on
    the struct are preserved verbatim and skip text reparsing. The three
    yield keys are always emitted (with 0/0/"" defaults) so Mealie does
    not fall back to its own defaults.

  Time boundary:
    Mealie displays `totalTime` / `prepTime` / `cookTime` / `performTime`
    as readable strings, not ISO-8601. ISO-8601 durations in the struct
    (including the non-canonical `PT245M`) are converted to canonical
    text here — `PT245M` -> `"4 hours 5 minutes"`, `PT5M` -> `"5 minutes"`,
    singular/plural respected. Already-human-readable or otherwise
    unparseable strings are preserved verbatim. Empty strings are dropped
    per the existing nil-drop contract.

    If exactly one of total / prep / cook is missing and the other two are
    parseable nonnegative ISO durations, the missing value is derived
    (total = prep + cook; cook = total - prep; prep = total - cook). The
    derived value is only emitted when arithmetic is safe (subtractions
    are nonnegative). Supplied values are never overwritten.
  """
  @spec to_mealie_payload(t()) :: map()
  def to_mealie_payload(%__MODULE__{} = recipe) do
    times = canonicalise_times(recipe)

    Enum.reduce(@payload_fields, %{}, fn {field, key}, acc ->
      value =
        case {field, Map.get(recipe, field)} do
          {:ingredients, list} when is_list(list) ->
            Ingredient.to_payload_list(list)

          {:tags, list} when is_list(list) ->
            list

          {:instructions, list} when is_list(list) ->
            Enum.map(list, fn
              inst when is_map(inst) -> Map.put_new(inst, "type", "RecipeInstruction")
              inst -> %{"text" => to_string(inst), "type" => "RecipeInstruction"}
            end)

          {:recipe_yield, _} ->
            nil

          {:total_time, _} ->
            Map.get(times, :total)

          {:prep_time, _} ->
            Map.get(times, :prep)

          {:cook_time, _} ->
            Map.get(times, :cook)

          {:perform_time, _} ->
            Map.get(times, :perform)

          {_, v} ->
            v
        end

      if is_nil(value) do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
    |> Map.merge(yield_payload(recipe))
  end

  @doc """
  Validate a `%Recipe{}` for shape correctness. Returns `{:ok, recipe}` when
  valid, or `{:error, field_name}` naming the first offending field.

  Rules (strict-shape, lenient-presence):
  - `name`, `description`, `recipe_yield` — if present, must be strings
  - `recipe_servings`, `recipe_yield_quantity` — if present, must be numbers
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
         :ok <- validate_number(:recipe_servings, recipe.recipe_servings),
         :ok <- validate_number(:recipe_yield_quantity, recipe.recipe_yield_quantity),
         :ok <- validate_list(:ingredients, recipe.ingredients),
         :ok <- validate_instructions(recipe.instructions),
         :ok <- validate_string(:total_time, recipe.total_time),
         :ok <- validate_string(:prep_time, recipe.prep_time),
         :ok <- validate_string(:cook_time, recipe.cook_time),
         :ok <- validate_string(:perform_time, recipe.perform_time),
         :ok <- validate_list(:tags, recipe.tags),
         :ok <- validate_list(:categories, recipe.categories),
         :ok <- validate_string(:source_url, recipe.source_url) do
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

      _inst, _acc ->
        {:halt, {:error, :instructions}}
    end)
  end

  defp validate_instructions(_), do: {:error, :instructions}

  defp validate_number(_field, nil), do: :ok
  defp validate_number(_field, val) when is_number(val), do: :ok
  defp validate_number(field, _val), do: {:error, field}

  # ── Yield (clean_yield) payload shaping ──────────────────────────────
  #
  # Returns the three yield keys that always land in the Mealie payload.
  # When the struct carries explicit numeric `recipe_servings` /
  # `recipe_yield_quantity`, those win and the text is not reparsed.
  defp yield_payload(%__MODULE__{} = recipe) do
    {servings, quantity, text} =
      case {recipe.recipe_servings, recipe.recipe_yield_quantity} do
        {nil, nil} -> clean_yield(recipe.recipe_yield)
        {s, q} -> {s || 0, q || 0, recipe.recipe_yield || ""}
      end

    %{
      "recipeServings" => servings,
      "recipeYieldQuantity" => quantity,
      "recipeYield" => text || ""
    }
  end

  # Parse a raw `recipe_yield` text into the {servings, quantity, text}
  # triple Mealie expects. Falls back to {0, 0, original_text} when the
  # text does not match a recognised pattern — never fabricates a number.
  @spec clean_yield(any()) :: {number(), number(), String.t()}
  defp clean_yield(text) when is_binary(text) do
    trimmed = String.trim(text)

    if trimmed == "" do
      {0, 0, ""}
    else
      parse_yield_pattern(trimmed, text)
    end
  end

  defp clean_yield(_), do: {0, 0, ""}

  defp parse_yield_pattern(trimmed, original) do
    case Regex.run(@yield_pattern_regex, trimmed) do
      [_, num_str] ->
        to_servings(num_str)

      [_, num_str, trailing] ->
        trailing_trim = String.trim(trailing)

        if servings_keyword?(trailing_trim) do
          to_servings(num_str)
        else
          to_quantity_unit(num_str, trailing_trim, original)
        end

      nil ->
        parse_bare_number(trimmed, original)
    end
  end

  defp parse_bare_number(trimmed, original) do
    case Regex.run(@yield_bare_number_regex, trimmed) do
      [_, num_str] -> to_servings(num_str)
      _ -> {0, 0, original}
    end
  end

  defp to_servings(num_str) do
    case parse_yield_number(num_str) do
      {:ok, n} -> {n, 0, ""}
      :error -> {0, 0, ""}
    end
  end

  defp to_quantity_unit(num_str, unit, original) do
    case parse_yield_number(num_str) do
      {:ok, n} -> {0, n, unit}
      :error -> {0, 0, original}
    end
  end

  # A trailing word that signals "this yield is a serving count, not a
  # quantity+unit". Matches "serving", "servings", "serve", "serves" with
  # or without a trailing descriptor (e.g. "servings of").
  defp servings_keyword?(text) do
    lower = String.downcase(text)

    lower in ["serving", "servings", "serve", "serves"] or
      String.starts_with?(lower, "serving ") or
      String.starts_with?(lower, "servings ") or
      String.starts_with?(lower, "serve ") or
      String.starts_with?(lower, "serves ")
  end

  # Parse a yield quantity string. Accepts:
  #   - plain integers and decimals: "4", "2.5"
  #   - fractions with whitespace: "1 / 2"
  # Whole-number floats collapse to integers ("8.0" -> 8) so the
  # canonical payload reads "8" rather than "8.0".
  defp parse_yield_number(str) do
    trimmed = String.trim(str)

    case Float.parse(trimmed) do
      {f, ""} ->
        {:ok, normalise_yield_number(f)}

      _ ->
        parse_fraction(trimmed)
    end
  end

  defp parse_fraction(trimmed) do
    case String.split(trimmed, "/") do
      [num, denom] ->
        with {n, ""} <- Float.parse(String.trim(num)),
             {d, ""} <- Float.parse(String.trim(denom)) do
          divide_normalised(n, d)
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp divide_normalised(_n, 0), do: :error
  defp divide_normalised(n, d), do: {:ok, normalise_yield_number(n / d)}

  defp normalise_yield_number(f) when is_float(f) do
    if f == Float.floor(f), do: trunc(f), else: f
  end

  defp normalise_yield_number(f), do: f

  # Accept numeric values from Mealie-shaped inputs (numbers) and tolerant
  # string coercion for hand-written JSON. Anything unparseable becomes
  # nil so downstream code can decide whether to derive from text.
  defp coerce_number(val) when is_number(val), do: val
  defp coerce_number(nil), do: nil

  defp coerce_number(val) when is_binary(val) do
    case Float.parse(String.trim(val)) do
      {f, ""} -> normalise_yield_number(f)
      _ -> nil
    end
  end

  defp coerce_number(_), do: nil

  # ── Time canonicalisation and derivation ─────────────────────────────

  # Map of finalised time strings for the four time keys.
  defp canonicalise_times(%__MODULE__{} = recipe) do
    total_in = recipe.total_time
    prep_in = recipe.prep_time
    cook_in = recipe.cook_time
    perform_in = recipe.perform_time

    # Step 1 — parse each input to ISO minutes (nil if not ISO-parseable).
    # `parse_iso8601_to_minutes/1` only succeeds on canonical
    # `PT…H…M…S` strings, so human-readable text (e.g. "1 hour 20
    # minutes", "until done") leaves the minutes as nil and the field
    # passes through `emit_time/2` unchanged.
    total_min = parse_iso8601_to_minutes(total_in)
    prep_min = parse_iso8601_to_minutes(prep_in)
    cook_min = parse_iso8601_to_minutes(cook_in)

    # Step 2 — derive one missing field from the other two when both of
    # those are parseable ISO durations.
    {total_min, prep_min, cook_min} = derive_time(total_min, prep_min, cook_min)

    %{
      total: emit_time(total_in, total_min),
      prep: emit_time(prep_in, prep_min),
      cook: emit_time(cook_in, cook_min),
      perform: emit_perform(perform_in)
    }
  end

  defp parse_iso8601_to_minutes(nil), do: nil
  defp parse_iso8601_to_minutes(""), do: nil

  defp parse_iso8601_to_minutes(value) when is_binary(value) do
    case Regex.run(@iso8601_duration_regex, String.trim(value)) do
      [_, h, m, s] ->
        # All four groups present: PT?H?M?S.
        total_seconds = parse_int(h) * 3600 + parse_int(m) * 60 + parse_int(s)
        div(total_seconds, 60)

      [_, h, m] ->
        # PT?H?M — no seconds. (With `(?:…)?` optional groups, a group that
        # didn't match is reported as an empty string. This 3-element shape
        # is what we get for "PT245M".)
        total_seconds = parse_int(h) * 3600 + parse_int(m) * 60
        div(total_seconds, 60)

      [_, h] ->
        # PT?H — hours only ("PT1H" -> 60 minutes).
        parse_int(h) * 60

      _ ->
        nil
    end
  end

  defp parse_int(nil), do: 0
  defp parse_int(""), do: 0
  defp parse_int(str) when is_binary(str), do: String.to_integer(str)

  # Derive one missing field from the other two when both sources are
  # parseable ISO durations and arithmetic is safe (subtractions are
  # nonnegative). The existing values are never overwritten. If no
  # derivation applies, returns the inputs unchanged.
  defp derive_time(total_min, prep_min, cook_min) do
    cond do
      # Cook missing, total & prep parseable.
      is_nil(cook_min) and not is_nil(total_min) and not is_nil(prep_min) ->
        diff = total_min - prep_min
        if diff >= 0, do: {total_min, prep_min, diff}, else: {total_min, prep_min, nil}

      # Prep missing, total & cook parseable.
      is_nil(prep_min) and not is_nil(total_min) and not is_nil(cook_min) ->
        diff = total_min - cook_min
        if diff >= 0, do: {total_min, diff, cook_min}, else: {total_min, nil, cook_min}

      # Total missing, prep & cook parseable.
      is_nil(total_min) and not is_nil(prep_min) and not is_nil(cook_min) ->
        {prep_min + cook_min, prep_min, cook_min}

      true ->
        {total_min, prep_min, cook_min}
    end
  end

  # Emit a final time string for total / prep / cook:
  # - If the input was nil and we have no derivation, drop the field (nil).
  # - If the input was human-readable / unparseable, preserve as-is.
  # - If the input was ISO-parseable, convert to canonical text.
  # - If the input was nil but derivation produced minutes, emit canonical text.
  defp emit_time(nil, nil), do: nil
  defp emit_time(nil, minutes) when is_integer(minutes), do: format_minutes(minutes)

  defp emit_time(original, _minutes) when is_binary(original) do
    case parse_iso8601_to_minutes(original) do
      nil ->
        # Human-readable / unparseable: preserve. An empty string also
        # falls through here, and we drop it per the existing nil-drop
        # contract so callers don't ship empty payload fields.
        if original == "", do: nil, else: original

      _ ->
        format_minutes(parse_iso8601_to_minutes(original))
    end
  end

  # perform_time is never derived from; it is only converted in place.
  defp emit_perform(nil), do: nil
  defp emit_perform(""), do: nil

  defp emit_perform(value) when is_binary(value) do
    case parse_iso8601_to_minutes(value) do
      nil -> value
      mins -> format_minutes(mins)
    end
  end

  # Format a (nonnegative) minute count as canonical text:
  #   0 -> "0 minutes"
  #   1 -> "1 minute"
  #   60 -> "1 hour"
  #   65 -> "1 hour 5 minutes"
  defp format_minutes(total) when is_integer(total) and total >= 0 do
    hours = div(total, 60)
    minutes = rem(total, 60)

    cond do
      hours == 0 and minutes == 0 -> "0 minutes"
      hours == 0 -> "#{minutes} minute#{pluralize(minutes)}"
      minutes == 0 -> "#{hours} hour#{pluralize(hours)}"
      true -> "#{hours} hour#{pluralize(hours)} #{minutes} minute#{pluralize(minutes)}"
    end
  end

  defp pluralize(1), do: ""
  defp pluralize(_), do: "s"
end

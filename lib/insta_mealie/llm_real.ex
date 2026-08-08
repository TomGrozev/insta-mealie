defmodule InstaMealie.Llm.Real do
  @moduledoc """
  Real OpenAI-compatible LLM client backed by Req.

  Implements `InstaMealie.Llm` behaviour for both `format` (Prompt 1 —
  routing + recipe extraction) and `merge` (Prompt 2 — transcript merge).
  """

  @behaviour InstaMealie.Llm

  # ── Few-shot examples ──────────────────────────────────────────────

  @prompt1_fewshots [
    {
      "Check out this amazing butter chicken recipe! 🍛 Melt 3 tbsp ghee in a pan, add 2 finely diced onions and cook until golden. Stir in 3 tbsp ginger-garlic paste, 2 tbsp Kashmiri chilli powder, 1 tbsp garam masala, 1 tsp turmeric and 1 tsp cumin. Cook 2 min. Add 700g diced chicken thigh, sear 5 min. Pour in 400ml coconut milk and 200ml tomato passata, simmer 25 min. Finish with 1/2 cup cream and fresh coriander. Serve over basmati. #chicken #dinner",
      ~s({"completeness":"recipe_complete","missing_fields":[],"recipe":{"name":"Butter Chicken","description":"Creamy Indian butter chicken simmered in spiced tomato-coconut sauce.","recipeYield":"4 servings","recipeIngredient":["3 tbsp ghee","2 onions, finely diced","3 tbsp ginger-garlic paste","2 tbsp Kashmiri chilli powder","1 tbsp garam masala","1 tsp turmeric","1 tsp cumin","700g chicken thigh, diced","400ml coconut milk","200ml tomato passata","1/2 cup cream","Fresh coriander"],"recipeInstructions":[{"text":"Melt ghee in a pan, add onions and cook until golden."},{"text":"Stir in ginger-garlic paste, chilli powder, garam masala, turmeric and cumin. Cook 2 minutes."},{"text":"Add diced chicken thigh, sear for 5 minutes."},{"text":"Pour in coconut milk and tomato passata, simmer 25 minutes."},{"text":"Finish with cream and fresh coriander. Serve over basmati rice."}],"tags":["chicken","dinner","indian"]}})
    },
    {
      "My grandma's secret apple pie 🥧 apples sliced thin, cinnamon, sugar. bake 375F. #pie",
      ~s({"completeness":"recipe_partial","missing_fields":["recipeInstructions"],"recipe":{"name":"Apple Pie","description":"Classic cinnamon apple pie.","recipeYield":"1 pie","recipeIngredient":["Apples, thinly sliced","Cinnamon","Sugar"],"recipeInstructions":[],"tags":["pie","dessert"]}})
    },
    {
      "Just vibing at the beach today 🌊 no recipes just sunset pics. Follow for more travel content! #travel #sunset #beachlife",
      ~s({"completeness":"no_recipe","missing_fields":[],"recipe":{}})
    }
  ]

  @prompt2_fewshots [
    {
      "I added the chicken and simmered for about 20 minutes then stirred in some cream. Oh and I used turmeric instead of saffron because I'm broke lol.",
      ~s({"completeness":"recipe_complete","missing_fields":[],"recipe":{"name":"Adapted Chicken Curry","description":"A budget-friendly chicken curry adapted from a basic draft.","recipeYield":"4 servings","recipeIngredient":["Chicken pieces","Turmeric","Cream","Basic curry spices"],"recipeInstructions":[{"text":"Cook chicken pieces with basic curry spices for 20 minutes."},{"text":"Stir in cream and serve."}],"tags":["budget","curry"]}})
    },
    {
      "So basically you boil the pasta al dente, make a roux with butter and flour, add milk慢慢 stir until thick, toss in cheddar and pour over the noodles. Bake at 350F for 20 minutes until bubbly.",
      ~s({"completeness":"recipe_complete","missing_fields":[],"recipe":{"name":"Homemade Mac and Cheese","description":"Classic baked mac and cheese with a from-scratch cheese sauce.","recipeYield":"6 servings","recipeIngredient":["Pasta","Butter","Flour","Milk","Cheddar cheese"],"recipeInstructions":[{"text":"Boil pasta al dente."},{"text":"Make a roux with butter and flour, add milk and stir until thick."},{"text":"Add cheddar cheese to the sauce."},{"text":"Toss pasta with sauce, pour into baking dish."},{"text":"Bake at 350F for 20 minutes until bubbly."}],"tags":["pasta","comfort food","baked"]}})
    }
  ]

  # ── Public API ─────────────────────────────────────────────────────

  @impl true
  def format(caption, opts) do
    output_language = Keyword.get(opts, :output_language, "en")
    comments = Keyword.get(opts, :comments, [])

    cfg = config()
    model = cfg[:model]

    messages =
      build_format_messages(caption, output_language, comments)

    request_body = %{
      model: model,
      temperature: 0,
      response_format: %{type: "json_object"},
      messages: messages
    }

    case http_adapter().request(request_body, timeout: 30_000) do
      {:ok, response} ->
        case parse_content(response) do
          {:ok, envelope} -> {:ok, envelope}
          {:error, reason} -> {:error, :api_error, reason}
        end

      {:error, class, reason} ->
        {:error, class, reason}
    end
  end

  @impl true
  def merge(caption, transcript, opts) do
    output_language = Keyword.get(opts, :output_language, "en")
    draft = Keyword.get(opts, :draft)

    cfg = config()
    model = cfg[:merge_model] || cfg[:model]

    messages =
      build_merge_messages(caption, transcript, output_language, draft)

    request_body = %{
      model: model,
      temperature: 0,
      response_format: %{type: "json_object"},
      messages: messages
    }

    case http_adapter().request(request_body, timeout: 30_000) do
      {:ok, response} ->
        case parse_content(response) do
          {:ok, envelope} -> {:ok, envelope}
          {:error, reason} -> {:error, :api_error, reason}
        end

      {:error, class, reason} ->
        {:error, class, reason}
    end
  end

  # ── Content parser ─────────────────────────────────────────────────

  defp parse_content(response) do
    case get_in(response, ["choices", Access.at(0), "message", "content"]) do
      content when is_binary(content) ->
        case Jason.decode(content) do
          {:ok, json} when is_map(json) -> {:ok, envelope_from_json(json)}
          {:ok, _} -> {:error, "completion was not a JSON object"}
          {:error, _} -> {:error, "invalid JSON in completion"}
        end

      _ ->
        {:error, "no completion content"}
    end
  end

  # ── Pure envelope parser (Step 2) ─────────────────────────────────

  @doc """
  Parse a decoded JSON map (string keys) into a normalised envelope.

  - `completeness` is mapped via a fixed whitelist — never `String.to_atom`.
  - `missing_fields` only allows `"recipeIngredient"` / `"recipeInstructions"`.
  - `recipe` stays as a string-keyed map.
  - Duration fields are normalised to ISO-8601 (Step 7).
  """
  def envelope_from_json(json) when is_map(json) do
    completeness = parse_completeness(json["completeness"])
    missing_fields = parse_missing_fields(json["missing_fields"])
    recipe = normalize_durations(json["recipe"] || %{})

    %{completeness: completeness, missing_fields: missing_fields, recipe: recipe}
  end

  # ── Completeness whitelist ─────────────────────────────────────────

  defp parse_completeness("recipe_complete"), do: :recipe_complete
  defp parse_completeness("recipe_partial"), do: :recipe_partial
  defp parse_completeness("no_recipe"), do: :no_recipe
  defp parse_completeness(_), do: :no_recipe

  # ── Missing fields whitelist ───────────────────────────────────────

  defp parse_missing_fields(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      "recipeIngredient" -> [:recipeIngredient]
      "recipeInstructions" -> [:recipeInstructions]
      "recipeingredient" -> [:recipeIngredient]
      "recipeinstructions" -> [:recipeInstructions]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp parse_missing_fields(_), do: []

  # ── Duration normalisation (Step 7) ───────────────────────────────

  @duration_keys ~w(totalTime prepTime cookTime performTime)

  @iso8601_re ~r/^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/

  defp normalize_durations(recipe) when is_map(recipe) do
    Enum.reduce(@duration_keys, recipe, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        "" -> Map.delete(acc, key)
        value when is_binary(value) -> Map.put(acc, key, normalise_duration(value))
        _ -> acc
      end
    end)
  end

  defp normalise_duration(value) do
    if String.match?(value, @iso8601_re) do
      value
    else
      case parse_human_duration(value) do
        {:ok, iso} -> iso
        :error -> value
      end
    end
  end

  @doc false
  def parse_human_duration(str) when is_binary(str) do
    str = str |> String.trim() |> String.downcase()

    cond do
      # Already ISO-8601
      String.match?(str, @iso8601_re) ->
        {:ok, str}

      # Try to extract hours + minutes
      true ->
        hours = extract_hours(str)
        minutes = extract_minutes(str)

        cond do
          hours > 0 or minutes > 0 ->
            build_iso(hours, minutes)

          # Try "90 min" or "90 minutes" (minutes only, no space-based compound)
          Regex.match?(~r/(\d+)\s*min(?:ute)?s?\b/, str) ->
            [_, m] = Regex.run(~r/(\d+)\s*min(?:ute)?s?\b/, str)
            build_iso(0, String.to_integer(m))

          # Try bare number like "1.5" (assume hours)
          Regex.match?(~r/^(\d+(?:\.\d+)?)\s*$/, str) ->
            [_, n] = Regex.run(~r/^(\d+(?:\.\d+)?)$/, str)
            val = String.to_float(n)
            h = floor(val)
            m = round((val - h) * 60)
            build_iso(h, m)

          true ->
            :error
        end
    end
  end

  defp extract_hours(str) do
    cond do
      Regex.match?(~r/(\d+)\s*h(?:rs?|ours?)?(?![a-z])/i, str) ->
        [_, h] = Regex.run(~r/(\d+)\s*h(?:rs?|ours?)?(?![a-z])/i, str)
        String.to_integer(h)

      Regex.match?(~r/(\d+)\s*:\s*(\d+)/, str) ->
        [_, h, _] = Regex.run(~r/(\d+)\s*:\s*(\d+)/, str)
        String.to_integer(h)

      true ->
        0
    end
  end

  defp extract_minutes(str) do
    cond do
      # "1h 30m" or "1 hour 30 minutes" — need the minute part after the hour part
      Regex.match?(~r/\d+\s*(?:h|hr|hours?)\b.*?(\d+)\s*(?:m|min|minutes?)\b/, str) ->
        [_, m] =
          Regex.run(~r/\d+\s*(?:h|hr|hours?)\b.*?(\d+)\s*(?:m|min|minutes?)\b/, str)

        String.to_integer(m)

      # Standalone minutes
      Regex.match?(~r/(\d+)\s*m(?:in(?:ute)?s?)?\b/, str) ->
        [_, m] = Regex.run(~r/(\d+)\s*m(?:in(?:ute)?s?)?\b/, str)
        String.to_integer(m)

      # "1:30" format
      Regex.match?(~r/(\d+)\s*:\s*(\d+)/, str) ->
        [_, _, m] = Regex.run(~r/(\d+)\s*:\s*(\d+)/, str)
        String.to_integer(m)

      true ->
        0
    end
  end

  defp build_iso(hours, minutes) when minutes >= 60 do
    extra_hours = div(minutes, 60)
    remaining_minutes = rem(minutes, 60)
    build_iso(hours + extra_hours, remaining_minutes)
  end

  defp build_iso(0, 0), do: :error

  defp build_iso(hours, minutes) do
    parts = []

    parts =
      if hours > 0 do
        parts ++ ["PT", "#{hours}H"]
      else
        parts ++ ["PT"]
      end

    parts =
      if minutes > 0 do
        parts ++ ["#{minutes}M"]
      else
        parts
      end

    {:ok, IO.iodata_to_binary(parts)}
  end

  # ── Message builders ───────────────────────────────────────────────

  defp build_format_messages(caption, output_language, comments) do
    comments_text =
      case comments do
        [] -> ""
        _ -> "\n\nOP comments:\n" <> Enum.map_join(comments, "\n", &"  - #{&1}")
      end

    system = """
    You are a recipe extractor for Instagram food reels. Given an Instagram caption (and optionally the reel owner's comments), determine whether it contains a recipe.

    Return ONLY a JSON object with this exact shape:
    {
      "completeness": "recipe_complete" | "recipe_partial" | "no_recipe",
      "missing_fields": [],
      "recipe": { ...Mealie recipe fields... }
    }

    Rules:
    - `completeness` must be exactly one of: "recipe_complete", "recipe_partial", "no_recipe".
    - `missing_fields` may ONLY contain "recipeIngredient" or "recipeInstructions". Leave it empty [] when completeness is "recipe_complete" or "no_recipe".
    - On "no_recipe", the "recipe" MUST be an empty object {}. Do NOT invent a recipe name.
    - On "recipe_complete", include ALL fields: name, description, recipeYield, recipeIngredient (list of strings), recipeInstructions (list of objects with "text" key), tags (list of strings), and optionally totalTime, prepTime, cookTime, performTime as ISO-8601 durations.
    - On "recipe_partial", include whatever fields ARE present; leave missing ones out of the recipe object.
    - Preserve original recipe terms (e.g. ingredient names, technique names). Translate only the surrounding descriptive text if the output language differs from the caption's language.
    - Use string keys for all recipe fields (Mealie expects strings).
    - tags should capture relevant recipe categories inferred from the content (e.g. "vegan", "quick", "dessert").

    Output language: #{output_language}
    """

    user_content = caption <> comments_text

    ([
       %{role: "system", content: system}
     ] ++
       Enum.map(@prompt1_fewshots, fn {user, assistant} ->
         [
           %{role: "user", content: user},
           %{role: "assistant", content: assistant}
         ]
       end) ++
       [%{role: "user", content: user_content}])
    |> List.flatten()
  end

  defp build_merge_messages(caption, transcript, output_language, draft) do
    draft_text =
      case draft do
        nil ->
          ""

        %{} = d when map_size(d) == 0 ->
          ""

        d when is_map(d) ->
          "\n\nPartial recipe draft from caption analysis:\n" <> Jason.encode!(d)

        _ ->
          ""
      end

    system = """
    You are a recipe merge assistant for Instagram food reels. You receive:
    1. The original Instagram caption
    2. A voiceover transcript from the reel
    3. Optionally, a partial recipe draft extracted from the caption

    Merge ALL available information into a FINAL complete Mealie recipe. Return ONLY a JSON object with this exact shape:
    {
      "completeness": "recipe_complete" | "recipe_partial" | "no_recipe",
      "missing_fields": [],
      "recipe": { ...Mealie recipe fields... }
    }

    Rules:
    - If a draft is provided, refine and keep all its fields. Add information from the transcript. Do NOT discard existing fields unless the transcript explicitly contradicts them.
    - If no draft is provided, build the recipe entirely from the caption + transcript.
    - Do NOT invent a recipe name unless the transcript or caption provides one.
    - `completeness` must be one of: "recipe_complete", "recipe_partial", "no_recipe".
    - `missing_fields` may ONLY contain "recipeIngredient" or "recipeInstructions". Leave it empty [] when completeness is "recipe_complete".
    - Preserve original recipe terms. Translate only the surrounding descriptive text if the output language differs from the source language.
    - Use string keys for all recipe fields.
    - tags should capture relevant recipe categories inferred from the content.
    - Include totalTime, prepTime, cookTime, performTime as ISO-8601 durations when mentioned.

    Output language: #{output_language}
    """

    user_content = "Caption: #{caption}\n\nTranscript: #{transcript}#{draft_text}"

    ([
       %{role: "system", content: system}
     ] ++
       Enum.map(@prompt2_fewshots, fn {user, assistant} ->
         [
           %{role: "user", content: user},
           %{role: "assistant", content: assistant}
         ]
       end) ++
       [%{role: "user", content: user_content}])
    |> List.flatten()
  end

  # ── Config & adapter ──────────────────────────────────────────────

  defp config, do: Application.get_env(:insta_mealie, :openai, [])

  defp http_adapter do
    Application.get_env(:insta_mealie, :llm_http_adapter, InstaMealie.Llm.Real.Http)
  end
end

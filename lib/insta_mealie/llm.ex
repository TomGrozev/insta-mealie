defmodule InstaMealie.LLM.Envelope do
  @moduledoc """
  The LLM recipe verdict envelope.

  Carried through the pipeline as the output of `LLM.format/2` and `LLM.merge/3`.
  """
  defstruct [:recipe, :completeness, :missing_fields]
end

defmodule InstaMealie.LLM do
  @moduledoc """
  Single LLM module for routing/format/merge calls.

  Both calls return `{:ok, %InstaMealie.LLM.Envelope{}}` with fields:
  `completeness` (`:recipe_complete` | `:recipe_partial` | `:no_recipe`),
  `missing_fields` (list of atoms), and `recipe` (a `%Recipe{}` struct or empty map).

  ## Routing verdict contract

  A single routing call (Prompt 1) returns the verdict plus a (possibly
  partial) recipe. `missing_fields` is limited to the vocabulary
  `[:recipeIngredient, :recipeInstructions]` — anything else is dropped by
  `envelope_from_json/1`.

  The guard against a *spurious* `recipe_complete` verdict lives in the
  prompt, **not** in the interpreter. The FSM therefore trusts the
  verdict flatly: `recipe_complete` skips transcription, while
  `recipe_partial` AND `no_recipe` both fire transcription + merge.
  `no_recipe` must never cause a fabricated recipe name — that
  invariant is the prompt's responsibility; the interpreter only
  forwards what it is given.
  """
  require Logger

  alias InstaMealie.Error
  alias InstaMealie.LLM.Envelope
  alias InstaMealie.Recipe

  @type completeness :: :recipe_complete | :recipe_partial | :no_recipe
  @type envelope :: %Envelope{
          completeness: completeness(),
          missing_fields: list(),
          recipe: Recipe.t()
        }

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
      "Just vibing at the beach today 🌊 eating my fav food hotdogs and taking sunset pics. Follow for more travel and food content! #travel #hotdog #food #sunset #beachlife",
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

  @spec format(String.t(), keyword()) :: {:ok, envelope} | {:error, Error.t()}
  def format(caption, opts \\ []) do
    output_language = Keyword.get(opts, :output_language, "en")
    comments = Keyword.get(opts, :comments, [])

    cfg = config()
    model = cfg[:model]

    messages =
      build_format_messages(caption, output_language, comments)

    request_llm(:format, model, messages)
  end

  @spec merge(String.t(), String.t(), keyword()) :: {:ok, envelope} | {:error, Error.t()}
  def merge(caption, transcript, opts \\ []) do
    output_language = Keyword.get(opts, :output_language, "en")
    draft = Keyword.get(opts, :draft)

    cfg = config()
    model = cfg[:merge_model] || cfg[:model]

    messages =
      build_merge_messages(caption, transcript, output_language, draft)

    request_llm(:merge, model, messages)
  end

  # ── LLM request helper ────────────────────────────────────────────

  defp request_llm(op, model, messages) do
    adapter = Application.get_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Http)
    model = model || "unknown"
    start = System.monotonic_time(:millisecond)

    result = adapter.chat(model, messages)
    elapsed = System.monotonic_time(:millisecond) - start

    with {:ok, resp} <- result,
         {:ok, envelope} <- parse_content(resp) do
      Logger.info(
        "[llm] #{op} completed in #{elapsed}ms (model=#{model}, completeness=#{envelope.completeness})"
      )

      {:ok, envelope}
    else
      {:error, reason} ->
        llm_error(:api_error, reason, op, elapsed, model)
    end
  end

  defp llm_error(class, reason, op, elapsed, model) do
    Logger.error(
      "[llm] #{op} failed in #{elapsed}ms (model=#{model}, class=#{class}, reason=#{reason})"
    )

    {:error, Error.new(class, reason)}
  end

  # ── Content parser ─────────────────────────────────────────────────

  defp parse_content(response) do
    with content when is_binary(content) <-
           get_in(response, ["choices", Access.at(0), "message", "content"]),
         {:ok, json} when is_map(json) <- Jason.decode(content) do
      envelope = envelope_from_json(json)

      if valid_completeness?(envelope.completeness) do
        {:ok, envelope}
      else
        {:error, "unknown completeness verdict: " <> inspect(envelope.completeness)}
      end
    else
      {:ok, _} ->
        {:error, "completion was not a JSON object"}

      {:error, _} ->
        {:error, "invalid JSON in completion"}

      _ ->
        {:error, "no completion content"}
    end
  end

  # ── Pure envelope parser (Step 2) ─────────────────────────────────

  @doc "Construct an envelope from a parsed JSON map returned by the LLM."
  def envelope_from_json(json) when is_map(json) do
    completeness = parse_completeness(json["completeness"])
    missing_fields = parse_missing_fields(json["missing_fields"])

    recipe =
      (json["recipe"] || %{})
      |> normalize_durations()
      |> Recipe.from_map()

    %Envelope{completeness: completeness, missing_fields: missing_fields, recipe: recipe}
  end

  # ── Completeness whitelist ─────────────────────────────────────────

  defp parse_completeness("recipe_complete"), do: :recipe_complete
  defp parse_completeness("recipe_partial"), do: :recipe_partial
  defp parse_completeness("no_recipe"), do: :no_recipe
  defp parse_completeness(_), do: :unknown

  defp valid_completeness?(c), do: c in [:recipe_complete, :recipe_partial, :no_recipe]

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
            val = elem(Float.parse(n), 0)
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
        [] ->
          ""

        _ ->
          "\n\nOP comments:\n" <>
            Enum.map_join(comments, "\n", fn c ->
              text = c[:text] || c["text"] || "#{inspect(c)}"
              "  - #{text}"
            end)
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
    - Each `recipeIngredient` entry must be exactly ONE ingredient. Never combine multiple ingredients into a single entry using "+", "and", or a comma — split them into separate list entries instead (e.g. "Melted dark chocolate + 1 tsp coconut oil" becomes "Melted dark chocolate" and "1 tsp coconut oil").
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

        %Recipe{} = d ->
          payload = Recipe.to_prompt_projection(d)

          if map_size(payload) == 0 do
            ""
          else
            "\n\nPartial recipe draft from caption analysis:\n" <> Jason.encode!(payload)
          end

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
    - Each `recipeIngredient` entry must be exactly ONE ingredient. Never combine multiple ingredients into a single entry using "+", "and", or a comma — split them into separate list entries instead (e.g. "Melted dark chocolate + 1 tsp coconut oil" becomes "Melted dark chocolate" and "1 tsp coconut oil").
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

  # ── Config ────────────────────────────────────────────────────────

  defp config, do: Application.get_env(:insta_mealie, :openai, [])
end

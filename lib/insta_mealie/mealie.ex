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

defmodule InstaMealie.Mealie do
  @moduledoc """
  Single Mealie module for pushing recipe drafts into a Mealie instance.

  This module is a thin façade over `InstaMealie.Mealie.Adapter`. Each
  public function delegates to the configured adapter (default
  `InstaMealie.Mealie.Http`) and adds logging + the post-processing that
  belongs at the application boundary (e.g. shaping the parse response,
  rolling back an orphan draft on PATCH failure).

  The create flow is POST /api/recipes with a name to obtain a slug,
  then PATCH /api/recipes/{slug} with the full recipe.
  """

  require Logger
  alias InstaMealie.Error
  alias InstaMealie.Recipe
  alias InstaMealie.Mealie.RecipeRef

  # Resolve the configured adapter at call time so a test or alternate
  # implementation can be swapped in via `Application.put_env/3` without
  # a recompile. Default is the production HTTP client.
  defp impl,
    do: Application.get_env(:insta_mealie, InstaMealie.Mealie, InstaMealie.Mealie.Http)

  # ── Public API ─────────────────────────────────────────────────────

  @doc "Build a deep link from a Mealie slug or RecipeRef."
  def deep_link(%RecipeRef{slug: slug}), do: deep_link(slug)

  @spec deep_link(String.t() | RecipeRef.t()) :: String.t()
  def deep_link(slug) when is_binary(slug) do
    cfg = Application.get_env(:insta_mealie, :mealie, [])
    base = cfg[:base_url] || "http://localhost:9000"
    group = cfg[:group_slug] || "home"
    "#{base}/g/#{group}/r/#{slug}?edit=true"
  end

  @spec search_foods(String.t()) :: {:ok, list()} | {:error, Error.t()}
  def search_foods(term) when is_binary(term), do: search_collection("foods", term)

  @spec search_units(String.t()) :: {:ok, list()} | {:error, Error.t()}
  def search_units(term) when is_binary(term), do: search_collection("units", term)

  @spec search_recipes(String.t()) :: {:ok, list()} | {:error, Error.t()}
  def search_recipes(term) when is_binary(term), do: search_collection("recipes", term)

  @doc """
  Classify a `%Req.Response{}`-shaped map into `{:ok, body}` or
  `{:error, %Error{}}`. Delegates to the configured adapter's
  `classify_response/1` so callers can inspect HTTP responses without
  going through the named operations.
  """
  def classify_response(resp),
    do: impl().classify_response(resp)

  @spec parse_ingredients(list(String.t())) :: {:ok, list(map())} | {:error, Error.t()}
  def parse_ingredients(list) when is_list(list) do
    case impl().parse_ingredients(list) do
      {:ok, body} when is_list(body) ->
        Logger.info("[mealie] POST /api/parser/ingredients -> ok (parsed=#{length(body)})")

        parsed =
          Enum.map(body, fn item ->
            source = Map.get(item, "ingredient") || item
            unit = Map.get(source, "unit") || %{}
            food = Map.get(source, "food") || %{}

            # Extract all confidence sub-scores
            {food_conf, unit_conf, qty_conf, avg_conf} = extract_confidence(item, food)

            %{
              "quantity" => Map.get(source, "quantity"),
              "unit" => Map.get(unit, "name"),
              "unit_id" => Map.get(unit, "id"),
              "food" => Map.get(food, "name"),
              "food_id" => Map.get(food, "id"),
              "food_confidence" => food_conf,
              "unit_confidence" => unit_conf,
              "quantity_confidence" => qty_conf,
              "average_confidence" => avg_conf,
              "note" => Map.get(source, "note")
            }
          end)

        {:ok, parsed}

      {:error, %Error{} = error} ->
        Logger.error(
          "[mealie] POST /api/parser/ingredients failed (#{error.class}: #{error.summary})"
        )

        {:error, error}
    end
  end

  @doc """
  Import a recipe, optionally reusing an existing draft slug.

  This is the sole public write entrypoint into Mealie. When `existing_slug`
  is a non-nil binary the POST step is skipped and the recipe is PATCHed
  directly under that slug. When `nil` the normal POST-then-PATCH flow runs;
  if the PATCH fails after a successful POST, the orphaned stub is deleted
  before the error is returned so no draft is left dangling in Mealie.

  On success returns `{:ok, slug, deep_link}`. On failure returns
  `{:error, %Error{}}`.
  """
  @spec import_recipe(Recipe.t(), String.t() | nil) ::
          {:ok, String.t(), String.t()}
          | {:error, Error.t()}
  def import_recipe(%Recipe{} = recipe, existing_slug) when is_binary(existing_slug) do
    case impl().patch_recipe(existing_slug, recipe) do
      {:ok, _slug} ->
        _ = impl().upload_image(existing_slug, recipe.image)
        {:ok, existing_slug, deep_link(existing_slug)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def import_recipe(%Recipe{} = recipe, nil) do
    # Idempotency guard: check for existing recipe with same name
    slug =
      case recipe.name do
        nil ->
          nil

        name ->
          case search_recipes(name) do
            {:ok, results} ->
              Enum.find_value(results, fn r ->
                case RecipeRef.from_result(r) do
                  {:ok, ref} when ref.name == name -> ref.slug
                  _ -> nil
                end
              end)

            {:error, %Error{}} ->
              nil
          end
      end

    if slug do
      # Reuse existing recipe
      Logger.info("[mealie] import_recipe found existing recipe #{slug}, reusing")

      case impl().patch_recipe(slug, recipe) do
        {:ok, _slug} ->
          _ = impl().upload_image(slug, recipe.image)
          {:ok, slug, deep_link(slug)}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    else
      name = recipe.name || "Untitled recipe"

      case impl().create_recipe(name) do
        {:ok, %RecipeRef{slug: slug} = ref} ->
          case impl().patch_recipe(slug, recipe) do
            {:ok, _slug} ->
              _ = impl().upload_image(slug, recipe.image)
              {:ok, slug, deep_link(ref)}

            {:error, %Error{} = error} ->
              # Roll back the orphaned draft
              _ = impl().delete_recipe(slug)
              {:error, error}
          end

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  end

  # ── Private helpers ────────────────────────────────────────────────

  defp search_collection(type, term) do
    case impl().search(type, term) do
      {:ok, results} ->
        Logger.info("[mealie] GET /api/#{type} -> ok (results=#{length(results)})")
        {:ok, results}

      {:error, %Error{} = error} ->
        Logger.error("[mealie] GET /api/#{type} failed (#{error.class}: #{error.summary})")
        {:error, error}
    end
  end

  defp extract_confidence(item, food) do
    conf = Map.get(item, "confidence")
    food_conf = get_confidence(conf, "food") || Map.get(food, "confidence")
    unit_conf = get_confidence(conf, "unit")
    qty_conf = get_confidence(conf, "quantity")
    avg_conf = get_confidence(conf, "average") || food_conf
    {food_conf, unit_conf, qty_conf, avg_conf}
  end

  defp get_confidence(%{} = conf, key) do
    case Map.get(conf, key) do
      val when is_number(val) -> val
      _ -> nil
    end
  end

  defp get_confidence(_, _key), do: nil
end

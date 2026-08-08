defmodule InstaMealie.Mealie do
  @moduledoc """
  Single Mealie module for pushing recipe drafts into a Mealie instance.

  The create flow is POST /api/recipes with a name to obtain a slug,
  then PUT /api/recipes/{slug} with the full recipe.
  """

  require Logger
  alias InstaMealie.Recipe

  # ── Public API ─────────────────────────────────────────────────────

  @spec deep_link(String.t()) :: String.t()
  def deep_link(slug) when is_binary(slug) do
    cfg = Application.get_env(:insta_mealie, :mealie, [])
    base = cfg[:base_url] || "http://localhost:9000"
    group = cfg[:group_slug] || "home"
    "#{base}/g/#{group}/r/#{slug}?edit=true"
  end

  @spec search_foods(String.t()) :: {:ok, list()} | {:error, atom(), term()}
  def search_foods(term) when is_binary(term), do: search_collection("foods", term)

  @spec search_units(String.t()) :: {:ok, list()} | {:error, atom(), term()}
  def search_units(term) when is_binary(term), do: search_collection("units", term)

  @spec search_recipes(String.t()) :: {:ok, list()} | {:error, atom(), term()}
  def search_recipes(term) when is_binary(term) do
    path = "/api/recipes?perPage=5&search=#{URI.encode_www_form(term)}"

    case request(:get, path) do
      {:ok, body} ->
        results =
          if Map.has_key?(body, "items"),
            do: body["items"],
            else: Map.get(body, "data", [])

        Logger.info("[mealie] GET /api/recipes search=#{term} -> ok (results=#{length(results)})")
        {:ok, results}

      {:error, class, reason} ->
        Logger.error("[mealie] GET /api/recipes search=#{term} failed (#{class}: #{reason})")
        {:error, class, reason}
    end
  end

  @spec parse_ingredients(list(String.t())) :: {:ok, list(map())} | {:error, atom(), term()}
  def parse_ingredients(list) when is_list(list) do
    payload = %{"ingredients" => list}

    case request(:post, "/api/parser/ingredients", payload) do
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

      {:ok, _other} ->
        Logger.warning("[mealie] POST /api/parser/ingredients returned unexpected response")
        {:error, :api_error, "unexpected parse response"}

      {:error, class, reason} ->
        Logger.error("[mealie] POST /api/parser/ingredients failed (#{class}: #{reason})")
        {:error, class, reason}
    end
  end

  @doc """
  Import a recipe, optionally reusing an existing draft slug.

  This is the sole public write entrypoint into Mealie. When `existing_slug`
  is a non-nil binary the POST step is skipped and the recipe is PUT directly
  under that slug. When `nil` the normal POST-then-PUT flow runs; if the PUT
  fails after a successful POST, the orphaned stub is deleted before the
  error is returned so no draft is left dangling in Mealie.

  On success returns `{:ok, slug, deep_link}`. On failure returns
  `{:error, class, reason}`.
  """
  @spec import_recipe(Recipe.t(), String.t() | nil) ::
          {:ok, String.t(), String.t()}
          | {:error, atom(), term()}
  def import_recipe(%Recipe{} = recipe, existing_slug) when is_binary(existing_slug) do
    case update_recipe(existing_slug, recipe) do
      {:ok, _slug} -> {:ok, existing_slug, deep_link(existing_slug)}
      {:error, class, reason} -> {:error, class, reason}
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
              match = Enum.find(results, fn r -> (r["name"] || r[:name]) == name end)

              if match, do: match["slug"] || match[:slug] || match["id"] || match[:id]

            {:error, _class, _reason} ->
              nil
          end
      end

    if slug do
      # Reuse existing recipe
      Logger.info("[mealie] import_recipe found existing recipe #{slug}, reusing")

      case update_recipe(slug, recipe) do
        {:ok, _slug} -> {:ok, slug, deep_link(slug)}
        {:error, class, reason} -> {:error, class, reason}
      end
    else
      case create_recipe(recipe) do
        {:ok, slug} ->
          case update_recipe(slug, recipe) do
            {:ok, _slug} -> {:ok, slug, deep_link(slug)}
            {:error, class, reason} ->
              # Roll back the orphaned draft
              delete_recipe(slug)
              {:error, class, reason}
          end

        {:error, class, reason} ->
          {:error, class, reason}
      end
    end
  end

  def classify_response(%{status: st, body: body}) do
    case InstaMealie.HttpClassify.classify(st) do
      :ok ->
        {:ok, body}

      {:error, class, reason} ->
        {:error, class, format_error_reason(reason, body)}
    end
  end

  # ── Private helpers ────────────────────────────────────────────────

  @spec create_recipe(Recipe.t()) :: {:ok, String.t()} | {:error, atom(), term()}
  defp create_recipe(%Recipe{name: name}) do
    name = name || "Untitled recipe"

    case request(:post, "/api/recipes", %{name: name}) do
      {:ok, body} when is_map(body) ->
        Logger.info("[mealie] POST /api/recipes -> ok (slug=#{body["slug"] || body["id"]})")
        {:ok, body["slug"] || body["id"]}

      {:ok, slug} when is_binary(slug) ->
        Logger.info("[mealie] POST /api/recipes -> ok (slug=#{slug})")
        {:ok, slug}

      {:ok, other} ->
        Logger.warning("[mealie] POST /api/recipes returned unexpected response shape")
        {:error, :api_error, "unexpected create response: #{inspect(other)}"}

      {:error, class, reason} ->
        Logger.error("[mealie] POST /api/recipes failed (#{class}: #{reason})")
        {:error, class, reason}
    end
  end

  @spec update_recipe(String.t(), Recipe.t()) :: {:ok, String.t()} | {:error, atom(), term()}
  defp update_recipe(slug, %Recipe{} = recipe) when is_binary(slug) do
    payload = Recipe.to_mealie_payload(recipe)

    Logger.debug("[mealie] PATCH /api/recipes/#{slug} payload keys: #{inspect(Map.keys(payload))}")

    case request(:patch, "/api/recipes/#{slug}", payload) do
      {:ok, _} ->
        _ = upload_image_if_present(slug, recipe)
        Logger.info("[mealie] PATCH /api/recipes/#{slug} -> ok")
        {:ok, slug}

      {:error, class, reason} ->
        Logger.error("[mealie] PATCH /api/recipes/#{slug} failed (#{class}: #{reason})")
        {:error, class, reason}
    end
  end

  defp delete_recipe(slug) when is_binary(slug) do
    case request(:delete, "/api/recipes/#{slug}") do
      {:ok, _} ->
        Logger.info("[mealie] DELETE /api/recipes/#{slug} -> ok")
        :ok

      {:error, class, reason} ->
        Logger.error("[mealie] DELETE /api/recipes/#{slug} failed (#{class}: #{reason})")
        {:error, class, reason}
    end
  end

  @spec format_error_reason(String.t(), term()) :: String.t()
  defp format_error_reason(reason, body) when body in [nil, %{}, []], do: reason

  defp format_error_reason(reason, body) do
    truncated = inspect(body, limit: 500, printable_limit: 300)
    "#{reason}: #{truncated}"
  end

  defp search_collection(type, term) do
    path = "/api/#{type}?perPage=25&search=#{URI.encode_www_form(term)}"

    case request(:get, path) do
      {:ok, body} ->
        results =
          if Map.has_key?(body, "items"),
            do: body["items"],
            else: Map.get(body, "data", [])

        Logger.info("[mealie] GET /api/#{type} -> ok (results=#{length(results)})")
        {:ok, results}

      {:error, class, reason} ->
        Logger.error("[mealie] GET /api/#{type} failed (#{class}: #{reason})")
        {:error, class, reason}
    end
  end

  # ---- image ----

  defp upload_image_if_present(slug, %Recipe{image: image}) do
    case image do
      nil ->
        :ok

      url when is_binary(url) ->
        if String.starts_with?(url, "http://") or String.starts_with?(url, "https://") do
          case request(:post, "/api/recipes/#{slug}/image", %{url: url}) do
            {:ok, _} ->
              Logger.info("[mealie] POST /api/recipes/#{slug}/image (url) -> ok")
              :ok

            {:error, class, reason} ->
              Logger.error(
                "[mealie] POST /api/recipes/#{slug}/image (url) failed (#{class}: #{reason})"
              )

              :ok
          end
        else
          if File.exists?(url) do
            upload_image_file(slug, url)
          else
            :ok
          end
        end
    end
  end

  defp upload_image_file(slug, path) do
    url = base_url() <> "/api/recipes/#{slug}/image"

    try do
      resp =
        Req.put!(url,
          headers: auth_headers(),
          form: [
            image: {:file, path},
            extension: Path.extname(path) |> String.trim_leading(".")
          ]
        )

      Logger.debug("[mealie] PUT /api/recipes/#{slug}/image (file) status=#{resp.status}")

      case classify_response(resp) do
        {:ok, _} -> {:ok, resp.status}

        {:error, class, reason} ->
          Logger.error(
            "[mealie] PUT /api/recipes/#{slug}/image (file) failed (#{class}: #{reason})"
          )

          :ok
      end
    rescue
      _e -> :ok
    end
  end

  # ---- http ----

  defp request(method, path, body \\ nil) do
    adapter = Application.get_env(:insta_mealie, :mealie_http_adapter, &default_mealie_req/3)

    adapter.(method, path, body)
  end

  defp default_mealie_req(method, path, body) do
    cfg = mealie_config()
    url = (cfg[:base_url] || "http://localhost:9000") <> path

    req_args = [method: method, url: url, headers: auth_headers()]

    req =
      if(body, do: Keyword.put(req_args, :json, body), else: req_args)
      |> Req.new()

    start = System.monotonic_time(:millisecond)

    try do
      resp = Req.request!(req)
      elapsed = System.monotonic_time(:millisecond) - start

      Logger.debug(
        "[mealie] #{method |> to_string() |> String.upcase()} #{path} status=#{resp.status} #{elapsed}ms"
      )

      classify_response(resp)
    rescue
      e -> {:error, :network, Exception.message(e)}
    end
  end

  defp auth_headers do
    token = mealie_config()[:api_token] || ""
    [{"Authorization", "Bearer #{token}"}]
  end

  defp base_url, do: mealie_config()[:base_url] || "http://localhost:9000"

  defp mealie_config, do: Application.get_env(:insta_mealie, :mealie, [])

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

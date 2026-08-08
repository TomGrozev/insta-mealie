defmodule InstaMealie.Mealie do
  @moduledoc """
  Single Mealie module for pushing recipe drafts into a Mealie instance.

  The create flow is POST /api/recipes with a name to obtain a slug,
  then PUT /api/recipes/{slug} with the full recipe.
  """

  @payload_keys ~w(name description recipeYield recipeIngredient recipeInstructions tags categories notes totalTime prepTime cookTime performTime)

  # ── Public API ─────────────────────────────────────────────────────

  @spec create_recipe(map()) :: {:ok, String.t()} | {:error, atom(), term()}
  def create_recipe(recipe) when is_map(recipe) do
    name = recipe["name"] || recipe[:name] || "Untitled recipe"

    case request(:post, "/api/recipes", %{name: name}) do
      {:ok, body} -> {:ok, body["slug"] || body["id"]}
      {:error, class, reason} -> {:error, class, reason}
    end
  end

  @spec update_recipe(String.t(), map()) :: {:ok, String.t()} | {:error, atom(), term()}
  def update_recipe(slug, recipe) when is_binary(slug) and is_map(recipe) do
    payload = build_payload(recipe)

    with {:ok, _} <- request(:put, "/api/recipes/#{slug}", payload),
         :ok <- upload_image_if_present(slug, recipe) do
      {:ok, slug}
    else
      {:error, class, reason} -> {:error, class, reason}
    end
  end

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

  @spec parse_ingredients(list(String.t())) :: {:ok, list(map())} | {:error, atom(), term()}
  def parse_ingredients(list) when is_list(list) do
    payload = Enum.map(list, fn text -> %{text: text} end)

    case request(:post, "/api/parser/ingredients", payload) do
      {:ok, body} when is_list(body) ->
        parsed =
          Enum.map(body, fn item ->
            unit = Map.get(item, "unit") || %{}
            food = Map.get(item, "food") || %{}

            %{
              "quantity" => Map.get(item, "quantity"),
              "unit" => Map.get(unit, "name"),
              "unit_id" => Map.get(unit, "id"),
              "food" => Map.get(food, "name"),
              "food_id" => Map.get(food, "id"),
              "food_confidence" => get_in(food, ["confidence"]),
              "note" => Map.get(item, "note")
            }
          end)

        {:ok, parsed}

      {:ok, _other} ->
        {:error, :api_error, "unexpected parse response"}

      {:error, class, reason} ->
        {:error, class, reason}
    end
  end

  @spec import_recipe(map()) :: {:ok, String.t(), String.t()} | {:error, atom(), term()}
  def import_recipe(recipe) do
    with {:ok, slug} <- create_recipe(recipe),
         {:ok, slug} <- update_recipe(slug, recipe) do
      {:ok, slug, deep_link(slug)}
    else
      {:error, class, reason} -> {:error, class, reason}
    end
  end

  @doc false
  def build_payload(recipe) when is_map(recipe) do
    Enum.reduce(@payload_keys, %{}, fn key, acc ->
      case Map.get(recipe, key) || Map.get(recipe, String.to_atom(key)) do
        nil -> acc
        val -> Map.put(acc, key, val)
      end
    end)
  end

  @doc false
  def classify_response(%{status: st, body: body}) do
    case InstaMealie.HttpClassify.classify(st) do
      :ok -> {:ok, body}
      {:error, class, reason} -> {:error, class, reason}
    end
  end

  # ── Private helpers ────────────────────────────────────────────────

  defp search_collection(type, term) do
    case request(:get, "/api/#{type}?perPage=25&search=#{URI.encode_www_form(term)}") do
      {:ok, body} -> {:ok, Map.get(body, "data", [])}
      {:error, class, reason} -> {:error, class, reason}
    end
  end

  # ---- image ----

  defp upload_image_if_present(slug, recipe) do
    case recipe["image"] || recipe[:image] do
      nil ->
        :ok

      url when is_binary(url) ->
        if String.starts_with?(url, "http://") or String.starts_with?(url, "https://") do
          case request(:post, "/api/recipes/#{slug}/image", %{url: url}) do
            {:ok, _} -> :ok
            {:error, class, reason} -> {:error, class, reason}
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
      resp = Req.put!(url, headers: auth_headers(), form: [image: {:file, path}])

      case classify_response(resp) do
        {:ok, _} -> {:ok, resp.status}
        {:error, class, reason} -> {:error, class, reason}
      end
    rescue
      e -> {:error, :network, Exception.message(e)}
    end
  end

  # ---- http ----

  defp request(method, path, body \\ nil) do
    adapter = Application.get_env(:insta_mealie, :mealie_http_adapter, &default_mealie_req/1)
    adapter.(%{method: method, path: path, body: body})
  end

  defp default_mealie_req(%{method: method, path: path, body: body}) do
    cfg = mealie_config()
    url = (cfg[:base_url] || "http://localhost:9000") <> path

    req =
      if body do
        Req.new(method: method, url: url, headers: auth_headers(), json: body)
      else
        Req.new(method: method, url: url, headers: auth_headers())
      end

    try do
      resp = Req.request!(req)
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
end

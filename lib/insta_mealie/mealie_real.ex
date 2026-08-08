defmodule InstaMealie.Mealie.Real do
  @moduledoc """
  Req-backed Mealie client implementing the `InstaMealie.Mealie` behaviour.

  Import flow (per spec / ADR 0003):
    1. POST /api/recipes {name}            -> slug
    2. PUT  /api/recipes/{slug} (payload)  -> updated
    3. optional image upload (PUT .../image multipart, or POST {url:})

  Candidate search via /api/foods and /api/units backs the later
  unknown-ingredient review screen.
  """
  @behaviour InstaMealie.Mealie

  @payload_keys ~w(name description recipeYield recipeIngredient recipeInstructions tags categories notes totalTime prepTime cookTime performTime)

  @impl true
  def create_recipe(recipe) when is_map(recipe) do
    name = recipe["name"] || recipe[:name] || "Untitled recipe"

    case request(:post, "/api/recipes", %{name: name}) do
      {:ok, body} -> {:ok, body["slug"] || body["id"]}
      {:error, class, reason} -> {:error, class, reason}
    end
  end

  @impl true
  def update_recipe(slug, recipe) when is_binary(slug) and is_map(recipe) do
    payload = build_payload(recipe)

    with {:ok, _} <- request(:put, "/api/recipes/#{slug}", payload),
         :ok <- upload_image_if_present(slug, recipe) do
      {:ok, slug}
    else
      {:error, class, reason} -> {:error, class, reason}
    end
  end

  @impl true
  def deep_link(slug) when is_binary(slug) do
    base = mealie_config()[:base_url] || "http://localhost:9000"
    group = mealie_config()[:group_slug] || "home"
    "#{base}/g/#{group}/r/#{slug}?edit=true"
  end

  @impl true
  def search_foods(term) when is_binary(term), do: search_collection("foods", term)

  @impl true
  def search_units(term) when is_binary(term), do: search_collection("units", term)

  @impl true
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

  # ---- payload ----

  @doc false
  def build_payload(recipe) when is_map(recipe) do
    Enum.reduce(@payload_keys, %{}, fn key, acc ->
      case Map.get(recipe, key) || Map.get(recipe, String.to_atom(key)) do
        nil -> acc
        val -> Map.put(acc, key, val)
      end
    end)
  end

  # ---- http ----

  defp request(method, path, body \\ nil) do
    url = base_url() <> path

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

  @doc false
  def classify_response(%{status: st, body: body}) when st in 200..299, do: {:ok, body}
  def classify_response(%{status: 401}), do: {:error, :auth, "unauthorized"}
  def classify_response(%{status: 403}), do: {:error, :auth, "forbidden"}
  def classify_response(%{status: 422}), do: {:error, :validation, "validation failed"}

  def classify_response(%{status: st}) when st in 400..499,
    do: {:error, :api_error, "client error #{st}"}

  def classify_response(%{status: st}) when st >= 500,
    do: {:error, :network, "server error #{st}"}

  defp auth_headers do
    token = mealie_config()[:api_token] || ""
    [{"Authorization", "Bearer #{token}"}]
  end

  defp base_url, do: mealie_config()[:base_url] || "http://localhost:9000"

  defp mealie_config, do: Application.get_env(:insta_mealie, :mealie, [])
end

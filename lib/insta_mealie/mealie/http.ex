defmodule InstaMealie.Mealie.Http do
  @moduledoc false
  @behaviour InstaMealie.Mealie.Adapter

  alias InstaMealie.Error
  alias InstaMealie.Recipe
  alias InstaMealie.Mealie.RecipeRef

  require Logger

  # ── @behaviour callbacks ───────────────────────────────────────────

  @impl true
  def create_recipe(name) when is_binary(name) do
    case request(:post, "/api/recipes", %{name: name}) do
      {:ok, body} when is_map(body) ->
        case body["slug"] do
          slug when is_binary(slug) ->
            {:ok, %RecipeRef{slug: slug, name: name}}

          _ ->
            {:error, Error.new(:api_error, "create response missing slug")}
        end

      {:ok, slug} when is_binary(slug) ->
        {:ok, slug}

      {:ok, other} ->
        {:error, Error.new(:api_error, "unexpected create response: #{inspect(other)}")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @impl true
  def patch_recipe(slug, %Recipe{} = recipe) when is_binary(slug) do
    payload = Recipe.to_mealie_payload(recipe)

    case request(:patch, "/api/recipes/#{slug}", payload) do
      {:ok, _} -> {:ok, slug}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @impl true
  def delete_recipe(slug) when is_binary(slug) do
    case request(:delete, "/api/recipes/#{slug}") do
      {:ok, _} -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @impl true
  def search(type, term) when is_binary(type) and is_binary(term) do
    per_page = if type == "recipes", do: 5, else: 25
    path = "/api/#{type}?perPage=#{per_page}&search=#{URI.encode_www_form(term)}"

    case request(:get, path) do
      {:ok, body} ->
        results = extract_results(body)
        {:ok, results}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @impl true
  def parse_ingredients(list) when is_list(list) do
    case request(:post, "/api/parser/ingredients", %{"ingredients" => list}) do
      {:ok, body} when is_list(body) -> {:ok, body}
      {:ok, _other} -> {:error, Error.new(:api_error, "unexpected parse response")}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @impl true
  def upload_image(slug, image) when is_binary(slug) do
    cond do
      is_nil(image) ->
        :ok

      String.starts_with?(image, "http://") or String.starts_with?(image, "https://") ->
        upload_image_url(slug, image)

      File.exists?(image) ->
        upload_image_file(slug, image)

      true ->
        :ok
    end
  end

  # ── Image upload helpers ───────────────────────────────────────────

  defp upload_image_url(slug, url) do
    case request(:post, "/api/recipes/#{slug}/image", %{url: url}) do
      {:ok, _} -> :ok
      {:error, %Error{} = error} -> {:error, error}
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
        {:ok, _} -> :ok
        {:error, %Error{} = error} -> {:error, error}
      end
    rescue
      e -> {:error, Error.new(:network, Exception.message(e))}
    end
  end

  # ── HTTP plumbing (extracted from Mealie) ──────────────────────────

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
      e -> {:error, Error.new(:network, Exception.message(e))}
    end
  end

  @doc "Classify a `%Req.Response{}`-shaped map into `{:ok, body}` or `{:error, %Error{}}`."
  def classify_response(%{status: st, body: body}) do
    case InstaMealie.HttpClassify.classify(st) do
      :ok ->
        {:ok, body}

      %Error{} = error ->
        {:error, %{error | summary: format_error_reason(error.summary, body)}}
    end
  end

  @spec format_error_reason(String.t(), term()) :: String.t()
  defp format_error_reason(reason, body) when body in [nil, %{}, []], do: reason

  defp format_error_reason(reason, body) do
    truncated = inspect(body, limit: 500, printable_limit: 300)
    "#{reason}: #{truncated}"
  end

  # ── Config & headers ───────────────────────────────────────────────

  defp auth_headers do
    token = mealie_config()[:api_token] || ""
    [{"Authorization", "Bearer #{token}"}]
  end

  defp base_url, do: mealie_config()[:base_url] || "http://localhost:9000"

  defp mealie_config, do: Application.get_env(:insta_mealie, :mealie, [])

  defp extract_results(%{"items" => items}) when is_list(items), do: items
  defp extract_results(%{"data" => data}) when is_list(data), do: data
  defp extract_results(_), do: []
end

defmodule InstaMealie.Mealie do
  @moduledoc """
  Single Mealie module for pushing recipe drafts into a Mealie instance.

  Wraps Mealie's HTTP API with the post-processing that belongs at the
  application boundary (e.g. shaping the parse response, rolling back an
  orphan draft on PATCH failure).

  The create flow is POST /api/recipes with a name to obtain a slug,
  then PATCH /api/recipes/{slug} with the full recipe.
  """

  require Logger

  alias InstaMealie.Error
  alias InstaMealie.Recipe
  alias InstaMealie.Mealie.RecipeRef

  # ── Public API ─────────────────────────────────────────────────────

  @doc "Build a deep link from a Mealie slug or RecipeRef."
  @spec deep_link(String.t() | RecipeRef.t()) :: String.t()
  def deep_link(%RecipeRef{slug: slug}), do: deep_link(slug)

  def deep_link(slug) when is_binary(slug) do
    cfg = Application.get_env(:insta_mealie, :mealie, [])
    base = cfg[:base_url] || "http://localhost:9000"
    group = cfg[:group_slug] || "home"
    "#{base}/g/#{group}/r/#{slug}?edit=true"
  end

  @spec search_foods(String.t()) :: {:ok, list()} | {:error, Error.t()}
  def search_foods(term) when is_binary(term), do: search_collection("foods", term)

  @doc """
  Resolve a food name to an existing Mealie food or create it, and return
  the food's id.

  Searches `/api/foods` first and reuses any result whose `name` field
  matches the input exactly (the existing client semantics — no
  case-insensitive or slug-equivalence fallback). When no exact match
  exists, POSTs `/api/foods` with a name-only payload to create it.

  Search and create errors are propagated verbatim — failures are never
  treated as "food not found", which would silently mask the real cause
  and risk creating a duplicate record.
  """
  @spec get_or_create_food(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def get_or_create_food(name) when is_binary(name) do
    case search_foods(name) do
      {:ok, results} ->
        case find_exact_food_id(results, name) do
          {:ok, food_id} ->
            Logger.info(
              "[mealie] get_or_create_food reused existing food #{food_id} for #{inspect(name)}"
            )

            {:ok, food_id}

          :none ->
            create_food(name)
        end

      {:error, %Error{} = error} ->
        Logger.error(
          "[mealie] get_or_create_food search failed (#{error.class}: #{error.summary})"
        )

        {:error, error}
    end
  end

  @spec search_units(String.t()) :: {:ok, list()} | {:error, Error.t()}
  def search_units(term) when is_binary(term), do: search_collection("units", term)

  @doc """
  Resolve a unit name to an existing Mealie unit or create it, and return
  the unit's id.

  Searches `/api/units` first and reuses any result whose `name` field
  matches the input exactly (the existing client semantics — no
  case-insensitive or slug-equivalence fallback). When no exact match
  exists, POSTs `/api/units` with a name-only payload to create it.

  Search and create errors are propagated verbatim — failures are never
  treated as "unit not found", which would silently mask the real cause
  and risk creating a duplicate record.
  """
  @spec get_or_create_unit(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def get_or_create_unit(name) when is_binary(name) do
    case search_units(name) do
      {:ok, results} ->
        case find_exact_unit_id(results, name) do
          {:ok, unit_id} ->
            Logger.info(
              "[mealie] get_or_create_unit reused existing unit #{unit_id} for #{inspect(name)}"
            )

            {:ok, unit_id}

          :none ->
            create_unit(name)
        end

      {:error, %Error{} = error} ->
        Logger.error(
          "[mealie] get_or_create_unit search failed (#{error.class}: #{error.summary})"
        )

        {:error, error}
    end
  end

  @spec parse_ingredients(list(String.t())) :: {:ok, list(map())} | {:error, Error.t()}
  def parse_ingredients(list) when is_list(list) do
    case request(:post, "/api/parser/ingredients", %{"ingredients" => list}) do
      {:ok, body} when is_list(body) ->
        Logger.info("[mealie] POST /api/parser/ingredients -> ok (parsed=#{length(body)})")
        {:ok, Enum.map(body, &parse_ingredient_item/1)}

      {:ok, _other} ->
        {:error, Error.new(:api_error, "unexpected parse response")}

      {:error, %Error{} = error} ->
        Logger.error(
          "[mealie] POST /api/parser/ingredients failed (#{error.class}: #{error.summary})"
        )

        {:error, error}
    end
  end

  @doc """
  Scrape a recipe URL via Mealie's test-scrape-url endpoint and return the
  parsed recipe without creating anything in Mealie.

  Wraps `POST /api/recipes/test-scrape-url`, which uses recipe-scrapers
  (with site-specific parsers and a wild-mode fallback) to parse a
  recipe page and return its schema.org/Recipe JSON-LD content.

  Returns `{:ok, %Recipe{}}` on success, or `{:error, %Error{}}` on
  failure (e.g. a 400 when the URL is not scrapeable, or a 408 timeout).
  No retry or candidate-list logic happens here — that orchestration
  belongs to the pipeline stage that calls this function.
  """
  @spec scrape_url(String.t()) :: {:ok, Recipe.t()} | {:error, Error.t()}
  def scrape_url(url) when is_binary(url) do
    case request(:post, "/api/recipes/test-scrape-url", %{"url" => url, "useOpenAI" => false}) do
      {:ok, body} when is_map(body) ->
        Logger.info("[mealie] POST /api/recipes/test-scrape-url -> ok")
        {:ok, Recipe.from_map(body)}

      {:error, %Error{} = error} ->
        Logger.error(
          "[mealie] POST /api/recipes/test-scrape-url failed (#{error.class}: #{error.summary})"
        )

        {:error, error}
    end
  end

  @doc """
  Import a recipe. Reuses an existing draft with the same slug if one exists,
  otherwise creates it.

  `fetch_dir` constrains which local-file paths are acceptable for
  `Recipe.image` (see `upload_image/3`). It is the per-job temp directory
  that `InstaMealie.YtDlp` created for the reel fetch — the only place a
  legitimate local thumbnail ever lives. Pass `nil` for caption-only
  jobs and for jobs whose GenServer was revived from an ETS snapshot;
  in both cases the gate fails closed and any non-URL `recipe.image`
  is rejected with a logged warning.

  On success returns `{:ok, slug, deep_link}`. On failure returns
  `{:error, %Error{}}`.
  """
  @spec import_recipe(Recipe.t(), String.t() | nil) ::
          {:ok, String.t(), String.t()}
          | {:error, Error.t()}
  def import_recipe(%Recipe{} = recipe, fetch_dir) do
    name = recipe.name || "Untitled recipe"
    slug = slugify(name)

    # `maybe_create_recipe/2` distinguishes whether THIS call created the
    # recipe (`:created`) or only reused a pre-existing one (`:reused`) — the
    # rollback below must only fire when we own the slug we are about to
    # touch, never when the slug pre-dates this call. See
    # `maybe_create_recipe/2`'s docstring and the regression tests in
    # `test/insta_mealie/mealie_real_test.exs`.
    case maybe_create_recipe(slug, name) do
      {:ok, create_status} ->
        with {:ok, ^slug} <- patch_recipe(slug, recipe),
             :ok <- upload_image(slug, recipe.image, fetch_dir) do
          {:ok, slug, deep_link(slug)}
        else
          {:error, %Error{} = error} ->
            if create_status == :created, do: delete_recipe(slug)
            {:error, error}
        end

      {:error, %Error{} = error} ->
        # No recipe was created or reused — propagate the failure.
        {:error, error}
    end
  end

  # Ensure a recipe exists at `slug`, either by creating a new draft or by
  # confirming a pre-existing one. Only a HTTP 404 from the GET — i.e.
  # `Error{class: :not_found}` — is treated as "doesn't exist"; any other
  # failure (network, auth, rate-limited, generic 4xx, 5xx) propagates
  # verbatim. Without this gate, a transient 5xx on the GET would otherwise
  # be mis-classified as "recipe missing", prompting `create_recipe/1` which
  # against a name that genuinely exists server-side silently suffixes the
  # name with " (1)", " (2)", ... and returns a *different* slug — matching
  # no `with` pattern and raising `WithClauseError` while leaving a duplicate
  # orphan recipe in Mealie.
  #
  # Returns `{:ok, :created}` when this call created the recipe,
  # `{:ok, :reused}` when an existing recipe was found, or
  # `{:error, %Error{}}` on any failure.
  defp maybe_create_recipe(slug, name) do
    with {:error, %Error{class: :not_found}} <- get_recipe(slug),
         {:ok, %RecipeRef{slug: ^slug}} <- create_recipe(name) do
      {:ok, :created}
    else
      {:ok, %RecipeRef{slug: ^slug}} ->
        Logger.info("[mealie] import_recipe found existing recipe #{slug}, reusing")
        {:ok, :reused}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  # ── Recipe CRUD ────────────────────────────────────────────────────

  defp create_recipe(name) when is_binary(name) do
    case request(:post, "/api/recipes", %{name: name}) do
      {:ok, body} when is_map(body) ->
        case body["slug"] do
          slug when is_binary(slug) ->
            {:ok, %RecipeRef{slug: slug, name: name}}

          _ ->
            {:error, Error.new(:api_error, "create response missing slug")}
        end

      {:ok, slug} when is_binary(slug) ->
        {:ok, %RecipeRef{slug: slug, name: name}}

      {:ok, other} ->
        {:error, Error.new(:api_error, "unexpected create response: #{inspect(other)}")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp get_recipe(slug) when is_binary(slug) do
    case request(:get, "/api/recipes/#{slug}") do
      {:ok, body} when is_map(body) ->
        case body["slug"] do
          found when is_binary(found) ->
            {:ok, %RecipeRef{slug: found, name: body["name"]}}

          _ ->
            {:error, Error.new(:api_error, "get response missing slug")}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp patch_recipe(slug, %Recipe{} = recipe) when is_binary(slug) do
    # Mealie treats "name" in PATCH as a rename and false-positives "already exists" against itself
    with {:ok, tag_refs} <- resolve_tags(recipe.tags),
         {:ok, category_refs} <- resolve_categories(recipe.categories) do
      payload =
        recipe
        |> Recipe.to_mealie_payload()
        |> put_or_delete("tags", tag_refs)
        |> put_or_delete("recipeCategory", category_refs)

      case request(:patch, "/api/recipes/#{slug}", payload) do
        {:ok, _} -> {:ok, slug}
        {:error, %Error{} = error} -> {:error, error}
      end
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  # Bare-string tag/category names in PATCH get auto-created server-side, so reusing
  # any name across two recipes collides on the unique-slug index. Resolve to existing
  # id/name/slug refs by slug lookup, creating only when the name is new.
  defp resolve_tags(nil), do: {:ok, nil}
  defp resolve_tags([]), do: {:ok, []}
  defp resolve_tags(names) when is_list(names), do: resolve_tag_refs(names, "tags")

  defp resolve_categories(nil), do: {:ok, nil}
  defp resolve_categories([]), do: {:ok, []}
  defp resolve_categories(names) when is_list(names), do: resolve_tag_refs(names, "categories")

  defp resolve_tag_refs(names, kind) when is_list(names) and is_binary(kind) do
    with {:ok, by_slug} <- fetch_organizer_index(kind),
         {:ok, refs} <- resolve_names_against(names, by_slug, kind) do
      {:ok, refs}
    end
  end

  # One list call returns every existing organizer; per-name GETs would round-trip
  # the API once per name even when nothing needs to be created.
  defp fetch_organizer_index(kind) when is_binary(kind) do
    case request(:get, "/api/organizers/#{kind}?perPage=-1") do
      {:ok, %{"items" => items}} when is_list(items) ->
        index =
          Enum.reduce(items, %{}, fn item, acc ->
            case item do
              %{"id" => id, "name" => n, "slug" => s} when is_binary(s) ->
                Map.put(acc, s, %{"id" => id, "name" => n, "slug" => s})

              _ ->
                acc
            end
          end)

        {:ok, index}

      {:ok, other} ->
        {:error, Error.new(:api_error, "unexpected organizers list response: #{inspect(other)}")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp resolve_names_against(names, by_slug, kind) do
    case Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
           slug = slugify(name)

           case Map.fetch(by_slug, slug) do
             {:ok, ref} ->
               {:cont, {:ok, [ref | acc]}}

             :error ->
               case request(:post, "/api/organizers/#{kind}", %{name: name}) do
                 {:ok, %{"id" => id, "name" => n, "slug" => s}} ->
                   {:cont, {:ok, [%{"id" => id, "name" => n, "slug" => s} | acc]}}

                 {:error, %Error{} = error} ->
                   {:halt, {:error, error}}
               end
           end
         end) do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp put_or_delete(map, _key, nil), do: map
  defp put_or_delete(map, _key, []), do: map
  defp put_or_delete(map, key, value), do: Map.put(map, key, value)

  defp delete_recipe(slug) when is_binary(slug) do
    case request(:delete, "/api/recipes/#{slug}") do
      {:ok, _} -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  # ── Search ─────────────────────────────────────────────────────────

  defp search_collection(type, term) when is_binary(type) and is_binary(term) do
    per_page = if type == "recipes", do: 5, else: 25
    path = "/api/#{type}?perPage=#{per_page}&search=#{URI.encode_www_form(term)}"

    case request(:get, path) do
      {:ok, body} ->
        results = extract_results(body)
        Logger.info("[mealie] GET /api/#{type} -> ok (results=#{length(results)})")
        {:ok, results}

      {:error, %Error{} = error} ->
        Logger.error("[mealie] GET /api/#{type} failed (#{error.class}: #{error.summary})")
        {:error, error}
    end
  end

  defp extract_results(%{"items" => items}) when is_list(items), do: items
  defp extract_results(%{"data" => data}) when is_list(data), do: data
  defp extract_results(_), do: []

  # ── Food helpers ───────────────────────────────────────────────────

  defp find_exact_food_id(results, name) when is_list(results) and is_binary(name) do
    case Enum.find(results, fn result -> Map.get(result, "name") == name end) do
      %{"id" => id} when is_binary(id) -> {:ok, id}
      _ -> :none
    end
  end

  defp create_food(name) when is_binary(name) do
    case request(:post, "/api/foods", %{"name" => name}) do
      {:ok, body} when is_map(body) ->
        case body["id"] do
          id when is_binary(id) ->
            Logger.info("[mealie] get_or_create_food created food #{id} for #{inspect(name)}")
            {:ok, id}

          _ ->
            {:error, Error.new(:api_error, "food create response missing id")}
        end

      {:error, %Error{} = error} ->
        Logger.error(
          "[mealie] get_or_create_food create failed (#{error.class}: #{error.summary})"
        )

        {:error, error}
    end
  end

  # ── Unit helpers ───────────────────────────────────────────────────

  defp find_exact_unit_id(results, name) when is_list(results) and is_binary(name) do
    case Enum.find(results, fn result -> Map.get(result, "name") == name end) do
      %{"id" => id} when is_binary(id) -> {:ok, id}
      _ -> :none
    end
  end

  defp create_unit(name) when is_binary(name) do
    case request(:post, "/api/units", %{"name" => name}) do
      {:ok, body} when is_map(body) ->
        case body["id"] do
          id when is_binary(id) ->
            Logger.info("[mealie] get_or_create_unit created unit #{id} for #{inspect(name)}")
            {:ok, id}

          _ ->
            {:error, Error.new(:api_error, "unit create response missing id")}
        end

      {:error, %Error{} = error} ->
        Logger.error(
          "[mealie] get_or_create_unit create failed (#{error.class}: #{error.summary})"
        )

        {:error, error}
    end
  end

  # ── Image upload ───────────────────────────────────────────────────

  # Local-file image upload is gated by `fetch_dir` (the per-job temp
  # directory `InstaMealie.YtDlp` created for this reel fetch). The
  # legitimate thumbnail is the only file the app ever needs to push
  # from disk to Mealie, and it always lives inside that directory.
  # Without the gate, an attacker-controlled `recipe.image` value
  # (LLM-prompt-injected from a reel caption/comments, or scraped from
  # a third-party recipe page) can coerce the pipeline into streaming
  # an arbitrary local file — the Instagram session cookie, `.envrc`,
  # SSH keys, anything the BEAM process can read — to Mealie. The gate
  # closes that path:
  #
  #   * `image: nil`            → `:ok` (no-op, unchanged)
  #   * `image: "http(s)://..."` → `upload_image_url/2` (unchanged; the
  #                                URL branch is independent of
  #                                fetch_dir — Mealie itself fetches the
  #                                bytes server-side)
  #   * `image: "/some/path"`   → `upload_image_file/2` ONLY when
  #                                `fetch_dir` is a non-nil binary AND
  #                                `Path.expand(image)` lives inside
  #                                `Path.expand(fetch_dir)` AND is a
  #                                regular file. The expanded path
  #                                (not the raw string) is used so a
  #                                raw `../` segment cannot escape
  #                                the prefix check. The file branch
  #                                receives the EXPANDED path so a
  #                                relative `..` cannot smuggle bytes
  #                                outside fetch_dir either.
  #   * anything else           → log a warning with the rejected path
  #                                and slug, return `:ok` (silently
  #                                skip the image, do NOT fail the
  #                                recipe import — mirrors the
  #                                existing catch-all's spirit).
  #
  # `fetch_dir: nil` covers two production cases: `:caption_only` jobs
  # never ran a fetch stage, and a GenServer revived from an ETS
  # snapshot always has `fetch_data: nil` (see `init({:revive, job})`
  # in `lib/insta_mealie/pipeline/job.ex`). In both, fail closed:
  # only URLs are accepted. This is an accepted tradeoff — an
  # already-succeeded-fetch's thumbnail can be silently dropped on a
  # revive+retry rather than risk an unvalidated path.
  defp upload_image(slug, image, fetch_dir) when is_binary(slug) do
    cond do
      is_nil(image) ->
        :ok

      String.starts_with?(image, "http://") or String.starts_with?(image, "https://") ->
        upload_image_url(slug, image)

      is_binary(fetch_dir) and inside_fetch_dir?(image, fetch_dir) ->
        upload_image_file(slug, Path.expand(image))

      true ->
        Logger.warning(
          "[mealie] rejecting recipe image outside fetch_dir for #{slug}: path=#{inspect(image)} fetch_dir=#{inspect(fetch_dir)}"
        )

        :ok
    end
  end

  # The prefix check uses the EXPANDED path on both sides so a raw
  # `../` segment cannot smuggle outside `fetch_dir`. The trailing `/`
  # on the fetch_dir prefix prevents `/tmp/fetch_dir_evil` from
  # matching `/tmp/fetch_dir` (substring without separator).
  defp inside_fetch_dir?(image, fetch_dir) do
    expanded_image = Path.expand(image)
    expanded_fetch_dir = Path.expand(fetch_dir)
    prefix = expanded_fetch_dir <> "/"

    String.starts_with?(expanded_image, prefix) and File.regular?(expanded_image)
  end

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
          form_multipart: [
            image: {File.stream!(path, 64 * 1024, []), filename: Path.basename(path)},
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

  # ── HTTP plumbing ──────────────────────────────────────────────────

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

  defp classify_response(%{status: st, body: body}) do
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

  # ── Ingredient parsing helpers ─────────────────────────────────────

  defp parse_ingredient_item(item) do
    source = Map.get(item, "ingredient") || item
    unit = Map.get(source, "unit") || %{}
    food = Map.get(source, "food") || %{}
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

  # ── Slug helpers ───────────────────────────────────────────────────

  defp slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end
end

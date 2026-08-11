defmodule FakeMealie do
  use Plug.Router

  plug :fetch_query_params
  plug :match
  plug :dispatch

  post "/api/recipes" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(201, Jason.encode!(%{slug: "homemade-granola", id: "homemade-granola"}))
  end

  get "/api/recipes/:slug" do
    # The e2e test exercises import_recipe/1 against a fresh draft, so the
    # fake always reports "missing" for any slug — letting the create branch run.
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{detail: "recipe not found"}))
  end

  patch "/api/recipes/:slug" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{slug: slug}))
  end

  post "/api/recipes/:slug/image" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{}))
  end

  get "/api/foods" do
    if conn.query_params["search"] == "status-400" do
      body = %{
        "detail" => "validation failed for recipeIngredient",
        "recipeIngredient" => [
          %{
            "loc" => ["body", "recipeIngredient"],
            "msg" => "ingredient list must be a non-empty array",
            "type" => "value_error"
          }
        ]
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(body))
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{items: [%{"name" => "oats"}]}))
    end
  end

  get "/api/units" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{items: [%{"name" => "cup"}]}))
  end

  post "/api/parser/ingredients" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    %{"ingredients" => ingredients} = Jason.decode!(body)

    parsed =
      Enum.with_index(ingredients)
      |> Enum.map(fn {item, i} ->
        if i == 0 do
          %{
            "quantity" => 3,
            "unit" => %{"name" => "cups", "id" => "unit-cups"},
            "food" => %{"name" => "oats", "id" => "food-oats", "confidence" => 1.0},
            "note" => nil
          }
        else
          %{
            "quantity" => 1,
            "unit" => %{"name" => "cup", "id" => "unit-cup"},
            "food" => %{
              "name" => item,
              "id" => "food-#{i}",
              "confidence" => 1.0
            },
            "note" => nil
          }
        end
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(parsed))
  end

  # Organizer index — current Mealie import resolves tag/category names to refs
  # via a single /api/organizers/{kind}?perPage=-1 call.
  get "/api/organizers/:kind" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{items: []}))
  end

  post "/api/organizers/:kind" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    %{"name" => name} = Jason.decode!(body)
    slug = slugify(name)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(201, Jason.encode!(%{id: slug, name: name, slug: slug}))
  end

  defp slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end
end

defmodule InstaMealie.Mealie.RealTest do
  use ExUnit.Case, async: false

  alias InstaMealie.Error
  alias InstaMealie.Mealie
  alias InstaMealie.Pipeline
  alias InstaMealie.Pipeline.Job
  alias InstaMealie.Pipeline.JobStore
  alias InstaMealie.PubSub
  alias InstaMealie.Recipe

  setup do
    Mox.set_mox_global()
    JobStore.clear()

    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)

    {:ok, pid} = Bandit.start_link(plug: FakeMealie, port: port)

    base = "http://127.0.0.1:#{port}"

    # Set mealie config WITHOUT :plug — default Req adapter hits the fake server
    Application.put_env(:insta_mealie, :mealie,
      base_url: base,
      api_token: "test-token",
      group_slug: "home"
    )

    # Use Mock for YtDlp only
    Application.put_env(:insta_mealie, InstaMealie.YtDlp, InstaMealie.YtDlp.Mock)

    # Register YtDlp mock to return canned data (two-stage fetch contract)
    Mox.stub(InstaMealie.YtDlp.Mock, :fetch_metadata, fn _url, _opts ->
      caption = """
      Homemade Granola
      Makes about 8 servings.
      Ingredients:
      - 3 cups rolled oats
      - 1 cup raw almonds
      - 1/2 cup maple syrup
      - 1/3 cup coconut oil
      - 1 tsp salt
      Steps:
      Mix everything, spread on a tray, bake at 160C for 40 minutes stirring halfway.
      """

      {:ok,
       %{
         author: "chef_og",
         caption: caption,
         comments: [
           %{author: "chef_og", text: "So good, I add cranberries!"},
           %{author: "random_fan", text: "tried this, loved it"},
           %{author: "chef_og", text: "Tip: use parchment paper."}
         ],
         fetch_dir: "/tmp/insta_mealie/fetch_mealie"
       }}
    end)

    Mox.stub(InstaMealie.YtDlp.Mock, :fetch_audio, fn _url, _opts ->
      {:ok,
       %{
         audio_path:
           "/tmp/insta_mealie/" <>
             (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)) <> ".mp3"
       }}
    end)

    # Set LLM adapter to return a recipe_complete envelope for the e2e test
    Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

    Mox.stub(InstaMealie.LLM.Mock, :chat, fn _model, _messages ->
      {:ok,
       %{
         "choices" => [
           %{
             "message" => %{
               "content" =>
                 Jason.encode!(%{
                   "completeness" => "recipe_complete",
                   "missing_fields" => [],
                   "recipe" => %{
                     "name" => "Homemade Granola",
                     "description" => "A simple oven-toasted granola.",
                     "recipeYield" => "8 servings",
                     "recipeIngredient" => [
                       "3 cups rolled oats",
                       "1 cup raw almonds",
                       "1/2 cup maple syrup",
                       "1/3 cup coconut oil",
                       "1 tsp salt"
                     ],
                     "recipeInstructions" => [
                       %{"text" => "Combine oats, almonds, syrup, oil, and salt."},
                       %{"text" => "Bake at 160C for 40 minutes, stirring halfway."}
                     ],
                     "tags" => ["breakfast"]
                   }
                 })
             }
           }
         ]
       }}
    end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      Application.put_env(:insta_mealie, :mealie, [])
      Application.put_env(:insta_mealie, InstaMealie.YtDlp, InstaMealie.YtDlp.Cli)

      try do
        Application.delete_env(:insta_mealie, InstaMealie.LLM)
      rescue
        _ -> :ok
      end
    end)

    {:ok, port: port, base: base}
  end

  describe "Recipe.to_mealie_payload/1" do
    test "forwards known Mealie keys, drops unknown" do
      recipe =
        Recipe.from_map(%{
          "name" => "Granola",
          "description" => "Tasty",
          "recipeYield" => "8",
          "recipeIngredient" => ["3 cups oats"],
          "recipeInstructions" => [%{"text" => "Mix"}],
          "tags" => ["breakfast"],
          "secret" => "ignored"
        })

      payload = Recipe.to_mealie_payload(recipe)
      assert payload["name"] == "Granola"
      assert [%{"note" => "3 cups oats"}] = payload["recipeIngredient"]
      assert payload["tags"] == ["breakfast"]
      assert payload["recipeInstructions"] == [%{"text" => "Mix", "type" => "RecipeInstruction"}]
      refute Map.has_key?(payload, "secret")
    end
  end

  describe "search dispatch" do
    test "search_foods returns data list" do
      assert {:ok, [%{"name" => "oats"}]} = Mealie.search_foods("oats")
    end

    test "search_units returns data list" do
      assert {:ok, [%{"name" => "cup"}]} = Mealie.search_units("cup")
    end

    test "search_foods returns :api_error with a diagnostic summary when Mealie replies 400" do
      # Exercises the real Req → FakeMealie → classify_response/format_error_reason path:
      # no :mealie_http_adapter injection here, so the production HTTP adapter runs.
      assert {:error, %Error{class: :api_error, summary: summary}} =
               Mealie.search_foods("status-400")

      assert summary =~ "recipeIngredient"
      assert summary =~ "ingredient list must be a non-empty array"
    end
  end

  describe "parse_ingredients/1 request shape" do
    test "wraps ingredients in a map with an \"ingredients\" key (Mealie API contract)" do
      prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

      test_pid = self()

      Application.put_env(:insta_mealie, :mealie_http_adapter, fn method, path, body ->
        send(test_pid, {:adapter_called, method, path, body})
        # Return a minimal success response: list of parsed ingredient maps
        {:ok,
         [
           %{"quantity" => 1, "unit" => %{}, "food" => %{"name" => "flour"}, "note" => nil},
           %{"quantity" => 2, "unit" => %{}, "food" => %{"name" => "eggs"}, "note" => nil}
         ]}
      end)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
          _ -> Application.put_env(:insta_mealie, :mealie_http_adapter, prev)
        end
      end)

      ingredients = ["1 cup flour", "2 eggs"]
      assert {:ok, _parsed} = Mealie.parse_ingredients(ingredients)

      assert_receive {:adapter_called, :post, "/api/parser/ingredients", body}

      # The Mealie API expects a map wrapping the ingredient strings,
      # i.e. %{"ingredients" => [...]}, NOT a bare list.
      assert body == %{"ingredients" => ingredients}
    end
  end

  describe "parse_ingredients/1 nested response fields" do
    test "preserves nested quantity, unit, food, and note from Mealie parser response" do
      prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

      Application.put_env(:insta_mealie, :mealie_http_adapter, fn _method, _path, _body ->
        {:ok,
         [
           %{
             "ingredient" => %{
               "quantity" => 1,
               "unit" => %{"name" => "cup", "id" => "unit-id"},
               "food" => %{"name" => "flour", "id" => "food-id", "confidence" => 0.9},
               "note" => "sifted"
             }
           }
         ]}
      end)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
          _ -> Application.put_env(:insta_mealie, :mealie_http_adapter, prev)
        end
      end)

      assert {:ok, [parsed]} = Mealie.parse_ingredients(["1 cup flour"])

      assert parsed == %{
               "quantity" => 1,
               "unit" => "cup",
               "unit_id" => "unit-id",
               "food" => "flour",
               "food_id" => "food-id",
               "food_confidence" => 0.9,
               "unit_confidence" => nil,
               "quantity_confidence" => nil,
               "average_confidence" => 0.9,
               "note" => "sifted"
             }
    end
  end

  describe "parse_ingredients/1 top-level confidence (Mealie response shape)" do
    test "reads food confidence from top-level item.confidence.food" do
      prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

      Application.put_env(:insta_mealie, :mealie_http_adapter, fn _method, _path, _body ->
        {:ok,
         [
           %{
             "confidence" => %{"food" => 0.97},
             "ingredient" => %{
               "quantity" => 3,
               "unit" => %{"name" => "cups", "id" => "unit-cups"},
               "food" => %{"name" => "oats", "id" => "food-oats"},
               "note" => nil
             }
           }
         ]}
      end)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
          _ -> Application.put_env(:insta_mealie, :mealie_http_adapter, prev)
        end
      end)

      assert {:ok, [parsed]} = Mealie.parse_ingredients(["3 cups oats"])

      assert parsed == %{
               "quantity" => 3,
               "unit" => "cups",
               "unit_id" => "unit-cups",
               "food" => "oats",
               "food_id" => "food-oats",
               "food_confidence" => 0.97,
               "unit_confidence" => nil,
               "quantity_confidence" => nil,
               "average_confidence" => 0.97,
               "note" => nil
             }
    end

    test "falls back to nested food.confidence when top-level confidence is missing" do
      prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

      Application.put_env(:insta_mealie, :mealie_http_adapter, fn _method, _path, _body ->
        {:ok,
         [
           %{
             "ingredient" => %{
               "quantity" => 1,
               "unit" => %{"name" => "cup", "id" => "unit-id"},
               "food" => %{"name" => "flour", "id" => "food-id", "confidence" => 0.9},
               "note" => "sifted"
             }
           }
         ]}
      end)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
          _ -> Application.put_env(:insta_mealie, :mealie_http_adapter, prev)
        end
      end)

      assert {:ok, [parsed]} = Mealie.parse_ingredients(["1 cup flour"])

      assert parsed == %{
               "quantity" => 1,
               "unit" => "cup",
               "unit_id" => "unit-id",
               "food" => "flour",
               "food_id" => "food-id",
               "food_confidence" => 0.9,
               "unit_confidence" => nil,
               "quantity_confidence" => nil,
               "average_confidence" => 0.9,
               "note" => "sifted"
             }
    end

    test "top-level confidence with non-map or missing food key falls back to nested" do
      prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

      Application.put_env(:insta_mealie, :mealie_http_adapter, fn _method, _path, _body ->
        {:ok,
         [
           %{
             "confidence" => "invalid",
             "ingredient" => %{
               "quantity" => 1,
               "unit" => %{"name" => "cup", "id" => "unit-id"},
               "food" => %{"name" => "flour", "id" => "food-id", "confidence" => 0.5},
               "note" => nil
             }
           }
         ]}
      end)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
          _ -> Application.put_env(:insta_mealie, :mealie_http_adapter, prev)
        end
      end)

      assert {:ok, [parsed]} = Mealie.parse_ingredients(["1 cup flour"])

      assert parsed["food_confidence"] == 0.5
    end

    test "uses top-level confidence.average when confidence.food is absent (newer Mealie shape)" do
      prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

      Application.put_env(:insta_mealie, :mealie_http_adapter, fn _method, _path, _body ->
        {:ok,
         [
           %{
             "confidence" => %{"average" => 0.93},
             "ingredient" => %{
               "quantity" => 3,
               "unit" => %{"name" => "cups", "id" => "unit-cups"},
               "food" => %{"name" => "oats", "id" => "food-oats"},
               "note" => nil
             }
           }
         ]}
      end)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
          _ -> Application.put_env(:insta_mealie, :mealie_http_adapter, prev)
        end
      end)

      assert {:ok, [parsed]} = Mealie.parse_ingredients(["3 cups oats"])

      assert parsed == %{
               "quantity" => 3,
               "unit" => "cups",
               "unit_id" => "unit-cups",
               "food" => "oats",
               "food_id" => "food-oats",
               "food_confidence" => nil,
               "unit_confidence" => nil,
               "quantity_confidence" => nil,
               "average_confidence" => 0.93,
               "note" => nil
             }
    end

    test "both confidence sources missing yields nil without crashing" do
      prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

      Application.put_env(:insta_mealie, :mealie_http_adapter, fn _method, _path, _body ->
        {:ok,
         [
           %{
             "ingredient" => %{
               "quantity" => 1,
               "unit" => %{"name" => "cup", "id" => "unit-id"},
               "food" => %{"name" => "flour", "id" => "food-id"},
               "note" => nil
             }
           }
         ]}
      end)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
          _ -> Application.put_env(:insta_mealie, :mealie_http_adapter, prev)
        end
      end)

      assert {:ok, [parsed]} = Mealie.parse_ingredients(["1 cup flour"])

      assert parsed["food_confidence"] == nil
    end
  end

  describe "import_recipe/1 with a new recipe (POST then PATCH)" do
    test "drives the get-then-create-then-patch flow via the http adapter stub" do
      test_pid = self()
      prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

      Application.put_env(:insta_mealie, :mealie_http_adapter, fn method, path, body ->
        send(test_pid, {:adapter_called, method, path, body})

        case {method, path} do
          {:get, "/api/recipes/test"} ->
            # No recipe with this slug yet — slug comes from the recipe name.
            {:error, Error.new(:api_error, "not found")}

          {:post, "/api/recipes"} ->
            # POST /api/recipes returns a map with a slug — the adapter
            # normalizes this into a %RecipeRef{}.
            {:ok, %{"slug" => "test"}}

          {:patch, "/api/recipes/test"} ->
            {:ok, %{}}
        end
      end)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
          _ -> Application.put_env(:insta_mealie, :mealie_http_adapter, prev)
        end
      end)

      recipe = Recipe.from_map(%{"name" => "Test"})

      assert {:ok, "test", deep_link} = Mealie.import_recipe(recipe)
      assert deep_link =~ "/g/home/r/test?edit=true"

      # GET /api/recipes/test with no body — slug is derived from the recipe name.
      assert_receive {:adapter_called, :get, "/api/recipes/test", nil}

      # POST /api/recipes with the recipe name
      assert_receive {:adapter_called, :post, "/api/recipes", post_body}
      assert post_body == %{name: "Test"}

      # PATCH /api/recipes/test with the recipe payload
      assert_receive {:adapter_called, :patch, "/api/recipes/test", patch_body}
      assert patch_body["name"] == "Test"
    end
  end

  describe "import_recipe/1 with an existing slug (PATCH only) — slug reuse" do
    test "performs a single PATCH under the existing slug and returns the deep link" do
      test_pid = self()
      prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

      Application.put_env(:insta_mealie, :mealie_http_adapter, fn method, path, body ->
        send(test_pid, {:adapter_called, method, path, body})

        case {method, path} do
          {:get, "/api/recipes/draft-slug"} ->
            # Recipe already exists — slug comes from the recipe name and is reused.
            {:ok, %{"slug" => "draft-slug"}}

          {:patch, "/api/recipes/draft-slug"} ->
            {:ok, %{}}
        end
      end)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
          _ -> Application.put_env(:insta_mealie, :mealie_http_adapter, prev)
        end
      end)

      recipe = Recipe.from_map(%{"name" => "Draft Slug"})

      assert {:ok, "draft-slug", deep_link} = Mealie.import_recipe(recipe)

      assert deep_link =~ "/g/home/r/draft-slug?edit=true"

      # GET finds the existing recipe so the slug is reused (no create).
      assert_receive {:adapter_called, :get, "/api/recipes/draft-slug", _get_body}

      # PATCH /api/recipes/draft-slug with the recipe payload (no id/slug in
      # body — those live in the URL path).
      assert_receive {:adapter_called, :patch, "/api/recipes/draft-slug", patch_body}
      assert patch_body["name"] == "Draft Slug"

      # No create, no update under another path
      refute_receive {:adapter_called, :post, _, _}, 50
    end
  end

  describe "end-to-end import on recipe_complete path (real client, fake Mealie)" do
    test "a recipe lands in Mealie via POST->PATCH and yields a deep link", %{
      port: _port,
      base: base
    } do
      Phoenix.PubSub.subscribe(PubSub, "jobs")

      assert {:ok, id} = Pipeline.create_job(%{url: "https://instagram.com/reel/abc"})

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000

      assert job.slug == "homemade-granola"
      assert job.deep_link == "#{base}/g/home/r/homemade-granola?edit=true"
      assert Map.get(job.stages, :fetch) == :done
      assert Map.get(job.stages, :llm_format) == :done
      assert Map.get(job.stages, :mealie_import) == :done
      assert Map.get(job.stages, :transcribe) == :skipped
    end
  end
end

defmodule FakeMealie do
  use Plug.Router

  plug :match
  plug :dispatch

  post "/api/recipes" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(201, Jason.encode!(%{slug: "granola-1", id: "granola-1"}))
  end

  get "/api/recipes/:slug" do
    recipe = %{
      "id" => "server-id-#{slug}",
      "slug" => slug,
      "name" => "Recipe",
      "recipeIngredient" => [],
      "recipeInstructions" => []
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(recipe))
  end

  put "/api/recipes/:slug" do
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
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{items: [%{"name" => "oats"}]}))
  end

  get "/api/units" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{items: [%{"name" => "cup"}]}))
  end

  post "/api/parser/ingredients" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    ingredients = Jason.decode!(body)

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
              "name" => Map.get(item, "text", "unknown"),
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
end

defmodule InstaMealie.Mealie.RealTest do
  use ExUnit.Case, async: false

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
    Application.put_env(:insta_mealie, :llm_http_adapter, fn _body ->
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
        Application.delete_env(:insta_mealie, :llm_http_adapter)
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

  describe "classify_response/1" do
    test "2xx is ok with body" do
      assert Mealie.classify_response(%{status: 200, body: %{"slug" => "x"}}) ==
               {:ok, %{"slug" => "x"}}

      assert Mealie.classify_response(%{status: 201, body: %{}}) == {:ok, %{}}
    end

    test "validation is a dead row" do
      assert Mealie.classify_response(%{status: 422, body: %{}}) ==
               {:error, :validation, "validation failed"}
    end

    test "auth errors" do
      assert Mealie.classify_response(%{status: 401, body: %{}}) ==
               {:error, :auth, "unauthorized"}

      assert Mealie.classify_response(%{status: 403, body: %{}}) == {:error, :auth, "forbidden"}
    end

    test "server errors are network (retryable)" do
      assert Mealie.classify_response(%{status: 500, body: %{}}) ==
               {:error, :network, "server error 500"}
    end

    test "other 4xx is api_error" do
      assert Mealie.classify_response(%{status: 404, body: %{}}) ==
               {:error, :api_error, "client error 404"}
    end

    test "non-empty error body is retained in the error reason for diagnostics" do
      body = %{
        "detail" => [
          %{"loc" => ["body", "recipeIngredient", 0], "msg" => "invalid ingredient"}
        ]
      }

      assert {:error, :api_error, reason} =
               Mealie.classify_response(%{status: 400, body: body})

      assert reason =~ "recipeIngredient"
      assert reason =~ "invalid ingredient"
    end
  end

  describe "search dispatch" do
    test "search_foods returns data list" do
      assert {:ok, [%{"name" => "oats"}]} = Mealie.search_foods("oats")
    end

    test "search_units returns data list" do
      assert {:ok, [%{"name" => "cup"}]} = Mealie.search_units("cup")
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
               "food_confidence" => 0.93,
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

  describe "create_recipe/1 with plain string response" do
    test "accepts a bare string slug from the adapter" do
      prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

      Application.put_env(:insta_mealie, :mealie_http_adapter, fn _method, _path, _body ->
        {:ok, "plain-slug"}
      end)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
          _ -> Application.put_env(:insta_mealie, :mealie_http_adapter, prev)
        end
      end)

      assert Mealie.create_recipe(Recipe.from_map(%{"name" => "Test"})) == {:ok, "plain-slug"}
    end
  end

  describe "update_recipe/2" do
    test "performs GET then PUT, and PUT body contains server id/slug plus caller fields" do
      test_pid = self()
      prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

      Application.put_env(:insta_mealie, :mealie_http_adapter, fn method, path, body ->
        send(test_pid, {:adapter_called, method, path, body})

        case method do
          :get ->
            {:ok,
             %{
               "id" => "draft-id",
               "slug" => "draft-slug",
               "name" => "Recipe",
               "recipeIngredient" => [],
               "recipeInstructions" => []
             }}

          :put ->
            {:ok, %{"slug" => "draft-slug"}}
        end
      end)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
          _ -> Application.put_env(:insta_mealie, :mealie_http_adapter, prev)
        end
      end)

      assert {:ok, "draft-slug"} =
               Mealie.update_recipe(
                 "draft-slug",
                 Recipe.from_map(%{"name" => "Updated Granola"})
               )

      # Must have done a GET first
      assert_receive {:adapter_called, :get, "/api/recipes/draft-slug", _}

      # Must have done a PUT with server identity preserved
      assert_receive {:adapter_called, :put, "/api/recipes/draft-slug", put_body}
      assert put_body["id"] == "draft-id"
      assert put_body["slug"] == "draft-slug"
      assert put_body["name"] == "Updated Granola"
    end
  end

  describe "end-to-end import on recipe_complete path (real client, fake Mealie)" do
    test "a recipe lands in Mealie via POST->PUT and yields a deep link", %{
      port: _port,
      base: base
    } do
      Phoenix.PubSub.subscribe(PubSub, "jobs")

      assert {:ok, id} = Pipeline.create_job(%{url: "https://instagram.com/reel/abc"})

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000

      assert job.slug == "granola-1"
      assert job.deep_link == "#{base}/g/home/r/granola-1?edit=true"
      assert Map.get(job.stages, :fetch) == :done
      assert Map.get(job.stages, :llm_format) == :done
      assert Map.get(job.stages, :mealie_import) == :done
      assert Map.get(job.stages, :transcribe) == :skipped
    end
  end
end

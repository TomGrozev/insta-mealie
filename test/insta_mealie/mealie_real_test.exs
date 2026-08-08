defmodule FakeMealie do
  use Plug.Router

  plug :match
  plug :dispatch

  post "/api/recipes" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(201, Jason.encode!(%{slug: "granola-1", id: "granola-1"}))
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
    |> send_resp(200, Jason.encode!(%{data: [%{"name" => "oats"}]}))
  end

  get "/api/units" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{data: [%{"name" => "cup"}]}))
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

    # Register YtDlp mock to return canned data
    Mox.stub(InstaMealie.YtDlp.Mock, :fetch, fn _url, _opts ->
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
         video_path:
           "/tmp/insta_mealie/" <>
             (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)) <> ".mp4"
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

  describe "build_payload/1" do
    test "forwards known Mealie keys, drops unknown" do
      recipe = %{
        "name" => "Granola",
        "description" => "Tasty",
        "recipeYield" => "8",
        "recipeIngredient" => ["3 cups oats"],
        "recipeInstructions" => [%{"text" => "Mix"}],
        "tags" => ["breakfast"],
        "secret" => "ignored"
      }

      payload = Mealie.build_payload(recipe)
      assert payload["name"] == "Granola"
      assert payload["recipeIngredient"] == ["3 cups oats"]
      assert payload["tags"] == ["breakfast"]
      assert payload["recipeInstructions"] == [%{"text" => "Mix"}]
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
      assert Mealie.classify_response(%{status: 401, body: %{}}) == {:error, :auth, "unauthorized"}
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
  end

  describe "search dispatch" do
    test "search_foods returns data list" do
      assert {:ok, [%{"name" => "oats"}]} = Mealie.search_foods("oats")
    end

    test "search_units returns data list" do
      assert {:ok, [%{"name" => "cup"}]} = Mealie.search_units("cup")
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

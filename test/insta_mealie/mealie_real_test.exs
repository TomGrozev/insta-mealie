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

  alias InstaMealie.Mealie.Real
  alias InstaMealie.Pipeline
  alias InstaMealie.Pipeline.Job
  alias InstaMealie.Pipeline.JobStore
  alias InstaMealie.PubSub

  setup do
    JobStore.clear()

    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)

    {:ok, pid} = Bandit.start_link(plug: FakeMealie, port: port)

    base = "http://127.0.0.1:#{port}"
    original_clients = Application.get_env(:insta_mealie, :clients, [])
    original_mealie = Application.get_env(:insta_mealie, :mealie, [])

    Application.put_env(:insta_mealie, :mealie,
      base_url: base,
      api_token: "test-token",
      group_slug: "home"
    )

    Application.put_env(:insta_mealie, :clients,
      mealie: InstaMealie.Mealie.Real,
      llm: InstaMealie.LlmStub,
      ytdlp: InstaMealie.YtDlpStub
    )

    on_exit(fn ->
      Process.exit(pid, :kill)
      Application.put_env(:insta_mealie, :clients, original_clients)
      Application.put_env(:insta_mealie, :mealie, original_mealie)
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

      payload = Real.build_payload(recipe)
      assert payload["name"] == "Granola"
      assert payload["recipeIngredient"] == ["3 cups oats"]
      assert payload["tags"] == ["breakfast"]
      assert payload["recipeInstructions"] == [%{"text" => "Mix"}]
      refute Map.has_key?(payload, "secret")
    end
  end

  describe "classify_response/1" do
    test "2xx is ok with body" do
      assert Real.classify_response(%{status: 200, body: %{"slug" => "x"}}) ==
               {:ok, %{"slug" => "x"}}

      assert Real.classify_response(%{status: 201, body: %{}}) == {:ok, %{}}
    end

    test "validation is a dead row" do
      assert Real.classify_response(%{status: 422, body: %{}}) ==
               {:error, :validation, "validation failed"}
    end

    test "auth errors" do
      assert Real.classify_response(%{status: 401, body: %{}}) == {:error, :auth, "unauthorized"}
      assert Real.classify_response(%{status: 403, body: %{}}) == {:error, :auth, "forbidden"}
    end

    test "server errors are network (retryable)" do
      assert Real.classify_response(%{status: 500, body: %{}}) ==
               {:error, :network, "server error 500"}
    end

    test "other 4xx is api_error" do
      assert Real.classify_response(%{status: 404, body: %{}}) ==
               {:error, :api_error, "client error 404"}
    end
  end

  describe "search dispatch" do
    test "search_foods returns data list" do
      assert {:ok, [%{"name" => "oats"}]} = Real.search_foods("oats")
    end

    test "search_units returns data list" do
      assert {:ok, [%{"name" => "cup"}]} = Real.search_units("cup")
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

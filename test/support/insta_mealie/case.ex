defmodule InstaMealie.TestCase do
  @moduledoc """
  Shared test case that sets up Mox mock stubs for YtDlp, LLM, and Whisper,
  plus an env-stored function adapter for Mealie.

  Pipeline stages run their blocking work inside
  `Task.Supervisor.async_nolink/2` against
  `InstaMealie.Pipeline.TaskSupervisor` (see `InstaMealie.Pipeline.Job`'s
  moduledoc). Those task processes are not the test process, so the
  setup runs in Mox *global mode*. That makes every stub registered in
  this setup block visible to any process that later calls into the
  mock — including the dynamically-spawned stage tasks under
  `InstaMealie.Pipeline.TaskSupervisor` and the per-job GenServers that
  supervise them. Global mode requires `async: false`, which the
  `using` block below already enforces.

  The Mealie HTTP adapter is stored under `:mealie_http_adapter` in the
  `:insta_mealie` application env and is resolved at call time, so no
  per-process allow is needed for it.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
    end
  end

  defp default_recipe do
    %{
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
        %{"title" => "Mix", "text" => "Combine oats, almonds, syrup, oil, and salt."},
        %{"title" => "Bake", "text" => "Bake at 160C for 40 minutes, stirring halfway."}
      ],
      "tags" => ["breakfast", "make-ahead"]
    }
  end

  setup do
    InstaMealie.Pipeline.JobStore.clear()
    InstaMealie.Pipeline.JobAdmission.reset()

    # JobStore.clear() and JobAdmission.reset() scrub the registered
    # metadata, but the Job GenServers themselves continue to live under
    # JobSupervisor unless explicitly terminated — including jobs left in
    # non-terminal states such as :needs_review from a previous test.
    # Terminate them here to prevent process leaks between tests.
    InstaMealie.Pipeline.JobSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        DynamicSupervisor.terminate_child(InstaMealie.Pipeline.JobSupervisor, pid)

      _ ->
        :ok
    end)

    # Each pipeline stage runs in a supervised task under the Pipeline's
    # TaskSupervisor. Those task processes are not the test process, so
    # Mox must be in global mode for the stubs registered below to be
    # visible to them. Global mode is compatible with `async: false`,
    # which the `using` block above enforces. See
    # `InstaMealie.Pipeline.Job` moduledoc.
    Mox.set_mox_global()

    # Set YtDlp to Mock (the only behaviour left with Mox)
    Application.put_env(:insta_mealie, InstaMealie.YtDlp, InstaMealie.YtDlp.Mock)

    # Register default YtDlp mock stubs (two-stage fetch contract)
    Mox.stub(InstaMealie.YtDlp.Mock, :fetch_metadata, fn _url, _opts ->
      {:ok,
       %{
         author: "chef_og",
         caption: "Homemade Granola\nMakes about 8 servings.",
         comments: [
           %{author: "chef_og", text: "So good, I add cranberries!"},
           %{author: "random_fan", text: "tried this, loved it"},
           %{author: "chef_og", text: "Tip: use parchment paper."}
         ],
         fetch_dir: "/tmp/insta_mealie/fetch_default"
       }}
    end)

    Mox.stub(InstaMealie.YtDlp.Mock, :fetch_audio, fn _url, _opts ->
      {:ok, %{audio_path: "/tmp/insta_mealie/x.mp3"}}
    end)

    # Default adapter stubs for LLM, Whisper, and Mealie
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
                   "recipe" => default_recipe()
                 })
             }
           }
         ]
       }}
    end)

    Application.put_env(:insta_mealie, InstaMealie.Whisper, InstaMealie.Whisper.Mock)

    Mox.stub(InstaMealie.Whisper.Mock, :transcribe, fn _model, _file_path, _prompt, _language ->
      {:ok, "Transcribed audio: mix oats almonds syrup oil salt, bake at 160C for 40 minutes."}
    end)

    Application.put_env(:insta_mealie, :mealie_http_adapter, fn m, p, body ->
      cond do
        m == :post and p == "/api/recipes" ->
          name = body[:name] || body["name"] || "untitled-recipe"

          slug =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          slug = if slug == "", do: "untitled-recipe", else: slug

          {:ok, %{"slug" => slug, "id" => slug}}

        m in [:put, :post] and String.starts_with?(p, "/api/recipes/") ->
          if String.ends_with?(p, "/image") do
            {:ok, %{}}
          else
            slug = Path.basename(p)
            {:ok, %{"slug" => slug}}
          end

        m == :get and String.starts_with?(p, "/api/foods") ->
          {:ok, %{"data" => []}}

        # POST /api/foods is reached when the review resolution enriches a
        # nonblank custom food name through `Mealie.get_or_create_food/1`
        # (issue #29). The search above returns no match, so the create
        # branch fires; echo back a deterministic id derived from the name
        # so the resolved ingredient reaches the PATCH payload with an id.
        m == :post and p == "/api/foods" ->
          name = body[:name] || body["name"] || "untitled-food"

          id =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          id = if id == "", do: "untitled-food", else: id
          {:ok, %{"id" => id, "name" => name}}

        m == :get and String.starts_with?(p, "/api/units") ->
          {:ok, %{"data" => []}}

        m == :post and p == "/api/units" ->
          name = body[:name] || body["name"] || "untitled-unit"

          id =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          id = if id == "", do: "untitled-unit", else: id
          {:ok, %{"id" => id, "name" => name}}

        m == :get and String.starts_with?(p, "/api/organizers/") ->
          {:ok, %{"items" => []}}

        # The create-or-reuse-recipe flow in `InstaMealie.Mealie.import_recipe/1`
        # does `GET /api/recipes/{slug}` first and only proceeds to `POST /api/recipes`
        # on a `:not_found` error. The real Mealie returns 404 when the slug is
        # absent — the production code classifies that via `InstaMealie.HttpClassify`
        # to `Error{class: :not_found}`. The stub mirrors that directly so the
        # `maybe_create_recipe/2` gate fires correctly (see bug 1 fix). Tests
        # that exercise the reuse path override this handler with their own
        # adapter that returns `{:ok, %{"slug" => ...}}`.
        m == :get and String.starts_with?(p, "/api/recipes/") and
            not String.ends_with?(p, "/image") ->
          {:error, InstaMealie.Error.new(:not_found, "not found")}

        m == :post and String.starts_with?(p, "/api/organizers/") ->
          name = body[:name] || body["name"] || "untitled-organizer"

          slug =
            name
            |> String.downcase()
            |> String.normalize(:nfd)
            |> String.replace(~r/[^a-z0-9]+/u, "-")
            |> String.trim("-")

          slug = if slug == "", do: "untitled-organizer", else: slug

          {:ok, %{"id" => slug, "name" => name, "slug" => slug}}

        m == :post and p == "/api/recipes/test-scrape-url" ->
          {:error, InstaMealie.Error.new(:validation, "not scrapeable (default test stub)")}

        m == :post and p == "/api/parser/ingredients" ->
          ingredients = body["ingredients"] || []

          parsed =
            Enum.map(ingredients, fn ingredient ->
              name =
                if is_binary(ingredient), do: ingredient, else: ingredient["text"] || "unknown"

              %{
                "quantity" => 1.0,
                "unit" => %{"name" => "cup", "id" => "stub-unit"},
                "food" => %{
                  "name" => name,
                  "id" => "stub-food",
                  "confidence" => 1.0
                },
                "confidence" => %{
                  "food" => 1.0,
                  "unit" => 1.0,
                  "quantity" => 1.0,
                  "average" => 1.0
                },
                "note" => nil
              }
            end)

          {:ok, parsed}

        true ->
          {:ok, %{}}
      end
    end)

    on_exit(fn ->
      # Restore defaults
      Application.put_env(:insta_mealie, InstaMealie.YtDlp, InstaMealie.YtDlp.Cli)

      Application.delete_env(:insta_mealie, InstaMealie.LLM)
      Application.delete_env(:insta_mealie, InstaMealie.Whisper)

      try do
        Application.delete_env(:insta_mealie, :mealie_http_adapter)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end
end

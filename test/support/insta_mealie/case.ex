defmodule InstaMealie.TestCase do
  @moduledoc """
  Shared test case that sets up Mox mocks for YtDlp and adapter env stubs
  for LLM, Mealie, and Whisper HTTP services.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
      import InstaMealie.TestCase, only: [allow_job_services: 1]
    end
  end

  @doc """
  No-op. Adapter stubs are stored in Application env and are visible to all
  processes (including pipeline GenServers) without per-process allow.
  """
  def allow_job_services(_job_id), do: :ok

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
    # Make stubs global so GenServer processes can access them
    Mox.set_mox_global()

    InstaMealie.Pipeline.JobStore.clear()

    # Set YtDlp to Mock (the only behaviour left with Mox)
    Application.put_env(:insta_mealie, InstaMealie.YtDlp, InstaMealie.YtDlp.Mock)

    # Register default YtDlp mock stub
    Mox.stub(InstaMealie.YtDlp.Mock, :fetch, fn _url, _opts ->
      {:ok,
       %{
         author: "chef_og",
         caption: "Homemade Granola\nMakes about 8 servings.",
         comments: [
           %{author: "chef_og", text: "So good, I add cranberries!"},
           %{author: "random_fan", text: "tried this, loved it"},
           %{author: "chef_og", text: "Tip: use parchment paper."}
         ],
         video_path: "/tmp/insta_mealie/x.mp4"
       }}
    end)

    # Default adapter stubs for LLM, Whisper, and Mealie
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
                   "recipe" => default_recipe()
                 })
             }
           }
         ]
       }}
    end)

    Application.put_env(:insta_mealie, :whisper_http_adapter, fn _ ->
      {:ok,
       "Transcribed audio: mix oats almonds syrup oil salt, bake at 160C for 40 minutes."}
    end)

    Application.put_env(:insta_mealie, :mealie_http_adapter, fn %{method: m, path: p, body: body} ->
      cond do
        m == :post and p == "/api/recipes" ->
          slug =
            "homemade-granola-" <> (:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower))

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

        m == :get and String.starts_with?(p, "/api/units") ->
          {:ok, %{"data" => []}}

        m == :post and p == "/api/parser/ingredients" ->
          ingredients = if is_list(body), do: body, else: []

          parsed =
            Enum.map(ingredients, fn ingredient ->
              %{
                "quantity" => nil,
                "unit" => %{"name" => nil},
                "food" => %{
                  "name" => ingredient["text"] || "unknown",
                  "id" => "stub-food",
                  "confidence" => 1.0
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

      Enum.each([:llm_http_adapter, :mealie_http_adapter, :whisper_http_adapter], fn k ->
        try do
          Application.delete_env(:insta_mealie, k)
        rescue
          _ -> :ok
        end
      end)
    end)

    Mox.verify_on_exit!()
    :ok
  end
end

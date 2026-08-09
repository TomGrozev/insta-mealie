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
    InstaMealie.Pipeline.JobStore.clear()
    InstaMealie.Pipeline.JobAdmission.reset()

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
          ingredients = body["ingredients"] || []

          parsed =
            Enum.map(ingredients, fn ingredient ->
              name = if is_binary(ingredient), do: ingredient, else: ingredient["text"] || "unknown"

              %{
                "quantity" => 1.0,
                "unit" => %{"name" => "cup", "id" => "stub-unit"},
                "food" => %{
                  "name" => name,
                  "id" => "stub-food",
                  "confidence" => 1.0
                },
                "confidence" => %{"food" => 1.0, "unit" => 1.0, "quantity" => 1.0, "average" => 1.0},
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

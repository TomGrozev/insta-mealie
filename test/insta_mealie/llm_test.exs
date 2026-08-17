defmodule FakeLLMServer do
  @moduledoc false
  # Minimal Plug server that always returns 401 to any /chat/completions
  # request. Used by the `Http.chat/2 against a real non-2xx response`
  # describe block to drive the production Req → HttpClassify path that
  # the Mox-based tests stub over. The single-status design is intentional:
  # 401 classifies as `:auth`, which is the cleanest probe for both bugs:
  #
  #   * Bug 1 (Http.chat/2) — must wrap the bare `%Error{}` in a tuple.
  #   * Bug 2 (LLM.request_llm/3) — must propagate the `:auth` class
  #     verbatim rather than rewrapping it as `:api_error`.

  use Plug.Router

  plug :match
  plug :dispatch

  post "/chat/completions" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{"error" => %{"message" => "Invalid API key"}}))
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{"detail" => "not found"}))
  end
end

defmodule InstaMealie.LLMTest do
  use ExUnit.Case, async: true

  alias InstaMealie.Error
  alias InstaMealie.LLM
  alias InstaMealie.Recipe

  setup do
    on_exit(fn ->
      try do
        Application.delete_env(:insta_mealie, InstaMealie.LLM)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  # ── envelope_from_json/1 tests ────────────────────────────────────

  describe "envelope_from_json/1" do
    test "parses recipe_complete envelope" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => [],
        "recipe" => %{"name" => "Test Recipe", "recipeIngredient" => ["flour"]}
      }

      result = LLM.envelope_from_json(json)

      assert result.completeness == :recipe_complete
      assert result.missing_fields == []
      assert result.recipe.name == "Test Recipe"
      assert length(result.recipe.ingredients) == 1
      assert hd(result.recipe.ingredients).note == "flour"
    end

    test "parses recipe_partial envelope with recipeInstructions missing" do
      json = %{
        "completeness" => "recipe_partial",
        "missing_fields" => ["recipeInstructions"],
        "recipe" => %{"name" => "Partial Recipe"}
      }

      result = LLM.envelope_from_json(json)

      assert result.completeness == :recipe_partial
      assert result.missing_fields == [:recipeInstructions]
      assert result.recipe.name == "Partial Recipe"
    end

    test "parses no_recipe envelope with empty recipe" do
      json = %{
        "completeness" => "no_recipe",
        "missing_fields" => [],
        "recipe" => %{}
      }

      result = LLM.envelope_from_json(json)

      assert result.completeness == :no_recipe
      assert result.missing_fields == []
      assert result.recipe == %InstaMealie.Recipe{}
    end

    test "no_recipe never fabricates a name" do
      json = %{
        "completeness" => "no_recipe",
        "missing_fields" => [],
        "recipe" => %{}
      }

      result = LLM.envelope_from_json(json)
      refute result.recipe.name
    end

    test "drops bogus missing_fields values" do
      json = %{
        "completeness" => "recipe_partial",
        "missing_fields" => ["recipeIngredient", "bogus_field", "recipeInstructions"],
        "recipe" => %{"name" => "X"}
      }

      result = LLM.envelope_from_json(json)
      assert result.missing_fields == [:recipeIngredient, :recipeInstructions]
    end

    test "unknown completeness defaults to :unknown" do
      json = %{
        "completeness" => "something_weird",
        "missing_fields" => [],
        "recipe" => %{"name" => "X"}
      }

      result = LLM.envelope_from_json(json)
      assert result.completeness == :unknown
    end

    test "missing recipe defaults to empty map" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => []
      }

      result = LLM.envelope_from_json(json)
      assert result.recipe == %InstaMealie.Recipe{}
    end

    test "missing missing_fields defaults to empty list" do
      json = %{
        "completeness" => "recipe_complete",
        "recipe" => %{"name" => "X"}
      }

      result = LLM.envelope_from_json(json)
      assert result.missing_fields == []
    end
  end

  # ── consult_link parsing ──────────────────────────────────────────

  describe "envelope_from_json/1 consult_link" do
    test "literal true parses to true" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => [],
        "consult_link" => true,
        "recipe" => %{"name" => "X"}
      }

      result = LLM.envelope_from_json(json)
      assert result.consult_link == true
    end

    test "literal false parses to false" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => [],
        "consult_link" => false,
        "recipe" => %{"name" => "X"}
      }

      result = LLM.envelope_from_json(json)
      assert result.consult_link == false
    end

    test "missing key defaults to false" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => [],
        "recipe" => %{"name" => "X"}
      }

      result = LLM.envelope_from_json(json)
      assert result.consult_link == false
    end

    test "string \"true\" does NOT parse to true (strict-whitelist)" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => [],
        "consult_link" => "true",
        "recipe" => %{"name" => "X"}
      }

      result = LLM.envelope_from_json(json)
      assert result.consult_link == false
    end

    test "string \"false\" parses to false" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => [],
        "consult_link" => "false",
        "recipe" => %{"name" => "X"}
      }

      result = LLM.envelope_from_json(json)
      assert result.consult_link == false
    end

    test "non-boolean (integer, list, nil) parses to false" do
      for value <- [1, 0, nil, [], "yes", %{}] do
        json = %{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "consult_link" => value,
          "recipe" => %{"name" => "X"}
        }

        result = LLM.envelope_from_json(json)

        assert result.consult_link == false,
               "consult_link=#{inspect(value)} should default to false, got #{inspect(result.consult_link)}"
      end
    end
  end

  # ── Duration normalisation tests ───────────────────────────────────

  describe "duration normalisation" do
    test "preserves valid ISO-8601 duration" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => [],
        "recipe" => %{
          "name" => "Test",
          "totalTime" => "PT1H20M"
        }
      }

      result = LLM.envelope_from_json(json)
      assert result.recipe.total_time == "PT1H20M"
    end

    test "normalises '40 minutes' to PT40M" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => [],
        "recipe" => %{
          "name" => "Test",
          "totalTime" => "40 minutes"
        }
      }

      result = LLM.envelope_from_json(json)
      assert result.recipe.total_time == "PT40M"
    end

    test "normalises '1 hour' to PT1H" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => [],
        "recipe" => %{
          "name" => "Test",
          "prepTime" => "1 hour"
        }
      }

      result = LLM.envelope_from_json(json)
      assert result.recipe.prep_time == "PT1H"
    end

    test "normalises '1h20m' to PT1H20M" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => [],
        "recipe" => %{
          "name" => "Test",
          "cookTime" => "1h20m"
        }
      }

      result = LLM.envelope_from_json(json)
      assert result.recipe.cook_time == "PT1H20M"
    end

    test "normalises '1 hour 20 minutes' to PT1H20M" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => [],
        "recipe" => %{
          "name" => "Test",
          "performTime" => "1 hour 20 minutes"
        }
      }

      result = LLM.envelope_from_json(json)
      assert result.recipe.perform_time == "PT1H20M"
    end

    test "normalises '2 hrs' to PT2H" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => [],
        "recipe" => %{
          "name" => "Test",
          "totalTime" => "2 hrs"
        }
      }

      result = LLM.envelope_from_json(json)
      assert result.recipe.total_time == "PT2H"
    end

    test "normalises '90 min' to PT1H30M" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => [],
        "recipe" => %{
          "name" => "Test",
          "totalTime" => "90 min"
        }
      }

      result = LLM.envelope_from_json(json)
      assert result.recipe.total_time == "PT1H30M"
    end

    test "normalises '1:30' to PT1H30M" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => [],
        "recipe" => %{
          "name" => "Test",
          "totalTime" => "1:30"
        }
      }

      result = LLM.envelope_from_json(json)
      assert result.recipe.total_time == "PT1H30M"
    end

    test "leaves unparseable duration strings untouched" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => [],
        "recipe" => %{
          "name" => "Test",
          "totalTime" => "until done"
        }
      }

      result = LLM.envelope_from_json(json)
      assert result.recipe.total_time == "until done"
    end

    test "drops empty string duration values" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => [],
        "recipe" => %{
          "name" => "Test",
          "totalTime" => ""
        }
      }

      result = LLM.envelope_from_json(json)
      refute result.recipe.total_time
    end
  end

  # ── format/2 end-to-end with adapter stub ────────────────────────

  describe "format/2" do
    test "returns envelope from stubbed response" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "consult_link" => false,
          "recipe" => %{
            "name" => "Pasta Aglio e Olio",
            "description" => "Simple garlic pasta",
            "recipeIngredient" => ["spaghetti", "garlic", "olive oil", "chili flakes"],
            "recipeInstructions" => [%{"text" => "Cook pasta. Sauté garlic in oil. Toss."}],
            "tags" => ["pasta", "quick"]
          }
        })

      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, _messages ->
        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => envelope_json}}]
         }}
      end)

      assert {:ok, result} =
               LLM.format({"Pasta recipe caption", [], []}, output_language: "en")

      assert result.completeness == :recipe_complete
      assert result.consult_link == false
      assert result.recipe.name == "Pasta Aglio e Olio"

      assert Enum.map(result.recipe.ingredients, & &1.note) == [
               "spaghetti",
               "garlic",
               "olive oil",
               "chili flakes"
             ]
    end

    test "passes output_language in the system prompt" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "consult_link" => false,
          "recipe" => %{"name" => "Test"}
        })

      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, _messages ->
        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => envelope_json}}]
         }}
      end)

      assert {:ok, result} =
               LLM.format({"Test caption", [], []}, output_language: "fr")

      assert result.recipe.name == "Test"
    end

    test "handles no_recipe envelope" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "no_recipe",
          "missing_fields" => [],
          "consult_link" => false,
          "recipe" => %{}
        })

      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, _messages ->
        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => envelope_json}}]
         }}
      end)

      assert {:ok, result} =
               LLM.format({"No recipe here", [], []}, output_language: "en")

      assert result.completeness == :no_recipe
      assert result.consult_link == false
      assert result.recipe == %Recipe{}
    end

    test "consult_link true in response parses through to envelope" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_partial",
          "missing_fields" => ["recipeInstructions"],
          "consult_link" => true,
          "recipe" => %{"name" => "Partial"}
        })

      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, _messages ->
        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => envelope_json}}]
         }}
      end)

      assert {:ok, result} =
               LLM.format({"Full recipe on my blog", [], ["https://example.com/recipe"]},
                 output_language: "en"
               )

      assert result.consult_link == true
      assert result.completeness == :recipe_partial
    end

    test "appends candidate links to user content when non-empty" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "consult_link" => true,
          "recipe" => %{"name" => "Test"}
        })

      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, messages ->
        # Find the LAST user message — the prompt's user content is appended there.
        last_user = messages |> Enum.reverse() |> Enum.find(&(&1.role == "user"))
        assert last_user != nil
        assert last_user.content =~ "Candidate recipe links:"
        assert last_user.content =~ "https://blog.example.com/recipe-1"
        assert last_user.content =~ "https://blog.example.com/recipe-2"

        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => envelope_json}}]
         }}
      end)

      assert {:ok, _result} =
               LLM.format(
                 {"Caption text", [],
                  ["https://blog.example.com/recipe-1", "https://blog.example.com/recipe-2"]},
                 output_language: "en"
               )
    end

    test "omits candidate links block when links list is empty" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "consult_link" => false,
          "recipe" => %{"name" => "Test"}
        })

      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, messages ->
        last_user = messages |> Enum.reverse() |> Enum.find(&(&1.role == "user"))
        assert last_user != nil
        refute last_user.content =~ "Candidate recipe links:"

        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => envelope_json}}]
         }}
      end)

      assert {:ok, _result} =
               LLM.format({"Plain caption", [], []}, output_language: "en")
    end

    test "system prompt mentions consult_link contract" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "consult_link" => false,
          "recipe" => %{"name" => "Test"}
        })

      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, messages ->
        system = Enum.find(messages, &(&1.role == "system"))
        assert system.content =~ "consult_link"
        assert system.content =~ "\"consult_link\": false"

        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => envelope_json}}]
         }}
      end)

      assert {:ok, _result} =
               LLM.format({"Caption", [], []}, output_language: "en")
    end
  end

  # ── merge/3 end-to-end with adapter stub ────────────────────────

  describe "merge/3" do
    test "merges with draft into complete envelope" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "consult_link" => false,
          "recipe" => %{
            "name" => "Merged Recipe",
            "description" => "Combined from caption and transcript",
            "recipeIngredient" => ["ingredient1", "ingredient2"],
            "recipeInstructions" => [%{"text" => "Step 1"}, %{"text" => "Step 2"}],
            "tags" => ["merged"]
          }
        })

      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, _messages ->
        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => envelope_json}}]
         }}
      end)

      draft = %{"name" => "Partial Draft", "recipeIngredient" => ["ingredient1"]}

      assert {:ok, result} =
               LLM.merge(
                 draft,
                 {"Original caption", "Transcript of the voiceover", nil},
                 output_language: "en"
               )

      assert result.completeness == :recipe_complete
      assert result.consult_link == false
      assert result.recipe.name == "Merged Recipe"
    end

    test "works without draft (positional draft=nil)" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "consult_link" => false,
          "recipe" => %{"name" => "From Transcript Only"}
        })

      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, _messages ->
        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => envelope_json}}]
         }}
      end)

      assert {:ok, result} =
               LLM.merge(nil, {"Caption", "Transcript", nil}, output_language: "en")

      assert result.recipe.name == "From Transcript Only"
    end

    test "draft: %Recipe{} is projected into user content" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "consult_link" => false,
          "recipe" => %{"name" => "Refined"}
        })

      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, messages ->
        last_user = messages |> Enum.reverse() |> Enum.find(&(&1.role == "user"))
        assert last_user.content =~ "Partial recipe draft from caption analysis:"
        assert last_user.content =~ "Refined"

        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => envelope_json}}]
         }}
      end)

      draft = %Recipe{name: "Refined", recipe_yield: "4 servings"}

      assert {:ok, _result} =
               LLM.merge(draft, {"caption", "transcript", nil}, output_language: "en")
    end

    test "transcript nil omits the transcript section (no transcript available)" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "consult_link" => false,
          "recipe" => %{"name" => "Caption Only"}
        })

      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, messages ->
        last_user = messages |> Enum.reverse() |> Enum.find(&(&1.role == "user"))
        # The user content must NOT include a "Transcript: ..." line — there's
        # no transcript to show.
        refute last_user.content =~ ~r/\nTranscript:/

        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => envelope_json}}]
         }}
      end)

      assert {:ok, _result} =
               LLM.merge(nil, {"Caption only here", nil, nil}, output_language: "en")
    end

    test "transcript empty string keeps a transcript section labelled as empty" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "consult_link" => false,
          "recipe" => %{"name" => "Caption Only"}
        })

      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, messages ->
        last_user = messages |> Enum.reverse() |> Enum.find(&(&1.role == "user"))
        # The transcript section IS present (we attempted transcription, it
        # produced no text) — distinct from "no transcript available".
        assert last_user.content =~ "Transcript:"

        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => envelope_json}}]
         }}
      end)

      assert {:ok, _result} =
               LLM.merge(nil, {"Caption only here", "", nil}, output_language: "en")
    end

    test "non-nil linked_recipe is projected into user content with a 'Linked recipe' label" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "consult_link" => false,
          "recipe" => %{"name" => "Merged with Linked"}
        })

      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, messages ->
        last_user = messages |> Enum.reverse() |> Enum.find(&(&1.role == "user"))
        # The linked recipe block must be present and labelled so the model
        # doesn't treat it as ground truth.
        assert last_user.content =~ "Linked recipe"
        # A unique field from the linked recipe's ingredients must appear in
        # the projected JSON content (the merge model needs the actual lines
        # to fill gaps).
        assert last_user.content =~ "chia seeds"

        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => envelope_json}}]
         }}
      end)

      linked = %Recipe{
        name: "SourceYogurtPudding",
        recipe_yield: "4 servings",
        ingredients: [%InstaMealie.Ingredient{note: "chia seeds"}]
      }

      assert {:ok, _result} =
               LLM.merge(
                 nil,
                 {"Adapted caption", nil, linked},
                 output_language: "en"
               )
    end

    # ADR-0006: only `recipeIngredient`, `recipeInstructions`, `recipeYield`,
    # and times are taken from the linked recipe. `name`, `description`,
    # `tags`, and `notes` MUST NOT leak into the merge prompt — otherwise the
    # LLM is handed the very renaming bait the "linked recipe may NEVER
    # rename the dish" rule exists to prevent.
    test "linked_recipe projection omits name/description/tags/notes but keeps ingredients/instructions" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "consult_link" => false,
          "recipe" => %{"name" => "Merged with Linked"}
        })

      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, messages ->
        last_user = messages |> Enum.reverse() |> Enum.find(&(&1.role == "user"))
        assert last_user != nil
        assert last_user.content =~ "Linked recipe"

        # Allowed fields ARE projected.
        assert last_user.content =~ "chia seeds"
        assert last_user.content =~ "Whisk everything together"
        assert last_user.content =~ "4 servings"

        # Forbidden fields are NOT projected (ADR-0006).
        refute last_user.content =~ "Yogurt Chia Pudding"
        refute last_user.content =~ "Overnight chia base — refined"
        refute last_user.content =~ "make-ahead"
        refute last_user.content =~ "From the linked page"

        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => envelope_json}}]
         }}
      end)

      linked = %Recipe{
        name: "Yogurt Chia Pudding",
        description: "Overnight chia base — refined on the show",
        recipe_yield: "4 servings",
        ingredients: [%InstaMealie.Ingredient{note: "chia seeds"}],
        instructions: [%{"text" => "Whisk everything together"}],
        tags: ["make-ahead", "base"],
        notes: [%{"title" => "From the linked page", "text" => "some note"}]
      }

      assert {:ok, _result} =
               LLM.merge(
                 nil,
                 {"Adapted caption", nil, linked},
                 output_language: "en"
               )
    end

    test "linked_recipe=nil omits the linked recipe block" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "consult_link" => false,
          "recipe" => %{"name" => "Just Merged"}
        })

      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, messages ->
        last_user = messages |> Enum.reverse() |> Enum.find(&(&1.role == "user"))
        refute last_user.content =~ "Linked recipe"

        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => envelope_json}}]
         }}
      end)

      assert {:ok, _result} =
               LLM.merge(nil, {"Caption", "Transcript", nil}, output_language: "en")
    end

    test "system prompt mentions the linked recipe source contract" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "consult_link" => false,
          "recipe" => %{"name" => "X"}
        })

      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, messages ->
        system = Enum.find(messages, &(&1.role == "system"))
        # The system prompt must describe the linked recipe as a suspect
        # supplementary source (ADR-0006).
        assert system.content =~ "linked recipe"
        # It must forbid overwriting what the caption states explicitly.
        assert system.content =~ ~r/(caption|must never|never overwrite|never drop)/i

        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => envelope_json}}]
         }}
      end)

      assert {:ok, _result} =
               LLM.merge(nil, {"Caption", "Transcript", nil}, output_language: "en")
    end
  end

  # ── Malformed response handling ────────────────────────────────────

  describe "malformed response handling" do
    test "format returns api_error on non-JSON completion" do
      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, _messages ->
        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => "this is not json"}}]
         }}
      end)

      assert {:error, %Error{class: :api_error}} =
               LLM.format({"x", [], []}, output_language: "en")
    end
  end

  # ── Error path tests ───────────────────────────────────────────────

  describe "error handling" do
    test "format returns error tuple on HTTP failure" do
      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, _messages ->
        {:error, :auth}
      end)

      assert {:error, %Error{class: :api_error}} =
               LLM.format({"test", [], []}, output_language: "en")
    end

    test "merge returns error tuple on HTTP failure" do
      Application.put_env(:insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Mock)

      Mox.expect(InstaMealie.LLM.Mock, :chat, fn _model, _messages ->
        {:error, :auth}
      end)

      assert {:error, %Error{class: :api_error}} =
               LLM.merge(nil, {"caption", "transcript", nil}, output_language: "en")
    end
  end

  # ── Real HTTP chat/2 regression ─────────────────────────────────
  # The Mox-based tests above stub at the Adapter boundary, which is
  # exactly why the bare-%Error{} bug in `LLM.Http.chat/2` and the
  # rewrap-corruption bug in `LLM.request_llm/3` had zero coverage.
  # This describe stands up a real Bandit server returning 401, points
  # `:openai, :base_url` at it, and exercises the full Req →
  # HttpClassify → chat/2 → request_llm/3 path that production runs.
  #
  # Pre-fix:
  #   * Bug 1 — `chat/2` returned a bare `%Error{}` (the unmatched `with`
  #     value), violating the `{:ok, _} | {:error, _}` Adapter contract.
  #   * Bug 2 — `request_llm/3` either rewrapped an `:auth` Error into
  #     `:api_error` (corrupting retry semantics — `:auth` is
  #     non-retryable, `:api_error` is retryable) or, if Bug 1 was
  #     already fixed, hit `Logger.error("... reason=#{reason}")` with
  #     a `%Error{}` reason and raised `Protocol.UndefinedError` from
  #     the implicit `String.Chars.to_string/1` call.
  #
  # Post-fix:
  #   * chat/2 returns `{:error, %Error{class: :auth}}` directly.
  #   * request_llm/3 propagates that struct as-is, so the class
  #     survives all the way to the pipeline caller.

  describe "Http.chat/2 against a real non-2xx response" do
    setup do
      {:ok, sock} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(sock)
      :gen_tcp.close(sock)

      {:ok, server_pid} = Bandit.start_link(plug: FakeLLMServer, port: port)

      prev_openai = Application.get_env(:insta_mealie, :openai, [])

      base = "http://127.0.0.1:#{port}"

      Application.put_env(
        :insta_mealie,
        :openai,
        Keyword.put(prev_openai, :base_url, base)
      )

      # Other tests in this module install `InstaMealie.LLM.Mock` via
      # Application.put_env. Delete the override so `LLM.request_llm/3`
      # resolves `InstaMealie.LLM.Http` and exercises the real Req path.
      Application.delete_env(:insta_mealie, InstaMealie.LLM)

      on_exit(fn ->
        Process.exit(server_pid, :kill)

        case prev_openai do
          [] -> Application.delete_env(:insta_mealie, :openai)
          kw -> Application.put_env(:insta_mealie, :openai, kw)
        end
      end)

      {:ok, port: port}
    end

    test "chat/2 returns {:error, %Error{class: :auth}} on a 401 response (Bug 1 regression)" do
      # Pre-fix, the `with :ok <- ...` in chat/2 had no `else` clause and
      # returned the bare `%Error{}` it received from HttpClassify — the
      # Adapter contract `{:ok, _} | {:error, _}` was violated, and any
      # caller doing `{:error, %Error{}} = chat(...)` would crash with
      # `MatchError` (or `WithClauseError` inside a `with`).
      assert {:error, %Error{class: :auth}} =
               InstaMealie.LLM.Http.chat("test-model", [
                 %{role: "user", content: "hi"}
               ])
    end

    test "request_llm/3 preserves the class returned by Http.chat/2 (Bug 2 regression)" do
      # Pre-fix, request_llm/3 either saw a bare `%Error{}` from chat/2
      # (Bug 1) and skipped `llm_error` entirely — leaving the caller with
      # a bare struct — or, if Bug 1 was already fixed, fed the struct
      # into `llm_error(:api_error, reason, ...)`, which both raised
      # `Protocol.UndefinedError` from the `Logger.error` interpolation
      # AND corrupted retry semantics by rewrapping `:auth` (non-retryable)
      # as `:api_error` (retryable).
      assert {:error, %Error{class: :auth}} =
               LLM.format({"test caption", [], []}, output_language: "en")
    end
  end
end

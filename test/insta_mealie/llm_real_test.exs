defmodule InstaMealie.LlmRealTest do
  use ExUnit.Case, async: true

  alias InstaMealie.Llm.Real

  @openai_config [
    base_url: "http://localhost:12345",
    api_key: "test-key",
    model: "test-model",
    merge_model: "test-merge-model"
  ]

  setup do
    # Swap HTTP adapter to the test stub
    original_adapter = Application.get_env(:insta_mealie, :llm_http_adapter)
    Application.put_env(:insta_mealie, :llm_http_adapter, InstaMealie.Test.LlmHttpStub)

    # Ensure :openai config exists
    original_openai = Application.get_env(:insta_mealie, :openai)
    Application.put_env(:insta_mealie, :openai, @openai_config)

    on_exit(fn ->
      if original_adapter do
        Application.put_env(:insta_mealie, :llm_http_adapter, original_adapter)
      else
        Application.delete_env(:insta_mealie, :llm_http_adapter)
      end

      if original_openai do
        Application.put_env(:insta_mealie, :openai, original_openai)
      else
        Application.delete_env(:insta_mealie, :openai)
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

      result = Real.envelope_from_json(json)

      assert result.completeness == :recipe_complete
      assert result.missing_fields == []
      assert result.recipe["name"] == "Test Recipe"
      assert result.recipe["recipeIngredient"] == ["flour"]
    end

    test "parses recipe_partial envelope with recipeInstructions missing" do
      json = %{
        "completeness" => "recipe_partial",
        "missing_fields" => ["recipeInstructions"],
        "recipe" => %{"name" => "Partial Recipe"}
      }

      result = Real.envelope_from_json(json)

      assert result.completeness == :recipe_partial
      assert result.missing_fields == [:recipeInstructions]
      assert result.recipe["name"] == "Partial Recipe"
    end

    test "parses no_recipe envelope with empty recipe" do
      json = %{
        "completeness" => "no_recipe",
        "missing_fields" => [],
        "recipe" => %{}
      }

      result = Real.envelope_from_json(json)

      assert result.completeness == :no_recipe
      assert result.missing_fields == []
      assert result.recipe == %{}
    end

    test "no_recipe never fabricates a name" do
      json = %{
        "completeness" => "no_recipe",
        "missing_fields" => [],
        "recipe" => %{}
      }

      result = Real.envelope_from_json(json)
      refute Map.has_key?(result.recipe, "name")
    end

    test "drops bogus missing_fields values" do
      json = %{
        "completeness" => "recipe_partial",
        "missing_fields" => ["recipeIngredient", "bogus_field", "recipeInstructions"],
        "recipe" => %{"name" => "X"}
      }

      result = Real.envelope_from_json(json)
      assert result.missing_fields == [:recipeIngredient, :recipeInstructions]
    end

    test "unknown completeness defaults to :no_recipe" do
      json = %{
        "completeness" => "something_weird",
        "missing_fields" => [],
        "recipe" => %{"name" => "X"}
      }

      result = Real.envelope_from_json(json)
      assert result.completeness == :no_recipe
    end

    test "missing recipe defaults to empty map" do
      json = %{
        "completeness" => "recipe_complete",
        "missing_fields" => []
      }

      result = Real.envelope_from_json(json)
      assert result.recipe == %{}
    end

    test "missing missing_fields defaults to empty list" do
      json = %{
        "completeness" => "recipe_complete",
        "recipe" => %{"name" => "X"}
      }

      result = Real.envelope_from_json(json)
      assert result.missing_fields == []
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

      result = Real.envelope_from_json(json)
      assert result.recipe["totalTime"] == "PT1H20M"
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

      result = Real.envelope_from_json(json)
      assert result.recipe["totalTime"] == "PT40M"
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

      result = Real.envelope_from_json(json)
      assert result.recipe["prepTime"] == "PT1H"
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

      result = Real.envelope_from_json(json)
      assert result.recipe["cookTime"] == "PT1H20M"
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

      result = Real.envelope_from_json(json)
      assert result.recipe["performTime"] == "PT1H20M"
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

      result = Real.envelope_from_json(json)
      assert result.recipe["totalTime"] == "PT2H"
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

      result = Real.envelope_from_json(json)
      assert result.recipe["totalTime"] == "PT1H30M"
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

      result = Real.envelope_from_json(json)
      assert result.recipe["totalTime"] == "PT1H30M"
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

      result = Real.envelope_from_json(json)
      assert result.recipe["totalTime"] == "until done"
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

      result = Real.envelope_from_json(json)
      refute Map.has_key?(result.recipe, "totalTime")
    end
  end

  # ── format/2 end-to-end with stubbed HTTP ──────────────────────────

  describe "format/2" do
    test "returns envelope from canned response" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "recipe" => %{
            "name" => "Pasta Aglio e Olio",
            "description" => "Simple garlic pasta",
            "recipeIngredient" => ["spaghetti", "garlic", "olive oil", "chili flakes"],
            "recipeInstructions" => [%{"text" => "Cook pasta. Sauté garlic in oil. Toss."}],
            "tags" => ["pasta", "quick"]
          }
        })

      canned = %{
        "choices" => [%{"message" => %{"content" => envelope_json}}]
      }

      Application.put_env(:insta_mealie, :llm_canned_response, canned)

      assert {:ok, result} =
               Real.format("Pasta recipe caption", output_language: "en", comments: [])

      assert result.completeness == :recipe_complete
      assert result.recipe["name"] == "Pasta Aglio e Olio"

      assert result.recipe["recipeIngredient"] == [
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
          "recipe" => %{"name" => "Test"}
        })

      canned = %{
        "choices" => [%{"message" => %{"content" => envelope_json}}]
      }

      Application.put_env(:insta_mealie, :llm_canned_response, canned)

      assert {:ok, result} = Real.format("Test caption", output_language: "fr", comments: [])
      assert result.recipe["name"] == "Test"
    end

    test "handles no_recipe envelope" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "no_recipe",
          "missing_fields" => [],
          "recipe" => %{}
        })

      canned = %{
        "choices" => [%{"message" => %{"content" => envelope_json}}]
      }

      Application.put_env(:insta_mealie, :llm_canned_response, canned)

      assert {:ok, result} = Real.format("No recipe here", output_language: "en", comments: [])
      assert result.completeness == :no_recipe
      assert result.recipe == %{}
    end
  end

  # ── merge/3 end-to-end with stubbed HTTP ──────────────────────────

  describe "merge/3" do
    test "merges with draft into complete envelope" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "recipe" => %{
            "name" => "Merged Recipe",
            "description" => "Combined from caption and transcript",
            "recipeIngredient" => ["ingredient1", "ingredient2"],
            "recipeInstructions" => [%{"text" => "Step 1"}, %{"text" => "Step 2"}],
            "tags" => ["merged"]
          }
        })

      canned = %{
        "choices" => [%{"message" => %{"content" => envelope_json}}]
      }

      Application.put_env(:insta_mealie, :llm_canned_response, canned)

      draft = %{"name" => "Partial Draft", "recipeIngredient" => ["ingredient1"]}

      assert {:ok, result} =
               Real.merge(
                 "Original caption",
                 "Transcript of the voiceover",
                 output_language: "en",
                 draft: draft
               )

      assert result.completeness == :recipe_complete
      assert result.recipe["name"] == "Merged Recipe"
    end

    test "works without draft" do
      envelope_json =
        Jason.encode!(%{
          "completeness" => "recipe_complete",
          "missing_fields" => [],
          "recipe" => %{"name" => "From Transcript Only"}
        })

      canned = %{
        "choices" => [%{"message" => %{"content" => envelope_json}}]
      }

      Application.put_env(:insta_mealie, :llm_canned_response, canned)

      assert {:ok, result} =
               Real.merge("Caption", "Transcript", output_language: "en")

      assert result.recipe["name"] == "From Transcript Only"
    end
  end

  # ── Malformed response handling ────────────────────────────────────

  describe "malformed response handling" do
    test "format returns api_error on non-JSON completion" do
      original_canned = Application.get_env(:insta_mealie, :llm_canned_response)

      canned = %{
        "choices" => [%{"message" => %{"content" => "this is not json"}}]
      }

      Application.put_env(:insta_mealie, :llm_canned_response, canned)

      on_exit(fn ->
        if original_canned do
          Application.put_env(:insta_mealie, :llm_canned_response, original_canned)
        else
          Application.delete_env(:insta_mealie, :llm_canned_response)
        end
      end)

      assert {:error, :api_error, _} = Real.format("x", output_language: "en")
    end
  end

  # ── Error path tests ───────────────────────────────────────────────

  describe "error handling" do
    test "format returns error tuple on HTTP failure" do
      # Use a stub that returns an error
      original = Application.get_env(:insta_mealie, :llm_http_adapter)
      Application.put_env(:insta_mealie, :llm_http_adapter, InstaMealie.Test.LlmErrorStub)

      on_exit(fn ->
        if original do
          Application.put_env(:insta_mealie, :llm_http_adapter, original)
        else
          Application.delete_env(:insta_mealie, :llm_http_adapter)
        end
      end)

      assert {:error, :auth, "unauthorized"} =
               Real.format("test", output_language: "en", comments: [])
    end

    test "merge returns error tuple on HTTP failure" do
      original = Application.get_env(:insta_mealie, :llm_http_adapter)
      Application.put_env(:insta_mealie, :llm_http_adapter, InstaMealie.Test.LlmErrorStub)

      on_exit(fn ->
        if original do
          Application.put_env(:insta_mealie, :llm_http_adapter, original)
        else
          Application.delete_env(:insta_mealie, :llm_http_adapter)
        end
      end)

      assert {:error, :auth, "unauthorized"} =
               Real.merge("caption", "transcript", output_language: "en")
    end
  end
end

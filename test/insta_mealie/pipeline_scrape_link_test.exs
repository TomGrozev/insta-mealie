defmodule InstaMealie.PipelineScrapeLinkTest do
  @moduledoc """
  FSM tests for the `scrape_link` stage introduced by ADR-0006.

  Each scenario corresponds to one acceptance criterion from issue #50:
  a new pipeline stage between `llm_format` and `transcribe` that scrapes
  candidate links via Mealie's `POST /api/recipes/test-scrape-url`,
  pre-empts transcription when the linked recipe covers the caption's
  missing fields, never fails the job, and stamps provenance at import
  (`orgURL` = reel URL, linked page URL in notes, image fallback).

  The default test stubs (see `test/support/insta_mealie/case.ex`) install
  a `:mealie_http_adapter` that returns `{:error, ...}` for the scrape
  endpoint — so tests that do NOT care about scraping get a deterministic
  `:unresolved` outcome if scrape_link is ever triggered. Tests that want
  a successful scrape install their own adapter via `with_overrides/2`.
  """

  use InstaMealie.TestCase

  alias InstaMealie.Error
  alias InstaMealie.LLM.Mock, as: LLMMock
  alias InstaMealie.Pipeline
  alias InstaMealie.Pipeline.Job

  # The format prompt's user content is `caption <> comments_text <> links_text`
  # (no prefix); the merge prompt's user content starts with `"Caption: "`.
  # This prefix discriminator is robust regardless of whether transcript /
  # draft / linked_recipe are nil in the sources tuple.
  defp merge_call?(messages) do
    case Enum.reverse(messages) |> Enum.find(fn m -> m[:role] == "user" end) do
      nil -> false
      msg -> String.starts_with?(msg[:content] || "", "Caption:")
    end
  end

  # Build a raw OpenAI-style chat response, with `consult_link` set so the
  # router can opt in or out of `scrape_link` (ADR-0006).
  defp chat_response(completeness, missing_fields, recipe, consult_link) do
    {:ok,
     %{
       "choices" => [
         %{
           "message" => %{
             "content" =>
               Jason.encode!(%{
                 "completeness" => completeness,
                 "missing_fields" => missing_fields,
                 "consult_link" => consult_link,
                 "recipe" => recipe
               })
           }
         }
       ]
     }}
  end

  # Build a body for `POST /api/recipes/test-scrape-url` that
  # `Mealie.scrape_url/1` will turn into a `%Recipe{}`.
  defp scraped_recipe_body(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Yogurt Chia Pudding",
        "description" => "A creamy overnight pudding.",
        "recipeYield" => "2 servings",
        "recipeIngredient" => [
          "1/4 cup chia seeds",
          "1 cup plain yogurt",
          "2 tbsp honey"
        ],
        "recipeInstructions" => [
          %{"text" => "Whisk chia seeds, yogurt, and honey together."},
          %{"text" => "Refrigerate overnight, then stir."}
        ],
        "image" => "https://example.com/yogurt-chia.jpg"
      },
      overrides
    )
  end

  # Install a YtDlp.fetch_metadata stub that returns a fetch whose caption
  # contains the given link (so the router's link extraction actually finds
  # candidates). Restores the previous stub on exit.
  defp stub_caption_with_link(link, opts \\ []) do
    comment_link = Keyword.get(opts, :comment_link)
    comments = build_includes([], comment_link)
    prev = Application.get_env(:insta_mealie, InstaMealie.YtDlp, InstaMealie.YtDlp.Mock)

    Application.put_env(:insta_mealie, InstaMealie.YtDlp, InstaMealie.YtDlp.Mock)

    Mox.stub(InstaMealie.YtDlp.Mock, :fetch_metadata, fn _url, _opts ->
      {:ok,
       %{
         author: "op_user",
         caption: "Check this out: #{link}",
         comments: comments,
         fetch_dir: "/tmp/insta_mealie/sc"
       }}
    end)

    on_exit(fn ->
      Application.put_env(:insta_mealie, InstaMealie.YtDlp, prev)
    end)
  end

  defp build_includes(_items, nil), do: []

  defp build_includes(_items, text) when is_binary(text),
    do: [%{author: "op_user", text: text}]

  # Install a `:mealie_http_adapter` that handles `/api/recipes/test-scrape-url`
  # with `scraped_fun` (receives the request body, returns either the success
  # map or `{:error, %Error{}}`), and delegates all other calls to `prev`.
  # Restores the previous adapter on exit.
  defp override_mealie(prev, scraped_fun) do
    Application.put_env(
      :insta_mealie,
      :mealie_http_adapter,
      fn m, p, body ->
        case m == :post and p == "/api/recipes/test-scrape-url" do
          true -> scraped_fun.(body)
          false -> prev.(m, p, body)
        end
      end
    )

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
        v -> Application.put_env(:insta_mealie, :mealie_http_adapter, v)
      end
    end)
  end

  defp current_mealie_adapter do
    Application.get_env(:insta_mealie, :mealie_http_adapter)
  end

  # ── Scenario 1: default LLM mock (no consult_link) → scrape_link skipped ──

  describe "scrape_link skipped (no consult_link)" do
    test "default LLM mock omits consult_link → scrape_link :skipped, behavior unchanged" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")

      assert {:ok, id} = Pipeline.create_job(%{url: "https://instagram.com/reel/abc"})

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000

      assert Map.get(job.stages, :scrape_link) == :skipped
      assert Map.get(job.stages, :llm_format) == :done
      assert Map.get(job.stages, :transcribe) == :skipped
      assert Map.get(job.stages, :llm_merge) == :skipped
      assert Map.get(job.stages, :mealie_import) == :done
    end
  end

  # ── Scenario: consult_link=true with ZERO link candidates ──
  # A router that asks to consult a link but finds no candidates in the
  # caption/comments must fall back to pre-#50 behaviour exactly — i.e.
  # `recipe_complete` skips both transcribe and llm_merge. The `consult_link`
  # flag alone is not enough to run llm_merge; it must be combined with an
  # actually-executed scrape_link (the previous bug keyed llm_merge off
  # `state.consult_link` alone, causing a phantom llm_merge run that did
  # nothing).

  describe "scrape_link skipped (consult_link true but zero link candidates)" do
    test "recipe_complete verdict, consult_link=true but no candidates → scrape_link, transcribe, llm_merge all :skipped" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")

      # A caption with NO URL candidates, but the router still returns
      # consult_link: true (e.g. it interpreted some vague textual cue).
      stub_caption_with_link("Just a complete caption with no link at all.")

      Mox.stub(LLMMock, :chat, fn _model, _messages ->
        chat_response(
          "recipe_complete",
          [],
          %{"name" => "Standalone Caption"},
          true
        )
      end)

      assert {:ok, id} = Pipeline.create_job(%{url: "https://instagram.com/reel/no-candidates"})

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000

      # Pre-#50 `recipe_complete` behaviour: scrape_link, transcribe, and
      # llm_merge ALL skipped, mealie_import runs.
      assert Map.get(job.stages, :scrape_link) == :skipped
      assert Map.get(job.stages, :transcribe) == :skipped
      assert Map.get(job.stages, :llm_merge) == :skipped
      assert Map.get(job.stages, :mealie_import) == :done
    end
  end

  # ── Scenario 2: consult_link: true + recipe_complete → scrape_link AND
  #    llm_merge run, transcribe skipped, no Whisper call ──

  describe "scrape_link resolved + recipe_complete (URL mode)" do
    test "scrape_link :done, llm_merge :done, transcribe :skipped, no Whisper call" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")
      link = "https://example.com/recipe-page"

      stub_caption_with_link(link)

      override_mealie(current_mealie_adapter(), fn _body ->
        {:ok, scraped_recipe_body()}
      end)

      # If Whisper were ever called from this test path, the stub below raises
      # and fails the test loudly. Combined with Mox global mode, any stray
      # call from any spawned stage task surfaces here too.
      Mox.stub(InstaMealie.Whisper.Mock, :transcribe, fn _, _, _, _ ->
        raise "Whisper.transcribe/4 must NOT be called when scrape_link resolved recipe_complete"
      end)

      Mox.stub(LLMMock, :chat, fn _model, messages ->
        if merge_call?(messages) do
          chat_response("recipe_complete", [], %{"name" => "Merged Complete"}, false)
        else
          chat_response(
            "recipe_complete",
            [],
            %{"name" => "Caption Complete"},
            true
          )
        end
      end)

      assert {:ok, id} = Pipeline.create_job(%{url: "https://instagram.com/reel/sc1"})

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000

      assert Map.get(job.stages, :fetch) == :done
      assert Map.get(job.stages, :llm_format) == :done
      assert Map.get(job.stages, :scrape_link) == :done
      assert Map.get(job.stages, :transcribe) == :skipped
      assert Map.get(job.stages, :llm_merge) == :done
      assert Map.get(job.stages, :mealie_import) == :done
    end
  end

  # ── Scenario 3: scrape failure (400-shaped error) is survivable ──

  describe "scrape_link failure is survivable" do
    test "scrape_url returns :api_error 400-shaped error → scrape_link :unresolved, job still :succeeded, error_stage nil" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")
      link = "https://example.com/not-a-recipe"

      stub_caption_with_link(link)

      override_mealie(current_mealie_adapter(), fn _body ->
        # HttpClassify maps 400 to :api_error "client error 400" — the actual
        # shape the production code will surface when Mealie rejects a URL.
        {:error, Error.new(:api_error, "client error 400")}
      end)

      Mox.stub(LLMMock, :chat, fn _model, messages ->
        if merge_call?(messages) do
          chat_response("recipe_complete", [], %{"name" => "After Failed Scrape"}, false)
        else
          chat_response("recipe_complete", [], %{"name" => "Caption"}, true)
        end
      end)

      assert {:ok, id} = Pipeline.create_job(%{url: "https://instagram.com/reel/sc3"})

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000

      assert Map.get(job.stages, :scrape_link) == :unresolved
      assert job.state == :succeeded
      assert job.error_stage == nil
      assert job.error_class == nil
      assert job.error_summary == nil
    end
  end

  # ── Scenario 4: transcription pre-emption ──

  describe "transcription pre-emption when linked recipe covers missing_fields" do
    test "recipe_partial with missing recipeInstructions + scraped recipe has instructions → transcribe :skipped, llm_merge :done, no Whisper" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")
      link = "https://example.com/recipe-with-instructions"

      stub_caption_with_link(link)

      override_mealie(current_mealie_adapter(), fn _body ->
        # Non-empty recipeInstructions — the structural check inside
        # `linked_recipe_covers_missing_fields?/2` only requires non-empty.
        {:ok, scraped_recipe_body()}
      end)

      Mox.stub(InstaMealie.Whisper.Mock, :transcribe, fn _, _, _, _ ->
        raise "Whisper.transcribe/4 must NOT be called when the linked recipe covers missing recipeInstructions"
      end)

      Mox.stub(LLMMock, :chat, fn _model, messages ->
        if merge_call?(messages) do
          chat_response("recipe_complete", [], %{"name" => "Pre-empted"}, false)
        else
          chat_response(
            "recipe_partial",
            ["recipeInstructions"],
            %{"name" => "Partial Caption", "recipeIngredient" => ["flour", "water"]},
            true
          )
        end
      end)

      assert {:ok, id} = Pipeline.create_job(%{url: "https://instagram.com/reel/sc4"})

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000

      assert Map.get(job.stages, :scrape_link) == :done
      assert Map.get(job.stages, :transcribe) == :skipped
      assert Map.get(job.stages, :llm_merge) == :done
      assert Map.get(job.stages, :mealie_import) == :done
    end
  end

  # ── Scenario 6: regression test on the issue's own example ──

  describe "issue #50 regression — Chocolate Yogurt Chia Pudding" do
    test "caption + linked base recipe are merged, neither overwrites the other" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")
      url = "https://instagram.com/reel/Da6Pg1Bhtep"
      linked_url = "https://foolproofliving.com/yogurt-chia-pudding/"

      stub_caption_with_link(
        "Chocolate Yogurt Chia Pudding 🍫 Based on the base recipe from " <>
          linked_url <>
          " — I added cocoa powder to make it chocolatey! #recipe #healthy"
      )

      # The Mealie scrape returns the BASE recipe (no chocolate, with chia).
      linked_payload =
        scraped_recipe_body(%{
          "name" => "Yogurt Chia Pudding",
          "recipeIngredient" => [
            "1/4 cup chia seeds",
            "1 cup plain yogurt",
            "2 tbsp honey",
            "1 tsp vanilla extract",
            "1/2 cup milk",
            "1 pinch salt",
            "2 tbsp maple syrup"
          ],
          "recipeInstructions" => [
            %{"text" => "Whisk chia, yogurt, honey, and milk in a bowl."},
            %{"text" => "Cover and refrigerate overnight."},
            %{"text" => "Stir in maple syrup and vanilla before serving."},
            %{"text" => "Top with fresh berries if desired."}
          ],
          "image" => "https://example.com/yogurt-chia-base.jpg"
        })

      override_mealie(current_mealie_adapter(), fn _body -> {:ok, linked_payload} end)

      Mox.stub(InstaMealie.Whisper.Mock, :transcribe, fn _, _, _, _ ->
        raise "Whisper.transcribe/4 must NOT be called — the linked recipe covers recipeInstructions"
      end)

      Mox.stub(LLMMock, :chat, fn _model, messages ->
        if merge_call?(messages) do
          # Verify the merge prompt carries BOTH sources: the draft (from
          # the caption's LLM call) carries cocoa, and the linked-recipe
          # block is present so the model can fill in the missing pieces.
          last_user = messages |> Enum.reverse() |> Enum.find(&(&1.role == "user"))

          assert last_user != nil

          # Caption + draft from the format call — "cocoa" should appear
          # (the draft lists cocoa powder).
          assert last_user.content =~ "cocoa"

          # The linked-recipe block is present and labelled so the model
          # doesn't mistake it for the ground truth.
          assert last_user.content =~ "Linked recipe"

          # Return a merged recipe that retains the cocoa from the draft
          # AND gains the chia from the linked recipe. Name keeps
          # "Chocolate" — the model must NOT rename to the base recipe.
          {:ok,
           %{
             "choices" => [
               %{
                 "message" => %{
                   "content" =>
                     Jason.encode!(%{
                       "completeness" => "recipe_complete",
                       "missing_fields" => [],
                       "consult_link" => false,
                       "recipe" => %{
                         "name" => "Chocolate Yogurt Chia Pudding",
                         "description" => "Chocolate-y overnight chia pudding.",
                         "recipeYield" => "2 servings",
                         "recipeIngredient" => [
                           "1/4 cup chia seeds",
                           "1 cup plain yogurt",
                           "2 tbsp cocoa powder",
                           "2 tbsp honey",
                           "1 tsp vanilla extract",
                           "1/2 cup milk"
                         ],
                         "recipeInstructions" => [
                           %{
                             "text" => "Whisk chia, yogurt, cocoa, honey, vanilla, and milk."
                           },
                           %{"text" => "Refrigerate overnight."},
                           %{"text" => "Stir before serving."}
                         ],
                         "tags" => ["breakfast", "make-ahead"]
                       }
                     })
                 }
               }
             ]
           }}
        else
          # Format call: recipe_partial (caption has cocoa but no chia, no
          # method). consult_link is true so scrape_link runs.
          chat_response(
            "recipe_partial",
            ["recipeInstructions"],
            %{
              "name" => "Chocolate Yogurt Chia Pudding",
              "recipeIngredient" => ["1 cup plain yogurt", "2 tbsp cocoa powder", "2 tbsp honey"]
            },
            true
          )
        end
      end)

      assert {:ok, id} = Pipeline.create_job(%{url: url})

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000

      assert Map.get(job.stages, :scrape_link) == :done
      assert Map.get(job.stages, :transcribe) == :skipped
      assert Map.get(job.stages, :llm_merge) == :done
      assert Map.get(job.stages, :mealie_import) == :done

      # The merged recipe keeps the caption's "Chocolate" name — the linked
      # base recipe is NEVER allowed to rename the dish.
      assert job.recipe.name == "Chocolate Yogurt Chia Pudding"
      refute job.recipe.name == "Yogurt Chia Pudding"

      # Both cocoa (from the draft) and chia seeds (from the linked recipe)
      # end up in the merged ingredient list. The Mealie parser overwrites
      # `Ingredient.note` with its own `p["note"]` (nil in the default stub),
      # so we assert on the preserved `:raw` field — that's what the model
      # originally emitted and what `Ingredient.from_raw/1` stored verbatim.
      ingredient_raws =
        job.recipe.ingredients |> Enum.map(& &1.raw) |> Enum.join(" | ")

      assert ingredient_raws =~ "cocoa"
      assert ingredient_raws =~ "chia"
    end
  end

  # ── Scenario 7: provenance stamping — orgURL + linked note ──

  describe "provenance stamping at import" do
    test "orgURL = reel URL on every imported recipe; linked page URL in notes when scrape_link resolved" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")
      test_pid = self()
      reel_url = "https://instagram.com/reel/sc7"
      linked_url = "https://example.com/provenance-page"

      stub_caption_with_link("Check it: #{linked_url}")

      # Single adapter override: success on test-scrape-url + capture on PATCH.
      # (Stacking two overrides would clobber the first — combine them.)
      prev = current_mealie_adapter()

      Application.put_env(
        :insta_mealie,
        :mealie_http_adapter,
        fn m, p, body ->
          cond do
            m == :post and p == "/api/recipes/test-scrape-url" ->
              {:ok, scraped_recipe_body()}

            m in [:put, :patch] and
              String.starts_with?(p, "/api/recipes/") and
                not String.ends_with?(p, "/image") ->
              send(test_pid, {:patched_recipe, p, body})
              {:ok, %{"slug" => Path.basename(p)}}

            true ->
              prev.(m, p, body)
          end
        end
      )

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
          v -> Application.put_env(:insta_mealie, :mealie_http_adapter, v)
        end
      end)

      Mox.stub(LLMMock, :chat, fn _model, messages ->
        if merge_call?(messages) do
          chat_response("recipe_complete", [], %{"name" => "Merged Provenance"}, false)
        else
          chat_response("recipe_complete", [], %{"name" => "Caption Provenance"}, true)
        end
      end)

      assert {:ok, id} = Pipeline.create_job(%{url: reel_url})

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = _job}, 5000

      # The PATCH that built the recipe in Mealie must include:
      # * orgURL = the reel URL
      # * notes = a list containing a %{"title" => "Recipe link", "text" => linked_url}
      assert_receive {:patched_recipe, _path, patch_body}
      assert patch_body["orgURL"] == reel_url

      notes = patch_body["notes"]
      assert is_list(notes)
      assert Enum.any?(notes, &(&1["text"] == linked_url and &1["title"] == "Recipe link"))
    end
  end

  # ── Extra: image fallback when reel has no thumbnail ──

  describe "image fallback to linked recipe" do
    test "scraped recipe's image wins when the reel had none" do
      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")
      reel_url = "https://instagram.com/reel/sc_img"
      link = "https://example.com/has-image"

      stub_caption_with_link("Caption with link #{link}")

      override_mealie(current_mealie_adapter(), fn _body ->
        {:ok, scraped_recipe_body(%{"image" => "https://example.com/linked-image.jpg"})}
      end)

      Mox.stub(LLMMock, :chat, fn _model, messages ->
        if merge_call?(messages) do
          chat_response(
            "recipe_complete",
            [],
            %{"name" => "After Image Fallback"},
            false
          )
        else
          chat_response("recipe_complete", [], %{"name" => "Caption"}, true)
        end
      end)

      assert {:ok, id} = Pipeline.create_job(%{url: reel_url})

      assert_receive {:job_updated, %Job{id: ^id, state: :succeeded} = job}, 5000

      # The fetch stub omits :thumbnail, so the local recipe.image stays nil
      # before stamp_provenance runs, and `maybe_fallback_image/2` fills it
      # from the scraped recipe. (The image is uploaded to Mealie via a
      # separate POST /api/recipes/{slug}/image call, not the PATCH body —
      # so we assert on the in-memory recipe here.)
      assert job.recipe.image == "https://example.com/linked-image.jpg"
    end
  end

  # ── Scenario 5 (subsumed by 3): :unresolved distinct from :skipped/:failed ──
  # Covered by "scrape_link failure is survivable" above — explicit assertion
  # `job.state == :succeeded` and `Map.get(job.stages, :scrape_link) == :unresolved`
  # are already there, alongside the absence of `error_stage`.
end

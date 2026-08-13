defmodule InstaMealie.LinkExtractorTest do
  use ExUnit.Case, async: true

  alias InstaMealie.LinkExtractor

  describe "extract/2 — real caption from issue #50" do
    test "returns the foolproofliving recipe URL from the caption" do
      caption =
        "Chocolate Yogurt Chia Pudding 🍫 Based on the base recipe from " <>
          "https://foolproofliving.com/yogurt-chia-pudding/ " <>
          "— I added cocoa powder to make it chocolatey! #recipe #healthy"

      assert LinkExtractor.extract(caption, []) == [
               "https://foolproofliving.com/yogurt-chia-pudding/"
             ]
    end
  end

  describe "extract/2 — skip-list" do
    test "drops instagram.com and linktr.ee URLs from the caption" do
      caption =
        "Check out my reel https://www.instagram.com/reel/abc123/ " <>
          "and my links https://linktr.ee/somechef"

      assert LinkExtractor.extract(caption, []) == []
    end

    test "returns bit.ly shortener URLs as candidates (not skipped)" do
      caption = "Recipe: https://bit.ly/3xyzABC — try it!"

      assert LinkExtractor.extract(caption, []) == ["https://bit.ly/3xyzABC"]
    end

    test "skips amazon /shop/ storefront but keeps /dp/ product links" do
      caption =
        "Shop https://www.amazon.com/shop/somechef or buy " <>
          "https://www.amazon.com/dp/B012345"

      assert LinkExtractor.extract(caption, []) == ["https://www.amazon.com/dp/B012345"]
    end
  end

  describe "extract/2 — caption + comments" do
    test "collects URLs from caption and OP comments in caption-then-comment order" do
      caption = "Try this: https://a.com/recipe-one — link below!"
      comments = [%{author: "op", text: "Full recipe at https://b.com/recipe-two"}]

      assert LinkExtractor.extract(caption, comments) == [
               "https://a.com/recipe-one",
               "https://b.com/recipe-two"
             ]
    end

    test "accepts string-keyed comment maps with \"author\" and \"text\"" do
      caption = "Try this: https://a.com/recipe-one"
      comments = [%{"author" => "op", "text" => "https://b.com/recipe-two"}]

      assert LinkExtractor.extract(caption, comments) == [
               "https://a.com/recipe-one",
               "https://b.com/recipe-two"
             ]
    end

    test "deduplicates a URL that appears in both caption and a comment" do
      caption = "See https://example.com/recipe for details"
      comments = [%{author: "op", text: "Again, https://example.com/recipe"}]

      assert LinkExtractor.extract(caption, comments) == ["https://example.com/recipe"]
    end
  end

  describe "extract/2 — empty inputs" do
    test "returns [] for an empty caption and empty comments" do
      assert LinkExtractor.extract("", []) == []
    end

    test "returns [] for a caption with no URLs" do
      assert LinkExtractor.extract("Just a plain caption with no links here.", []) == []
    end
  end

  describe "extract/2 — trailing punctuation" do
    test "strips trailing period, comma, exclamation, and closing paren/bracket" do
      caption = "recipe here: https://example.com/recipe-page)."

      assert LinkExtractor.extract(caption, []) == ["https://example.com/recipe-page"]
    end
  end
end

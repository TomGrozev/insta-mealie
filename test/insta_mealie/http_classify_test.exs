defmodule InstaMealie.HttpClassifyTest do
  use ExUnit.Case, async: true

  alias InstaMealie.Error
  alias InstaMealie.HttpClassify

  describe "classify/1 — 2xx success" do
    for status <- [200, 201] do
      test "status #{status} returns :ok" do
        assert HttpClassify.classify(unquote(status)) == :ok
      end
    end
  end

  describe "classify/1 — auth failures" do
    test "401 maps to :auth with an unauthorized summary" do
      assert HttpClassify.classify(401) == Error.new(:auth, "unauthorized")
    end

    test "403 maps to :auth with a forbidden summary" do
      assert HttpClassify.classify(403) == Error.new(:auth, "forbidden")
    end
  end

  describe "classify/1 — known client errors" do
    test "422 maps to :validation" do
      assert HttpClassify.classify(422) == Error.new(:validation, "validation failed")
    end

    test "429 maps to :rate_limited" do
      assert HttpClassify.classify(429) == Error.new(:rate_limited, "rate limited")
    end
  end

  describe "classify/1 — not_found" do
    test "404 maps to :not_found (distinct from the generic :api_error class)" do
      # Mealie's create-or-reuse-recipe flow needs to distinguish "recipe
      # missing" from "transport / auth / 5xx" so a get-then-create dance
      # only fires for genuine 404s. See `InstaMealie.Mealie.maybe_create_recipe/2`.
      assert HttpClassify.classify(404) == Error.new(:not_found, "not found")
    end
  end

  describe "classify/1 — generic 4xx/5xx" do
    test "other 4xx (400) maps to :api_error with the status in the summary" do
      assert HttpClassify.classify(400) == Error.new(:api_error, "client error 400")
    end

    test "500 maps to :network with the status in the summary" do
      assert HttpClassify.classify(500) == Error.new(:network, "server error 500")
    end
  end
end

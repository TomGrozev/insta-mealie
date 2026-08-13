defmodule InstaMealie.Mealie.ScrapeUrlTest do
  @moduledoc """
  Unit tests for `InstaMealie.Mealie.scrape_url/1` — the Mealie wrapper around
  `POST /api/recipes/test-scrape-url`.

  The HTTP seam is the same env-stored function as the rest of the Mealie
  client (`Application.put_env(:insta_mealie, :mealie_http_adapter, ...)`),
  so each test installs its own adapter stub and restores the previous one
  on exit. Tests are `async: false` because the env key is process-global.
  """

  use ExUnit.Case, async: false

  alias InstaMealie.Error
  alias InstaMealie.Mealie
  alias InstaMealie.Recipe

  defp with_adapter(fun) do
    prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

    Application.put_env(:insta_mealie, :mealie_http_adapter, fun)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
        v -> Application.put_env(:insta_mealie, :mealie_http_adapter, v)
      end
    end)
  end

  describe "scrape_url/1 — success" do
    test "POSTs {url, useOpenAI: false} to /api/recipes/test-scrape-url and returns a Recipe" do
      test_pid = self()
      url = "https://foolproofliving.com/yogurt-chia-pudding/"

      with_adapter(fn method, path, body ->
        send(test_pid, {:adapter_called, method, path, body})

        {:ok,
         %{
           "name" => "Yogurt Chia Pudding",
           "description" => "A creamy overnight pudding.",
           "recipeYield" => "2 servings",
           "totalTime" => "PT5M",
           "prepTime" => "PT5M",
           "cookTime" => nil,
           "performTime" => "PT4H",
           "recipeIngredient" => [
             "1/4 cup chia seeds",
             "1 cup plain yogurt",
             "2 tbsp honey"
           ],
           "recipeInstructions" => [
             %{"text" => "Whisk chia seeds, yogurt, and honey together."},
             %{"text" => "Refrigerate overnight, then stir."}
           ],
           "image" => "https://example.com/pudding.jpg"
         }}
      end)

      assert {:ok, %Recipe{name: "Yogurt Chia Pudding"} = recipe} = Mealie.scrape_url(url)

      assert recipe.description == "A creamy overnight pudding."
      assert recipe.recipe_yield == "2 servings"
      assert recipe.total_time == "PT5M"
      assert recipe.prep_time == "PT5M"
      assert recipe.cook_time == nil
      assert recipe.perform_time == "PT4H"
      assert length(recipe.ingredients) == 3
      assert length(recipe.instructions) == 2

      assert_receive {:adapter_called, :post, "/api/recipes/test-scrape-url", body}
      assert body == %{"url" => url, "useOpenAI" => false}
    end
  end

  describe "scrape_url/1 — failure: 400 not scrapeable" do
    test "passes the HttpClassify-shaped error through unchanged" do
      # HttpClassify maps 400 to :api_error "client error 400"; the brief
      # leaves the exact class open. The contract here is "any Error{} from
      # request/3 is returned verbatim" — assert on the same shape.
      error = Error.new(:api_error, "client error 400")

      with_adapter(fn _method, _path, _body ->
        {:error, error}
      end)

      assert {:error, %Error{} = returned} =
               Mealie.scrape_url("https://example.com/not-a-recipe")

      assert returned == error
    end
  end

  describe "scrape_url/1 — failure: 408 timeout" do
    test "passes the timeout error through unchanged" do
      error = Error.new(:timeout, "recipe scrape timed out")

      with_adapter(fn _method, _path, _body ->
        {:error, error}
      end)

      assert {:error, %Error{class: :timeout} = returned} =
               Mealie.scrape_url("https://slow.example.com/recipe")

      assert returned == error
    end
  end
end

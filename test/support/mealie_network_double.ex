defmodule InstaMealie.Test.MealieNetworkDouble do
  @moduledoc "Test double: create_recipe fails with a network error so the UI shows a retryable mealie_import failure."
  @behaviour InstaMealie.Mealie

  @impl true
  def create_recipe(_recipe), do: {:error, :network, "mealie is down"}
  @impl true
  def update_recipe(slug, _recipe), do: {:ok, slug}
  @impl true
  def deep_link(slug) do
    base = Application.get_env(:insta_mealie, :mealie, [])[:base_url] || "http://localhost:9000"
    group = Application.get_env(:insta_mealie, :mealie, [])[:group_slug] || "home"
    "#{base}/g/#{group}/r/#{slug}?edit=true"
  end

  @impl true
  def search_foods(_term), do: {:ok, []}
  @impl true
  def search_units(_term), do: {:ok, []}
end

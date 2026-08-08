defmodule InstaMealie.Pipeline.Clients do
  @moduledoc "Dispatches pipeline stages to the configured client adapters."

  def fetch(job), do: client(:ytdlp).fetch(job.url, [])
  def format(caption, opts), do: client(:llm).format(caption, opts)
  def merge(caption, transcript, opts), do: client(:llm).merge(caption, transcript, opts)
  def transcribe(path, opts), do: client(:ytdlp).transcribe(path, opts)
  def create_recipe(recipe), do: client(:mealie).create_recipe(recipe)
  def update_recipe(slug, recipe), do: client(:mealie).update_recipe(slug, recipe)
  def deep_link(slug), do: client(:mealie).deep_link(slug)
  def search_foods(term), do: client(:mealie).search_foods(term)
  def search_units(term), do: client(:mealie).search_units(term)

  def import_recipe(recipe) do
    with {:ok, slug} <- create_recipe(recipe),
         {:ok, slug} <- update_recipe(slug, recipe) do
      {:ok, slug, deep_link(slug)}
    else
      {:error, class, reason} -> {:error, class, reason}
    end
  end

  defp client(key) do
    Application.get_env(:insta_mealie, :clients, [])[key] ||
      raise("Missing client adapter for #{key}; configure :clients in config.")
  end
end

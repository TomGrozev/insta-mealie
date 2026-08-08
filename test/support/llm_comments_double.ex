defmodule InstaMealie.Test.LlmCommentsDouble do
  @moduledoc "Test double: echoes the authors of the (OP-filtered) comments it received into the recipe name, so tests can prove filtering happened."
  @behaviour InstaMealie.Llm

  @impl true
  def format(_caption, opts) do
    authors =
      (opts[:comments] || [])
      |> Enum.map(fn c -> Map.get(c, :author) || Map.get(c, "author") end)
      |> Enum.join(",")

    {:ok,
     %{
       completeness: :recipe_complete,
       missing_fields: [],
       recipe: %{"name" => "authors:#{authors}"}
     }}
  end

  @impl true
  def merge(_caption, _transcript, _opts) do
    {:ok, %{completeness: :recipe_complete, missing_fields: [], recipe: %{}}}
  end
end

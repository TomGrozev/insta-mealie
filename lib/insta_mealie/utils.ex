defmodule InstaMealie.Utils do
  @moduledoc """
  Shared utilities used across the codebase.
  """

  @doc """
  Read a value from a map by a string key, falling back to the atom-key equivalent.

  When working with data that may come from JSON parsing (string keys) or Elixir
  structs (atom keys), this avoids the `map["key"] || map[:key]` repetition.
  """
  @spec map_get(map(), String.t()) :: term()
  def map_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end
end

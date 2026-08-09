defmodule InstaMealie.HttpClassify do
  @moduledoc "Normalise an HTTP status into :ok | %InstaMealie.Error{}."

  alias InstaMealie.Error

  def classify(status) when status in 200..299, do: :ok
  def classify(401), do: Error.new(:auth, "unauthorized")
  def classify(403), do: Error.new(:auth, "forbidden")
  def classify(422), do: Error.new(:validation, "validation failed")
  def classify(429), do: Error.new(:rate_limited, "rate limited")
  def classify(s) when s in 400..499, do: Error.new(:api_error, "client error #{s}")
  def classify(s) when s >= 500, do: Error.new(:network, "server error #{s}")
end

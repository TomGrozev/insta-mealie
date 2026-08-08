defmodule InstaMealie.HttpClassify do
  @moduledoc "Normalise an HTTP status into {:ok, :success} | {:error, class, reason}."
  def classify(status) when status in 200..299, do: :ok
  def classify(401), do: {:error, :auth, "unauthorized"}
  def classify(403), do: {:error, :auth, "forbidden"}
  def classify(422), do: {:error, :validation, "validation failed"}
  def classify(429), do: {:error, :rate_limited, "rate limited"}
  def classify(s) when s in 400..499, do: {:error, :api_error, "client error #{s}"}
  def classify(s) when s >= 500, do: {:error, :network, "server error #{s}"}
end

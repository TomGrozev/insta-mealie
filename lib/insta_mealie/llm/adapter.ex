defmodule InstaMealie.LLM.Adapter do
  @moduledoc """
  Behaviour for the LLM HTTP client.

  The implementation module is resolved at call time via `Application.get_env`.
  """

  alias InstaMealie.Error
  alias InstaMealie.LLM.Envelope

  @doc "Send a chat completion request and return a parsed envelope."
  @callback chat(String.t(), [map()]) :: {:ok, Envelope.t()} | {:error, Error.t()}
end

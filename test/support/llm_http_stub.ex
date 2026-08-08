defmodule InstaMealie.Test.LlmHttpStub do
  @moduledoc """
  Test double for the LLM HTTP adapter.

  Returns a canned OpenAI-shaped response read from
  `Application.get_env(:insta_mealie, :llm_canned_response)`.
  """

  def request(_request_body, _opts \\ []) do
    case Application.get_env(:insta_mealie, :llm_canned_response) do
      nil -> {:error, :api_error, "no canned response configured"}
      response -> {:ok, response}
    end
  end
end

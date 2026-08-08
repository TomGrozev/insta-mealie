defmodule InstaMealie.Test.LlmErrorStub do
  @moduledoc "Test double: always returns an auth error."

  def request(_request_body, _opts) do
    {:error, :auth, "unauthorized"}
  end
end

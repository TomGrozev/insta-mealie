defmodule InstaMealie.ClientsAndErrorsTest do
  use ExUnit.Case, async: false

  alias InstaMealie.Pipeline
  alias InstaMealie.Pipeline.Clients

  setup do
    Application.put_env(:insta_mealie, :clients,
      mealie: InstaMealie.MealieStub,
      llm: InstaMealie.LlmStub,
      ytdlp: InstaMealie.YtDlpStub
    )

    :ok
  end

  describe "error_retryable?/1" do
    test "validation is a dead row" do
      refute Pipeline.error_retryable?(:validation)
    end

    test "network and auth are retryable" do
      assert Pipeline.error_retryable?(:network)
      assert Pipeline.error_retryable?(:auth)
    end

    test "other transient classes are retryable; unknowns are not" do
      assert Pipeline.error_retryable?(:timeout)
      assert Pipeline.error_retryable?(:rate_limited)
      assert Pipeline.error_retryable?(:ip_banned)
      assert Pipeline.error_retryable?(:cookie_expired)
      assert Pipeline.error_retryable?(:api_error)
      refute Pipeline.error_retryable?(:something_else)
    end
  end

  describe "candidate search dispatch" do
    test "search_foods / search_units route to the mealie client" do
      assert {:ok, []} = Clients.search_foods("x")
      assert {:ok, []} = Clients.search_units("y")
    end
  end
end

defmodule InstaMealie.ClientsAndErrorsTest do
  use InstaMealie.TestCase

  alias InstaMealie.Pipeline

  describe "error_retryable?/1" do
    test "validation is a dead row" do
      refute Pipeline.error_retryable?(:validation)
    end

    test "network is retryable, auth is a dead row" do
      assert Pipeline.error_retryable?(:network)
      refute Pipeline.error_retryable?(:auth)
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
      # The TestCase setup already stubs mealie to return empty data for /api/foods and /api/units
      assert {:ok, []} = InstaMealie.Mealie.search_foods("x")
      assert {:ok, []} = InstaMealie.Mealie.search_units("y")
    end
  end
end

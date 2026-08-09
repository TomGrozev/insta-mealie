defmodule InstaMealie.ClientsAndErrorsTest do
  use InstaMealie.TestCase

  alias InstaMealie.Error
  alias InstaMealie.Pipeline

  describe "error_retryable?/1" do
    test "validation is a dead row" do
      refute Pipeline.error_retryable?(%Error{class: :validation})
    end

    test "network is retryable, auth is a dead row" do
      assert Pipeline.error_retryable?(%Error{class: :network})
      refute Pipeline.error_retryable?(%Error{class: :auth})
    end

    test "other transient classes are retryable; unknowns are not" do
      assert Pipeline.error_retryable?(%Error{class: :timeout})
      assert Pipeline.error_retryable?(%Error{class: :rate_limited})
      assert Pipeline.error_retryable?(%Error{class: :ip_banned})
      assert Pipeline.error_retryable?(%Error{class: :cookie_expired})
      assert Pipeline.error_retryable?(%Error{class: :api_error})
      refute Pipeline.error_retryable?(%Error{class: :something_else})
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

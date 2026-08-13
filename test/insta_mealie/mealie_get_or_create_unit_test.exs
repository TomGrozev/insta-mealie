defmodule InstaMealie.Mealie.GetOrCreateUnitTest do
  @moduledoc """
  Unit tests for `InstaMealie.Mealie.get_or_create_unit/1` — the Mealie
  client operation that resolves one unit name to an existing Mealie unit
  or creates one and returns its id.

  The HTTP seam is the same env-stored function as the rest of the Mealie
  client (`Application.put_env(:insta_mealie, :mealie_http_adapter, ...)`),
  so each test installs its own adapter stub and restores the previous one
  on exit. Tests are `async: false` because the env key is process-global.
  """

  use ExUnit.Case, async: false

  alias InstaMealie.Error
  alias InstaMealie.Mealie

  defp with_adapter(fun) do
    prev = Application.get_env(:insta_mealie, :mealie_http_adapter)

    Application.put_env(:insta_mealie, :mealie_http_adapter, fun)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
        v -> Application.put_env(:insta_mealie, :mealie_http_adapter, v)
      end
    end)
  end

  # The search path is constructed inside `search_collection/2` from the
  # configured `per_page` (25 for any non-recipe type, including "units")
  # and the URL-encoded term. Helpers below pre-bind the encoded path to
  # a variable so the `^` pin can reference it from `assert_receive` /
  # `case` patterns.
  defp search_path(term), do: "/api/units?perPage=25&search=#{URI.encode_www_form(term)}"

  describe "get_or_create_unit/1 — existing match" do
    test "returns the existing unit id and does not POST to /api/units" do
      test_pid = self()
      name = "tablespoon"
      expected_path = search_path(name)

      with_adapter(fn method, path, body ->
        send(test_pid, {:adapter_called, method, path, body})

        case {method, path} do
          {_, ^expected_path} ->
            {:ok,
             %{
               "items" => [
                 %{"id" => "unit-tbsp", "name" => "tablespoon"},
                 %{"id" => "unit-tsp", "name" => "teaspoon"}
               ]
             }}
        end
      end)

      assert {:ok, "unit-tbsp"} = Mealie.get_or_create_unit(name)

      # The search ran; no POST to /api/units followed because the exact
      # match was reused. `refute_receive` runs against the 100ms default
      # timeout — the call is synchronous, so any POST would have landed
      # before it.
      assert_receive {:adapter_called, :get, ^expected_path, nil}
      refute_receive {:adapter_called, :post, "/api/units", _}
    end
  end

  describe "get_or_create_unit/1 — no match" do
    test "POSTs %{name: name} to /api/units and returns the new unit id" do
      test_pid = self()
      name = "pinch"
      expected_path = search_path(name)

      with_adapter(fn method, path, body ->
        send(test_pid, {:adapter_called, method, path, body})

        case {method, path} do
          {_, ^expected_path} ->
            {:ok, %{"items" => []}}

          {:post, "/api/units"} ->
            {:ok, %{"id" => "unit-pinch", "name" => "pinch"}}
        end
      end)

      assert {:ok, "unit-pinch"} = Mealie.get_or_create_unit(name)

      assert_receive {:adapter_called, :get, ^expected_path, nil}
      assert_receive {:adapter_called, :post, "/api/units", %{"name" => ^name}}
    end
  end

  describe "get_or_create_unit/1 — search error" do
    test "propagates the search error and does not POST to /api/units" do
      test_pid = self()
      name = "Anything"
      expected_path = search_path(name)
      error = Error.new(:api_error, "client error 500")

      with_adapter(fn method, path, body ->
        send(test_pid, {:adapter_called, method, path, body})
        {:error, error}
      end)

      assert {:error, %Error{} = returned} = Mealie.get_or_create_unit(name)
      assert returned == error

      # Only the search GET hit the adapter; the create POST must not be
      # attempted when the lookup failed — silent absence would mask the
      # real failure and risk creating a duplicate record.
      assert_receive {:adapter_called, :get, ^expected_path, nil}
      refute_receive {:adapter_called, :post, "/api/units", _}
    end
  end

  describe "get_or_create_unit/1 — create error" do
    test "propagates the POST /api/units error verbatim" do
      name = "furlong"
      expected_path = search_path(name)
      error = Error.new(:validation, "validation failed")

      with_adapter(fn method, path, _body ->
        case {method, path} do
          {_, ^expected_path} ->
            {:ok, %{"items" => []}}

          {:post, "/api/units"} ->
            {:error, error}
        end
      end)

      assert {:error, %Error{} = returned} = Mealie.get_or_create_unit(name)
      assert returned == error
    end
  end
end

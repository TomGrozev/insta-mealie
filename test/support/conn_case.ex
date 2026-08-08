defmodule InstaMealieWeb.ConnCase do
  @moduledoc """
  Test case for tests that require a connection (HTTP requests).
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint InstaMealieWeb.Endpoint
      use InstaMealieWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest
      import InstaMealieWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end

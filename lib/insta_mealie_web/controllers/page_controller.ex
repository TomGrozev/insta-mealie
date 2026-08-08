defmodule InstaMealieWeb.PageController do
  use InstaMealieWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

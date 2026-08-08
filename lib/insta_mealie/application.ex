defmodule InstaMealie.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      InstaMealieWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:insta_mealie, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: InstaMealie.PubSub},
      InstaMealie.Pipeline,
      InstaMealieWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: InstaMealie.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    InstaMealieWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

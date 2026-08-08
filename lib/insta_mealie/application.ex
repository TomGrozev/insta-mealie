defmodule InstaMealie.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    maybe_run_preflight()

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

  defp maybe_run_preflight do
    if Application.get_env(:insta_mealie, :skip_preflight, false) do
      :ok
    else
      case Application.get_env(:insta_mealie, InstaMealie.YtDlp, InstaMealie.YtDlp.Cli) do
        InstaMealie.YtDlp.Cli -> InstaMealie.YtDlp.Cli.preflight!()
        _ -> :ok
      end
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    InstaMealieWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :insta_mealie,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :insta_mealie, InstaMealieWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: InstaMealieWeb.ErrorHTML, json: InstaMealieWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: InstaMealie.PubSub,
  live_view: [signing_salt: "SQ3qtWkt"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  insta_mealie: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  insta_mealie: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Per-module behaviour defaults (overridable per environment / test).
config :insta_mealie, InstaMealie.YtDlp, InstaMealie.YtDlp.Cli

# Pipeline housekeeping defaults (overridable per environment / test).
config :insta_mealie, InstaMealie.Pipeline,
  ttl_ms: 24 * 60 * 60 * 1000,
  cap: 500,
  sweep_interval_ms: 5 * 60 * 1000

# Per-stage pipeline deadlines in milliseconds. Each stage's `handle_info`
# schedules a `{:stage_timeout, stage}` message at this delay; if the stage
# is still `:running` when the message arrives, the job is failed with
# error_class `:timeout`. Set a stage to 0 to disable its timeout.
config :insta_mealie, :insta_mealie,
  stage_timeouts: %{
    fetch: 120_000,
    llm_format: 180_000,
    scrape_link: 60_000,
    transcribe: 300_000,
    llm_merge: 180_000,
    mealie_import: 60_000
  }

if Mix.env() != :prod do
  config :git_hooks,
    auto_install: true,
    verbose: true,
    hooks: [
      pre_commit: [
        tasks: [
          {:cmd, "mix format --check-formatted"},
          {:cmd, "mix compile --warnings-as-errors"},
          {:cmd, "mix credo"},
          {:cmd, "mix doctor --summary"}
        ]
      ],
      pre_push: [
        verbose: false,
        tasks: [
          {:cmd, "mix format --check-formatted"},
          {:cmd, "mix compile --warnings-as-errors"},
          {:cmd, "mix credo"},
          {:cmd, "mix doctor --summary"},
          {:cmd, "mix sobelow"},
          {:cmd, "mix test"}
        ]
      ]
    ]
end

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

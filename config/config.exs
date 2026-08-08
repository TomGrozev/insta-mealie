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

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :insta_mealie, InstaMealie.Mailer, adapter: Swoosh.Adapters.Local

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

# For T1 the three external clients are stubbed so the app runs with zero network.
# Later tickets swap these for Req-backed real adapters.
config :insta_mealie, :clients,
  mealie: InstaMealie.MealieStub,
  llm: InstaMealie.LlmStub,
  ytdlp: InstaMealie.YtDlpStub

# Pipeline housekeeping defaults (overridable per environment / test).
config :insta_mealie, InstaMealie.Pipeline,
  ttl_ms: 24 * 60 * 60 * 1000,
  cap: 500,
  sweep_interval_ms: 5 * 60 * 1000

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

import Config

# Adapter mocks — set via Mox expectations in individual tests.
# When no expectation is set, the real Http module is used as fallback.
config :insta_mealie, InstaMealie.Mealie, InstaMealie.Mealie.Http
config :insta_mealie, InstaMealie.LLM, InstaMealie.LLM.Http
config :insta_mealie, InstaMealie.Whisper, InstaMealie.Whisper.Http

config :insta_mealie, :skip_preflight, true

# LLM and Whisper test config (stubs set via Application env adapters in tests)
config :insta_mealie, :openai,
  base_url: "http://localhost:9999",
  api_key: "test-key",
  model: "test-model",
  merge_model: "test-merge-model"

config :insta_mealie, :whisper,
  base_url: "http://localhost:9999",
  api_key: "test-key",
  model: "whisper-1"

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :insta_mealie, InstaMealieWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "UIk2H5D4lCatS1SFUHoW80Rvrfnf93RRT43qsE4pJKQOBwjDhxhSJHux8AqM0wxn",
  server: false

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

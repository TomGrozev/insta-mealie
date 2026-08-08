defmodule InstaMealie.Repo do
  use Ecto.Repo,
    otp_app: :insta_mealie,
    adapter: Ecto.Adapters.Postgres
end

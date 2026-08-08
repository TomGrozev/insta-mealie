defmodule InstaMealie.Test.YtDlpFetchIpBannedDouble do
  @moduledoc "Test double: fetch fails with ip_banned so the UI shows paste-only."
  @behaviour InstaMealie.YtDlp

  @impl true
  def fetch(_url, _opts), do: {:error, :ip_banned, "ip address banned by instagram"}
  @impl true
  def transcribe(_video_path, _opts), do: {:ok, "transcribed audio"}
end

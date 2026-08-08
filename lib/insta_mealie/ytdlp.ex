defmodule InstaMealie.YtDlp do
  @moduledoc """
  Behaviour for fetching reels via yt-dlp.

  Classified fetch failures: extraction | rate_limited | cookie_expired |
  network | ip_banned.

  `fetch/2` returns `{:ok, result}` where `result` is a map with the keys:
  - `:author` — the reel owner's username (the "OP")
  - `:caption` — the reel caption text
  - `:comments` — a list of `%{author: String.t(), text: String.t()}` (may be empty)
  - `:video_path` — local path to the downloaded video for transcription
  """
  @callback fetch(url :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, atom(), term()}

  @spec fetch(String.t(), keyword()) :: {:ok, map()} | {:error, atom(), term()}
  def fetch(url, opts \\ []), do: impl().fetch(url, opts)
  defp impl, do: Application.get_env(:insta_mealie, __MODULE__, InstaMealie.YtDlp.Cli)
end

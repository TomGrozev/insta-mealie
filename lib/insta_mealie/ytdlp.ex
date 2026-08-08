defmodule InstaMealie.YtDlp do
  @moduledoc """
  Behaviour for fetching reels via yt-dlp and transcribing audio with Whisper.

  Classified fetch failures: extraction | rate_limited | cookie_expired |
  network | ip_banned.
  """
  @callback fetch(url :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, atom(), term()}
  @callback transcribe(video_path :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, atom(), term()}
end

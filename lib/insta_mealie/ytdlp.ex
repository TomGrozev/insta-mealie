defmodule InstaMealie.YtDlp do
  @moduledoc """
  Behaviour for fetching reels via yt-dlp and transcribing audio with Whisper.

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
  @callback transcribe(video_path :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, atom(), term()}
end

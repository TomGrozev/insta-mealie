defmodule InstaMealie.YtDlp do
  @moduledoc """
  Behaviour for the two-stage yt-dlp fetch contract.

  **Stage 1 — `fetch_metadata/2`** fetches author, caption, comments, and
  thumbnail without downloading media. It runs yt-dlp with `--skip-download`
  and writes the info-json, comments, and thumbnail into a per-fetch temp
  directory. The result includes an internal `:fetch_dir` key for the later
  audio request.

  **Stage 2 — `fetch_audio/2`** downloads audio from the same reel into the
  per-fetch directory (or a new one) and returns `%{audio_path: path}`.

  Both callbacks return `{:ok, map()} | {:error, atom(), term()}`.

  Classified fetch failures: extraction | rate_limited | cookie_expired |
  network | ip_banned.
  """
  @callback fetch_metadata(url :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, atom(), term()}

  @callback fetch_audio(url :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, atom(), term()}

  @spec fetch_metadata(String.t(), keyword()) :: {:ok, map()} | {:error, atom(), term()}
  def fetch_metadata(url, opts \\ []), do: impl().fetch_metadata(url, opts)

  @spec fetch_audio(String.t(), keyword()) :: {:ok, map()} | {:error, atom(), term()}
  def fetch_audio(url, opts \\ []), do: impl().fetch_audio(url, opts)

  defp impl, do: Application.get_env(:insta_mealie, __MODULE__, InstaMealie.YtDlp.Cli)
end

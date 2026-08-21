defmodule InstaMealie.Whisper do
  @moduledoc """
  Transcribe audio via an external Whisper-compatible API.

  The caller supplies a local MP3 file produced by yt-dlp. The default HTTP
  adapter (`InstaMealie.Whisper.Http`) uploads it directly using multipart
  form encoding — no local conversion is performed and the file is never
  deleted by this module; yt-dlp owns the artifact lifecycle.

  Whisper accepts audio natively in mp3, mp4, mpeg, mpga, m4a, wav, and
  webm formats.
  """

  require Logger
  alias InstaMealie.Error

  @doc """
  Transcribe the audio file at `audio_path` and return the transcript text.

  Supports the `:prompt` and `:language` options. Returns `{:error, %Error{}}`
  when the adapter reports a failure.
  """
  @spec transcribe(String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def transcribe(audio_path, opts \\ []) when is_binary(audio_path) do
    adapter = Application.get_env(:insta_mealie, InstaMealie.Whisper, InstaMealie.Whisper.Http)
    cfg = Application.get_env(:insta_mealie, :whisper, [])

    model = cfg[:model] || "whisper-1"
    prompt = Keyword.get(opts, :prompt, "")
    language = Keyword.get(opts, :language, "")

    start = System.monotonic_time(:millisecond)
    result = adapter.transcribe(model, audio_path, prompt, language)
    elapsed = System.monotonic_time(:millisecond) - start

    case result do
      {:ok, text} ->
        Logger.info(
          "[whisper] transcribe completed in #{elapsed}ms (model=#{model}, chars=#{String.length(text)})"
        )

        {:ok, text}

      {:error, %Error{class: class, summary: reason} = error} ->
        Logger.error(
          "[whisper] transcribe failed in #{elapsed}ms (model=#{model}, class=#{class}, reason=#{reason})"
        )

        {:error, error}
    end
  end
end

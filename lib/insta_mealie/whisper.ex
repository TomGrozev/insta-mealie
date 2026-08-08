defmodule InstaMealie.Whisper do
  @moduledoc """
  Transcribe audio via an external Whisper-compatible API.

  The caller supplies a local MP3 file produced by yt-dlp. The default HTTP
  adapter (`default_whisper_req/4`) uploads it directly using multipart form
  encoding — no local conversion is performed and the file is never deleted
  by this module; yt-dlp owns the artifact lifecycle.

  Whisper accepts audio natively in mp3, mp4, mpeg, mpga, m4a, wav, and
  webm formats.
  """

  require Logger

  @spec transcribe(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom(), term()}
  def transcribe(audio_path, _opts \\ []) when is_binary(audio_path) do
    adapter = Application.get_env(:insta_mealie, :whisper_http_adapter, &default_whisper_req/4)
    cfg = Application.get_env(:insta_mealie, :whisper, [])

    base_url = cfg[:base_url] || ""
    model = cfg[:model] || "whisper-1"
    api_key = cfg[:api_key] || ""

    start = System.monotonic_time(:millisecond)
    result = adapter.(base_url, api_key, model, audio_path)
    elapsed = System.monotonic_time(:millisecond) - start

    case result do
      {:ok, text} ->
        Logger.info(
          "[whisper] transcribe completed in #{elapsed}ms (model=#{model}, chars=#{String.length(text)})"
        )

        {:ok, text}

      {:error, class, reason} ->
        Logger.error(
          "[whisper] transcribe failed in #{elapsed}ms (model=#{model}, class=#{class}, reason=#{reason})"
        )

        {:error, class, reason}
    end
  end

  defp default_whisper_req(base_url, _, _, _) when base_url in ["", nil] do
    {:error, :configuration, "WHISPER_BASE_URL not configured"}
  end

  defp default_whisper_req(base_url, api_key, model, audio_path) do
    uri =
      base_url
      |> URI.parse()
      |> URI.append_path("/v1/audio/transcriptions")

    try do
      resp =
        Req.post!(uri,
          auth: {:bearer, api_key},
          form_multipart: [
            file:
              {File.stream!(audio_path, [], 64 * 1024),
               filename: Path.basename(audio_path), content_type: "audio/mpeg"},
            model: model
          ]
        )

      Logger.debug("[whisper] POST #{uri} status=#{resp.status}")

      case InstaMealie.HttpClassify.classify(resp.status) do
        :ok -> {:ok, String.trim(resp.body["text"] || "")}
        {:error, class, reason} -> {:error, class, reason}
      end
    rescue
      e -> {:error, :network, Exception.message(e)}
    end
  end
end

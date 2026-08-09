defmodule InstaMealie.Whisper.Http do
  @moduledoc """
  Default HTTP-based implementation of `InstaMealie.Whisper.Adapter`.

  Uploads an audio file to a Whisper-compatible endpoint using multipart form
  encoding and returns the transcribed text. No local conversion is performed
  and the file is never deleted by this module; yt-dlp owns the artifact
  lifecycle.

  Whisper accepts audio natively in mp3, mp4, mpeg, mpga, m4a, wav, and webm
  formats.

  `prompt` and `language` are accepted per the behaviour contract but not yet
  forwarded to the API in this default implementation; tests inject their
  own stub module via `Application.get_env/3`.
  """

  @behaviour InstaMealie.Whisper.Adapter

  require Logger

  alias InstaMealie.Error

  @impl true
  def transcribe(model, file_path, _prompt, _language) do
    cfg = Application.get_env(:insta_mealie, :whisper, [])

    base_url = cfg[:base_url] || ""
    api_key = cfg[:api_key] || ""
    model = model || cfg[:model] || "whisper-1"

    do_transcribe(base_url, api_key, model, file_path)
  end

  defp do_transcribe(base_url, _api_key, _model, _file_path) when base_url in ["", nil] do
    {:error, Error.new(:validation, "WHISPER_BASE_URL not configured")}
  end

  defp do_transcribe(base_url, api_key, model, file_path) do
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
              {File.stream!(file_path, [], 64 * 1024),
               filename: Path.basename(file_path), content_type: "audio/mpeg"},
            model: model
          ]
        )

      Logger.debug("[whisper] POST #{uri} status=#{resp.status}")

      case InstaMealie.HttpClassify.classify(resp.status) do
        :ok -> {:ok, String.trim(resp.body["text"] || "")}
        %Error{} = error -> {:error, error}
      end
    rescue
      e -> {:error, Error.new(:network, Exception.message(e))}
    end
  end
end

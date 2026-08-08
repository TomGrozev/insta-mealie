defmodule InstaMealie.Whisper do
  @moduledoc "Single Whisper module for transcribing reel audio via an external Whisper API."

  @spec transcribe(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom(), term()}
  def transcribe(video_path, _opts \\ []) when is_binary(video_path) do
    cfg = Application.get_env(:insta_mealie, :whisper, [])
    base_url = cfg[:base_url] || ""

    adapter = Application.get_env(:insta_mealie, :whisper_http_adapter, &default_whisper_req/1)

    adapter.(%{
      base_url: base_url,
      api_key: cfg[:api_key] || "",
      model: cfg[:model] || "whisper-1",
      video_path: video_path
    })
  end

  defp default_whisper_req(%{base_url: base_url}) when base_url in ["", nil] do
    {:error, :configuration, "WHISPER_BASE_URL not configured"}
  end

  defp default_whisper_req(%{base_url: base_url, api_key: api_key, model: model, video_path: video_path}) do
    url = base_url <> "/v1/audio/transcriptions"

    try do
      resp =
        Req.post!(url,
          headers: [{"authorization", "Bearer #{api_key}"}],
          form: [file: {:file, video_path}, model: model]
        )

      case InstaMealie.HttpClassify.classify(resp.status) do
        :ok -> {:ok, String.trim(resp.body["text"] || "")}
        {:error, class, reason} -> {:error, class, reason}
      end
    rescue
      e -> {:error, :network, Exception.message(e)}
    end
  end
end

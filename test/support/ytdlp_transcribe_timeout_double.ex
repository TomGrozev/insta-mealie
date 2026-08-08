defmodule InstaMealie.Test.YtDlpTranscribeTimeoutDouble do
  @moduledoc "Test double: fetch ok, transcribe times out (pair with a partial-format LLM double to reach the transcribe stage)."
  @behaviour InstaMealie.YtDlp

  @impl true
  def fetch(_url, _opts) do
    {:ok,
     %{
       author: "chef_og",
       caption: "Some caption",
       comments: [],
       video_path: "/tmp/insta_mealie/x.mp4"
     }}
  end

  @impl true
  def transcribe(_video_path, _opts), do: {:error, :timeout, "whisper timed out"}
end

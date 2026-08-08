defmodule InstaMealie.Test.YtDlpCommentsDouble do
  @moduledoc "Test double: fetch returns a mix of OP and non-OP comments."
  @behaviour InstaMealie.YtDlp

  @impl true
  def fetch(_url, _opts) do
    {:ok,
     %{
       author: "op_user",
       caption: "Some caption text",
       comments: [
         %{author: "op_user", text: "OP says hi"},
         %{author: "stranger", text: "not the owner"},
         %{author: "op_user", text: "OP says bye"}
       ],
       video_path: "/tmp/insta_mealie/x.mp4"
     }}
  end

  @impl true
  def transcribe(_video_path, _opts) do
    {:ok, "transcribed audio"}
  end
end

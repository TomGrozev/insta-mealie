defmodule InstaMealie.YtDlpStub do
  @moduledoc "In-memory yt-dlp stub. Returns a canned caption; never downloads or transcribes."
  @behaviour InstaMealie.YtDlp

  @impl true
  def fetch(_url, _opts) do
    caption = """
    Homemade Granola
    Makes about 8 servings.
    Ingredients:
    - 3 cups rolled oats
    - 1 cup raw almonds
    - 1/2 cup maple syrup
    - 1/3 cup coconut oil
    - 1 tsp salt
    Steps:
    Mix everything, spread on a tray, bake at 160C for 40 minutes stirring halfway.
    """

    {:ok,
     %{
       caption: caption,
       video_path:
         "/tmp/insta_mealie/" <>
           (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)) <> ".mp4"
     }}
  end

  @impl true
  def transcribe(_video_path, _opts) do
    {:ok, "Transcribed audio: mix oats almonds syrup oil salt, bake at 160C for 40 minutes."}
  end
end

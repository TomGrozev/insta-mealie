defmodule InstaMealie.Whisper.Adapter do
  @moduledoc """
  Behaviour for the Whisper transcription client.

  The implementation module is resolved at call time via `Application.get_env`.
  """

  alias InstaMealie.Error

  @doc "Transcribe an audio file and return the text."
  @callback transcribe(String.t(), String.t(), String.t(), String.t()) ::
              {:ok, String.t()} | {:error, Error.t()}
end

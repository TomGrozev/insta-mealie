defmodule InstaMealie.Test.YtDlpFetchNetworkDouble do
  @moduledoc "Test double: fetch fails with a network error so the pipeline surfaces a retryable failure at the fetch stage."
  @behaviour InstaMealie.YtDlp

  @impl true
  def fetch(_url, _opts), do: {:error, :network, "could not reach instagram"}
  @impl true
  def transcribe(_video_path, _opts), do: {:ok, "transcribed audio"}
end

defmodule InstaMealie.LLM.Http do
  @moduledoc """
  Default HTTP-based implementation of `InstaMealie.LLM.Adapter`.

  Sends a chat-completion request to an OpenAI-compatible endpoint and returns
  the raw response body. The caller (`InstaMealie.LLM`) is responsible for
  parsing the body into an `InstaMealie.LLM.Envelope`.

  Tests inject their own stub module via `Application.get_env/3`.
  """

  @behaviour InstaMealie.LLM.Adapter

  require Logger

  alias InstaMealie.Error

  @impl true
  def chat(model, messages) do
    cfg = Application.get_env(:insta_mealie, :openai, [])

    uri =
      (cfg[:base_url] || "https://api.openai.com/v1")
      |> URI.parse()
      |> URI.append_path("/chat/completions")

    request_body = %{
      response_format: %{type: "json_object"},
      temperature: 0,
      model: model,
      messages: messages
    }

    req =
      Req.new(
        url: uri,
        method: :post,
        headers: [
          {"authorization", "Bearer #{cfg[:api_key] || ""}"},
          {"content-type", "application/json"}
        ],
        json: request_body,
        receive_timeout: 180_000
      )

    try do
      resp = Req.request!(req)
      Logger.debug("[llm] POST #{uri} status=#{resp.status}")

      case InstaMealie.HttpClassify.classify(resp.status) do
        :ok -> {:ok, resp.body}
        %Error{} = error -> {:error, error}
      end
    rescue
      e -> {:error, Error.new(:network, Exception.message(e))}
    end
  end
end

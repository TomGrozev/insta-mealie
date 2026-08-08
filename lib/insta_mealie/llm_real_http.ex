defmodule InstaMealie.Llm.Real.Http do
  @moduledoc """
  Req-backed HTTP adapter for OpenAI-compatible chat-completions.

  Called by `InstaMealie.Llm.Real` via `http_adapter().request/2`.
  Returns `{:ok, openai_response_map()} | {:error, atom(), term()}`.
  """

  @doc """
  POST the request body to the chat-completions endpoint.

  Options:
    - `:timeout` — receive timeout in milliseconds (default 30_000).
  """
  def request(request_body, opts \\ []) do
    cfg = Application.get_env(:insta_mealie, :openai, [])
    base_url = cfg[:base_url] || "https://api.openai.com/v1"
    api_key = cfg[:api_key] || ""

    url = base_url <> "/chat/completions"
    timeout = Keyword.get(opts, :timeout, 30_000)

    req =
      Req.new(
        method: :post,
        url: url,
        headers: [
          {"authorization", "Bearer #{api_key}"},
          {"content-type", "application/json"}
        ],
        json: request_body,
        receive_timeout: timeout
      )

    try do
      resp = Req.request!(req)

      case resp.status do
        status when status in 200..299 ->
          {:ok, resp.body}

        401 ->
          {:error, :auth, "unauthorized"}

        403 ->
          {:error, :auth, "forbidden"}

        429 ->
          {:error, :rate_limited, "rate limited"}

        status when status in 400..499 ->
          {:error, :api_error, "client error #{status}"}

        status when status >= 500 ->
          {:error, :network, "server error #{status}"}
      end
    rescue
      e -> {:error, :network, Exception.message(e)}
    end
  end
end

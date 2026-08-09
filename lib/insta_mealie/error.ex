defmodule InstaMealie.Error do
  @moduledoc """
  Structured error type used by all external clients and the pipeline.
  """

  defstruct [:class, :summary, :stage, :operation, :detail]

  @type t :: %__MODULE__{
          class: atom(),
          summary: String.t(),
          stage: atom() | nil,
          operation: atom() | nil,
          detail: term() | nil
        }

  @doc """
  Create a new error. `summary` is stringified.

  Options:
  - `:stage` — pipeline stage where the error occurred
  - `:operation` — specific operation within the stage
  - `:detail` — optional extra detail (response body, etc.)
  """
  def new(class, summary, opts \\ []) do
    %__MODULE__{
      class: class,
      summary: to_string(summary),
      stage: Keyword.get(opts, :stage),
      operation: Keyword.get(opts, :operation),
      detail: Keyword.get(opts, :detail)
    }
  end

  @doc """
  Whether this error class is retryable.
  """
  def retryable?(%__MODULE__{class: class}) do
    class in [:network, :timeout, :rate_limited, :ip_banned, :cookie_expired, :api_error]
  end
end

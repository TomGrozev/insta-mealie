defmodule InstaMealie.Error do
  @moduledoc """
  Structured error type used by all external clients and the pipeline.
  Replaces ad-hoc `{:error, class, reason}` tuples.
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
  Convert the legacy `{:error, class, reason}` tuple form into the structured
  error type wrapped in an `{:error, error}` tuple. Pass-through for any other
  value so callers can pipe a result through without first pattern-matching.

  Used during the expand phase of the migration in #45. Will be removed once
  every client returns the structured type directly.
  """
  def from_tuple({:error, class, reason}) when is_atom(class) do
    {:error, InstaMealie.Error.new(class, reason)}
  end

  def from_tuple(other), do: other

  @doc """
  Whether this error class is retryable.
  """
  def retryable?(%__MODULE__{class: class}) do
    class in [:network, :timeout, :rate_limited, :ip_banned, :cookie_expired, :api_error]
  end
end

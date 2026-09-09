defmodule ReqCircuitBreaker.OpenError do
  @moduledoc """
  Error that occurs when the circuit breaker is open.
  """

  defexception [:name]

  @type t :: %__MODULE__{name: ReqCircuitBreaker.name()}

  @impl Exception
  def message(%__MODULE__{name: name}) do
    "circuit breaker #{inspect(name)} is open"
  end
end

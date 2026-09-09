defmodule ReqCircuitBreaker.NotInstalledError do
  @moduledoc """
  Error that occurs when a circuit breaker is used before it was installed.

  Circuit breakers must be installed once at startup.
  """

  defexception [:name]

  @type t :: %__MODULE__{name: ReqCircuitBreaker.name()}

  @impl Exception
  def message(%__MODULE__{name: name}) do
    """
    circuit breaker #{inspect(name)} is not installed

    Install it when your application starts:

        def start(_type, _args) do
          :ok = ReqCircuitBreaker.install(#{inspect(name)})
          Supervisor.start_link(children, opts)
        end
    """
  end
end

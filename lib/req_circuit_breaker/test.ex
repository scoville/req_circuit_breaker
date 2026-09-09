defmodule ReqCircuitBreaker.Test do
  @moduledoc """
  Test helpers for code that uses a circuit breaker.

  A circuit breaker is state outside the test process. Tests that install a
  breaker under the same name cannot run concurrently.

      defmodule MyApp.PaymentsTest do
        use ExUnit.Case, async: true

        import ReqCircuitBreaker.Test

        setup :circuit_breaker

        test "the circuit opens after a failure", %{circuit_breaker: name} do
          :ok = ReqCircuitBreaker.install(name, failures: 0)
          # ...
        end
      end
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Names a circuit breaker after the running test and removes it afterwards.

  Returns `%{circuit_breaker: name}`. The breaker is not installed. It must be
  installed in the tests that need it.

  Intended as a `setup` callback:

      setup :circuit_breaker

  The breaker is named after the running test. Therefore, the function cannot
  be used with `setup_all`.
  """
  @spec circuit_breaker(map) :: %{circuit_breaker: ReqCircuitBreaker.name()}
  def circuit_breaker(%{test: name}) do
    on_exit(fn -> ReqCircuitBreaker.remove(name) end)
    %{circuit_breaker: name}
  end

  def circuit_breaker(context) when is_map(context) do
    raise ArgumentError, """
    circuit_breaker/1 needs the context of a running test

    The breaker is named after the running test and can only be used with
    `setup`, not with `setup_all`.

    Got the context:

        #{inspect(Map.keys(context))}
    """
  end
end

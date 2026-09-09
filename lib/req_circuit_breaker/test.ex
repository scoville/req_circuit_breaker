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

  Intended as an `ExUnit` setup callback:

      setup :circuit_breaker
  """
  @spec circuit_breaker(map) :: %{circuit_breaker: ReqCircuitBreaker.name()}
  def circuit_breaker(%{test: name}) do
    on_exit(fn -> ReqCircuitBreaker.remove(name) end)
    %{circuit_breaker: name}
  end
end

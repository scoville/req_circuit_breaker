defmodule ReqCircuitBreakerTest do
  use ExUnit.Case, async: true

  alias ReqCircuitBreaker.NotInstalledError
  alias ReqCircuitBreaker.OpenError

  doctest ReqCircuitBreaker, import: true

  setup_all do
    on_exit(fn ->
      Enum.each(
        [
          MyApp.CircuitBreaker.Example,
          MyApp.CircuitBreaker.Installed
        ],
        &ReqCircuitBreaker.remove/1
      )
    end)
  end

  setup context do
    name = context.test
    on_exit(fn -> ReqCircuitBreaker.remove(name) end)
    %{name: name}
  end

  describe "install/2" do
    test "installs a circuit breaker", %{name: name} do
      refute ReqCircuitBreaker.installed?(name)
      assert ReqCircuitBreaker.install(name) == :ok
      assert ReqCircuitBreaker.installed?(name)
    end

    test "resets a circuit breaker that already exists", %{name: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)
      :ok = ReqCircuitBreaker.record_failure(name)
      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)

      assert ReqCircuitBreaker.install(name, failures: 0) == :ok
      assert ReqCircuitBreaker.ask(name) == :ok
    end

    test "raises on an unknown option", %{name: name} do
      assert_raise ArgumentError, fn ->
        ReqCircuitBreaker.install(name, failure: 1)
      end
    end

    test "raises a named error on an invalid option value", %{name: name} do
      error =
        assert_raise ArgumentError, fn ->
          ReqCircuitBreaker.install(name, within: 1.5)
        end

      message = Exception.message(error)
      assert message =~ ":within"
      assert message =~ "non-negative integer"
      assert message =~ "1.5"
      refute message =~ "fuse"
    end
  end

  describe "ask/2" do
    test "returns :ok while the circuit is closed", %{name: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 1)

      assert ReqCircuitBreaker.ask(name) == :ok
      :ok = ReqCircuitBreaker.record_failure(name)
      assert ReqCircuitBreaker.ask(name) == :ok
    end

    test "returns an error once the circuit opens", %{name: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 1)
      :ok = ReqCircuitBreaker.record_failure(name)
      :ok = ReqCircuitBreaker.record_failure(name)

      assert {:error, %OpenError{name: ^name} = error} =
               ReqCircuitBreaker.ask(name)

      assert Exception.message(error) =~ "is open"
    end

    test "returns error for a breaker that is not installed", %{name: name} do
      assert {:error, %NotInstalledError{name: ^name} = error} =
               ReqCircuitBreaker.ask(name)

      assert Exception.message(error) =~ "is not installed"
    end

    test "answers in :async_dirty mode too", %{name: name} do
      assert ReqCircuitBreaker.ask(name, mode: :async_dirty) ==
               {:error, %NotInstalledError{name: name}}

      :ok = ReqCircuitBreaker.install(name, failures: 0)
      assert ReqCircuitBreaker.ask(name, mode: :async_dirty) == :ok

      :ok = ReqCircuitBreaker.record_failure(name)

      assert {:error, %OpenError{}} =
               ReqCircuitBreaker.ask(name, mode: :async_dirty)
    end

    test "raises a named error on an invalid mode", %{name: name} do
      :ok = ReqCircuitBreaker.install(name)

      error =
        assert_raise ArgumentError, fn ->
          ReqCircuitBreaker.ask(name, mode: :nonsense)
        end

      message = Exception.message(error)
      assert message =~ ":mode"
      assert message =~ ":async_dirty"
      refute message =~ "fuse"
    end
  end

  describe "record_failure/1" do
    test "records a failure", %{name: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)

      assert ReqCircuitBreaker.record_failure(name) == :ok
      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)
    end

    test "keeps the circuit closed up to the threshold", %{name: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 2)

      assert ReqCircuitBreaker.record_failure(name) == :ok
      assert ReqCircuitBreaker.record_failure(name) == :ok
      assert ReqCircuitBreaker.ask(name) == :ok

      assert ReqCircuitBreaker.record_failure(name) == :ok
      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)
    end

    test "returns error for a breaker that is not installed", %{name: name} do
      assert ReqCircuitBreaker.record_failure(name) ==
               {:error, %NotInstalledError{name: name}}
    end

    test "emits an event when a failure is recorded", %{name: name} do
      attach_handler(name, [:req_circuit_breaker, :failure])
      :ok = ReqCircuitBreaker.install(name)
      :ok = ReqCircuitBreaker.record_failure(name)

      assert_receive {:event, [:req_circuit_breaker, :failure], %{name: ^name}}
    end

    test "emits an event when a call is refused", %{name: name} do
      attach_handler(name, [:req_circuit_breaker, :refused])
      :ok = ReqCircuitBreaker.install(name, failures: 0)
      :ok = ReqCircuitBreaker.record_failure(name)
      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)

      assert_receive {:event, [:req_circuit_breaker, :refused], %{name: ^name}}
    end

    test "emits no event for a breaker that is not installed", %{name: name} do
      attach_handler(name, [:req_circuit_breaker, :failure])

      assert {:error, %NotInstalledError{}} =
               ReqCircuitBreaker.record_failure(name)

      refute_receive {:event, [:req_circuit_breaker, :failure], _metadata}
    end
  end

  describe "reset/1" do
    test "closes an open circuit", %{name: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)
      :ok = ReqCircuitBreaker.record_failure(name)
      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)

      assert ReqCircuitBreaker.reset(name) == :ok
      assert ReqCircuitBreaker.ask(name) == :ok
    end

    test "returns error for a breaker that is not installed", %{name: name} do
      assert ReqCircuitBreaker.reset(name) ==
               {:error, %NotInstalledError{name: name}}
    end
  end

  describe "remove/1" do
    test "removes a circuit breaker", %{name: name} do
      :ok = ReqCircuitBreaker.install(name)
      assert ReqCircuitBreaker.remove(name) == :ok
      refute ReqCircuitBreaker.installed?(name)
    end

    test "returns :ok for a breaker that is not installed", %{name: name} do
      assert ReqCircuitBreaker.remove(name) == :ok
    end
  end

  defp attach_handler(name, event) do
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, name},
      event,
      fn event, _measurements, metadata, _config ->
        send(test_pid, {:event, event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, name}) end)
  end
end

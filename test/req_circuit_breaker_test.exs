defmodule ReqCircuitBreakerTest do
  use ExUnit.Case, async: true

  import ReqCircuitBreaker.Test

  alias ReqCircuitBreaker.NotInstalledError
  alias ReqCircuitBreaker.OpenError

  doctest ReqCircuitBreaker, import: true

  setup_all do
    on_exit(fn ->
      Enum.each(
        [
          MyApp.CircuitBreaker.Example,
          MyApp.CircuitBreaker.Installed,
          MyApp.CircuitBreaker.Run
        ],
        &ReqCircuitBreaker.remove/1
      )
    end)
  end

  setup :circuit_breaker

  describe "install/2" do
    test "installs a circuit breaker", %{circuit_breaker: name} do
      refute ReqCircuitBreaker.installed?(name)
      assert ReqCircuitBreaker.install(name) == :ok
      assert ReqCircuitBreaker.installed?(name)
    end

    test "resets a circuit breaker that already exists", %{
      circuit_breaker: name
    } do
      :ok = ReqCircuitBreaker.install(name, failures: 0)
      :ok = ReqCircuitBreaker.record_failure(name)
      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)

      assert ReqCircuitBreaker.install(name, failures: 0) == :ok
      assert ReqCircuitBreaker.ask(name) == :ok
    end

    test "raises on an unknown option", %{circuit_breaker: name} do
      assert_raise ArgumentError, fn ->
        ReqCircuitBreaker.install(name, failure: 1)
      end
    end

    test "raises a named error on an invalid option value", %{
      circuit_breaker: name
    } do
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
    test "returns :ok while the circuit is closed", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 1)

      assert ReqCircuitBreaker.ask(name) == :ok
      :ok = ReqCircuitBreaker.record_failure(name)
      assert ReqCircuitBreaker.ask(name) == :ok
    end

    test "returns an error once the circuit opens", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 1)
      :ok = ReqCircuitBreaker.record_failure(name)
      :ok = ReqCircuitBreaker.record_failure(name)

      assert {:error, %OpenError{name: ^name} = error} =
               ReqCircuitBreaker.ask(name)

      assert Exception.message(error) =~ "is open"
    end

    test "returns error for a breaker that is not installed", %{
      circuit_breaker: name
    } do
      assert {:error, %NotInstalledError{name: ^name} = error} =
               ReqCircuitBreaker.ask(name)

      assert Exception.message(error) =~ "is not installed"
    end

    test "answers in :async_dirty mode too", %{circuit_breaker: name} do
      assert ReqCircuitBreaker.ask(name, mode: :async_dirty) ==
               {:error, %NotInstalledError{name: name}}

      :ok = ReqCircuitBreaker.install(name, failures: 0)
      assert ReqCircuitBreaker.ask(name, mode: :async_dirty) == :ok

      :ok = ReqCircuitBreaker.record_failure(name)

      assert {:error, %OpenError{}} =
               ReqCircuitBreaker.ask(name, mode: :async_dirty)
    end

    test "raises a named error on an invalid mode", %{circuit_breaker: name} do
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
    test "records a failure", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)

      assert ReqCircuitBreaker.record_failure(name) == :ok
      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)
    end

    test "keeps the circuit closed up to the threshold", %{
      circuit_breaker: name
    } do
      :ok = ReqCircuitBreaker.install(name, failures: 2)

      assert ReqCircuitBreaker.record_failure(name) == :ok
      assert ReqCircuitBreaker.record_failure(name) == :ok
      assert ReqCircuitBreaker.ask(name) == :ok

      assert ReqCircuitBreaker.record_failure(name) == :ok
      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)
    end

    test "returns error for a breaker that is not installed", %{
      circuit_breaker: name
    } do
      assert ReqCircuitBreaker.record_failure(name) ==
               {:error, %NotInstalledError{name: name}}
    end

    test "emits an event when a failure is recorded", %{circuit_breaker: name} do
      attach_handler(name, [:req_circuit_breaker, :failure])
      :ok = ReqCircuitBreaker.install(name)
      :ok = ReqCircuitBreaker.record_failure(name)

      assert_receive {:event, [:req_circuit_breaker, :failure],
                      %{system_time: system_time}, %{name: ^name}}

      assert is_integer(system_time)
    end

    test "emits an event when a call is refused", %{circuit_breaker: name} do
      attach_handler(name, [:req_circuit_breaker, :refused])
      :ok = ReqCircuitBreaker.install(name, failures: 0)
      :ok = ReqCircuitBreaker.record_failure(name)
      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)

      assert_receive {:event, [:req_circuit_breaker, :refused],
                      %{system_time: _}, %{name: ^name}}
    end

    test "emits no event for a breaker that is not installed", %{
      circuit_breaker: name
    } do
      attach_handler(name, [:req_circuit_breaker, :failure])

      assert {:error, %NotInstalledError{}} =
               ReqCircuitBreaker.record_failure(name)

      refute_receive {:event, [:req_circuit_breaker, :failure], _, _}
    end
  end

  describe "reset/1" do
    test "closes an open circuit", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)
      :ok = ReqCircuitBreaker.record_failure(name)
      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)

      assert ReqCircuitBreaker.reset(name) == :ok
      assert ReqCircuitBreaker.ask(name) == :ok
    end

    test "returns error for a breaker that is not installed", %{
      circuit_breaker: name
    } do
      assert ReqCircuitBreaker.reset(name) ==
               {:error, %NotInstalledError{name: name}}
    end
  end

  describe "remove/1" do
    test "removes a circuit breaker", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name)
      assert ReqCircuitBreaker.remove(name) == :ok
      refute ReqCircuitBreaker.installed?(name)
    end

    test "returns :ok for a breaker that is not installed", %{
      circuit_breaker: name
    } do
      assert ReqCircuitBreaker.remove(name) == :ok
    end
  end

  describe "run/3" do
    test "returns the result of the function", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name)
      assert ReqCircuitBreaker.run(name, fn -> {:ok, 1} end) == {:ok, 1}
    end

    test "records an error tuple as a failure", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)

      assert ReqCircuitBreaker.run(name, fn -> {:error, :nope} end) ==
               {:error, :nope}

      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)
    end

    test "takes a custom failure predicate", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)

      assert ReqCircuitBreaker.run(name, fn -> :bad end,
               failure?: &(&1 == :bad)
             ) ==
               :bad

      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)
    end

    test "does not call the function while open", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)
      :ok = ReqCircuitBreaker.record_failure(name)

      assert ReqCircuitBreaker.run(name, fn -> raise "called" end) ==
               {:error, %OpenError{name: name}}
    end

    test "raises for a breaker that is not installed", %{circuit_breaker: name} do
      assert_raise NotInstalledError, fn ->
        ReqCircuitBreaker.run(name, fn -> :ok end)
      end
    end

    test "records a raise as a failure and re-raises it", %{
      circuit_breaker: name
    } do
      :ok = ReqCircuitBreaker.install(name, failures: 0)

      assert_raise RuntimeError, "service exploded", fn ->
        ReqCircuitBreaker.run(name, fn -> raise "service exploded" end)
      end

      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)
    end

    test "keeps the stacktrace of a raise", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name)

      stacktrace =
        try do
          ReqCircuitBreaker.run(name, fn -> raise "service exploded" end)
        rescue
          RuntimeError -> __STACKTRACE__
        end

      assert {__MODULE__, _, _, _} = hd(stacktrace)
    end

    test "records a throw as a failure and re-throws it", %{
      circuit_breaker: name
    } do
      :ok = ReqCircuitBreaker.install(name, failures: 0)

      assert catch_throw(ReqCircuitBreaker.run(name, fn -> throw(:nope) end)) ==
               :nope

      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)
    end

    test "records an exit as a failure and re-exits", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)

      assert catch_exit(ReqCircuitBreaker.run(name, fn -> exit(:timeout) end)) ==
               :timeout

      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)
    end

    test "takes a custom exception predicate", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)

      exception_failure? = fn
        :exit, :timeout -> true
        _kind, _reason -> false
      end

      assert_raise RuntimeError, fn ->
        ReqCircuitBreaker.run(name, fn -> raise "a bug in my own code" end,
          exception_failure?: exception_failure?
        )
      end

      assert ReqCircuitBreaker.ask(name) == :ok

      catch_exit(
        ReqCircuitBreaker.run(name, fn -> exit(:timeout) end,
          exception_failure?: exception_failure?
        )
      )

      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)
    end
  end

  describe "failure?/1" do
    test "counts a server error" do
      assert ReqCircuitBreaker.failure?(%Req.Response{status: 500})
      assert ReqCircuitBreaker.failure?(%Req.Response{status: 503})
    end

    test "does not count a successful or client error response" do
      refute ReqCircuitBreaker.failure?(%Req.Response{status: 200})
      refute ReqCircuitBreaker.failure?(%Req.Response{status: 404})
      refute ReqCircuitBreaker.failure?(%Req.Response{status: 429})
    end

    test "counts a transport or protocol error" do
      assert ReqCircuitBreaker.failure?(%Req.TransportError{reason: :timeout})

      assert ReqCircuitBreaker.failure?(%Req.HTTPError{
               protocol: :http2,
               reason: :x
             })
    end

    test "does not count an error the client caused" do
      refute ReqCircuitBreaker.failure?(%Req.TooManyRedirectsError{
               max_redirects: 1
             })

      refute ReqCircuitBreaker.failure?(%RuntimeError{message: "oops"})
    end
  end

  describe "attach/2" do
    test "makes the request while the circuit is closed", %{
      circuit_breaker: name
    } do
      :ok = ReqCircuitBreaker.install(name)
      Req.Test.stub(name, fn conn -> Req.Test.text(conn, "hello") end)

      assert {:ok, %Req.Response{status: 200, body: "hello"}} =
               Req.get(request(name))
    end

    test "halts the request while the circuit is open", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)
      :ok = ReqCircuitBreaker.record_failure(name)
      Req.Test.stub(name, fn _conn -> raise "requested" end)

      assert Req.get(request(name)) == {:error, %OpenError{name: name}}
    end

    test "raises for a breaker that is not installed", %{circuit_breaker: name} do
      Req.Test.stub(name, fn conn -> Req.Test.text(conn, "hello") end)

      assert_raise NotInstalledError, fn -> Req.get(request(name)) end
    end

    test "records a server error as a failure", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      assert {:ok, %Req.Response{status: 500}} = Req.get(request(name))
      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)
    end

    test "records a transport error as a failure", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)

      Req.Test.stub(name, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Req.TransportError{}} = Req.get(request(name))
      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)
    end

    test "does not record a rate limited response", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 429, "") end)

      assert {:ok, %Req.Response{status: 429}} = Req.get(request(name))
      assert ReqCircuitBreaker.ask(name) == :ok
    end

    test "records one failure per request, not per attempt", %{
      circuit_breaker: name
    } do
      :ok = ReqCircuitBreaker.install(name, failures: 1)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      request =
        Req.merge(request(name),
          retry: :transient,
          max_retries: 2,
          retry_delay: 0,
          retry_log_level: false
        )

      assert {:ok, %Req.Response{status: 500}} = Req.request(request)
      assert ReqCircuitBreaker.ask(name) == :ok

      assert {:ok, %Req.Response{status: 500}} = Req.request(request)
      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)
    end

    test "takes a custom failure predicate", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      request =
        [plug: {Req.Test, name}, url: "http://circuit.example", retry: false]
        |> Req.new()
        |> ReqCircuitBreaker.attach(
          name: name,
          failure?: &match?(%Req.Response{status: 404}, &1)
        )

      assert {:ok, %Req.Response{status: 404}} = Req.get(request)
      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)
    end

    test "skips an attached breaker when the option is false", %{
      circuit_breaker: name
    } do
      :ok = ReqCircuitBreaker.install(name, failures: 0)
      :ok = ReqCircuitBreaker.record_failure(name)
      Req.Test.stub(name, fn conn -> Req.Test.text(conn, "hello") end)

      assert {:ok, %Req.Response{status: 200}} =
               Req.get(request(name), circuit_breaker: false)
    end

    test "requires a name" do
      assert_raise KeyError, fn ->
        ReqCircuitBreaker.attach(Req.new(), mode: :sync)
      end
    end

    test "raises on an unknown option", %{circuit_breaker: name} do
      assert_raise ArgumentError, fn ->
        ReqCircuitBreaker.attach(Req.new(), name: name, melt: true)
      end
    end

    test "raises on an unknown option given at request time", %{
      circuit_breaker: name
    } do
      :ok = ReqCircuitBreaker.install(name)
      Req.Test.stub(name, fn conn -> Req.Test.text(conn, "hello") end)

      assert_raise ArgumentError, fn ->
        Req.get(request(name), circuit_breaker: [name: name, melt: true])
      end
    end

    test "raises when a request-time list omits the name", %{
      circuit_breaker: name
    } do
      :ok = ReqCircuitBreaker.install(name)
      Req.Test.stub(name, fn conn -> Req.Test.text(conn, "hello") end)

      assert_raise ArgumentError, ~r/missing :name/, fn ->
        Req.get(request(name), circuit_breaker: [mode: :async_dirty])
      end
    end

    test "takes a complete list at request time", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      assert {:ok, %Req.Response{status: 500}} =
               Req.get(request(name),
                 circuit_breaker: [name: name, failure?: fn _ -> false end]
               )

      assert ReqCircuitBreaker.ask(name) == :ok
    end

    test "records a failure when http_errors raises", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      assert_raise RuntimeError, fn ->
        Req.get(request(name, http_errors: :raise))
      end

      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)
    end

    test "attaching twice replaces the first attachment", %{
      circuit_breaker: name
    } do
      :ok = ReqCircuitBreaker.install(name, failures: 1)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      request =
        name
        |> request()
        |> ReqCircuitBreaker.attach(name: name)

      assert {:ok, %Req.Response{status: 500}} = Req.get(request)
      assert ReqCircuitBreaker.ask(name) == :ok
    end

    test "the last attachment wins", %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      request =
        name
        |> request()
        |> ReqCircuitBreaker.attach(
          name: name,
          failure?: &match?(%Req.Response{status: 404}, &1)
        )

      assert {:ok, %Req.Response{status: 404}} = Req.get(request)
      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)
    end

    test "checks the circuit before the other request steps", %{
      circuit_breaker: name
    } do
      steps = Enum.map(request(name).request_steps, &elem(&1, 0))
      assert List.first(steps) == :circuit_breaker
    end

    test "records after retry and before http errors", %{circuit_breaker: name} do
      steps = Enum.map(request(name).response_steps, &elem(&1, 0))

      assert Enum.find_index(steps, &(&1 == :retry)) <
               Enum.find_index(steps, &(&1 == :circuit_breaker))

      assert Enum.find_index(steps, &(&1 == :circuit_breaker)) <
               Enum.find_index(steps, &(&1 == :handle_http_errors))
    end

    test "raises if Req registers no http error step", %{circuit_breaker: name} do
      request = %{Req.new() | response_steps: []}

      assert_raise RuntimeError, ~r/:handle_http_errors/, fn ->
        ReqCircuitBreaker.attach(request, name: name)
      end
    end

    test "records a redirect target failure against the breaker", %{
      circuit_breaker: name
    } do
      :ok = ReqCircuitBreaker.install(name, failures: 0)

      Req.Test.stub(name, fn conn ->
        case conn.host do
          "origin.example" ->
            conn
            |> Plug.Conn.put_resp_header(
              "location",
              "http://elsewhere.example/"
            )
            |> Plug.Conn.send_resp(302, "")

          "elsewhere.example" ->
            Plug.Conn.send_resp(conn, 500, "")
        end
      end)

      request =
        [
          plug: {Req.Test, name},
          url: "http://origin.example",
          retry: false,
          redirect_log_level: false
        ]
        |> Req.new()
        |> ReqCircuitBreaker.attach(name: name)

      assert {:ok, %Req.Response{status: 500}} = Req.get(request)
      assert {:error, %OpenError{}} = ReqCircuitBreaker.ask(name)
    end
  end

  defp request(name, opts \\ []) do
    ([plug: {Req.Test, name}, url: "http://circuit.example", retry: false] ++
       opts)
    |> Req.new()
    |> ReqCircuitBreaker.attach(name: name)
  end

  defp attach_handler(name, event) do
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, name},
      event,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, name}) end)
  end
end

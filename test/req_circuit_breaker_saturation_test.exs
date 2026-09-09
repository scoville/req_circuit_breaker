defmodule ReqCircuitBreakerSaturationTest do
  # async: false because it crashes the VM-wide :fuse server to prove that a
  # failure which cannot be recorded does not change what the caller sees.
  use ExUnit.Case, async: false

  import ReqCircuitBreaker.Test

  setup :circuit_breaker

  setup do
    # Restarting :fuse removes the race between the supervisor bringing
    # the crashed server back and the next test installing a breaker in it.
    on_exit(fn ->
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = Application.stop(:fuse)
        {:ok, _apps} = Application.ensure_all_started(:fuse)
      end)
    end)
  end

  describe "a failure that cannot be recorded" do
    setup %{circuit_breaker: name} do
      :ok = ReqCircuitBreaker.install(name, failures: 0)
    end

    test "leaves the result of run/3 unchanged", %{circuit_breaker: name} do
      assert ReqCircuitBreaker.run(
               name,
               fn ->
                 corrupt_fuse_server()
                 {:error, :nope}
               end,
               mode: :async_dirty
             ) == {:error, :nope}
    end

    test "leaves the exception of run/3 unchanged", %{circuit_breaker: name} do
      assert_raise RuntimeError, "the service, not the breaker", fn ->
        ReqCircuitBreaker.run(
          name,
          fn ->
            corrupt_fuse_server()
            raise "the service, not the breaker"
          end,
          mode: :async_dirty
        )
      end
    end

    test "leaves a Req response unchanged", %{circuit_breaker: name} do
      Req.Test.stub(name, fn conn ->
        corrupt_fuse_server()
        Plug.Conn.send_resp(conn, 500, "")
      end)

      request =
        [plug: {Req.Test, name}, url: "http://circuit.example", retry: false]
        |> Req.new()
        |> ReqCircuitBreaker.attach(name: name, mode: :async_dirty)

      assert {:ok, %Req.Response{status: 500}} = Req.request(request)
    end
  end

  defp corrupt_fuse_server do
    :sys.replace_state(:fuse_server, fn _state -> :corrupted end)
  end
end

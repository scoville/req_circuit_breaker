# ReqCircuitBreaker

ReqCircuitBreaker is a circuit breaker plugin for
[Req](https://hex.pm/packages/req) using [Fuse](https://hex.pm/packages/fuse).

## Installation

Add `req_circuit_breaker` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:req_circuit_breaker, "~> 0.1.0"}
  ]
end
```

## Requirements

ReqCircuitBreaker runs on the currently supported
[Elixir versions](https://elixir.hexdocs.pm/compatibility-and-deprecations.html)
and the compatible
[OTP versions](https://elixir.hexdocs.pm/compatibility-and-deprecations.html#between-elixir-and-erlang-otp).
OTP 24 is not supported because Finch doesn't either.

This package is tested against the Elixir and OTP versions that are still
supported upstream. Older versions down to the requirement in `mix.exs` may
still work, but they are not covered by CI and not officially supported.

## Circuit breakers

A circuit breaker counts failures. While the count stays under the threshold the
circuit is closed and requests go through. Once the threshold is crossed the
circuit opens, every call is refused without touching the network, and the
circuit closes again after the reset interval. For more information, refer to
https://martinfowler.com/bliki/CircuitBreaker.html.

## Installing a breaker

Every circuit breaker has to be installed when your application starts:

```elixir
defmodule MyApp.Application do
  use Application

  @impl Application
  def start(_type, _args) do
    :ok = ReqCircuitBreaker.install(MyApp.CircuitBreaker.Payments, failures: 5)
    Supervisor.start_link(children(), strategy: :one_for_one)
  end
end
```

A breaker is not installed on demand, because the first request would then be
unprotected, concurrent first requests would race, and a repeated install
would reset a circuit that had just opened. Using a breaker that is not
installed returns `{:error, %ReqCircuitBreaker.NotInstalledError{}}` from
`ReqCircuitBreaker.ask/2`, `ReqCircuitBreaker.record_failure/1` and
`ReqCircuitBreaker.reset/1`, and raises it from `ReqCircuitBreaker.run/3` and
from a request that has one attached.

See `t:ReqCircuitBreaker.install_opt/0` for available installation options.

## Usage

Attach the plugin to the request:

```elixir
"https://payments.example"
|> Req.new()
|> ReqCircuitBreaker.attach(name: MyApp.CircuitBreaker.Payments)
|> Req.get(url: "/charges")
```

A request refused by an open circuit returns
`{:error, %ReqCircuitBreaker.OpenError{}}` from `Req.request/2` and raises it
from `Req.request!/2`.

The circuit is checked before each attempt, including each retry and each
redirect hop, and one failure is recorded per request rather than per attempt,
so retries do not open the circuit faster than the threshold states.

See `t:ReqCircuitBreaker.attach_opt/0` for available attach options.

You can use `ReqCircuitBreaker` for arbitrary function calls without Req as
well by using `ReqCircuitBreaker.run/3`.

```elixir
ReqCircuitBreaker.run(MyApp.CircuitBreaker.Payments, fn ->
  MyApp.Payments.charge(order)
end)
```

### What counts as a failure

By default only 5xx responses and transport or protocol errors count as
failures.

A 429 does not count as failure by default. Whether it should depends on the
context of the application.

An error raised by the client, such as a `Req.TooManyRedirectsError` or a
decoding error, also does not count as failure.

You can change the defaults by passing the `:failure?` option. It receives a
`Req.Response` or an exception:

```elixir
[base_url: "https://payments.example"]
|> Req.new()
|> ReqCircuitBreaker.attach(
  name: MyApp.CircuitBreaker.Payments,
  failure?: fn
    %Req.Response{status: 429} -> true
    other -> ReqCircuitBreaker.failure?(other)
  end
)
```

The `:failure?` function of `ReqCircuitBreaker.run/3` takes the return value of
the given function.

### Tests

A circuit breaker is state outside the test process. Tests that install a
breaker under the same name cannot run concurrently. Install a breaker per
test and remove it afterwards:

```elixir
setup context do
  :ok = ReqCircuitBreaker.install(context.test, failures: 0)
  on_exit(fn -> ReqCircuitBreaker.remove(context.test) end)
  %{breaker: context.test}
end
```

You can use `ReqCircuitBreaker.reset/1` to close an open circuit and discards
the failures recorded so far.

## Performance

`:fuse` keeps one process for the whole VM, and it owns a public ETS table
holding each circuit's verdict. There are two read modes: `:async_dirty` reads
the ETS table directly; `:sync` sends a message to the process and waits for its
reply. The failure counts live in the process rather than the table, so
recording a failure always sends a message, whichever mode you use.

## Related Libraries

- [req_ssrf](https://hex.pm/packages/req_ssrf) - SSRF protection for Req
- [safe_redirect](https://hex.pm/packages/safe_redirect) - Redirect URI
  validation to avoid open redirect vulnerabilities

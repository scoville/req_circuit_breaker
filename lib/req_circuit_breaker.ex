defmodule ReqCircuitBreaker do
  @moduledoc """
  Stops sending requests to a service if too many error responses occur.

  A circuit breaker counts failures. While the count stays under the
  threshold the circuit is closed and requests go through. Once the threshold
  is crossed the circuit opens, every call is refused without touching the
  network, and the circuit closes again after the reset interval.

  The counting is done by [`:fuse`](https://hex.pm/packages/fuse), which keeps
  one counter per name in its own process.

  ## Installing

  A circuit breaker must be installed when the application starts. It is not
  installed on demand, because the first request would then be unprotected,
  concurrent first requests would race, and a repeated install would reset a
  circuit that had just opened.

      defmodule MyApp.Application do
        use Application

        @impl Application
        def start(_type, _args) do
          :ok = ReqCircuitBreaker.install(MyApp.CircuitBreaker.Payments)
          Supervisor.start_link(children(), strategy: :one_for_one)
        end
      end

  Trying to use a circuit breaker without installing it first results in
  `{:error, %ReqCircuitBreaker.NotInstalledError{}}`.

  ## Performance

  `:fuse` keeps one process for the whole VM, and it owns a public ETS table
  holding each circuit's verdict. There are two read modes: `:async_dirty` reads
  the ETS table directly; `:sync` sends a message to the process waits for its
  reply. The failure counts live in the process rather than the table, so
  recording a failure always sends a message, whichever mode you use.

  ## Telemetry

  - `[:req_circuit_breaker, :refused]` - a call was refused because the
    circuit was open. Metadata: `:name`.
  - `[:req_circuit_breaker, :failure]` - a failure was recorded. Metadata:
    `:name`.

  Neither event has any measurements.
  """

  alias ReqCircuitBreaker.NotInstalledError
  alias ReqCircuitBreaker.OpenError

  @default_failures 10
  @default_within 10_000
  @default_reset 30_000

  @typedoc """
  The name of a circuit breaker.

  Usually a module name.
  """
  @type name :: atom

  @typedoc """
  The mode determines how the state of a circuit breaker is read.

  - `:sync` - the read is serialized through the `:fuse` server. The default.
  - `:async_dirty` - the state is read in the calling process, without waiting
    for the server. Faster, but it may miss a failure or a reset that has just
    happened.

  Recording a failure is always serialized through the server.
  """
  @type mode :: :sync | :async_dirty

  @typedoc """
  Options for `install/2`.

  - `:failures` - how many failures are tolerated within `:within`
    milliseconds. The circuit opens on the next failure. Defaults to
    `#{@default_failures}`.
  - `:within` - the length of the counting window in milliseconds. Defaults to
    `#{@default_within}`.
  - `:reset` - how long an open circuit stays open, in milliseconds. Defaults
    to `#{@default_reset}`.
  """
  @type install_opts :: [
          failures: non_neg_integer,
          within: non_neg_integer,
          reset: non_neg_integer
        ]

  ## Installing

  @doc """
  Installs a circuit breaker.

  Call this once when your application starts. See the module documentation
  for the options.

  Installing a breaker that already exists resets it.

  ## Examples

      iex> install(MyApp.CircuitBreaker.Example, failures: 5, reset: 60_000)
      :ok
  """
  @spec install(name(), install_opts()) :: :ok
  def install(name, opts \\ []) do
    opts =
      Keyword.validate!(opts,
        failures: @default_failures,
        within: @default_within,
        reset: @default_reset
      )

    strategy =
      {:standard, fetch_count!(opts, :failures, "number of failures"),
       fetch_count!(opts, :within, "number of milliseconds")}

    reset = {:reset, fetch_count!(opts, :reset, "number of milliseconds")}

    # :fuse.install/2 raises on invalid options and returns :ok otherwise,
    # despite the three return values its spec declares.
    _ = :fuse.install(name, {strategy, reset})

    :ok
  end

  defp fetch_count!(opts, key, unit) do
    case Keyword.fetch!(opts, key) do
      value when is_integer(value) and value >= 0 ->
        value

      value ->
        raise ArgumentError, """
        invalid value for #{inspect(key)} in ReqCircuitBreaker.install/2

        Expected a non-negative integer #{unit}, got:

            #{inspect(value)}
        """
    end
  end

  @doc """
  Returns whether a circuit breaker is installed.

  ## Examples

      iex> install(MyApp.CircuitBreaker.Installed)
      iex> installed?(MyApp.CircuitBreaker.Installed)
      true

      iex> installed?(MyApp.CircuitBreaker.Absent)
      false
  """
  @spec installed?(name()) :: boolean
  def installed?(name) do
    :fuse.ask(name, :async_dirty) != {:error, :not_found}
  end

  @doc """
  Removes a circuit breaker.

  Intended for tests and for administrative use. Always returns `:ok`, even if
  the circuit breaker does not exist.
  """
  @spec remove(name()) :: :ok
  def remove(name) do
    _ = :fuse.remove(name)
    :ok
  end

  ## Using

  @doc """
  Returns `:ok` if the circuit is closed, `{:error, %OpenError{}}` if the
  circuit is open, and `{:error, %NotInstalledError{}}` if the circuit breaker
  is not installed.

  ## Options

  - `:mode` - see `t:mode/0`.
  """
  @spec ask(name(), mode: mode()) ::
          :ok | {:error, OpenError.t() | NotInstalledError.t()}
  def ask(name, opts \\ []) do
    opts = Keyword.validate!(opts, mode: :sync)

    case :fuse.ask(name, fetch_mode!(opts)) do
      :ok -> :ok
      :blown -> {:error, refused(name)}
      {:error, :not_found} -> {:error, %NotInstalledError{name: name}}
    end
  end

  defp fetch_mode!(opts) do
    case Keyword.fetch!(opts, :mode) do
      mode when mode in [:sync, :async_dirty] ->
        mode

      mode ->
        raise ArgumentError, """
        invalid value for :mode

        Expected :sync or :async_dirty, got:

            #{inspect(mode)}
        """
    end
  end

  defp refused(name) do
    :telemetry.execute([:req_circuit_breaker, :refused], %{}, %{name: name})

    %OpenError{name: name}
  end

  @doc """
  Records one failure against a circuit breaker.

  The circuit opens once the failures recorded within the counting window
  exceed the threshold given to `install/2`.

  Returns `{:error, %NotInstalledError{}}` if the breaker does not exist.
  """
  @spec record_failure(name()) :: :ok | {:error, NotInstalledError.t()}
  def record_failure(name) do
    case :fuse.ask(name, :async_dirty) do
      {:error, :not_found} ->
        {:error, %NotInstalledError{name: name}}

      _open_or_closed ->
        :telemetry.execute([:req_circuit_breaker, :failure], %{}, %{name: name})

        :fuse.melt(name)
    end
  end

  @doc """
  Closes an open circuit and discards the failures recorded so far.

  Intended for tests and for administrative use.
  """
  @spec reset(name()) :: :ok | {:error, NotInstalledError.t()}
  def reset(name) do
    case :fuse.reset(name) do
      :ok -> :ok
      {:error, :not_found} -> {:error, %NotInstalledError{name: name}}
    end
  end

  @doc """
  Calls a function through a circuit breaker and returns its result.

  If the circuit is open, the function is not called and the return value is
  `{:error, %OpenError{}}`. Raises `NotInstalledError` if the breaker does not
  exist.

  ## Options

  - `:failure?` - a 1-arity function deciding whether the result counts as a
    failure. The default function only counts `{:error, reason}` tuples as
    failures.
  - `:mode` - see `t:mode/0`.

  ## Examples

      iex> install(MyApp.CircuitBreaker.Run)
      iex> run(MyApp.CircuitBreaker.Run, fn -> {:ok, 1} end)
      {:ok, 1}
  """
  @spec run(name(), (-> result), failure?: (term -> boolean), mode: mode()) ::
          result | {:error, OpenError.t()}
        when result: term
  def run(name, fun, opts \\ []) when is_function(fun, 0) do
    {failure?, opts} = Keyword.pop(opts, :failure?, &error_tuple?/1)

    case ask(name, opts) do
      :ok ->
        result = fun.()
        _ = if failure?.(result), do: record_failure(name)
        result

      {:error, %NotInstalledError{} = error} ->
        raise error

      {:error, %OpenError{}} = error ->
        error
    end
  end

  defp error_tuple?({:error, _}), do: true
  defp error_tuple?(_result), do: false
end

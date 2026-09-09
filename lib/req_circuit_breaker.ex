defmodule ReqCircuitBreaker do
  @moduledoc """
  Stops sending requests to a service if too many error responses occur.

  A circuit breaker counts failures. While the count stays under the
  threshold the circuit is closed and requests go through. Once the threshold
  is crossed the circuit opens, every call is refused without touching the
  network, and the circuit closes again after the reset interval.

  The counting is done by [`:fuse`](https://hex.pm/packages/fuse), which keeps
  one counter per name in its own process.

  A circuit breaker must be installed when the application starts.
  `attach/2` adds one to a `Req` request, and `run/3` protects any other
  function.

  See [README](readme.html) for more details.

  ## Telemetry

  - `[:req_circuit_breaker, :refused]` - a call was refused because the
    circuit was open. Metadata: `:name`.
  - `[:req_circuit_breaker, :failure]` - a failure was recorded. Metadata:
    `:name`.

  Both events measure `:system_time`.
  """

  alias ReqCircuitBreaker.NotInstalledError
  alias ReqCircuitBreaker.OpenError

  @request_opts [:name, :failure?, :mode]

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
  @type install_opt ::
          {:failures, non_neg_integer}
          | {:within, non_neg_integer}
          | {:reset, non_neg_integer}

  @typedoc """
  Options for `run/3`.

  - `:failure?` - a 1-arity function deciding whether the result counts as a
    failure. The default function only counts `{:error, reason}` tuples as
    failures.
  - `:exception_failure?` - a 2-arity function taking the kind and the reason
    of a raise, a `throw` or an exit, and deciding whether it counts as a
    failure. The default function counts every exception.
  - `:mode` - see `t:mode/0`.
  """
  @type run_opt ::
          {:failure?, (term -> boolean)}
          | {:exception_failure?, (:error | :throw | :exit, term -> boolean)}
          | {:mode, mode()}

  @typedoc """
  Options for `attach/2`.

  - `:name` (required) - the name of the circuit breaker.
  - `:failure?` - a 1-arity function taking a `Req.Response` or an exception
    and returning `true` if it counts as a failure. Defaults to `failure?/1`.
  - `:mode` - see `t:mode/0`.
  """
  @type attach_opt ::
          {:name, name()}
          | {:failure?, (Req.Response.t() | Exception.t() -> boolean)}
          | {:mode, mode()}

  ## Installing

  @doc """
  Installs a circuit breaker.

  Call this once when your application starts.

  Installing a breaker that already exists resets it.

  ## Examples

      iex> install(MyApp.CircuitBreaker.Example, failures: 5, reset: 60_000)
      :ok
  """
  @spec install(name(), [install_opt()]) :: :ok
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
  @spec ask(name(), [{:mode, mode()}]) ::
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
    :telemetry.execute(
      [:req_circuit_breaker, :refused],
      %{system_time: System.system_time()},
      %{name: name}
    )

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
        :telemetry.execute(
          [:req_circuit_breaker, :failure],
          %{system_time: System.system_time()},
          %{name: name}
        )

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

  A raise, a `throw` or an exit in the function is recorded as a failure and
  then re-raised unchanged, with the original stacktrace. Pass
  `:exception_failure?` to specify which exceptions to count as failure.

  ## Examples

      iex> install(MyApp.CircuitBreaker.Run)
      iex> run(MyApp.CircuitBreaker.Run, fn -> {:ok, 1} end)
      {:ok, 1}
  """
  @spec run(name(), (-> result), [run_opt()]) ::
          result | {:error, OpenError.t()}
        when result: term
  def run(name, fun, opts \\ []) when is_function(fun, 0) do
    {failure?, opts} = Keyword.pop(opts, :failure?, &error_tuple?/1)

    {exception_failure?, opts} =
      Keyword.pop(opts, :exception_failure?, &exception_failure?/2)

    case ask(name, opts) do
      :ok ->
        try do
          result = fun.()
          _ = if failure?.(result), do: record_failure(name)
          result
        catch
          kind, reason ->
            _ = if exception_failure?.(kind, reason), do: record_failure(name)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:error, %NotInstalledError{} = error} ->
        raise error

      {:error, %OpenError{}} = error ->
        error
    end
  end

  defp error_tuple?({:error, _}), do: true
  defp error_tuple?(_result), do: false

  defp exception_failure?(_kind, _reason), do: true

  ## Req integration

  @doc """
  Adds a circuit breaker to a `Req` request.

  The circuit is checked before each attempt, including each retry and each
  redirect hop, and at most one failure is recorded per request.

  A request refused by an open circuit returns `{:error, %OpenError{}}` from
  `Req.request/2`, and raises it from `Req.request!/2`.

  A redirect is followed before the outcome is recorded, so a failure at the
  redirect target counts against the breaker named on the request, whatever
  host answered. Pass `redirect: false`, or a `:failure?` that inspects the
  response, if that is not what you want.

  The options are stored under the single `:circuit_breaker` request option.
  Pass `circuit_breaker: false` on a request to skip an attached breaker.

  Passing a list on a request replaces these options rather than merging into
  them, as `Req` does for every option, so a request-time list has to repeat
  `:name`.

  ## Examples

      [base_url: "https://payments.example"]
      |> Req.new()
      |> ReqCircuitBreaker.attach(name: MyApp.CircuitBreaker.Payments)
      |> Req.get(url: "/charges")
  """
  @spec attach(Req.Request.t(), [attach_opt()]) :: Req.Request.t()
  def attach(%Req.Request{} = request, opts) do
    opts = Keyword.validate!(opts, @request_opts)
    _name = Keyword.fetch!(opts, :name)

    request
    |> delete_steps()
    |> Req.Request.register_options([:circuit_breaker])
    |> Req.merge(circuit_breaker: opts)
    |> Req.Request.prepend_request_steps(circuit_breaker: &check_circuit/1)
    |> insert_response_step()
    |> Req.Request.append_error_steps(circuit_breaker: &record_result/1)
  end

  # Attaching twice would otherwise append a second copy of every step, and
  # record two failures per request.
  defp delete_steps(%Req.Request{} = request) do
    %{
      request
      | request_steps: Keyword.delete(request.request_steps, :circuit_breaker),
        response_steps:
          Keyword.delete(request.response_steps, :circuit_breaker),
        error_steps: Keyword.delete(request.error_steps, :circuit_breaker)
    }
  end

  # The response step runs after `retry`, so a retried request records one
  # failure rather than one per attempt, and before `handle_http_errors`, which
  # raises when `http_errors: :raise` and would skip the recording entirely.
  defp insert_response_step(%Req.Request{response_steps: steps} = request) do
    case Enum.split_while(steps, &(elem(&1, 0) != :handle_http_errors)) do
      {_steps, []} ->
        raise """
        Req registers no :handle_http_errors response step

        ReqCircuitBreaker inserts its own response step before the
        :handle_http_errors step. The Req version in use appears to have renamed
        or removed it, and this version of ReqCircuitBreaker is not compatible.
        """

      {before, rest} ->
        step = {:circuit_breaker, &record_result/1}
        %{request | response_steps: before ++ [step | rest]}
    end
  end

  @doc """
  Returns `true` if a `Req` response or exception counts as a failure of the
  service.

  This is the default for `attach/2`.

  ## Examples

      iex> failure?(%Req.Response{status: 503})
      true

      iex> failure?(%Req.Response{status: 429})
      false

      iex> failure?(%Req.TransportError{reason: :econnrefused})
      true

      iex> failure?(%Req.TooManyRedirectsError{max_redirects: 10})
      false
  """
  @spec failure?(Req.Response.t() | Exception.t()) :: boolean
  def failure?(%Req.Response{status: status}), do: status >= 500
  def failure?(%Req.TransportError{}), do: true
  def failure?(%Req.HTTPError{}), do: true
  def failure?(%{__exception__: true}), do: false

  defp check_circuit(%Req.Request{} = request) do
    case options(request) do
      nil ->
        request

      opts ->
        name = Keyword.fetch!(opts, :name)
        mode = Keyword.get(opts, :mode, :sync)

        case ask(name, mode: mode) do
          :ok ->
            request

          {:error, %NotInstalledError{} = error} ->
            raise error

          {:error, %OpenError{} = error} ->
            Req.Request.halt(request, error)
        end
    end
  end

  defp record_result({%Req.Request{} = request, response_or_exception}) do
    case options(request) do
      nil ->
        {request, response_or_exception}

      opts ->
        failure? = Keyword.get(opts, :failure?, &failure?/1)

        _ =
          if failure?.(response_or_exception) do
            record_failure(Keyword.fetch!(opts, :name))
          end

        {request, response_or_exception}
    end
  end

  # Validating the options in `attach/2` alone isn't sufficient, because
  # `Req.merge/2` replaces the whole value of a registered option.
  defp options(%Req.Request{options: %{circuit_breaker: opts}})
       when is_list(opts) do
    opts = Keyword.validate!(opts, @request_opts)

    if Keyword.has_key?(opts, :name) do
      opts
    else
      raise ArgumentError, """
      missing :name in the :circuit_breaker request option

      Passing :circuit_breaker on a request replaces the options given to
      attach/2 instead of merging into them, so :name has to be repeated.
      Pass `circuit_breaker: false` to skip the breaker. Got:

          #{inspect(opts)}
      """
    end
  end

  defp options(%Req.Request{}), do: nil
end

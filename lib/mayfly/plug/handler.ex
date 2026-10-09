defmodule Mayfly.Plug.Handler do
  @moduledoc """
  Makes any Plug (a `Plug.Router`, a Phoenix endpoint, your own module) a
  Mayfly Lambda handler.

      defmodule MyApp.Lambda do
        use Mayfly.Plug.Handler, plug: MyAppWeb.Router
      end

      # Phoenix: the endpoint is a plug too; pass init options as a tuple
      use Mayfly.Plug.Handler, plug: {MyAppWeb.Endpoint, []}

  Set the Lambda handler to `MyApp.Lambda`. Each API Gateway (v1/v2), Function
  URL or ALB event becomes a `%Plug.Conn{}` (see `Mayfly.Plug.Adapter`), the
  plug runs, and the response is returned as the proxy response the event
  source expects. The invocation's `Mayfly.Context` is available as
  `conn.private[:mayfly_context]` and `conn.assigns[:lambda_context]`.

  ## Options

    * `:plug` (required) – module or `{module, init_opts}`; `init/1` is called
      once per execution environment from `c:Mayfly.Handler.init/1`
    * `:streaming` – `true` to run the plug in its own process and stream
      `send_chunked`/`chunk` output through Lambda response streaming. Only
      use this when the function is invoked in `RESPONSE_STREAM` mode: the
      response is then always a `Mayfly.Response` stream with the Function URL
      prelude, which a buffered Function URL or API Gateway cannot decode.
      Default `false`: chunks are buffered and sent at once.
    * `:on_error` – what to do when the plug raises *after* it has already sent
      a response (that is what `Plug.ErrorHandler`, `Plug.Debugger` and
      Phoenix's `RenderErrors` do: render a 500, then re-raise so the server
      logs it). `:respond` (default) returns the rendered response to the
      client and logs the exception, like Cowboy and Bandit do. `:propagate`
      re-raises instead, so Lambda records a function error and the client
      gets the integration's generic 502. Exceptions raised before any
      response is sent always propagate.
    * `:binary_types` – content-type prefixes whose bodies are base64-encoded;
      see `Mayfly.Plug.Adapter`

  ## Events that are not HTTP

  SQS, EventBridge or plain `aws lambda invoke` payloads produce
  `{:error, %{errorType: "Mayfly.Plug.NotAnHttpEvent"}}`. Override `handle/3`
  with a clause of your own before falling through to `super` if the same
  function must also serve other sources.
  """

  require Logger

  alias Mayfly.Plug.Adapter

  @type opts :: %{
          plug: module(),
          plug_opts: term(),
          streaming: boolean(),
          on_error: :respond | :propagate,
          binary_types: [String.t()] | nil
        }

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use Mayfly.Handler

      @mayfly_plug_opts opts

      @impl Mayfly.Handler
      def init(_opts), do: Mayfly.Plug.Handler.init_plug(@mayfly_plug_opts)

      @impl Mayfly.Handler
      def handle(event, ctx, state), do: Mayfly.Plug.Handler.run(event, ctx, state)

      defoverridable init: 1, handle: 3
    end
  end

  @doc false
  @spec init_plug(keyword()) :: {:ok, opts()}
  def init_plug(opts) do
    {plug, plug_opts} =
      case Keyword.fetch!(opts, :plug) do
        {mod, o} when is_atom(mod) -> {mod, o}
        mod when is_atom(mod) -> {mod, []}
      end

    {:ok,
     %{
       plug: plug,
       plug_opts: plug.init(plug_opts),
       streaming: Keyword.get(opts, :streaming, false),
       on_error: Keyword.get(opts, :on_error, :respond),
       binary_types: Keyword.get(opts, :binary_types)
     }}
  end

  @doc "Runs one event through the plug. Called by the generated `handle/3`."
  @spec run(term(), Mayfly.Context.t(), opts()) :: {:ok, term()} | {:error, map()}
  def run(event, ctx, %{streaming: streaming} = state) do
    if Adapter.http_event?(event) do
      if streaming, do: run_streaming(event, ctx, state), else: run_buffered(event, ctx, state)
    else
      {:error,
       %{
         errorType: "Mayfly.Plug.NotAnHttpEvent",
         errorMessage:
           "expected an API Gateway, Function URL or ALB event, got keys #{inspect(keys(event))}"
       }}
    end
  end

  # -- buffered ------------------------------------------------------------------------

  defp run_buffered(event, ctx, state) do
    conn = Adapter.conn(event, ctx, adapter_opts(state))
    req = conn.private.mayfly_request

    try do
      conn = state.plug.call(conn, state.plug_opts)
      drain()

      case Adapter.proxy_response(conn) do
        {:ok, response} -> {:ok, response}
        {:error, :no_response} -> no_response()
      end
    rescue
      e ->
        case {sent_response(), state.on_error} do
          {%{} = response, :respond} ->
            log_after_send(e, __STACKTRACE__)
            {:ok, Adapter.to_proxy(req, response, binary_types(state))}

          _ ->
            drain()
            reraise_unwrapped(e, __STACKTRACE__)
        end
    end
  end

  # -- streaming -----------------------------------------------------------------------

  defp run_streaming(event, ctx, state) do
    conn = Adapter.conn(event, ctx, [sink: self()] ++ adapter_opts(state))
    req = conn.private.mayfly_request
    parent = self()
    plug = state.plug
    plug_opts = state.plug_opts

    {pid, mon} =
      spawn_monitor(fn ->
        plug.call(conn, plug_opts)
        send(parent, {:mayfly_plug, :done, self()})
      end)

    receive do
      {:mayfly_plug, {:response, %{status: status, headers: headers, body: body}}, ^pid} ->
        Process.demonitor(mon, [:flush])
        {:ok, streamed([body], status, headers)}

      {:mayfly_plug, {:chunked, status, headers}, ^pid} ->
        {:ok, streamed(chunk_stream(pid, mon), status, headers)}

      {:mayfly_plug, :done, ^pid} ->
        Process.demonitor(mon, [:flush])
        no_response()

      {:DOWN, ^mon, :process, ^pid, reason} ->
        case {sent_response(), state.on_error} do
          {%{} = response, :respond} ->
            log_after_send(reason)
            {:ok, Adapter.to_proxy(req, response, binary_types(state))}

          _ ->
            exit_with(reason)
        end
    end
  end

  defp chunk_stream(pid, mon) do
    Stream.resource(
      fn -> :open end,
      fn
        :closed ->
          {:halt, :closed}

        :open ->
          receive do
            {:mayfly_plug, :chunk, ref, ^pid, data} ->
              send(pid, {:mayfly_plug, :ack, ref})
              {[data], :open}

            {:mayfly_plug, :done, ^pid} ->
              Process.demonitor(mon, [:flush])
              {:halt, :closed}

            {:DOWN, ^mon, :process, ^pid, :normal} ->
              {:halt, :closed}

            {:DOWN, ^mon, :process, ^pid, reason} ->
              exit_with(reason)
          end
      end,
      fn _ -> :ok end
    )
  end

  defp streamed(body, status, headers) do
    {cookies, headers} = Enum.split_with(headers, fn {k, _} -> k == "set-cookie" end)

    header_map =
      Enum.group_by(headers, &elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {k, vs} -> {k, Enum.join(vs, ", ")} end)

    content_type = Map.get(header_map, "content-type", "application/octet-stream")

    %Mayfly.Response{body: body, content_type: content_type}
    |> Mayfly.Response.stream()
    |> Mayfly.Response.http(
      status: status,
      headers: header_map,
      cookies: Enum.map(cookies, &elem(&1, 1))
    )
  end

  # -- helpers ---------------------------------------------------------------------------

  defp adapter_opts(%{binary_types: nil}), do: []
  defp adapter_opts(%{binary_types: types}), do: [binary_types: types]

  defp binary_types(%{binary_types: nil}), do: Adapter.default_binary_types()
  defp binary_types(%{binary_types: types}), do: types

  defp no_response do
    {:error,
     %{
       errorType: "Mayfly.Plug.NoResponse",
       errorMessage: "the plug returned without sending a response"
     }}
  end

  # The last response the adapter reported to us, if any.
  defp sent_response do
    receive do
      {:mayfly_plug, {:response, response}, _} -> sent_response() || response
    after
      0 -> nil
    end
  end

  defp drain do
    receive do
      {:plug_conn, :sent} -> drain()
      {:mayfly_plug, _, _} -> drain()
    after
      0 -> :ok
    end
  end

  defp log_after_send(%Plug.Conn.WrapperError{} = e, _st), do: log_after_send(e.reason, e.stack)

  defp log_after_send(e, st) do
    Logger.error("plug raised after sending a response: " <> Exception.format(:error, e, st))
  end

  defp log_after_send({e, st}) when is_list(st), do: log_after_send(e, st)

  defp log_after_send(reason),
    do: Logger.error("plug exited after sending a response: #{inspect(reason)}")

  # Plug.Router and Phoenix wrap exceptions in Plug.Conn.WrapperError; Lambda
  # should see the original exception type.
  defp reraise_unwrapped(%Plug.Conn.WrapperError{kind: kind, reason: reason, stack: stack}, _st),
    do: :erlang.raise(kind, reason, stack)

  defp reraise_unwrapped(e, st), do: reraise(e, st)

  # Re-raises the failure of the plug process in the handler process with its stack trace.
  @spec exit_with(term()) :: no_return()
  defp exit_with({%Plug.Conn.WrapperError{} = e, st}), do: reraise_unwrapped(e, st)
  defp exit_with({%{__exception__: true} = e, st}) when is_list(st), do: reraise(e, st)
  defp exit_with({{:nocatch, thrown}, _st}), do: throw(thrown)
  defp exit_with({reason, st}) when is_list(st), do: :erlang.raise(:exit, reason, st)
  defp exit_with(reason), do: exit(reason)

  defp keys(event) when is_map(event), do: event |> Map.keys() |> Enum.take(8)
  defp keys(event), do: event
end

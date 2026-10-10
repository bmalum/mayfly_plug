defmodule Mayfly.Plug.Adapter do
  @moduledoc """
  `Plug.Conn.Adapter` that turns an API Gateway (v1/v2), Function URL or ALB
  event into a `%Plug.Conn{}` and collects the response the plug sends.

  You normally do not use this module directly; `Mayfly.Plug.Handler` wires it
  up. It is public so you can build conns from events in your own tests:

      conn = Mayfly.Plug.Adapter.conn(event, ctx)
      conn = MyRouter.call(conn, MyRouter.init([]))
      {:ok, response} = Mayfly.Plug.Adapter.proxy_response(conn)

  ## Responses

  `send_resp/4` and `send_file/6` capture status, headers and body. The body is
  base64-encoded (`isBase64Encoded: true`) when it is not valid UTF-8 or the
  content type is binary (see `binary_content_type?/2`). On v2 events,
  `set-cookie` headers become the `cookies` list; on v1 and ALB repeated
  headers become `multiValueHeaders`.

  `send_chunked/3` and `chunk/2` work in two modes:

    * **buffered** (default): chunks are concatenated and sent as one response
      when the plug returns. Function URLs in `BUFFERED` invoke mode and API
      Gateway cannot stream anyway.
    * **streaming** (`use Mayfly.Plug.Handler, streaming: true`): the plug runs
      in a separate process and every chunk is forwarded to Lambda as it is
      produced, as a `Mayfly.Response` stream with the Function URL prelude
      (status and headers). `chunk/2` blocks until the runtime has taken the
      previous chunk, so a slow client applies back-pressure to the plug.

  `inform/3` (1xx) and `upgrade/3` (WebSockets) return `{:error, :not_supported}`.
  """

  @behaviour Plug.Conn.Adapter

  alias Mayfly.Events.HTTP
  alias Mayfly.Events.HTTP.Request

  @default_binary_types ~w(image/ audio/ video/ font/ application/octet-stream application/pdf application/zip application/gzip application/wasm application/vnd.)

  @typedoc "Adapter payload stored in `conn.adapter`."
  @type payload :: %{
          request: Request.t(),
          body: binary(),
          body_read: boolean(),
          owner: pid(),
          sink: pid() | nil,
          response: nil | %{status: pos_integer(), headers: Plug.Conn.headers(), body: iodata()},
          chunked: nil | %{status: pos_integer(), headers: Plug.Conn.headers(), body: [binary()]},
          binary_types: [String.t()],
          send_timeout: pos_integer()
        }

  @doc "Content-type prefixes treated as binary (base64-encoded) by default."
  @spec default_binary_types() :: [String.t()]
  def default_binary_types, do: @default_binary_types

  # -- building a conn -----------------------------------------------------------

  @doc """
  Builds a `%Plug.Conn{}` from a raw HTTP event (or an already decoded
  `Mayfly.Events.HTTP.Request`) and the invocation context.

  Options: `:sink` (pid that receives chunks in streaming mode),
  `:binary_types` (content-type prefixes that force base64),
  `:send_timeout` (ms a streamed `chunk/2` may wait for the consumer).
  """
  @spec conn(map() | Request.t(), Mayfly.Context.t() | nil, keyword()) :: Plug.Conn.t()
  def conn(event, ctx \\ nil, opts \\ [])

  def conn(%Request{} = req, ctx, opts) do
    raw_body = raw_body(req)

    payload = %{
      request: req,
      body: raw_body,
      body_read: false,
      owner: self(),
      sink: Keyword.get(opts, :sink),
      response: nil,
      chunked: nil,
      binary_types: Keyword.get(opts, :binary_types, @default_binary_types),
      send_timeout: Keyword.get(opts, :send_timeout, 30_000)
    }

    host = req.headers["host"] || "localhost"

    uri = %URI{
      scheme: scheme(req),
      host: host,
      port: port(req),
      path: req.raw_path,
      query: query_string(req)
    }

    conn =
      Plug.Conn.Adapter.conn(
        {__MODULE__, payload},
        req.method,
        uri,
        remote_ip(req.source_ip),
        req_headers(req)
      )

    conn
    |> Map.put(:script_name, [])
    |> Plug.Conn.put_private(:mayfly_context, ctx)
    |> Plug.Conn.put_private(:mayfly_request, req)
    |> Plug.Conn.assign(:lambda_context, ctx)
  end

  def conn(event, ctx, opts) when is_map(event), do: conn(HTTP.decode(event), ctx, opts)

  @doc "True when the event is an API Gateway v1/v2, Function URL or ALB request."
  @spec http_event?(term()) :: boolean()
  def http_event?(%{"version" => "2.0", "requestContext" => %{"http" => _}}), do: true
  def http_event?(%{"httpMethod" => _}), do: true
  def http_event?(%{"requestContext" => %{"elb" => _}}), do: true
  def http_event?(_), do: false

  # -- Plug.Conn.Adapter callbacks ---------------------------------------------------

  @impl true
  def send_resp(payload, status, headers, body) do
    body = if payload.request.method == "HEAD", do: "", else: IO.iodata_to_binary(body)
    response = %{status: status, headers: headers, body: body}
    notify(payload, {:response, response})
    {:ok, body, %{payload | response: response}}
  end

  @impl true
  def send_file(payload, status, headers, path, offset, length) do
    data =
      File.open!(path, [:read, :binary], fn io ->
        :file.position(io, offset)

        case length do
          :all -> IO.binread(io, :eof)
          n -> IO.binread(io, n)
        end
      end)

    data = if data == :eof, do: "", else: data
    send_resp(payload, status, headers, data)
  end

  @impl true
  def send_chunked(%{sink: nil} = payload, status, headers) do
    {:ok, "", %{payload | chunked: %{status: status, headers: headers, body: []}}}
  end

  def send_chunked(payload, status, headers) do
    notify(payload, {:chunked, status, headers})
    {:ok, "", %{payload | chunked: %{status: status, headers: headers, body: []}}}
  end

  @impl true
  def chunk(%{request: %{method: "HEAD"}}, _body), do: :ok

  def chunk(%{sink: nil, chunked: chunked} = payload, body) do
    bin = IO.iodata_to_binary(body)
    {:ok, bin, %{payload | chunked: %{chunked | body: [bin | chunked.body]}}}
  end

  def chunk(%{sink: sink, send_timeout: timeout} = payload, body) do
    ref = make_ref()
    send(sink, {:mayfly_plug, :chunk, ref, self(), IO.iodata_to_binary(body)})

    receive do
      {:mayfly_plug, :ack, ^ref} -> {:ok, nil, payload}
      {:mayfly_plug, :closed, ^ref} -> {:error, :closed}
    after
      timeout -> {:error, :timeout}
    end
  end

  @impl true
  def read_req_body(%{body_read: true} = payload, _opts), do: {:ok, "", payload}

  def read_req_body(%{body: body} = payload, opts) do
    length = Keyword.get(opts, :length, 8_000_000)

    if byte_size(body) <= length do
      {:ok, body, %{payload | body: "", body_read: true}}
    else
      <<part::binary-size(length), rest::binary>> = body
      {:more, part, %{payload | body: rest}}
    end
  end

  @impl true
  def inform(_payload, _status, _headers), do: {:error, :not_supported}

  @impl true
  def upgrade(_payload, _protocol, _opts), do: {:error, :not_supported}

  @impl true
  def push(_payload, _path, _headers), do: {:error, :not_supported}

  @impl true
  def get_peer_data(%{request: req}) do
    %{address: remote_ip(req.source_ip), port: 0, ssl_cert: nil}
  end

  @impl true
  def get_http_protocol(%{request: req}) do
    case req.headers["x-forwarded-proto"] || req.raw["requestContext"]["http"]["protocol"] do
      "HTTP/2" <> _ -> :"HTTP/2"
      "HTTP/1.0" -> :"HTTP/1.0"
      _ -> :"HTTP/1.1"
    end
  end

  # -- turning the conn back into a Lambda response ----------------------------------

  @doc """
  Converts a conn the plug has responded to into the proxy response map for the
  event's version (`{:ok, map}`), or `{:error, :no_response}` when nothing was
  sent. Buffered chunked responses are flattened.
  """
  @spec proxy_response(Plug.Conn.t()) :: {:ok, map()} | {:error, :no_response}
  def proxy_response(%Plug.Conn{adapter: {__MODULE__, payload}}) do
    case response_of(payload) do
      nil -> {:error, :no_response}
      response -> {:ok, to_proxy(payload.request, response, payload.binary_types)}
    end
  end

  @doc false
  def response_of(%{response: %{} = r}), do: r

  def response_of(%{chunked: %{} = c}),
    do: %{
      status: c.status,
      headers: c.headers,
      body: c.body |> Enum.reverse() |> IO.iodata_to_binary()
    }

  def response_of(_), do: nil

  @doc false
  @spec to_proxy(Request.t(), map(), [String.t()]) :: map()
  def to_proxy(
        %Request{version: version} = req,
        %{status: status, headers: headers, body: body},
        binary_types
      ) do
    {cookies, headers} = Enum.split_with(headers, fn {k, _} -> k == "set-cookie" end)
    headers = if version == :v2, do: headers, else: headers ++ cookies
    base64? = base64?(body, content_type(headers), binary_types)

    opts = [headers: group_headers(headers), base64: base64?]

    opts =
      if version == :v2,
        do: Keyword.put(opts, :cookies, Enum.map(cookies, &elem(&1, 1))),
        else: opts

    {:ok, map} = HTTP.respond(status, body, req, opts)
    map
  end

  @doc "True when a body with this content type must be base64-encoded for Lambda."
  @spec binary_content_type?(String.t() | nil, [String.t()]) :: boolean()
  def binary_content_type?(nil, _types), do: false

  def binary_content_type?(ct, types) do
    ct = ct |> String.split(";") |> hd() |> String.trim() |> String.downcase()

    Enum.any?(types, &String.starts_with?(ct, &1)) and not String.contains?(ct, "json") and
      not String.contains?(ct, "xml")
  end

  # -- private -----------------------------------------------------------------------

  # The owner (the process that built the conn) gets Plug's :sent notice; the
  # sink (streaming) or, failing that, the owner gets the response itself so the
  # handler can recover it when the plug raises after sending.
  # The owner (the process that built the conn, i.e. the one running the plug)
  # always gets Plug's {:plug_conn, :sent}: Plug.ErrorHandler and Phoenix's
  # RenderErrors look for it to decide whether a response was already sent.
  # The handler (owner in buffered mode, sink in streaming mode) gets the
  # response itself so it can recover it when the plug raises after sending.
  defp notify(%{owner: owner, sink: sink}, message) do
    send(owner, {:plug_conn, :sent})
    send(sink || owner, {:mayfly_plug, message, self()})
    :ok
  end

  defp base64?(body, ct, types), do: binary_content_type?(ct, types) or not String.valid?(body)

  defp content_type(headers) do
    Enum.find_value(headers, fn {k, v} -> k == "content-type" && v end)
  end

  defp group_headers(headers) do
    headers
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn
      {k, [v]} -> {k, v}
      {k, vs} -> {k, vs}
    end)
  end

  defp raw_body(%Request{raw: raw, is_base64: b64}) do
    case raw["body"] do
      nil ->
        ""

      body when b64 ->
        # Tolerate missing padding; an undecodable body is passed through raw.
        case Base.decode64(body, padding: false) do
          {:ok, bin} -> bin
          :error -> body
        end

      body ->
        body
    end
  end

  # Only http/https are meaningful (and String.to_atom on a client header would
  # otherwise create arbitrary atoms).
  defp scheme(%Request{headers: h}) do
    case h["x-forwarded-proto"] do
      "http" -> "http"
      _ -> "https"
    end
  end

  defp port(%Request{headers: h} = req) do
    default = if scheme(req) == "http", do: 80, else: 443

    case h["x-forwarded-port"] do
      nil -> default
      p -> with({n, ""} when n in 1..65_535 <- Integer.parse(p), do: n, else: (_ -> default))
    end
  end

  defp query_string(%Request{version: :v2, raw: raw}), do: raw["rawQueryString"] || ""

  # ALB passes values URL-encoded as they were on the wire; API Gateway v1 decodes them.
  defp query_string(%Request{version: :alb, query: q}) do
    q
    |> Enum.flat_map(fn {k, vs} -> for v <- List.wrap(vs), do: "#{k}=#{v}" end)
    |> Enum.join("&")
  end

  defp query_string(%Request{query: q}) do
    q |> Enum.flat_map(fn {k, vs} -> for v <- List.wrap(vs), do: {k, v} end) |> URI.encode_query()
  end

  # Multi-value headers stay separate tuples (v1/ALB); v2 cookies become one cookie header.
  defp req_headers(%Request{raw: %{"multiValueHeaders" => mv}}) when is_map(mv) do
    for {k, vs} <- mv, v <- List.wrap(vs), do: {String.downcase(k), to_string(v)}
  end

  defp req_headers(%Request{version: :v2, headers: headers, cookies: cookies}) do
    list = Enum.map(headers, fn {k, v} -> {k, v} end)
    if cookies == [], do: list, else: list ++ [{"cookie", Enum.join(cookies, "; ")}]
  end

  defp req_headers(%Request{headers: headers}), do: Map.to_list(headers)

  defp remote_ip(nil), do: {0, 0, 0, 0}

  defp remote_ip(ip) when is_binary(ip) do
    # Mayfly.Events.HTTP already resolves source_ip (ALB: last X-Forwarded-For
    # hop, the one the load balancer saw). If a list still arrives, the last
    # entry is the trustworthy one; earlier ones are client-supplied.
    first = ip |> String.split(",") |> List.last() |> String.trim()

    case :inet.parse_address(String.to_charlist(first)) do
      {:ok, addr} -> addr
      {:error, _} -> {0, 0, 0, 0}
    end
  end
end

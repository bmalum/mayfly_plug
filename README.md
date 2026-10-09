# Mayfly.Plug

Run a `Plug.Router` or a **Phoenix** endpoint as an AWS Lambda function with
[Mayfly](https://elixir-aws-lambda.dev). API Gateway (v1/v2), Function URL
and ALB events become `%Plug.Conn{}`s, your plug runs, and the response goes
back as the proxy response the event source expects. No HTTP server, no
Bandit/Cowboy in the release.

```elixir
def deps do
  [{:mayfly, "~> 1.0.0-rc"}, {:mayfly_plug, "~> 0.1"}]
end
```

```elixir
defmodule MyApp.Lambda do
  use Mayfly.Plug.Handler, plug: MyAppWeb.Router        # any plug
  # use Mayfly.Plug.Handler, plug: {MyAppWeb.Endpoint, []}   # Phoenix
end
```

```elixir
# mix.exs release
lambda: [
  steps: [&Mayfly.Release.prepare/1, :assemble, &Mayfly.Release.bootstrap/1, &Mayfly.Release.zip/1],
  mayfly: [handler: MyApp.Lambda, layer: true]
]
```

Set the Lambda handler to `MyApp.Lambda`, attach a Mayfly Erlang layer, put an
API Gateway HTTP API, a Function URL or an ALB in front. Test locally:

```bash
mix lambda.invoke MyApp.Lambda '{}' --http --method GET --path /api/hello
mix lambda.invoke MyApp.Lambda '{"name":"Ada"}' --http --path /api/users
```

## What you get

| | |
|---|---|
| `conn.method`, `request_path`, `query_string`, `host`, `scheme`, `port`, `remote_ip` | from the event (`x-forwarded-*` honoured) |
| `req_headers` | lowercased; multi-value headers (v1/ALB) stay separate tuples; v2 `cookies` become one `cookie` header |
| `Plug.Conn.read_body/2` | raw body, base64-decoded when `isBase64Encoded` |
| `send_resp`, `send_file` | status, headers, body → proxy response. `set-cookie` → `cookies` (v2) or `multiValueHeaders` (v1/ALB). Binary or non-UTF-8 bodies are base64-encoded with `isBase64Encoded: true` (content types configurable via `binary_types:`) |
| `send_chunked` + `chunk` | buffered into one response by default; real streaming with `streaming: true` |
| `conn.private[:mayfly_context]`, `conn.assigns[:lambda_context]` | the `Mayfly.Context` (request id, deadline, …) |
| `inform` (1xx), `upgrade` (WebSocket) | `{:error, :not_supported}` |

## Streaming

```elixir
defmodule MyApp.StreamingLambda do
  use Mayfly.Plug.Handler, plug: MyAppWeb.Endpoint, streaming: true
end
```

With `streaming: true` the plug runs in its own process and every `chunk/2`
is forwarded to Lambda as soon as it is produced (the plug blocks until the
runtime has taken the chunk, so slow clients apply back-pressure). The
response is always a Lambda stream with the Function URL prelude (status,
headers, cookies), so use it only on a Function URL in `RESPONSE_STREAM`
invoke mode (or `InvokeWithResponseStream`); plain `send_resp` routes keep
working through the same function. Without the option, chunks are buffered
and sent as one response, which is what API Gateway and buffered Function URLs
need anyway.

## Errors

An exception raised before anything was sent propagates: Lambda records a
function error with the Elixir stack trace and the client gets the
integration's 502. `Plug.ErrorHandler`, `Plug.Debugger` and Phoenix render a
500 *and then re-raise*; by default (`on_error: :respond`) the rendered
response is returned to the client and the exception is logged, like Bandit
and Cowboy do. `on_error: :propagate` re-raises instead so the Lambda error
metrics count it. Events that are not HTTP (SQS, EventBridge, plain invoke)
produce a `Mayfly.Plug.NotAnHttpEvent` error.

## Phoenix

See the [Phoenix on Lambda guide](https://elixir-aws-lambda.dev/docs/phoenix.html):
`server: false`, no `http:` block, `url: [host: …, scheme: "https"]`, Bandit
only in `:dev`/`:test`. JSON APIs, controllers, plugs, sessions in signed
cookies and `Plug.Static` work; LiveView and channels do not (WebSockets).
Measured on the playground with Phoenix 1.8: 2.8 MB zip with the Erlang
layer, cold start (`Init Duration`) 0.6–0.75 s at 1024 MB arm64, warm
requests 3–10 ms.

## Tests

`mix test` runs the adapter against v1/v2/ALB fixtures and routers end to end
through `Mayfly.LocalRuntime`, including streaming. No AWS account needed.

MIT. Part of the Mayfly project by [Karrer](https://karrer.solutions).

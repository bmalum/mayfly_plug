# Changelog

## [Unreleased]

### Fixed
- Streaming mode: the conn is now built inside the plug process so Plug's
  `{:plug_conn, :sent}` reaches `Plug.ErrorHandler` / Phoenix `RenderErrors`;
  a controller raising after `send_chunked` no longer renders a stray 500 body.
  Mid-stream failures are reported through the response trailers.
- `on_error: :propagate` is honoured when the plug raises after `send_resp`.
- The handler process no longer leaks `{:plug_conn, :sent}` messages between
  invocations, and recovered responses are matched to the plug process that sent them.
- Consumer-side stream errors (`send_timeout`, socket closed) stop the plug
  process instead of leaving it blocked in `chunk/2`.
- ALB `remote_ip` uses the last `X-Forwarded-For` hop (the one the load balancer
  saw); the first entry is client-controlled.
- `x-forwarded-proto` only accepts `http`/`https`; `x-forwarded-port` is parsed
  defensively; base64 bodies without padding are tolerated.
- `mayfly` is a Hex dependency by default (`MAYFLY_PATH` for local development).

### Added
- Test suite now runs a real Phoenix 1.8 endpoint (`test/support/phoenix_app.ex`, phoenix as a
  test-only dependency): controller actions with the Lambda context, `Plug.Parsers`, Phoenix
  404/406/500 rendering through `RenderErrors`, cookie sessions across invocations, `Plug.Head`,
  `on_error: :propagate`, and `send_chunked` streaming from a controller.

## [0.1.0] - 2026-10-09

### Added
- `Mayfly.Plug.Adapter`: `Plug.Conn.Adapter` for API Gateway v1/v2, Function URL and ALB events (multi-value headers, cookies, base64 bodies, send_file, chunked buffered or streamed).
- `Mayfly.Plug.Handler`: `use Mayfly.Plug.Handler, plug: MyRouter` turns any plug (incl. Phoenix endpoints) into a Mayfly handler; `streaming: true` for Lambda response streaming; `on_error:` policy for errors raised after a response was sent.

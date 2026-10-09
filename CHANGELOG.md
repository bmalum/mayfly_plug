# Changelog

## [Unreleased]

### Added
- Test suite now runs a real Phoenix 1.8 endpoint (`test/support/phoenix_app.ex`, phoenix as a
  test-only dependency): controller actions with the Lambda context, `Plug.Parsers`, Phoenix
  404/406/500 rendering through `RenderErrors`, cookie sessions across invocations, `Plug.Head`,
  `on_error: :propagate`, and `send_chunked` streaming from a controller.

## [0.1.0] - 2026-10-09

### Added
- `Mayfly.Plug.Adapter`: `Plug.Conn.Adapter` for API Gateway v1/v2, Function URL and ALB events (multi-value headers, cookies, base64 bodies, send_file, chunked buffered or streamed).
- `Mayfly.Plug.Handler`: `use Mayfly.Plug.Handler, plug: MyRouter` turns any plug (incl. Phoenix endpoints) into a Mayfly handler; `streaming: true` for Lambda response streaming; `on_error:` policy for errors raised after a response was sent.

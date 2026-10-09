# Changelog

## [0.1.0] - 2026-10-09

### Added
- `Mayfly.Plug.Adapter`: `Plug.Conn.Adapter` for API Gateway v1/v2, Function URL and ALB events (multi-value headers, cookies, base64 bodies, send_file, chunked buffered or streamed).
- `Mayfly.Plug.Handler`: `use Mayfly.Plug.Handler, plug: MyRouter` turns any plug (incl. Phoenix endpoints) into a Mayfly handler; `streaming: true` for Lambda response streaming; `on_error:` policy for errors raised after a response was sent.

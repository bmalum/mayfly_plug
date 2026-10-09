import Config

if config_env() == :test do
  config :logger, level: :warning
end

if config_env() == :test do
  config :mayfly_plug, Mayfly.Plug.PhoenixApp.Endpoint,
    server: false,
    secret_key_base: String.duplicate("s", 64),
    render_errors: [formats: [json: Mayfly.Plug.PhoenixApp.ErrorJSON], layout: false],
    url: [host: "example.lambda-url.eu-central-1.on.aws", scheme: "https", port: 443]

  config :phoenix, :json_library, JSON
end

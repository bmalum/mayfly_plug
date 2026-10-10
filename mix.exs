defmodule Mayfly.Plug.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/bmalum/mayfly_plug"

  def project do
    [
      app: :mayfly_plug,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "Mayfly.Plug",
      description: "Run Plug and Phoenix routers as AWS Lambda handlers with Mayfly",
      package: package(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit], plt_file: {:no_warn, "_build/plts/dialyzer.plt"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      mayfly_dep(),
      {:plug, "~> 1.15"},
      {:telemetry, "~> 1.0", optional: true},
      # A real Phoenix endpoint in test/support exercises RenderErrors, Parsers and sessions.
      {:phoenix, "~> 1.8", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Hex release by default. Set MAYFLY_PATH=/path/to/mayfly to develop against a
  # local checkout (CI does this until mayfly itself is on Hex).
  defp mayfly_dep do
    case System.get_env("MAYFLY_PATH") do
      nil -> {:mayfly, "~> 1.0.0-rc"}
      path -> {:mayfly, path: path}
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "Mayfly" => "https://elixir-aws-lambda.dev"},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [main: "readme", source_url: @source_url, extras: ["README.md", "CHANGELOG.md"]]
  end
end

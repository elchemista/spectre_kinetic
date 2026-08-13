defmodule SpectreKinetic.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/elchemista/spectre_kinetic"

  def project do
    [
      app: :spectre_kinetic,
      name: "Spectre Kinetic",
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [plt_add_apps: [:mix]],
      description: description(),
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "docs/PUBLIC_API.md",
          "CHANGELOG.md",
          "TRAIN.md",
          "LICENSE"
        ],
        source_ref: "v#{@version}"
      ],
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :logger]
    ]
  end

  defp description do
    "Elixir-first planning toolkit for Action Language tool selection and reranker fallback"
  end

  defp deps do
    [
      {:spectre, "~> 0.3.0", only: :test},
      {:jason, "~> 1.2"},
      {:nx, "~> 0.11"},
      {:axon, "~> 0.7"},
      {:polaris, "~> 0.1"},
      {:ortex, "~> 0.1"},
      {:tokenizers, "~> 0.5"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

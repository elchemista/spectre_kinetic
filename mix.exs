defmodule SpectreKinetic.MixProject do
  use Mix.Project

  @version "0.1.3"

  def project do
    [
      app: :spectre_kinetic,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [plt_add_apps: [:mix]],
      description: description(),
      package: package(),
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "TRAIN.md",
          "LICENSE"
        ]
      ],
      source_url: "https://github.com/elchemista/spectre_kinetic",
      homepage_url: "https://github.com/elchemista/spectre_kinetic"
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

  defp package do
    [
      name: "spectre_kinetic",
      maintainers: ["Yuriy Zhar"],
      files: ~w(
             lib
             priv/dataset
             mix.exs
             README.md
             TRAIN.md
             LICENSE
      ),
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/elchemista/spectre_kinetic"
      }
    ]
  end

  defp deps do
    [
      spectre_dep(),
      {:jason, "~> 1.2"},
      {:nx, "~> 0.11"},
      {:axon, "~> 0.7"},
      {:polaris, "~> 0.1"},
      {:ortex, "~> 0.1"},
      {:tokenizers, "~> 0.5"},
      {:telemetry, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp spectre_dep do
    case System.get_env("SPECTRE_PATH") do
      path when is_binary(path) and path != "" -> {:spectre, path: Path.expand(path)}
      _other -> {:spectre, github: "elchemista/spectre", branch: "feature/v0.1.3-run"}
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

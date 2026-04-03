defmodule SpectreKinetic.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :spectre_kinetic,
      version: @version,
      elixir: "~> 1.15",
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
      extra_applications: [:logger]
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
      {:jason, "~> 1.2"},
      {:nx, "~> 0.11"},
      {:axon, "~> 0.7"},
      {:ortex, "~> 0.1"},
      {:tokenizers, "~> 0.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

defmodule SpectreKinetic.MixProject do
  use Mix.Project

  def project do
    [
      app: :spectre_kinetic,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.37.0"},
      {:jason, "~> 1.2"}
    ]
  end
end

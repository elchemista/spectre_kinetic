defmodule Mix.Tasks.CompileKinetic do
  use Mix.Task

  alias SpectreKinetic.Planner.Compiler

  @moduledoc """
  Compiles a registry JSON and encoder model into an Elixir-native ETF bundle.

  ## Usage

      mix compile_kinetic \\
        --registry path/to/registry.json \\
        --encoder path/to/encoder_model_dir \\
        --out artifacts/registry/registry.etf
  """

  @shortdoc "Compile registry JSON + encoder into an Elixir-native ETF bundle"

  @switches [
    registry: :string,
    encoder: :string,
    out: :string,
    batch_size: :integer
  ]

  @impl true
  def run(argv) do
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")

    registry = opts[:registry] || Mix.raise("missing required option --registry")
    encoder = opts[:encoder] || Mix.raise("missing required option --encoder")
    out = opts[:out] || Mix.raise("missing required option --out")

    Mix.Task.run("app.start")

    case Compiler.compile(
           registry_json: registry,
           encoder_model_dir: encoder,
           output: out,
           batch_size: opts[:batch_size] || 32
         ) do
      :ok -> Mix.shell().info("Registry compiled to #{out}")
      {:error, reason} -> Mix.raise("compilation failed: #{inspect(reason)}")
    end
  end
end

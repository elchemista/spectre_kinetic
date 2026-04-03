defmodule Mix.Tasks.Spectre.CompileRegistry do
  use Mix.Task

  @moduledoc """
  Compiles a registry JSON and encoder model into an Elixir-native ETF bundle.

  The compiled bundle contains normalized action definitions, precomputed
  tool-card embeddings, and metadata. It is loaded at runtime by
  `SpectreKinetic.Planner.RegistryStore` for zero-network-access boot.

  ## Usage

      mix spectre.compile_registry \\
        --registry path/to/registry.json \\
        --encoder path/to/encoder_model_dir \\
        --out artifacts/registry/registry.etf

  ## Options

    * `--registry` — path to source registry JSON (required)
    * `--encoder` — path to ONNX encoder model directory (required)
    * `--out` — output path for the compiled ETF bundle (required)
    * `--batch-size` — embedding batch size (default 32)
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

    case SpectreKinetic.Planner.Compiler.compile(
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

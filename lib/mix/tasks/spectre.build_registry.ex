defmodule Mix.Tasks.Spectre.BuildRegistry do
  use Mix.Task

  @moduledoc """
  Compiles a human-editable registry JSON file into a runtime `.mcr` registry.
  """

  alias SpectreKinetic.Helper

  @shortdoc "Compile a registry JSON file into a spectre .mcr registry"

  @switches [model: :string, registry: :string, out: :string]

  @doc """
  Runs the registry compilation helper with the provided CLI arguments.
  """
  @spec run([binary()]) :: any()
  @impl true
  def run(argv) do
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")

    required!(opts, [:model, :registry, :out])

    Helper.run!("build-registry", [
      "--model",
      opts[:model],
      "--registry",
      opts[:registry],
      "--out",
      opts[:out]
    ])
  end

  defp required!(opts, keys) do
    Enum.each(keys, fn key ->
      if is_nil(opts[key]) do
        Mix.raise("missing required option --#{key}")
      end
    end)
  end
end

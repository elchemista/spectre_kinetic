defmodule Mix.Tasks.Spectre.ExtractDict do
  use Mix.Task

  @moduledoc """
  Extracts a compact prompt dictionary from a corpus and optional registry input.
  """

  alias SpectreKinetic.Runtime

  @shortdoc "Extract a compact AL dictionary from a corpus and optional registry"

  @switches [corpus: :string, registry: :string, seed: :string, out: :string, top_n: :integer]

  @doc """
  Runs the dictionary extraction helper with the provided CLI arguments.
  """
  @spec run([binary()]) :: any()
  @impl true
  def run(argv) do
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")

    if is_nil(opts[:corpus]) do
      Mix.raise("missing required option --corpus")
    end

    args =
      [
        "--corpus",
        opts[:corpus]
      ]
      |> maybe_add("--registry", opts[:registry])
      |> maybe_add("--seed", opts[:seed])
      |> maybe_add("--out", opts[:out])
      |> maybe_add("--top-n", opts[:top_n])

    Runtime.run_helper!("extract-dict", args)
  end

  defp maybe_add(args, _flag, nil), do: args
  defp maybe_add(args, flag, value), do: args ++ [flag, to_string(value)]
end

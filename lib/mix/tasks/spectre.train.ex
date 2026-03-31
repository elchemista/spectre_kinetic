defmodule Mix.Tasks.Spectre.Train do
  use Mix.Task

  @moduledoc """
  Runs the upstream Rust training pipeline to build a new runtime model pack.
  """

  alias SpectreKinetic.Helper

  @shortdoc "Train a spectre model pack with the upstream Rust training pipeline"

  @switches [
    teacher_onnx: :string,
    tokenizer: :string,
    corpus: :string,
    out: :string,
    max_len: :integer,
    dim: :integer,
    zipf: :boolean
  ]

  @doc """
  Runs the upstream training helper with the provided CLI arguments.
  """
  @spec run([binary()]) :: any()
  @impl true
  def run(argv) do
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")

    required!(opts, [:teacher_onnx, :tokenizer, :corpus, :out])

    args =
      [
        "--teacher-onnx",
        opts[:teacher_onnx],
        "--tokenizer",
        opts[:tokenizer],
        "--corpus",
        opts[:corpus],
        "--out",
        opts[:out]
      ]
      |> maybe_add("--max-len", opts[:max_len])
      |> maybe_add("--dim", opts[:dim])
      |> maybe_add_flag("--zipf", opts[:zipf])

    Helper.run!("train", args)
  end

  defp required!(opts, keys) do
    Enum.each(keys, fn key ->
      if is_nil(opts[key]) do
        Mix.raise("missing required option --#{key |> to_string() |> String.replace("_", "-")}")
      end
    end)
  end

  defp maybe_add(args, _flag, nil), do: args
  defp maybe_add(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_add_flag(args, _flag, false), do: args
  defp maybe_add_flag(args, _flag, nil), do: args
  defp maybe_add_flag(args, flag, true), do: args ++ [flag]
end

defmodule Mix.Tasks.Spectre.TrainReranker do
  use Mix.Task

  @moduledoc """
  Trains an Elixir-native reranker from a JSONL dataset.

  Each line must contain:

      {"query":"...", "tool_card":"...", "label":1}

  The task writes `params.etf`, `metadata.json`, and `calibration.json`.
  """

  @shortdoc "Train an Elixir-native reranker with Nx/Axon"

  @switches [
    encoder: :string,
    dataset: :string,
    out: :string,
    hidden_dim: :integer,
    batch_size: :integer,
    epochs: :integer,
    learning_rate: :float
  ]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")

    encoder = opts[:encoder] || Mix.raise("missing required option --encoder")
    dataset_path = opts[:dataset] || Mix.raise("missing required option --dataset")
    out = opts[:out] || Mix.raise("missing required option --out")

    examples = load_dataset!(dataset_path)

    case SpectreKinetic.Training.Reranker.train(
           examples,
           encoder_model_dir: encoder,
           output_dir: out,
           hidden_dim: opts[:hidden_dim] || 128,
           batch_size: opts[:batch_size] || 32,
           epochs: opts[:epochs] || 5,
           learning_rate: opts[:learning_rate] || 1.0e-3
         ) do
      {:ok, %{metadata: metadata}} ->
        Mix.shell().info(
          "Reranker trained to #{out} (examples=#{metadata.example_count}, epochs=#{metadata.epochs})"
        )

      {:error, reason} ->
        Mix.raise("reranker training failed: #{inspect(reason)}")
    end
  end

  defp load_dataset!(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      decoded = Jason.decode!(line)

      %{
        query: Map.fetch!(decoded, "query"),
        tool_card: Map.fetch!(decoded, "tool_card"),
        label: Map.fetch!(decoded, "label")
      }
    end)
  end
end

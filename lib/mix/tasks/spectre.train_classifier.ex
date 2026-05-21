defmodule Mix.Tasks.Spectre.TrainClassifier do
  use Mix.Task

  @moduledoc """
  Trains one Axon-backed classifier from JSONL source examples.

      mix spectre.train_classifier plan_confidence --dataset data.jsonl --out priv/classifiers/plan_confidence

  Each line may include editable source fields such as `input`, `action`,
  `planner_result`, `arg`, and `label`. Legacy rows with `features` and `label`
  are still accepted.
  """

  @shortdoc "Train an Axon-backed classifier"

  alias SpectreKinetic.Classifiers.BuiltIn
  alias SpectreKinetic.Classifiers.Internal.Dataset

  @switches [
    dataset: :string,
    out: :string,
    hidden_dim: :integer,
    batch_size: :integer,
    epochs: :integer,
    learning_rate: :float,
    seed: :integer
  ]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {entry, opts} = parse_opts!(argv)
    examples = Dataset.load!(entry, opts[:dataset])

    case entry.trainer.train(examples, training_opts(opts)) do
      {:ok, %{metadata: metadata}} ->
        Mix.shell().info(
          "Classifier #{entry.id} trained to #{opts[:out]} (examples=#{metadata.example_count}, epochs=#{metadata.epochs})"
        )

      {:error, reason} ->
        Mix.raise("classifier training failed: #{inspect(reason)}")
    end
  end

  @spec parse_opts!([binary()]) :: {BuiltIn.entry(), keyword()}
  defp parse_opts!([classifier_name | argv]) do
    entry = fetch_classifier!(classifier_name)

    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")

    opts =
      opts
      |> Keyword.put(:dataset, opts[:dataset] || entry.dataset_path)
      |> Keyword.put(:out, opts[:out] || Mix.raise("missing required option --out"))

    {entry, opts}
  end

  defp parse_opts!(_argv), do: Mix.raise("expected classifier name")

  @spec fetch_classifier!(binary()) :: BuiltIn.entry()
  defp fetch_classifier!(classifier_name) do
    case BuiltIn.fetch(classifier_name) do
      {:ok, entry} ->
        entry

      :error ->
        Mix.raise(
          "unsupported classifier #{inspect(classifier_name)}; expected one of #{inspect(BuiltIn.ids())}"
        )
    end
  end

  @spec training_opts(keyword()) :: keyword()
  defp training_opts(opts) do
    [
      output_dir: opts[:out],
      hidden_dim: opts[:hidden_dim] || 32,
      batch_size: opts[:batch_size] || 16,
      epochs: opts[:epochs] || 10,
      learning_rate: opts[:learning_rate] || 1.0e-3,
      seed: opts[:seed]
    ]
    |> Stream.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.to_list()
  end
end

defmodule SpectreKinetic.Training.Reranker do
  @moduledoc """
  Elixir-native reranker trainer built on top of `Nx` and `Axon`.

  The current trainer learns a compact MLP over encoder-derived pair features
  and writes:

    * `params.etf` with the trained Axon model state
    * `metadata.json` with training hyperparameters
    * `calibration.json` with derived acceptance thresholds

  The runtime fallback remains ONNX-oriented, but this provides the Elixir-side
  training and calibration pipeline for v2 artifact generation.
  """

  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Training.Calibration
  alias SpectreKinetic.Training.FeatureBuilder

  @default_hidden_dim 128
  @default_batch_size 32
  @default_epochs 5
  @default_learning_rate 1.0e-3

  @type example :: %{
          required(:query) => binary(),
          required(:tool_card) => binary(),
          required(:label) => 0 | 1
        }

  @spec train([example()], keyword()) :: {:ok, map()} | {:error, term()}
  def train(examples, opts) when is_list(examples) do
    with {:ok, encoder_model_dir} <- fetch_opt(opts, :encoder_model_dir),
         {:ok, output_dir} <- fetch_opt(opts, :output_dir),
         {:ok, embedder} <- EmbeddingRuntime.load(encoder_model_dir: encoder_model_dir),
         {:ok, features} <- FeatureBuilder.build_matrix(embedder, examples) do
      labels = label_tensor(examples)
      feature_dim = Nx.axis_size(features, 1)
      hidden_dim = Keyword.get(opts, :hidden_dim, @default_hidden_dim)
      epochs = Keyword.get(opts, :epochs, @default_epochs)
      batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
      learning_rate = Keyword.get(opts, :learning_rate, @default_learning_rate)

      model = build_model(feature_dim, hidden_dim)
      train_data = batch_data(features, labels, batch_size)

      model_state =
        model
        |> Axon.Loop.trainer(
          :binary_cross_entropy,
          Polaris.Optimizers.adamw(learning_rate: learning_rate)
        )
        |> Axon.Loop.run(train_data, epochs: epochs)

      predictions = predict(model, model_state, features)

      calibration =
        predictions
        |> Nx.to_flat_list()
        |> Enum.zip(Nx.to_flat_list(labels))
        |> Enum.map(fn {score, label} -> %{score: score, label: label} end)
        |> Calibration.build()

      File.mkdir_p!(output_dir)
      File.write!(Path.join(output_dir, "params.etf"), :erlang.term_to_binary(model_state))

      metadata = %{
        encoder_model_dir: encoder_model_dir,
        feature_dim: feature_dim,
        hidden_dim: hidden_dim,
        batch_size: batch_size,
        epochs: epochs,
        learning_rate: learning_rate,
        example_count: length(examples),
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      File.write!(Path.join(output_dir, "metadata.json"), Jason.encode!(metadata, pretty: true))

      File.write!(
        Path.join(output_dir, "calibration.json"),
        Jason.encode!(calibration, pretty: true)
      )

      {:ok, %{metadata: metadata, calibration: calibration}}
    end
  end

  @spec build_model(pos_integer(), pos_integer()) :: Axon.t()
  def build_model(input_dim, hidden_dim) do
    Axon.input("pair_features", shape: {nil, input_dim})
    |> Axon.dense(hidden_dim, activation: :relu)
    |> Axon.dropout(rate: 0.1)
    |> Axon.dense(1, activation: :sigmoid)
  end

  @spec predict(Axon.t(), term(), Nx.Tensor.t()) :: Nx.Tensor.t()
  def predict(model, model_state, features) do
    {_init_fn, predict_fn} = Axon.build(model)
    Nx.backend_transfer(predict_fn.(model_state, features))
  end

  defp label_tensor(examples) do
    examples
    |> Enum.map(fn example -> [normalize_label(example.label)] end)
    |> Nx.tensor(type: :f32)
  end

  defp normalize_label(1), do: 1.0
  defp normalize_label(0), do: 0.0
  defp normalize_label(true), do: 1.0
  defp normalize_label(false), do: 0.0

  defp batch_data(features, labels, batch_size) do
    count = Nx.axis_size(features, 0)

    for start_idx <- Stream.iterate(0, &(&1 + batch_size)), start_idx < count do
      batch_len = min(batch_size, count - start_idx)
      feature_batch = features[start_idx..(start_idx + batch_len - 1)]
      label_batch = labels[start_idx..(start_idx + batch_len - 1)]
      {feature_batch, label_batch}
    end
  end

  defp fetch_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end
end

defmodule SpectreKinetic.Reranker.Trainer do
  @moduledoc """
  Elixir-native reranker trainer built on top of `Nx` and `Axon`.

  The current trainer learns a compact MLP over encoder-derived pair features
  and writes:

    * `params.etf` with the trained Axon model state
    * `metadata.json` with training hyperparameters
    * `calibration.json` with derived acceptance thresholds

  Use `SpectreKinetic.Reranker.Runtime.Axon` to load these artifacts at runtime.
  The separate ONNX runtime is for externally exported pair-scoring models.
  """

  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Reranker.Calibration
  alias SpectreKinetic.Reranker.FeatureBuilder

  @default_hidden_dim 128
  @default_batch_size 32
  @default_epochs 5
  @default_learning_rate 1.0e-3

  @artifact_files %{
    params: "params.etf",
    metadata: "metadata.json",
    calibration: "calibration.json"
  }

  @type example :: %{
          required(:query) => binary(),
          required(:tool_card) => binary(),
          required(:label) => 0 | 1
        }

  @typep train_config :: %{
           encoder_model_dir: binary(),
           output_dir: binary(),
           hidden_dim: pos_integer(),
           batch_size: pos_integer(),
           epochs: pos_integer(),
           learning_rate: float(),
           loop_opts: keyword()
         }

  @spec train([example()], keyword()) :: {:ok, map()} | {:error, term()}
  def train(examples, opts) when is_list(examples) do
    embedding_module = Keyword.get(opts, :embedding_module, EmbeddingRuntime)

    with {:ok, config} <- training_config(opts),
         {:ok, embedder} <- embedding_module.load(encoder_model_dir: config.encoder_model_dir),
         {:ok, features} <-
           FeatureBuilder.build_matrix(
             embedder,
             examples,
             embedding_module: embedding_module
           ) do
      train_and_persist(examples, features, config)
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

    Stream.iterate(0, &(&1 + batch_size))
    |> Stream.take_while(&(&1 < count))
    |> Enum.map(fn start_idx ->
      batch_len = min(batch_size, count - start_idx)
      feature_batch = features[start_idx..(start_idx + batch_len - 1)]
      label_batch = labels[start_idx..(start_idx + batch_len - 1)]
      {feature_batch, label_batch}
    end)
  end

  defp fetch_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end

  @spec training_config(keyword()) :: {:ok, train_config()} | {:error, term()}
  defp training_config(opts) do
    with {:ok, encoder_model_dir} <- fetch_opt(opts, :encoder_model_dir),
         {:ok, output_dir} <- fetch_opt(opts, :output_dir) do
      {:ok,
       %{
         encoder_model_dir: encoder_model_dir,
         output_dir: output_dir,
         hidden_dim: Keyword.get(opts, :hidden_dim, @default_hidden_dim),
         batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
         epochs: Keyword.get(opts, :epochs, @default_epochs),
         learning_rate: Keyword.get(opts, :learning_rate, @default_learning_rate),
         loop_opts: trainer_loop_opts(opts)
       }}
    end
  end

  @spec train_and_persist([example()], Nx.Tensor.t(), train_config()) ::
          {:ok, map()} | {:error, term()}
  defp train_and_persist(examples, features, config) do
    labels = label_tensor(examples)
    feature_dim = Nx.axis_size(features, 1)

    model = build_model(feature_dim, config.hidden_dim)
    train_data = batch_data(features, labels, config.batch_size)

    model_state =
      model
      |> Axon.Loop.trainer(
        :binary_cross_entropy,
        Polaris.Optimizers.adamw(learning_rate: config.learning_rate),
        config.loop_opts
      )
      |> Axon.Loop.run(train_data, Axon.ModelState.empty(), epochs: config.epochs)

    calibration = build_calibration(model, model_state, features, labels)

    metadata = %{
      encoder_model_dir: config.encoder_model_dir,
      feature_dim: feature_dim,
      hidden_dim: config.hidden_dim,
      batch_size: config.batch_size,
      epochs: config.epochs,
      learning_rate: config.learning_rate,
      example_count: length(examples),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with :ok <- persist_artifacts(config.output_dir, model_state, metadata, calibration) do
      {:ok, %{metadata: metadata, calibration: calibration}}
    end
  end

  defp build_calibration(model, model_state, features, labels) do
    model
    |> predict(model_state, features)
    |> Nx.to_flat_list()
    |> Enum.zip(Nx.to_flat_list(labels))
    |> Enum.map(fn {score, label} -> %{score: score, label: label} end)
    |> Calibration.build()
  end

  defp persist_artifacts(output_dir, model_state, metadata, calibration) do
    with :ok <- File.mkdir_p(output_dir),
         :ok <-
           write_artifact(output_dir, @artifact_files.params, :erlang.term_to_binary(model_state)),
         {:ok, metadata_json} <- Jason.encode(metadata, pretty: true),
         :ok <- write_artifact(output_dir, @artifact_files.metadata, metadata_json),
         {:ok, calibration_json} <- Jason.encode(calibration, pretty: true) do
      write_artifact(output_dir, @artifact_files.calibration, calibration_json)
    end
  end

  defp write_artifact(output_dir, file_name, content) do
    File.write(Path.join(output_dir, file_name), content)
  end

  defp trainer_loop_opts(opts) do
    case Keyword.fetch(opts, :seed) do
      {:ok, seed} -> [log: 0, seed: seed]
      :error -> [log: 0]
    end
  end
end

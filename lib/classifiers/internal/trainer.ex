defmodule SpectreKinetic.Classifiers.Internal.Trainer do
  @moduledoc false

  @default_hidden_dim 32
  @default_batch_size 16
  @default_epochs 10
  @default_learning_rate 1.0e-3

  @doc false
  @spec train_binary(module(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def train_binary(classifier, examples, opts) do
    with {:ok, output_dir} <- fetch_opt(opts, :output_dir),
         {:ok, {features, labels}} <- binary_tensors(classifier, examples) do
      feature_dim = Nx.axis_size(features, 1)
      hidden_dim = Keyword.get(opts, :hidden_dim, @default_hidden_dim)
      model = classifier.build_model(%{"feature_dim" => feature_dim, "hidden_dim" => hidden_dim})
      model_state = run_binary_loop(model, features, labels, opts)
      scores = predict(model, model_state, features) |> Nx.to_flat_list()

      calibration =
        labels
        |> Nx.to_flat_list()
        |> Enum.zip(scores)
        |> calibration()

      metadata =
        base_metadata(classifier, examples, feature_dim, hidden_dim, opts)
        |> Map.put(:output, "binary_sigmoid")

      persist_artifacts(output_dir, model_state, metadata, calibration)
      {:ok, %{metadata: metadata, calibration: calibration}}
    end
  end

  @doc false
  @spec train_multiclass(module(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def train_multiclass(classifier, examples, opts) do
    with {:ok, output_dir} <- fetch_opt(opts, :output_dir),
         {:ok, labels} <- fetch_opt(opts, :labels),
         {:ok, {features, label_tensor}} <- multiclass_tensors(classifier, examples, labels) do
      feature_dim = Nx.axis_size(features, 1)
      hidden_dim = Keyword.get(opts, :hidden_dim, @default_hidden_dim)

      metadata = %{
        "feature_dim" => feature_dim,
        "hidden_dim" => hidden_dim,
        "labels" => Enum.map(labels, &Atom.to_string/1)
      }

      model = classifier.build_model(metadata)
      model_state = run_multiclass_loop(model, features, label_tensor, opts)

      persisted_metadata =
        base_metadata(classifier, examples, feature_dim, hidden_dim, opts)
        |> Map.put(:labels, Enum.map(labels, &Atom.to_string/1))
        |> Map.put(:output, "multiclass_softmax")

      calibration = %{example_count: length(examples), labels: persisted_metadata.labels}

      persist_artifacts(output_dir, model_state, persisted_metadata, calibration)
      {:ok, %{metadata: persisted_metadata, calibration: calibration}}
    end
  end

  @doc false
  @spec predict(Axon.t(), term(), Nx.Tensor.t()) :: Nx.Tensor.t()
  def predict(model, model_state, features) do
    {_init_fn, predict_fn} = Axon.build(model)
    Nx.backend_transfer(predict_fn.(Axon.ModelState.new(model_state), features))
  end

  @spec binary_tensors(module(), [map()]) ::
          {:ok, {Nx.Tensor.t(), Nx.Tensor.t()}} | {:error, term()}
  defp binary_tensors(classifier, examples) do
    with {:ok, feature_rows} <- feature_rows(classifier, examples) do
      labels = Enum.map(examples, &[normalize_binary_label(Map.fetch!(&1, :label))])
      {:ok, {Nx.tensor(feature_rows, type: :f32), Nx.tensor(labels, type: :f32)}}
    end
  end

  @spec multiclass_tensors(module(), [map()], [atom()]) ::
          {:ok, {Nx.Tensor.t(), Nx.Tensor.t()}} | {:error, term()}
  defp multiclass_tensors(classifier, examples, labels) do
    with {:ok, feature_rows} <- feature_rows(classifier, examples) do
      label_indexes = Map.new(Enum.with_index(labels))

      targets =
        Enum.map(examples, fn example ->
          label = Map.fetch!(example, :label)

          label_indexes
          |> Map.fetch!(normalize_label(label))
          |> one_hot(length(labels))
        end)

      {:ok, {Nx.tensor(feature_rows, type: :f32), Nx.tensor(targets, type: :f32)}}
    end
  rescue
    error -> {:error, error}
  end

  @spec feature_rows(module(), [map()]) :: {:ok, [[number()]]} | {:error, term()}
  defp feature_rows(classifier, examples) do
    rows = Enum.map(examples, &Map.fetch!(&1, :features))
    expected_dim = classifier.feature_dim()

    validate_feature_rows(rows, expected_dim)
  rescue
    error -> {:error, error}
  end

  @spec validate_feature_rows([[number()]], pos_integer()) ::
          {:ok, [[number()]]} | {:error, term()}
  defp validate_feature_rows([], _expected_dim), do: {:error, :empty_dataset}

  defp validate_feature_rows(rows, expected_dim) do
    case Enum.find_value(rows, &mismatched_dim(&1, expected_dim)) do
      nil -> {:ok, rows}
      actual_dim -> {:error, {:feature_dim_mismatch, expected_dim, actual_dim}}
    end
  end

  @spec mismatched_dim([number()], pos_integer()) :: nil | non_neg_integer()
  defp mismatched_dim(row, expected_dim) do
    actual_dim = length(row)
    if actual_dim == expected_dim, do: nil, else: actual_dim
  end

  defp run_binary_loop(model, features, labels, opts) do
    labels = Nx.reshape(labels, {:auto, 1})
    train_data = batch_data(features, labels, Keyword.get(opts, :batch_size, @default_batch_size))

    model
    |> Axon.Loop.trainer(
      :binary_cross_entropy,
      Polaris.Optimizers.adamw(
        learning_rate: Keyword.get(opts, :learning_rate, @default_learning_rate)
      ),
      trainer_loop_opts(opts)
    )
    |> Axon.Loop.run(train_data, Axon.ModelState.empty(),
      epochs: Keyword.get(opts, :epochs, @default_epochs)
    )
  end

  defp run_multiclass_loop(model, features, labels, opts) do
    train_data = batch_data(features, labels, Keyword.get(opts, :batch_size, @default_batch_size))

    model
    |> Axon.Loop.trainer(
      :categorical_cross_entropy,
      Polaris.Optimizers.adamw(
        learning_rate: Keyword.get(opts, :learning_rate, @default_learning_rate)
      ),
      trainer_loop_opts(opts)
    )
    |> Axon.Loop.run(train_data, Axon.ModelState.empty(),
      epochs: Keyword.get(opts, :epochs, @default_epochs)
    )
  end

  defp batch_data(features, labels, batch_size) do
    count = Nx.axis_size(features, 0)

    Stream.iterate(0, &(&1 + batch_size))
    |> Stream.take_while(&(&1 < count))
    |> Enum.map(fn start_idx ->
      batch_len = min(batch_size, count - start_idx)

      {features[start_idx..(start_idx + batch_len - 1)],
       labels[start_idx..(start_idx + batch_len - 1)]}
    end)
  end

  defp calibration(label_score_pairs) do
    positive_count = Enum.count(label_score_pairs, fn {label, _score} -> label == 1.0 end)
    negative_count = length(label_score_pairs) - positive_count
    scores = Enum.map(label_score_pairs, &elem(&1, 1))

    %{
      positive_count: positive_count,
      negative_count: negative_count,
      min_score: if(scores == [], do: 0.0, else: Enum.min(scores)),
      max_score: if(scores == [], do: 0.0, else: Enum.max(scores))
    }
  end

  defp persist_artifacts(output_dir, model_state, metadata, calibration) do
    File.mkdir_p!(output_dir)
    File.write!(Path.join(output_dir, "params.etf"), :erlang.term_to_binary(model_state))
    File.write!(Path.join(output_dir, "metadata.json"), Jason.encode!(metadata, pretty: true))

    File.write!(
      Path.join(output_dir, "calibration.json"),
      Jason.encode!(calibration, pretty: true)
    )
  end

  @spec base_metadata(module(), [map()], pos_integer(), pos_integer(), keyword()) :: map()
  defp base_metadata(classifier, examples, feature_dim, hidden_dim, opts) do
    %{
      classifier: classifier.classifier_id(),
      feature_dim: feature_dim,
      hidden_dim: hidden_dim,
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      epochs: Keyword.get(opts, :epochs, @default_epochs),
      learning_rate: Keyword.get(opts, :learning_rate, @default_learning_rate),
      example_count: length(examples),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
    |> maybe_put_feature_names(classifier)
  end

  @spec maybe_put_feature_names(map(), module()) :: map()
  defp maybe_put_feature_names(metadata, classifier) do
    if function_exported?(classifier, :feature_names, 0) do
      Map.put(metadata, :feature_names, classifier.feature_names())
    else
      metadata
    end
  end

  defp normalize_binary_label(1), do: 1.0
  defp normalize_binary_label(0), do: 0.0
  defp normalize_binary_label(true), do: 1.0
  defp normalize_binary_label(false), do: 0.0

  defp normalize_label(label) when is_atom(label), do: label
  defp normalize_label(label) when is_binary(label), do: String.to_existing_atom(label)

  defp one_hot(index, label_count) do
    Enum.map(0..(label_count - 1), fn label_index ->
      if label_index == index, do: 1.0, else: 0.0
    end)
  end

  defp fetch_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp trainer_loop_opts(opts) do
    case Keyword.fetch(opts, :seed) do
      {:ok, seed} -> [log: 0, seed: seed]
      :error -> [log: 0]
    end
  end
end

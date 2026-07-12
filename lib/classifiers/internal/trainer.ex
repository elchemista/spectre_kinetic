defmodule SpectreKinetic.Classifiers.Internal.Trainer do
  @moduledoc false

  alias SpectreKinetic.Training.Options

  @default_hidden_dim 32
  @default_batch_size 16
  @default_epochs 10
  @default_learning_rate 1.0e-3

  @doc false
  @spec train_binary(module(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def train_binary(classifier, examples, opts) do
    with {:ok, output_dir} <- fetch_opt(opts, :output_dir),
         :ok <- Options.validate_path(output_dir, :output_dir),
         {:ok, values} <- training_options(opts),
         {:ok, {features, labels}} <- binary_tensors(classifier, examples) do
      opts = normalized_opts(opts, values)
      feature_dim = Nx.axis_size(features, 1)
      hidden_dim = values.hidden_dim
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
         :ok <- Options.validate_path(output_dir, :output_dir),
         {:ok, values} <- training_options(opts),
         :ok <- validate_class_labels(labels),
         {:ok, {features, label_tensor}} <- multiclass_tensors(classifier, examples, labels) do
      opts = normalized_opts(opts, values)
      feature_dim = Nx.axis_size(features, 1)
      hidden_dim = values.hidden_dim

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
    with :ok <- validate_binary_labels(examples),
         {:ok, feature_rows} <- feature_rows(classifier, examples) do
      labels = Enum.map(examples, &[normalize_binary_label(Map.fetch!(&1, :label))])
      {:ok, {Nx.tensor(feature_rows, type: :f32), Nx.tensor(labels, type: :f32)}}
    end
  end

  @spec multiclass_tensors(module(), [map()], [atom()]) ::
          {:ok, {Nx.Tensor.t(), Nx.Tensor.t()}} | {:error, term()}
  defp multiclass_tensors(classifier, examples, labels) do
    with :ok <- validate_multiclass_labels(examples, labels),
         {:ok, feature_rows} <- feature_rows(classifier, examples) do
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
    case Enum.find_index(rows, &(not valid_feature_row?(&1, expected_dim))) do
      nil -> {:ok, rows}
      index -> feature_row_error(Enum.at(rows, index), expected_dim, index)
    end
  end

  defp valid_feature_row?(row, expected_dim) when is_list(row) do
    length(row) == expected_dim and Enum.all?(row, &is_number/1)
  end

  defp valid_feature_row?(_row, _expected_dim), do: false

  defp feature_row_error(row, expected_dim, index) when is_list(row) do
    if length(row) == expected_dim do
      {:error, {:invalid_feature_value, index}}
    else
      {:error, {:feature_dim_mismatch, expected_dim, length(row)}}
    end
  end

  defp feature_row_error(_row, _expected_dim, index),
    do: {:error, {:invalid_feature_row, index}}

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

  defp training_options(opts) do
    Options.validate(opts,
      hidden_dim: @default_hidden_dim,
      batch_size: @default_batch_size,
      epochs: @default_epochs,
      learning_rate: @default_learning_rate
    )
  end

  defp normalized_opts(opts, values) do
    opts
    |> Keyword.put(:hidden_dim, values.hidden_dim)
    |> Keyword.put(:batch_size, values.batch_size)
    |> Keyword.put(:epochs, values.epochs)
    |> Keyword.put(:learning_rate, values.learning_rate)
    |> maybe_put_seed(values.seed)
  end

  defp maybe_put_seed(opts, nil), do: Keyword.delete(opts, :seed)
  defp maybe_put_seed(opts, seed), do: Keyword.put(opts, :seed, seed)

  defp validate_binary_labels([]), do: {:error, :empty_dataset}

  defp validate_binary_labels(examples) do
    with :ok <- validate_example_labels(examples, [0, 1, false, true]) do
      classes = examples |> Enum.map(&normalize_binary_label(&1.label)) |> MapSet.new()

      if classes == MapSet.new([0.0, 1.0]) do
        :ok
      else
        {:error, {:invalid_dataset, :requires_positive_and_negative_examples}}
      end
    end
  end

  defp validate_class_labels(labels)
       when is_list(labels) and length(labels) >= 2 do
    if Enum.all?(labels, &is_atom/1) and length(Enum.uniq(labels)) == length(labels) do
      :ok
    else
      {:error, {:invalid_training_option, :labels, labels}}
    end
  end

  defp validate_class_labels(labels),
    do: {:error, {:invalid_training_option, :labels, labels}}

  defp validate_multiclass_labels([], _labels), do: {:error, :empty_dataset}

  defp validate_multiclass_labels(examples, labels) do
    allowed = labels ++ Enum.map(labels, &Atom.to_string/1)
    validate_example_labels(examples, allowed)
  end

  defp validate_example_labels(examples, allowed) do
    case Enum.find_index(examples, fn example ->
           not is_map(example) or Map.get(example, :label) not in allowed
         end) do
      nil -> :ok
      index -> {:error, {:invalid_training_label, index}}
    end
  end

  defp trainer_loop_opts(opts) do
    case Keyword.fetch(opts, :seed) do
      {:ok, seed} when not is_nil(seed) -> [log: 0, seed: seed]
      {:ok, nil} -> [log: 0]
      :error -> [log: 0]
    end
  end
end

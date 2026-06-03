defmodule SpectreKinetic.Classifiers.Internal.AxonRuntime do
  @moduledoc false

  defstruct [
    :classifier,
    :model_dir,
    :metadata,
    :calibration,
    :model,
    :model_state,
    :predict_fn
  ]

  @type t :: %__MODULE__{
          classifier: module(),
          model_dir: binary(),
          metadata: map(),
          calibration: map(),
          model: Axon.t(),
          model_state: term(),
          predict_fn: function()
        }

  @spec load(module(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(classifier, opts) when is_atom(classifier) and is_list(opts) do
    with {:ok, model_dir} <- model_dir(opts),
         {:ok, metadata} <- read_json(Path.join(model_dir, "metadata.json")),
         :ok <- validate_metadata(classifier, metadata),
         {:ok, params_binary} <- File.read(Path.join(model_dir, "params.etf")),
         {:ok, model_state} <- decode_params(params_binary),
         {:ok, calibration} <- read_optional_json(Path.join(model_dir, "calibration.json")) do
      model = classifier.build_model(metadata)
      {_init_fn, predict_fn} = Axon.build(model)

      {:ok,
       %__MODULE__{
         classifier: classifier,
         model_dir: model_dir,
         metadata: metadata,
         calibration: calibration,
         model: model,
         model_state: Axon.ModelState.new(model_state),
         predict_fn: predict_fn
       }}
    end
  end

  @spec predict(t(), Nx.Tensor.t()) :: {:ok, [[float()]]} | {:error, term()}
  def predict(%__MODULE__{} = runtime, %Nx.Tensor{} = features) do
    with :ok <- validate_features(runtime, features) do
      output =
        runtime.predict_fn.(runtime.model_state, features)
        |> Nx.backend_transfer()

      {:ok, rows(output)}
    end
  rescue
    error -> {:error, error}
  end

  @spec predict_one(t(), Nx.Tensor.t()) :: {:ok, [float()]} | {:error, term()}
  def predict_one(%__MODULE__{} = runtime, %Nx.Tensor{} = features) do
    with {:ok, [row]} <- predict(runtime, features), do: {:ok, row}
  end

  @spec feature_dim(t() | map()) :: pos_integer()
  def feature_dim(%__MODULE__{metadata: metadata}), do: feature_dim(metadata)
  def feature_dim(metadata) when is_map(metadata), do: Map.fetch!(metadata, "feature_dim")

  @spec labels(t() | map()) :: [atom()]
  def labels(%__MODULE__{metadata: metadata}), do: labels(metadata)

  def labels(metadata) when is_map(metadata) do
    metadata
    |> Map.get("labels", [])
    |> Enum.map(&String.to_existing_atom/1)
  end

  defp model_dir(opts) do
    case Keyword.get(opts, :model_dir) || Keyword.get(opts, :classifier_model_dir) do
      path when is_binary(path) -> {:ok, path}
      nil -> {:error, {:missing_option, :model_dir}}
    end
  end

  defp read_json(path) do
    with {:ok, json} <- File.read(path) do
      Jason.decode(json)
    end
  end

  defp read_optional_json(path) do
    case File.read(path) do
      {:ok, json} -> Jason.decode(json)
      {:error, :enoent} -> {:ok, %{}}
      {:error, _reason} = error -> error
    end
  end

  defp decode_params(binary) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    error -> {:error, {:invalid_params, error}}
  end

  defp validate_metadata(classifier, metadata) do
    cond do
      not is_integer(metadata["feature_dim"]) or metadata["feature_dim"] <= 0 ->
        {:error, {:invalid_metadata, :feature_dim}}

      Map.has_key?(metadata, "classifier") and
          metadata["classifier"] != classifier.classifier_id() ->
        {:error, {:classifier_mismatch, metadata["classifier"], classifier.classifier_id()}}

      true ->
        :ok
    end
  end

  defp validate_features(runtime, features) do
    expected_dim = feature_dim(runtime)
    validate_feature_shape(Nx.shape(features), expected_dim)
  end

  defp validate_feature_shape({_rows, expected_dim}, expected_dim), do: :ok

  defp validate_feature_shape({_rows, dim}, expected_dim) do
    {:error, {:feature_dim_mismatch, expected_dim, dim}}
  end

  defp validate_feature_shape(shape, _expected_dim), do: {:error, {:invalid_feature_shape, shape}}

  defp rows(%Nx.Tensor{} = output) do
    output
    |> Nx.shape()
    |> rows_for_shape(output)
  end

  defp rows_for_shape({_rows, 1}, output), do: scalar_rows(output)

  defp rows_for_shape({_rows, cols}, output) do
    output
    |> Nx.to_flat_list()
    |> Enum.map(&normalize_number/1)
    |> Enum.chunk_every(cols)
  end

  defp rows_for_shape({_rows}, output), do: scalar_rows(output)

  defp scalar_rows(output) do
    output
    |> Nx.to_flat_list()
    |> Enum.map(&[normalize_number(&1)])
  end

  defp normalize_number(value) when is_number(value) do
    value * 1.0
  end
end

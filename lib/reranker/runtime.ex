defmodule SpectreKinetic.Reranker.Runtime do
  @moduledoc """
  Optional ONNX reranker runtime used for bounded tool-selection fallback.

  Models with more than one output class must declare `:score_index`; Kinetic
  will not guess which class represents relevance. Raw logits can be converted
  with `score_transform: :sigmoid` or `:softmax`.
  """

  alias SpectreKinetic.ONNX

  require Logger

  @score_transforms [:identity, :sigmoid, :softmax]

  defstruct [:model, :tokenizer, :max_length, :score_index, score_transform: :identity]

  @type input_pair :: {binary(), binary()}

  @type runtime_t :: %__MODULE__{
          model: term(),
          tokenizer: term(),
          max_length: pos_integer(),
          score_index: non_neg_integer() | nil,
          score_transform: :identity | :sigmoid | :softmax
        }

  @doc """
  Loads a reranker runtime from a model directory containing `model.onnx`
  and `tokenizer.json`.
  """
  @spec load(keyword()) :: {:ok, runtime_t()} | {:error, term()}
  def load(opts) do
    with {:ok, model_dir} <- fetch_model_dir(opts),
         {:ok, max_length} <- positive_integer_option(opts, :max_length, 512),
         {:ok, score_index} <- score_index_option(opts),
         {:ok, score_transform} <- score_transform_option(opts) do
      load_files(model_dir, max_length, score_index, score_transform)
    end
  end

  defp load_files(model_dir, max_length, score_index, score_transform) do
    model_path = Path.join(model_dir, "model.onnx")
    tokenizer_path = Path.join(model_dir, "tokenizer.json")

    with {:ok, tokenizer} <- ONNX.load_tokenizer(tokenizer_path, max_length),
         {:ok, model} <- ONNX.load_model(model_path) do
      Logger.info("RerankerRuntime ready: model=#{model_path} max_length=#{max_length}")

      {:ok,
       %__MODULE__{
         model: model,
         tokenizer: tokenizer,
         max_length: max_length,
         score_index: score_index,
         score_transform: score_transform
       }}
    end
  end

  @doc """
  Scores one `(query, tool_card)` pair.
  """
  @spec score(runtime_t(), binary(), binary()) :: {:ok, float()} | {:error, term()}
  def score(%__MODULE__{} = runtime, query, tool_card) do
    with {:ok, [score]} <- score_batch(runtime, [{query, tool_card}]) do
      {:ok, score}
    end
  end

  @doc """
  Scores multiple `(query, tool_card)` pairs and returns a score per pair.
  """
  @spec score_batch(runtime_t(), [input_pair()]) :: {:ok, [float()]} | {:error, term()}
  def score_batch(%__MODULE__{}, []), do: {:ok, []}

  def score_batch(%__MODULE__{} = runtime, pairs) when is_list(pairs) do
    encodings = encode_pairs!(runtime.tokenizer, pairs)
    inputs = ONNX.input_tensors(encodings)

    runtime.model
    |> Ortex.run(inputs)
    |> decode_scores(
      score_index: runtime.score_index,
      score_transform: runtime.score_transform
    )
  rescue
    error ->
      {:error, {:reranker_failed, Exception.message(error)}}
  end

  @doc false
  @spec decode_scores(tuple() | Nx.Tensor.t(), keyword()) ::
          {:ok, [float()]} | {:error, term()}
  def decode_scores(outputs, opts \\ []) do
    with {:ok, tensor} <- score_tensor(outputs),
         {:ok, rows} <- score_rows(tensor),
         {:ok, score_index} <- score_index_option(opts),
         {:ok, score_transform} <- score_transform_option(opts) do
      select_scores(rows, score_index, score_transform)
    end
  rescue
    error -> {:error, {:invalid_reranker_output, Exception.message(error)}}
  end

  @spec encode_pairs!(term(), [input_pair()]) :: [term()]
  defp encode_pairs!(tokenizer, pairs) do
    Enum.map(pairs, &encode_pair!(tokenizer, &1))
  end

  @spec encode_pair!(term(), input_pair()) :: term()
  defp encode_pair!(tokenizer, {query, tool_card}) do
    {:ok, encoding} = Tokenizers.Tokenizer.encode(tokenizer, {query, tool_card})
    encoding
  end

  defp score_tensor({%Nx.Tensor{} = tensor}), do: score_tensor(tensor)

  defp score_tensor(outputs) when is_tuple(outputs),
    do: {:error, {:ambiguous_reranker_outputs, tuple_size(outputs)}}

  defp score_tensor(%Nx.Tensor{} = tensor), do: {:ok, Nx.backend_transfer(tensor)}
  defp score_tensor(_outputs), do: {:error, :invalid_reranker_output}

  defp score_rows(tensor) do
    values = tensor |> Nx.to_flat_list() |> Enum.map(&ONNX.normalize_number/1)

    case Nx.shape(tensor) do
      {batch} when batch == length(values) -> {:ok, Enum.map(values, &[&1])}
      {batch, 1} when batch == length(values) -> {:ok, Enum.map(values, &[&1])}
      {batch, classes} when batch * classes == length(values) ->
        {:ok, Enum.chunk_every(values, classes)}

      shape ->
        {:error, {:unsupported_reranker_output_shape, shape}}
    end
  end

  defp select_scores([], _score_index, _score_transform), do: {:ok, []}

  defp select_scores([row | _] = rows, score_index, score_transform) do
    class_count = length(row)

    with {:ok, index} <- resolve_score_index(score_index, class_count),
         :ok <- validate_transform(score_transform, class_count) do
      scores =
        Enum.map(rows, fn values ->
          values
          |> transform_row(score_transform)
          |> Enum.fetch!(index)
        end)

      {:ok, scores}
    end
  end

  defp resolve_score_index(nil, 1), do: {:ok, 0}

  defp resolve_score_index(nil, class_count),
    do: {:error, {:score_index_required, class_count}}

  defp resolve_score_index(index, class_count)
       when is_integer(index) and index >= 0 and index < class_count,
       do: {:ok, index}

  defp resolve_score_index(index, class_count),
    do: {:error, {:score_index_out_of_range, index, class_count}}

  defp validate_transform(:softmax, 1), do: {:error, {:invalid_score_transform, :softmax, 1}}
  defp validate_transform(_transform, _class_count), do: :ok

  defp transform_row(values, :identity), do: values
  defp transform_row(values, :sigmoid), do: Enum.map(values, &sigmoid/1)

  defp transform_row(values, :softmax) do
    max_value = Enum.max(values)
    exponentials = Enum.map(values, &:math.exp(&1 - max_value))
    total = Enum.sum(exponentials)
    Enum.map(exponentials, &(&1 / total))
  end

  defp sigmoid(value) when value >= 0.0, do: 1.0 / (1.0 + :math.exp(-value))

  defp sigmoid(value) do
    exponential = :math.exp(value)
    exponential / (1.0 + exponential)
  end

  defp fetch_model_dir(opts) do
    case Keyword.fetch(opts, :fallback_model_dir) do
      {:ok, model_dir} when is_binary(model_dir) and model_dir != "" -> {:ok, model_dir}
      {:ok, _invalid} -> {:error, {:invalid_option, :fallback_model_dir}}
      :error -> {:error, {:missing_option, :fallback_model_dir}}
    end
  end

  defp positive_integer_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value -> {:error, {:invalid_option, key, value}}
    end
  end

  defp score_index_option(opts) do
    case Keyword.get(opts, :score_index) do
      nil -> {:ok, nil}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value -> {:error, {:invalid_option, :score_index, value}}
    end
  end

  defp score_transform_option(opts) do
    case Keyword.get(opts, :score_transform, :identity) do
      value when value in @score_transforms -> {:ok, value}
      value -> {:error, {:invalid_option, :score_transform, value}}
    end
  end
end

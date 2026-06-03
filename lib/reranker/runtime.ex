defmodule SpectreKinetic.Reranker.Runtime do
  @moduledoc """
  Optional ONNX reranker runtime used for bounded tool-selection fallback.
  """

  alias SpectreKinetic.ONNX

  require Logger

  defstruct [:model, :tokenizer, :max_length]

  @type input_pair :: {binary(), binary()}

  @type runtime_t :: %__MODULE__{
          model: term(),
          tokenizer: term(),
          max_length: pos_integer()
        }

  @doc """
  Loads a reranker runtime from a model directory containing `model.onnx`
  and `tokenizer.json`.
  """
  @spec load(keyword()) :: {:ok, runtime_t()} | {:error, term()}
  def load(opts) do
    model_dir = Keyword.fetch!(opts, :fallback_model_dir)
    max_length = Keyword.get(opts, :max_length, 512)

    model_path = Path.join(model_dir, "model.onnx")
    tokenizer_path = Path.join(model_dir, "tokenizer.json")

    with {:ok, tokenizer} <- ONNX.load_tokenizer(tokenizer_path, max_length),
         {:ok, model} <- ONNX.load_model(model_path) do
      Logger.info("RerankerRuntime ready: model=#{model_path} max_length=#{max_length}")
      {:ok, %__MODULE__{model: model, tokenizer: tokenizer, max_length: max_length}}
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
  def score_batch(%__MODULE__{} = runtime, pairs) when is_list(pairs) do
    encodings = encode_pairs!(runtime.tokenizer, pairs)
    inputs = ONNX.input_tensors(encodings)

    {:ok, runtime.model |> Ortex.run(inputs) |> output_scores()}
  rescue
    error ->
      {:error, {:reranker_failed, Exception.message(error)}}
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

  @spec output_scores(tuple() | Nx.Tensor.t()) :: [float()]
  defp output_scores(outputs) do
    outputs
    |> to_score_tensor()
    |> Nx.to_flat_list()
    |> Enum.map(&ONNX.normalize_number/1)
  end

  @spec to_score_tensor(tuple() | Nx.Tensor.t()) :: Nx.Tensor.t()
  defp to_score_tensor({tensor}), do: to_score_tensor(tensor)

  defp to_score_tensor(tensor) do
    tensor = Nx.backend_transfer(tensor)
    score_tensor_for_shape(tensor, Nx.shape(tensor))
  end

  defp score_tensor_for_shape(tensor, {batch, 1}), do: Nx.reshape(tensor, {batch})
  defp score_tensor_for_shape(tensor, {_batch}), do: tensor
  defp score_tensor_for_shape(tensor, {_batch, _classes}), do: tensor[[.., 0]]
  defp score_tensor_for_shape(tensor, _shape), do: Nx.reshape(tensor, {Nx.size(tensor)})
end

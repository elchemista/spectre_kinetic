defmodule SpectreKinetic.Reranker.Runtime do
  @moduledoc """
  Optional ONNX reranker runtime used for bounded tool-selection fallback.
  """

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

    with {:ok, tokenizer} <- load_tokenizer(tokenizer_path, max_length),
         {:ok, model} <- load_model(model_path) do
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
    encodings =
      Enum.map(pairs, fn {query, tool_card} ->
        {:ok, encoding} = Tokenizers.Tokenizer.encode(runtime.tokenizer, {query, tool_card})
        encoding
      end)

    {input_ids, attention_mask, token_type_ids} = build_input_tensors(encodings)
    outputs = Ortex.run(runtime.model, {input_ids, attention_mask, token_type_ids})

    {:ok, outputs |> to_score_tensor() |> Nx.to_flat_list() |> Enum.map(&normalize_number/1)}
  rescue
    error ->
      {:error, {:reranker_failed, Exception.message(error)}}
  end

  defp load_tokenizer(path, max_length) do
    case Tokenizers.Tokenizer.from_file(path) do
      {:ok, tokenizer} ->
        tokenizer = Tokenizers.Tokenizer.set_truncation(tokenizer, max_length: max_length)
        {:ok, tokenizer}

      {:error, reason} ->
        {:error, {:tokenizer_load_failed, reason}}
    end
  end

  defp load_model(path) do
    {:ok, Ortex.load(path)}
  rescue
    error -> {:error, {:model_load_failed, Exception.message(error)}}
  end

  defp build_input_tensors(encodings) do
    ids = Enum.map(encodings, &Tokenizers.Encoding.get_ids/1)
    masks = Enum.map(encodings, &Tokenizers.Encoding.get_attention_mask/1)
    type_ids = Enum.map(encodings, &Tokenizers.Encoding.get_type_ids/1)

    {
      Nx.tensor(ids, type: :s64),
      Nx.tensor(masks, type: :s64),
      Nx.tensor(type_ids, type: :s64)
    }
  end

  defp to_score_tensor({tensor}), do: to_score_tensor(tensor)

  defp to_score_tensor(tensor) do
    tensor = Nx.backend_transfer(tensor)

    case Nx.shape(tensor) do
      {batch, 1} -> Nx.reshape(tensor, {batch})
      {_batch} -> tensor
      {_batch, _classes} -> tensor[[.., 0]]
      _ -> Nx.reshape(tensor, {Nx.size(tensor)})
    end
  end

  defp normalize_number(value) when is_float(value), do: value
  defp normalize_number(value) when is_integer(value), do: value / 1
end

defmodule SpectreKinetic.ONNX do
  @moduledoc false

  @doc false
  @spec load_model(binary()) :: {:ok, term()} | {:error, term()}
  def load_model(path) do
    {:ok, Ortex.load(path)}
  rescue
    error -> {:error, {:model_load_failed, Exception.message(error)}}
  end

  @doc false
  @spec load_tokenizer(binary(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def load_tokenizer(path, max_length) do
    case Tokenizers.Tokenizer.from_file(path) do
      {:ok, tokenizer} ->
        {:ok, Tokenizers.Tokenizer.set_truncation(tokenizer, max_length: max_length)}

      {:error, reason} ->
        {:error, {:tokenizer_load_failed, reason}}
    end
  end

  @doc false
  @spec input_tensors([term()]) :: {Nx.Tensor.t(), Nx.Tensor.t(), Nx.Tensor.t()}
  def input_tensors(encodings) when is_list(encodings) do
    {ids_tensor(encodings), attention_mask_tensor(encodings), type_ids_tensor(encodings)}
  end

  @spec ids_tensor([term()]) :: Nx.Tensor.t()
  defp ids_tensor(encodings), do: encoding_tensor(encodings, &Tokenizers.Encoding.get_ids/1)

  @spec attention_mask_tensor([term()]) :: Nx.Tensor.t()
  defp attention_mask_tensor(encodings) do
    encoding_tensor(encodings, &Tokenizers.Encoding.get_attention_mask/1)
  end

  @spec type_ids_tensor([term()]) :: Nx.Tensor.t()
  defp type_ids_tensor(encodings),
    do: encoding_tensor(encodings, &Tokenizers.Encoding.get_type_ids/1)

  @spec encoding_tensor([term()], (term() -> [integer()])) :: Nx.Tensor.t()
  defp encoding_tensor(encodings, extractor) do
    encodings
    |> Enum.map(extractor)
    |> Nx.tensor(type: :s64)
  end

  @doc false
  @spec first_output(tuple()) :: Nx.Tensor.t()
  def first_output(outputs) when is_tuple(outputs), do: elem(outputs, 0)

  @doc false
  @spec normalize_number(number()) :: float()
  def normalize_number(value) when is_float(value), do: value
  def normalize_number(value) when is_integer(value), do: value / 1
end

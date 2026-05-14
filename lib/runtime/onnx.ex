defmodule SpectreKinetic.ONNX do
  @moduledoc false

  @spec load_model(binary()) :: {:ok, term()} | {:error, term()}
  def load_model(path) do
    {:ok, Ortex.load(path)}
  rescue
    error -> {:error, {:model_load_failed, Exception.message(error)}}
  end

  @spec load_tokenizer(binary(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def load_tokenizer(path, max_length) do
    case Tokenizers.Tokenizer.from_file(path) do
      {:ok, tokenizer} ->
        {:ok, Tokenizers.Tokenizer.set_truncation(tokenizer, max_length: max_length)}

      {:error, reason} ->
        {:error, {:tokenizer_load_failed, reason}}
    end
  end

  @spec input_tensors([term()]) :: {Nx.Tensor.t(), Nx.Tensor.t(), Nx.Tensor.t()}
  def input_tensors(encodings) when is_list(encodings) do
    {
      encodings |> Enum.map(&Tokenizers.Encoding.get_ids/1) |> Nx.tensor(type: :s64),
      encodings |> Enum.map(&Tokenizers.Encoding.get_attention_mask/1) |> Nx.tensor(type: :s64),
      encodings |> Enum.map(&Tokenizers.Encoding.get_type_ids/1) |> Nx.tensor(type: :s64)
    }
  end

  @spec first_output(tuple()) :: Nx.Tensor.t()
  def first_output(outputs) when is_tuple(outputs), do: elem(outputs, 0)

  @spec normalize_number(number()) :: float()
  def normalize_number(value) when is_float(value), do: value
  def normalize_number(value) when is_integer(value), do: value / 1
end

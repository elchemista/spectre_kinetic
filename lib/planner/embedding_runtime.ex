defmodule SpectreKinetic.Planner.EmbeddingRuntime do
  @moduledoc """
  Owns ONNX encoder sessions and tokenizers for text embedding.

  Loads a `model.onnx` and `tokenizer.json` from an encoder model directory
  (e.g. `BAAI/bge-small-en-v1.5`), tokenizes input text, runs inference, and
  returns L2-normalized CLS-token embeddings as Nx tensors.
  """

  use GenServer

  require Logger

  defstruct [:model, :tokenizer, :max_length, :dim]

  @type runtime_t :: %__MODULE__{
          model: term(),
          tokenizer: term(),
          max_length: pos_integer(),
          dim: pos_integer()
        }

  @type t :: GenServer.server() | runtime_t()

  @doc """
  Loads an embedding runtime without starting a server wrapper.
  """
  @spec load(keyword()) :: {:ok, runtime_t()} | {:error, term()}
  def load(opts) do
    model_dir = Keyword.fetch!(opts, :encoder_model_dir)
    max_length = Keyword.get(opts, :max_length, 512)

    model_path = Path.join(model_dir, "model.onnx")
    tokenizer_path = Path.join(model_dir, "tokenizer.json")

    with {:ok, tokenizer} <- load_tokenizer(tokenizer_path, max_length),
         {:ok, model} <- load_model(model_path) do
      dim = detect_dim(model, tokenizer)

      Logger.info(
        "EmbeddingRuntime ready: model=#{model_path} dim=#{dim} max_length=#{max_length}"
      )

      {:ok,
       %__MODULE__{
         model: model,
         tokenizer: tokenizer,
         max_length: max_length,
         dim: dim
       }}
    end
  end

  @doc """
  Starts the embedding runtime.

  ## Options

    * `:encoder_model_dir` — path to directory containing `model.onnx` and `tokenizer.json`
    * `:name` — process name (default `__MODULE__`)
    * `:max_length` — max token sequence length (default 512)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Embeds a single text string and returns an `{1, dim}` normalized tensor.
  """
  @spec embed(t(), binary()) :: {:ok, Nx.Tensor.t()} | {:error, term()}
  def embed(runtime \\ __MODULE__, text)

  def embed(%__MODULE__{} = runtime, text) do
    case embed_batch(runtime, [text]) do
      {:ok, matrix} -> {:ok, matrix[0]}
      error -> error
    end
  end

  def embed(runtime, text) do
    case embed_batch(runtime, [text]) do
      {:ok, matrix} -> {:ok, matrix[0]}
      error -> error
    end
  end

  @doc """
  Embeds a batch of text strings and returns an `{n, dim}` normalized tensor.
  """
  @spec embed_batch(t(), [binary()]) :: {:ok, Nx.Tensor.t()} | {:error, term()}
  def embed_batch(runtime \\ __MODULE__, texts)

  def embed_batch(%__MODULE__{} = runtime, texts) when is_list(texts) do
    do_embed_batch(runtime, texts)
  end

  def embed_batch(runtime, texts) when is_list(texts) do
    GenServer.call(runtime, {:embed_batch, texts}, :infinity)
  end

  @doc """
  Returns the embedding dimension of the loaded model.
  """
  @spec dim(t()) :: pos_integer()
  def dim(runtime \\ __MODULE__)

  def dim(%__MODULE__{} = runtime), do: runtime.dim

  def dim(runtime) do
    GenServer.call(runtime, :dim)
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    case load(opts) do
      {:ok, runtime} -> {:ok, runtime}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:embed_batch, texts}, _from, state) do
    result = do_embed_batch(state, texts)
    {:reply, result, state}
  end

  def handle_call(:dim, _from, state) do
    {:reply, state.dim, state}
  end

  # --- Internal helpers ---

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
    model = Ortex.load(path)
    {:ok, model}
  rescue
    error -> {:error, {:model_load_failed, Exception.message(error)}}
  end

  defp detect_dim(model, tokenizer) do
    # Run a dummy forward pass to detect output dimension
    {:ok, encoding} = Tokenizers.Tokenizer.encode(tokenizer, "hello")
    ids = Tokenizers.Encoding.get_ids(encoding)
    mask = Tokenizers.Encoding.get_attention_mask(encoding)
    type_ids = Tokenizers.Encoding.get_type_ids(encoding)

    input_ids = Nx.tensor([ids], type: :s64)
    attention_mask = Nx.tensor([mask], type: :s64)
    token_type_ids = Nx.tensor([type_ids], type: :s64)

    {output} = Ortex.run(model, {input_ids, attention_mask, token_type_ids})
    output_nx = Nx.backend_transfer(output)

    # Output shape is {1, seq_len, dim} — take the last axis
    {_batch, _seq, dim} = Nx.shape(output_nx)
    dim
  end

  defp do_embed_batch(state, texts) do
    {:ok, batch_encoding} = Tokenizers.Tokenizer.encode_batch(state.tokenizer, texts)

    {input_ids, attention_mask, token_type_ids} = build_input_tensors(batch_encoding)

    {output} = Ortex.run(state.model, {input_ids, attention_mask, token_type_ids})

    embeddings =
      output
      |> Nx.backend_transfer()
      |> extract_cls_embeddings()
      |> l2_normalize()

    {:ok, embeddings}
  rescue
    error -> {:error, {:embed_failed, Exception.message(error)}}
  end

  defp build_input_tensors(encodings) when is_list(encodings) do
    ids = Enum.map(encodings, &Tokenizers.Encoding.get_ids/1)
    masks = Enum.map(encodings, &Tokenizers.Encoding.get_attention_mask/1)
    type_ids = Enum.map(encodings, &Tokenizers.Encoding.get_type_ids/1)

    {
      Nx.tensor(ids, type: :s64),
      Nx.tensor(masks, type: :s64),
      Nx.tensor(type_ids, type: :s64)
    }
  end

  defp extract_cls_embeddings(output) do
    # output is {batch, seq_len, dim} — CLS token is at position 0
    case Nx.shape(output) do
      {_batch, _seq, _dim} ->
        output[[.., 0, ..]]

      {_batch, _dim} ->
        # Some models output pooled embeddings directly
        output
    end
  end

  defp l2_normalize(tensor) do
    norms = Nx.LinAlg.norm(tensor, ord: 2, axes: [-1], keep_axes: true)
    # Avoid division by zero
    safe_norms = Nx.max(norms, 1.0e-12)
    Nx.divide(tensor, safe_norms)
  end
end

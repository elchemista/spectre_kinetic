defmodule SpectreKinetic.Planner.Compiler do
  @moduledoc """
  Offline compiler that produces an Elixir-native registry bundle.

  Takes a `registry.json` and an encoder model directory, and produces a
  binary ETF file containing:

    * normalized action definitions
    * ordered action IDs
    * precomputed tool-card embeddings as Nx tensors

  This bundle is loaded at runtime by `RegistryStore` so that production
  boots do not need network access or model inference at startup.
  """

  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Planner.Registry.ETS

  require Logger

  @doc """
  Compiles a registry bundle from JSON + encoder model.

  ## Options

    * `:registry_json` — path to source registry JSON (required)
    * `:encoder_model_dir` — path to encoder model directory (required)
    * `:output` — output path for the compiled `.etf` bundle (required)
    * `:batch_size` — embedding batch size (default 32)
  """
  @spec compile(keyword()) :: :ok | {:error, term()}
  def compile(opts) do
    with {:ok, registry_json} <- fetch_opt(opts, :registry_json),
         {:ok, encoder_model_dir} <- fetch_opt(opts, :encoder_model_dir),
         {:ok, output_path} <- fetch_opt(opts, :output) do
      batch_size = Keyword.get(opts, :batch_size, 32)

      Logger.info("Compiling registry from #{registry_json}")

      with {:ok, registry} <- ETS.new(registry_json: registry_json),
           {:ok, embedder} <- EmbeddingRuntime.load(encoder_model_dir: encoder_model_dir) do
        try do
          do_compile(registry, embedder, output_path, batch_size)
        after
          ETS.close(registry)
        end
      end
    end
  end

  defp fetch_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp do_compile(registry, embedder, output_path, batch_size) do
    actions = ETS.all_actions(registry)
    cards = ETS.tool_cards(registry)

    Logger.info("Embedding #{length(cards)} tool cards...")

    {action_ids, card_texts} = Enum.unzip(cards)

    tool_embeddings = embed_in_batches(embedder, card_texts, batch_size)

    bundle = %{
      version: 1,
      actions: actions,
      action_ids: action_ids,
      tool_embeddings: split_embeddings(tool_embeddings),
      embedding_dim: EmbeddingRuntime.dim(embedder),
      compiled_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    binary = :erlang.term_to_binary(bundle, [:compressed])
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, binary)

    Logger.info("Compiled registry written to #{output_path} (#{byte_size(binary)} bytes)")
    :ok
  end

  defp embed_in_batches(embedder, texts, batch_size) do
    texts
    |> Enum.chunk_every(batch_size)
    |> Enum.map(fn batch ->
      {:ok, embeddings} = EmbeddingRuntime.embed_batch(embedder, batch)
      embeddings
    end)
    |> Nx.concatenate()
  end

  defp split_embeddings(matrix) do
    # Split {n, dim} matrix into a list of {dim} tensors for ETF storage
    {n, _dim} = Nx.shape(matrix)

    for i <- 0..(n - 1) do
      Nx.backend_transfer(matrix[i])
    end
  end
end

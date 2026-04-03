defmodule SpectreKinetic.Reranker.FeatureBuilder do
  @moduledoc """
  Builds numeric reranker features from encoder embeddings.
  """

  alias SpectreKinetic.Planner.EmbeddingRuntime

  @type example :: %{required(:query) => binary(), required(:tool_card) => binary()}

  @doc """
  Builds a dense feature matrix for reranker training.

  Each row is `[q, t, abs(q - t), q * t]`.
  """
  @spec build_matrix(term(), [example()], keyword()) ::
          {:ok, Nx.Tensor.t()} | {:error, term()}
  def build_matrix(embedder, examples, opts \\ []) when is_list(examples) do
    embedding_module = Keyword.get(opts, :embedding_module, EmbeddingRuntime)
    queries = Enum.map(examples, & &1.query)
    tool_cards = Enum.map(examples, & &1.tool_card)

    with {:ok, query_matrix} <- embedding_module.embed_batch(embedder, queries),
         {:ok, tool_matrix} <- embedding_module.embed_batch(embedder, tool_cards) do
      {:ok, pair_features(query_matrix, tool_matrix)}
    end
  end

  @doc """
  Returns the feature dimension produced for one encoder dimension.
  """
  @spec feature_dim(pos_integer()) :: pos_integer()
  def feature_dim(embedding_dim), do: embedding_dim * 4

  @spec pair_features(Nx.Tensor.t(), Nx.Tensor.t()) :: Nx.Tensor.t()
  defp pair_features(query_matrix, tool_matrix) do
    diff = query_matrix |> Nx.subtract(tool_matrix) |> Nx.abs()
    product = Nx.multiply(query_matrix, tool_matrix)
    Nx.concatenate([query_matrix, tool_matrix, diff, product], axis: 1)
  end
end

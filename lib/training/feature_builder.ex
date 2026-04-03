defmodule SpectreKinetic.Training.FeatureBuilder do
  @moduledoc """
  Builds numeric reranker features from encoder embeddings.
  """

  alias SpectreKinetic.Planner.EmbeddingRuntime

  @type example :: %{required(:query) => binary(), required(:tool_card) => binary()}

  @doc """
  Builds a dense feature matrix for reranker training.

  Each row is `[q, t, abs(q - t), q * t]`.
  """
  @spec build_matrix(EmbeddingRuntime.runtime_t(), [example()]) ::
          {:ok, Nx.Tensor.t()} | {:error, term()}
  def build_matrix(embedder, examples) when is_list(examples) do
    queries = Enum.map(examples, & &1.query)
    tool_cards = Enum.map(examples, & &1.tool_card)

    with {:ok, query_matrix} <- EmbeddingRuntime.embed_batch(embedder, queries),
         {:ok, tool_matrix} <- EmbeddingRuntime.embed_batch(embedder, tool_cards) do
      {:ok, pair_features(query_matrix, tool_matrix)}
    end
  end

  @doc """
  Returns the feature dimension produced for one encoder dimension.
  """
  @spec feature_dim(pos_integer()) :: pos_integer()
  def feature_dim(embedding_dim), do: embedding_dim * 4

  defp pair_features(query_matrix, tool_matrix) do
    diff = Nx.abs(query_matrix - tool_matrix)
    product = query_matrix * tool_matrix
    Nx.concatenate([query_matrix, tool_matrix, diff, product], axis: 1)
  end
end

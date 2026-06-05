defmodule SpectreKinetic.Planner.Scorer do
  @moduledoc """
  Nx-based scoring for tool retrieval and ranking.

  Combines embedding cosine similarity with lexical overlap, alias overlap,
  and action-shape heuristics to produce a final fused score.
  """

  @score_weights [
    embedding: 0.55,
    lexical: 0.20,
    arg_alias: 0.15,
    shape: 0.10
  ]

  @doc """
  Computes cosine similarity between a query vector `{1, dim}` or `{dim}`
  and a matrix of candidates `{n, dim}`. Returns a `{n}` tensor of scores.
  """
  @spec cosine_similarity(Nx.Tensor.t(), Nx.Tensor.t()) :: Nx.Tensor.t()
  def cosine_similarity(query, matrix) do
    query = Nx.reshape(query, {1, :auto})
    # Both are assumed L2-normalized, so dot product = cosine similarity
    Nx.dot(matrix, Nx.transpose(query)) |> Nx.squeeze(axes: [1])
  end

  @doc """
  Returns the top-k indices and scores from a `{n}` score tensor.
  """
  @spec top_k(Nx.Tensor.t(), pos_integer()) :: [{non_neg_integer(), float()}]
  def top_k(scores, k) do
    n = Nx.size(scores)
    k = min(k, n)

    scores
    |> Nx.to_flat_list()
    |> Enum.with_index()
    |> Enum.sort_by(fn {score, _idx} -> -score end)
    |> Enum.take(k)
    |> Enum.map(fn {score, idx} -> {idx, score} end)
  end

  @doc """
  Computes a lexical overlap score between a query and a tool card.
  Returns a float in [0, 1].
  """
  @spec lexical_overlap(binary(), binary()) :: float()
  def lexical_overlap(query, tool_card) do
    query_tokens = tokenize_for_overlap(query)
    card_tokens = tokenize_for_overlap(tool_card)

    case MapSet.size(query_tokens) do
      0 ->
        0.0

      query_size ->
        overlap = MapSet.intersection(query_tokens, card_tokens) |> MapSet.size()
        overlap / query_size
    end
  end

  @doc """
  Computes an alias overlap score: how many of the parsed AL slot keys
  match known arg names or aliases for this tool.
  Returns a float in [0, 1].
  """
  @spec alias_overlap(map(), map()) :: float()
  def alias_overlap(parsed_args, action) do
    arg_defs = action["args"] || []

    case map_size(parsed_args) do
      0 ->
        0.0

      n_slots ->
        known =
          arg_defs
          |> Enum.flat_map(&arg_names/1)
          |> Enum.map(&String.downcase/1)
          |> MapSet.new()

        matched =
          parsed_args
          |> Map.keys()
          |> Enum.count(fn key -> MapSet.member?(known, String.downcase(key)) end)

        matched / n_slots
    end
  end

  @doc """
  Computes an action-shape heuristic score: how well the number of provided
  args matches the expected arity and required arg count.
  """
  @spec shape_score(map(), map()) :: float()
  def shape_score(parsed_args, action) do
    n_provided = map_size(parsed_args)
    n_required = action["args"] |> List.wrap() |> Enum.count(& &1["required"])
    n_total = action["args"] |> List.wrap() |> length()

    shape_score_for_counts(n_provided, n_required, n_total)
  end

  defp arg_names(arg) do
    aliases = arg["aliases"] || []
    [arg["name"] | aliases]
  end

  defp shape_score_for_counts(0, _n_required, 0), do: 1.0
  defp shape_score_for_counts(_n_provided, _n_required, 0), do: 0.5

  defp shape_score_for_counts(n_provided, n_required, n_total)
       when n_provided >= n_required and n_provided <= n_total,
       do: 1.0

  defp shape_score_for_counts(n_provided, n_required, _n_total)
       when n_provided >= n_required,
       do: 0.8

  defp shape_score_for_counts(n_provided, n_required, _n_total) do
    max(0.0, 1.0 - (n_required - n_provided) / max(n_required, 1))
  end

  @doc """
  Combines individual scores into a final fused score.

  ## Weights

    * `:embedding` — cosine similarity weight (default 0.55)
    * `:lexical` — lexical overlap weight (default 0.20)
    * `:arg_alias` — argument alias overlap weight (default 0.15)
    * `:shape` — shape heuristic weight (default 0.10)
  """
  @spec fuse_scores(map()) :: float()
  def fuse_scores(scores) do
    Enum.reduce(@score_weights, 0.0, fn {key, weight}, acc ->
      acc + weight * Map.get(scores, key, 0.0)
    end)
  end

  defp tokenize_for_overlap(text) do
    ~r/[A-Z0-9_]+/
    |> Regex.scan(String.upcase(text))
    |> List.flatten()
    |> Enum.filter(&(String.length(&1) >= 2))
    |> MapSet.new()
  end
end

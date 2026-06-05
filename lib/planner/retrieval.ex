defmodule SpectreKinetic.Planner.Retrieval do
  @moduledoc false

  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Planner.Registry
  alias SpectreKinetic.Planner.RegistryStore
  alias SpectreKinetic.Planner.Scorer
  alias SpectreKinetic.RuntimeConfig
  alias SpectreKinetic.Telemetry

  @retrieval_fallback_event [:spectre_kinetic, :planner, :retrieval, :fallback]

  @type opts :: %{
          registry_module: module(),
          registry: GenServer.server(),
          embedder: GenServer.server() | nil,
          top_k: pos_integer()
        }

  @spec options(map()) :: opts()
  def options(opts) do
    %{
      registry_module: Map.get(opts, :registry_module, RegistryStore),
      registry: Map.get(opts, :registry, RegistryStore),
      embedder: Map.get(opts, :embedder),
      top_k: plan_option(opts, :top_k)
    }
  end

  @spec retrieve(binary(), opts()) :: {:ok, [map()]} | {:error, term()}
  def retrieve(al_text, %{
        registry_module: registry_module,
        registry: registry,
        embedder: embedder,
        top_k: top_k
      }) do
    case registry_module.embedding_matrix(registry) do
      {matrix, action_ids} ->
        retrieve_embedded(al_text, registry_module, registry, embedder, top_k, matrix, action_ids)

      nil ->
        retrieve_lexical(al_text, registry_module, registry, top_k)
    end
  end

  defp retrieve_lexical(al_text, registry_module, registry, top_k) do
    candidates =
      registry_module.all_actions(registry)
      |> Enum.map(&lexical_candidate(al_text, &1))
      |> Enum.sort_by(& &1.embedding_score, :desc)
      |> Enum.take(top_k)

    {:ok, candidates}
  end

  defp lexical_candidate(al_text, action) do
    card = Registry.build_tool_card(action)
    %{action: action, embedding_score: Scorer.lexical_overlap(al_text, card)}
  end

  defp retrieve_embedded(al_text, registry_module, registry, embedder, top_k, matrix, action_ids) do
    case embed_query(embedder, al_text) do
      {:ok, query_vec} ->
        {:ok,
         embedded_candidates(query_vec, matrix, top_k, action_ids, registry_module, registry)}

      {:error, :embedder_unavailable} ->
        result = retrieve_lexical(al_text, registry_module, registry, top_k)
        emit_lexical_fallback(result, top_k, :embedder_unavailable)
        result

      {:error, _reason} = error ->
        error
    end
  end

  defp embedded_candidates(query_vec, matrix, top_k, action_ids, registry_module, registry) do
    query_vec
    |> Scorer.cosine_similarity(matrix)
    |> Scorer.top_k(top_k)
    |> Enum.map(fn {idx, score} ->
      action_id = Enum.at(action_ids, idx)
      action = registry_module.get_action(registry, action_id)
      %{action: action, embedding_score: score}
    end)
    |> Enum.reject(&is_nil(&1.action))
  end

  defp embed_query(nil, _al_text), do: {:error, :embedder_unavailable}
  defp embed_query(embedder, al_text), do: EmbeddingRuntime.embed(embedder, al_text)

  defp emit_lexical_fallback({:ok, candidates}, top_k, reason) do
    Telemetry.execute(
      @retrieval_fallback_event,
      %{candidate_count: length(candidates), fallback_top_k: top_k},
      %{result: :fallback, reason: reason}
    )
  end

  defp plan_option(opts, key) do
    Map.get(opts, key, Keyword.fetch!(RuntimeConfig.built_in_plan_defaults(), key))
  end
end

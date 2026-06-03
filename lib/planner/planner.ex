defmodule SpectreKinetic.Planner do
  @moduledoc """
  Elixir-native planner pipeline for AL normalization, retrieval, scoring,
  bounded reranker fallback, and deterministic slot mapping.

  The planner is intentionally effect-light. Registry and embedding work comes
  through injected runtime handles, while this module coordinates the pure
  planning stages:

    * normalize AL text and parse provided slots
    * retrieve candidate tools by embedding or lexical fallback
    * score candidates with deterministic features
    * optionally consult a reranker for close or incomplete matches
    * map slots to the selected tool's canonical arguments
  """

  alias SpectreKinetic.Parser
  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Planner.Registry
  alias SpectreKinetic.Planner.RegistryStore
  alias SpectreKinetic.Planner.Runtime, as: PlannerRuntime
  alias SpectreKinetic.Planner.Scorer
  alias SpectreKinetic.Planner.SlotMapper
  alias SpectreKinetic.RuntimeConfig

  @type plan_opts :: %{
          optional(:top_k) => pos_integer(),
          optional(:tool_threshold) => float(),
          optional(:mapping_threshold) => float(),
          optional(:tool_selection_fallback) => :disabled | :reranker,
          optional(:fallback_top_k) => pos_integer(),
          optional(:fallback_margin) => float(),
          optional(:slots) => map(),
          optional(:registry_module) => module(),
          optional(:registry) => GenServer.server(),
          optional(:embedder) => GenServer.server(),
          optional(:reranker_module) => module(),
          optional(:reranker) => term()
        }

  @typep retrieval_opts :: %{
           registry_module: module(),
           registry: GenServer.server(),
           embedder: GenServer.server() | nil,
           top_k: pos_integer()
         }

  @typep selection_opts :: %{
           tool_threshold: float(),
           mapping_threshold: float(),
           tool_selection_fallback: :disabled | :reranker,
           fallback_top_k: pos_integer(),
           fallback_margin: float(),
           reranker_module: module() | nil,
           reranker: term() | nil
         }

  @type plan_result_value ::
          binary()
          | float()
          | map()
          | [binary()]
          | [map()]
          | nil

  @type plan_result :: %{optional(binary()) => plan_result_value()}

  @spec plan(PlannerRuntime.t(), binary(), keyword()) :: {:ok, plan_result()} | {:error, term()}
  def plan(%PlannerRuntime{} = runtime, al_text, opts) do
    plan(al_text, PlannerRuntime.plan_opts(runtime, opts))
  end

  @spec plan(binary(), plan_opts()) :: {:ok, plan_result()} | {:error, term()}
  def plan(al_text, opts \\ %{}) do
    retrieval_opts = retrieval_options(opts)
    selection_opts = selection_options(opts)

    with {:ok, normalized} <- normalize_al(al_text),
         parsed_args <- Parser.args(normalized),
         provided_slots <- Map.get(opts, :slots, parsed_args),
         {:ok, candidates} <-
           retrieve_candidates(normalized, retrieval_opts),
         {:ok, scored} <- score_candidates(normalized, provided_slots, candidates) do
      select_and_map(normalized, scored, provided_slots, selection_opts)
    end
  end

  @spec plan_request(PlannerRuntime.t(), map(), keyword()) ::
          {:ok, plan_result()} | {:error, term()}
  def plan_request(%PlannerRuntime{} = runtime, request, opts) do
    plan_request(request, PlannerRuntime.plan_opts(runtime, opts))
  end

  @spec plan_request(map(), plan_opts()) :: {:ok, plan_result()} | {:error, term()}
  def plan_request(request, opts \\ %{}) do
    request = RuntimeConfig.normalize_request(request)
    al_text = Map.get(request, "al", "")
    slots = Map.get(request, "slots", %{})

    merged_opts =
      opts
      |> Map.put(:slots, slots)
      |> maybe_put(:top_k, Map.get(request, "top_k"))
      |> maybe_put(:tool_threshold, Map.get(request, "tool_threshold"))
      |> maybe_put(:mapping_threshold, Map.get(request, "mapping_threshold"))

    plan(al_text, merged_opts)
  end

  defp normalize_al(al_text) do
    case Parser.normalize(al_text) do
      {:ok, _} = ok -> ok
      {:error, _} -> {:ok, al_text}
    end
  end

  @spec retrieve_candidates(binary(), retrieval_opts()) :: {:ok, [map()]} | {:error, term()}
  defp retrieve_candidates(al_text, %{
         registry_module: registry_module,
         registry: registry,
         embedder: embedder,
         top_k: top_k
       }) do
    case registry_module.embedding_matrix(registry) do
      {matrix, action_ids} ->
        retrieve_embedded_candidates(
          al_text,
          registry_module,
          registry,
          embedder,
          top_k,
          matrix,
          action_ids
        )

      nil ->
        retrieve_lexical_fallback(al_text, registry_module, registry, top_k)
    end
  end

  defp retrieve_lexical_fallback(al_text, registry_module, registry, top_k) do
    candidates =
      registry_module.all_actions(registry)
      |> Enum.map(fn action ->
        card = Registry.build_tool_card(action)
        %{action: action, embedding_score: Scorer.lexical_overlap(al_text, card)}
      end)
      |> Enum.sort_by(& &1.embedding_score, :desc)
      |> Enum.take(top_k)

    {:ok, candidates}
  end

  defp score_candidates(al_text, parsed_args, candidates) do
    scored =
      Enum.map(candidates, fn %{action: action, embedding_score: emb_score} ->
        card = Registry.build_tool_card(action)
        lex_score = Scorer.lexical_overlap(al_text, card)
        alias_score = Scorer.alias_overlap(parsed_args, action)
        shape = Scorer.shape_score(parsed_args, action)

        %{
          action: action,
          embedding_score: emb_score,
          lexical_score: lex_score,
          alias_score: alias_score,
          shape_score: shape,
          fused_score:
            Scorer.fuse_scores(%{
              embedding: emb_score,
              lexical: lex_score,
              alias: alias_score,
              shape: shape
            })
        }
      end)
      |> Enum.sort_by(& &1.fused_score, :desc)

    {:ok, scored}
  end

  defp select_and_map(_al_text, [], _slots, _selection_opts), do: {:ok, empty_registry_result()}

  @spec select_and_map(binary(), [map()], map(), selection_opts()) ::
          {:ok, plan_result()} | {:error, term()}
  defp select_and_map(al_text, scored_candidates, slots, selection_opts) do
    with {:ok, %{candidate: chosen, mapping: mapping, notes: reranker_notes}} <-
           choose_candidate(al_text, scored_candidates, slots, selection_opts) do
      build_selection_result(chosen, mapping, reranker_notes, scored_candidates, selection_opts)
    end
  end

  defp build_selection_result(chosen, mapping, reranker_notes, scored_candidates, selection_opts) do
    if selected_tool_accepted?(chosen, reranker_notes, selection_opts.tool_threshold) do
      {:ok, mapped_tool_result(chosen, mapping, reranker_notes, scored_candidates)}
    else
      no_tool_result(scored_candidates, selection_opts.tool_threshold)
    end
  end

  defp selected_tool_accepted?(chosen, reranker_notes, tool_threshold) do
    chosen.fused_score >= tool_threshold or reranker_notes != []
  end

  defp mapped_tool_result(chosen, mapping, reranker_notes, scored_candidates) do
    %{
      "status" => mapped_status(mapping),
      "selected_tool" => chosen.action["id"],
      "confidence" => chosen.fused_score,
      "tool_score" => chosen.embedding_score,
      "mapping_score" => mapping.mapping_score,
      "combined_score" => chosen.fused_score,
      "args" => mapping.args,
      "missing" => mapping.missing,
      "notes" => mapping.notes ++ reranker_notes,
      "candidates" => build_candidate_list(scored_candidates)
    }
  end

  defp mapped_status(%{missing: []}), do: "ok"
  defp mapped_status(_mapping), do: "MISSING_ARGS"

  defp retrieve_embedded_candidates(
         al_text,
         registry_module,
         registry,
         embedder,
         top_k,
         matrix,
         action_ids
       ) do
    case maybe_embed_query(embedder, al_text) do
      {:ok, query_vec} ->
        {:ok,
         build_embedded_candidates(
           query_vec,
           matrix,
           top_k,
           action_ids,
           registry_module,
           registry
         )}

      {:error, :embedder_unavailable} ->
        retrieve_lexical_fallback(al_text, registry_module, registry, top_k)

      {:error, _reason} = error ->
        error
    end
  end

  defp build_embedded_candidates(query_vec, matrix, top_k, action_ids, registry_module, registry) do
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

  defp choose_candidate(al_text, [best | rest] = scored_candidates, slots, selection_opts) do
    primary_mapping = SlotMapper.map_slots(slots, best.action)

    if reranker_fallback?(best, rest, primary_mapping, selection_opts) do
      rerank_candidates(al_text, scored_candidates, slots, selection_opts, best, primary_mapping)
    else
      {:ok, %{candidate: best, mapping: primary_mapping, notes: []}}
    end
  end

  defp reranker_fallback?(best, rest, mapping, selection_opts) do
    selection_opts.tool_selection_fallback == :reranker and
      not is_nil(selection_opts.reranker) and
      not is_nil(selection_opts.reranker_module) and
      (best.fused_score < selection_opts.tool_threshold or
         mapping.missing != [] or
         candidate_margin(best, rest) <= selection_opts.fallback_margin)
  end

  defp rerank_candidates(
         al_text,
         scored_candidates,
         slots,
         selection_opts,
         primary,
         primary_mapping
       ) do
    pool = Enum.take(scored_candidates, selection_opts.fallback_top_k)

    pairs =
      Enum.map(pool, fn candidate ->
        {al_text, Registry.build_tool_card(candidate.action)}
      end)

    case selection_opts.reranker_module.score_batch(selection_opts.reranker, pairs) do
      {:ok, scores} ->
        chosen =
          pool
          |> Enum.zip(scores)
          |> Enum.map(fn {candidate, reranker_score} ->
            Map.put(candidate, :reranker_score, reranker_score)
          end)
          |> Enum.sort_by(&{&1.reranker_score, &1.fused_score}, :desc)
          |> hd()

        mapping = SlotMapper.map_slots(slots, chosen.action)

        {:ok,
         %{
           candidate: chosen,
           mapping: mapping,
           notes: reranker_notes(chosen, primary, mapping, primary_mapping)
         }}

      {:error, _reason} ->
        {:ok, %{candidate: primary, mapping: primary_mapping, notes: []}}
    end
  end

  defp empty_registry_result do
    %{
      "status" => "NO_TOOL",
      "selected_tool" => nil,
      "confidence" => nil,
      "tool_score" => nil,
      "mapping_score" => nil,
      "combined_score" => nil,
      "args" => %{},
      "missing" => [],
      "notes" => ["empty registry"]
    }
  end

  defp no_tool_result(scored_candidates, tool_threshold) do
    suggestions =
      scored_candidates
      |> Enum.take(3)
      |> Enum.map(fn c ->
        %{
          "id" => c.action["id"],
          "score" => c.fused_score,
          "al_command" => nil
        }
      end)

    {:ok,
     %{
       "status" => "NO_TOOL",
       "selected_tool" => nil,
       "confidence" => nil,
       "tool_score" => nil,
       "mapping_score" => nil,
       "combined_score" => nil,
       "args" => %{},
       "missing" => [],
       "notes" => ["no tool above threshold (#{tool_threshold})"],
       "suggestions" => suggestions
     }}
  end

  defp build_candidate_list(scored) do
    Enum.map(scored, fn c ->
      %{
        "id" => c.action["id"],
        "score" => c.fused_score,
        "tool_score" => c.embedding_score,
        "mapping_score" => nil,
        "combined_score" => c.fused_score
      }
    end)
  end

  defp candidate_margin(_best, []), do: 1.0
  defp candidate_margin(best, [next | _rest]), do: best.fused_score - next.fused_score

  defp reranker_notes(
         %{action: %{"id" => chosen_id}},
         %{action: %{"id" => primary_id}},
         _mapping,
         _primary_mapping
       )
       when chosen_id != primary_id do
    ["reranker fallback selected #{chosen_id} over #{primary_id}"]
  end

  defp reranker_notes(_chosen, _primary, %{missing: missing}, %{missing: primary_missing})
       when missing != primary_missing do
    ["reranker fallback revalidated tool selection"]
  end

  defp reranker_notes(_chosen, _primary, _mapping, _primary_mapping) do
    ["reranker fallback confirmed tool selection"]
  end

  defp maybe_embed_query(nil, _al_text), do: {:error, :embedder_unavailable}
  defp maybe_embed_query(embedder, al_text), do: EmbeddingRuntime.embed(embedder, al_text)

  defp retrieval_options(opts) do
    %{
      registry_module: Map.get(opts, :registry_module, RegistryStore),
      registry: Map.get(opts, :registry, RegistryStore),
      embedder: Map.get(opts, :embedder),
      top_k: plan_option(opts, :top_k)
    }
  end

  defp selection_options(opts) do
    %{
      tool_threshold: plan_option(opts, :tool_threshold),
      mapping_threshold: plan_option(opts, :mapping_threshold),
      tool_selection_fallback: Map.get(opts, :tool_selection_fallback, :disabled),
      fallback_top_k: plan_option(opts, :fallback_top_k),
      fallback_margin: plan_option(opts, :fallback_margin),
      reranker_module: Map.get(opts, :reranker_module),
      reranker: Map.get(opts, :reranker)
    }
  end

  defp plan_option(opts, key) do
    Map.get(opts, key, Keyword.fetch!(RuntimeConfig.built_in_plan_defaults(), key))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

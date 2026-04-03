defmodule SpectreKinetic.Planner do
  @moduledoc """
  Elixir-native planner pipeline for AL normalization, retrieval, scoring,
  bounded reranker fallback, and deterministic slot mapping.
  """

  alias SpectreKinetic.Parser
  alias SpectreKinetic.Planner.EmbeddingRuntime
  alias SpectreKinetic.Planner.Registry
  alias SpectreKinetic.Planner.RegistryStore
  alias SpectreKinetic.Planner.Runtime, as: PlannerRuntime
  alias SpectreKinetic.Planner.Scorer
  alias SpectreKinetic.Planner.SlotMapper

  @default_top_k 5
  @default_tool_threshold 0.3
  @default_mapping_threshold 0.0
  @default_fallback_top_k 3
  @default_fallback_margin 0.12

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

  @type plan_result :: %{
          status: binary(),
          selected_tool: binary() | nil,
          confidence: float() | nil,
          tool_score: float() | nil,
          mapping_score: float() | nil,
          combined_score: float() | nil,
          args: map(),
          missing: [binary()],
          notes: [binary()],
          candidates: [map()]
        }

  @spec plan(PlannerRuntime.t(), binary(), keyword()) :: {:ok, plan_result()} | {:error, term()}
  def plan(%PlannerRuntime{} = runtime, al_text, opts) do
    plan(al_text, PlannerRuntime.plan_opts(runtime, opts))
  end

  @spec plan(binary(), plan_opts()) :: {:ok, plan_result()} | {:error, term()}
  def plan(al_text, opts \\ %{}) do
    registry_module = Map.get(opts, :registry_module, RegistryStore)
    registry = Map.get(opts, :registry, RegistryStore)
    embedder = Map.get(opts, :embedder)
    top_k = Map.get(opts, :top_k, @default_top_k)
    tool_threshold = Map.get(opts, :tool_threshold, @default_tool_threshold)
    mapping_threshold = Map.get(opts, :mapping_threshold, @default_mapping_threshold)

    selection_opts = %{
      tool_threshold: tool_threshold,
      mapping_threshold: mapping_threshold,
      tool_selection_fallback: Map.get(opts, :tool_selection_fallback, :disabled),
      fallback_top_k: Map.get(opts, :fallback_top_k, @default_fallback_top_k),
      fallback_margin: Map.get(opts, :fallback_margin, @default_fallback_margin),
      reranker_module: Map.get(opts, :reranker_module),
      reranker: Map.get(opts, :reranker)
    }

    with {:ok, normalized} <- normalize_al(al_text),
         parsed_args <- Parser.args(normalized),
         provided_slots <- Map.get(opts, :slots, parsed_args),
         {:ok, candidates} <-
           retrieve_candidates(normalized, registry_module, registry, embedder, top_k),
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

  defp retrieve_candidates(al_text, registry_module, registry, embedder, top_k) do
    case registry_module.embedding_matrix(registry) do
      {matrix, action_ids} ->
        case maybe_embed_query(embedder, al_text) do
          {:ok, query_vec} ->
            cos_scores = Scorer.cosine_similarity(query_vec, matrix)
            top = Scorer.top_k(cos_scores, top_k)

            candidates =
              Enum.map(top, fn {idx, score} ->
                action_id = Enum.at(action_ids, idx)
                action = registry_module.get_action(registry, action_id)
                %{action: action, embedding_score: score}
              end)
              |> Enum.reject(&is_nil(&1.action))

            {:ok, candidates}

          {:error, :embedder_unavailable} ->
            retrieve_lexical_fallback(al_text, registry_module, registry, top_k)

          {:error, _reason} = error ->
            error
        end

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

  defp select_and_map(al_text, scored_candidates, slots, selection_opts) do
    tool_threshold = selection_opts.tool_threshold

    with {:ok, %{candidate: chosen, mapping: mapping, notes: reranker_notes}} <-
           choose_candidate(al_text, scored_candidates, slots, selection_opts) do
      cond do
        chosen.fused_score >= tool_threshold or reranker_notes != [] ->
          {:ok,
           %{
             "status" => if(mapping.missing == [], do: "ok", else: "MISSING_ARGS"),
             "selected_tool" => chosen.action["id"],
             "confidence" => chosen.fused_score,
             "tool_score" => chosen.embedding_score,
             "mapping_score" => mapping.mapping_score,
             "combined_score" => chosen.fused_score,
             "args" => mapping.args,
             "missing" => mapping.missing,
             "notes" => mapping.notes ++ reranker_notes,
             "candidates" => build_candidate_list(scored_candidates)
           }}

        true ->
          no_tool_result(scored_candidates, tool_threshold)
      end
    end
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

        notes =
          cond do
            chosen.action["id"] != primary.action["id"] ->
              ["reranker fallback selected #{chosen.action["id"]} over #{primary.action["id"]}"]

            mapping.missing != primary_mapping.missing ->
              ["reranker fallback revalidated tool selection"]

            true ->
              ["reranker fallback confirmed tool selection"]
          end

        {:ok, %{candidate: chosen, mapping: mapping, notes: notes}}

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

  defp maybe_embed_query(nil, _al_text), do: {:error, :embedder_unavailable}
  defp maybe_embed_query(embedder, al_text), do: EmbeddingRuntime.embed(embedder, al_text)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

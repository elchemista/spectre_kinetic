defmodule SpectreKinetic.Planner.Selection do
  @moduledoc false

  alias SpectreKinetic.Planner.Registry
  alias SpectreKinetic.Planner.SlotMapper
  alias SpectreKinetic.RuntimeConfig

  @type opts :: %{
          tool_threshold: float(),
          mapping_threshold: float(),
          tool_selection_fallback: :disabled | :reranker,
          fallback_top_k: pos_integer(),
          fallback_margin: float(),
          reranker_module: module() | nil,
          reranker: term() | nil
        }

  @spec options(map()) :: opts()
  def options(opts) do
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

  @spec select(binary(), [map()], map(), opts()) :: {:ok, map()} | {:error, term()}
  def select(_al_text, [], _slots, _selection_opts), do: {:ok, empty_registry_result()}

  def select(al_text, scored_candidates, slots, selection_opts) do
    with {:ok, %{candidate: chosen, mapping: mapping, notes: reranker_notes}} <-
           choose_candidate(al_text, scored_candidates, slots, selection_opts) do
      finalize_selection(chosen, mapping, reranker_notes, scored_candidates, selection_opts)
    end
  end

  defp finalize_selection(chosen, mapping, reranker_notes, scored_candidates, selection_opts) do
    if accepted_selection?(chosen, reranker_notes, selection_opts.tool_threshold) do
      {:ok, mapped_tool_result(chosen, mapping, reranker_notes, scored_candidates)}
    else
      no_tool_result(scored_candidates, selection_opts.tool_threshold)
    end
  end

  defp accepted_selection?(chosen, reranker_notes, tool_threshold) do
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

  defp choose_candidate(al_text, [best | rest] = scored_candidates, slots, selection_opts) do
    primary_mapping = SlotMapper.map_slots(slots, best.action)

    if should_rerank?(best, rest, primary_mapping, selection_opts) do
      choose_with_reranker(
        al_text,
        scored_candidates,
        slots,
        selection_opts,
        best,
        primary_mapping
      )
    else
      {:ok, %{candidate: best, mapping: primary_mapping, notes: []}}
    end
  end

  defp should_rerank?(best, rest, mapping, selection_opts) do
    selection_opts.tool_selection_fallback == :reranker and
      not is_nil(selection_opts.reranker) and
      not is_nil(selection_opts.reranker_module) and
      reranker_would_help?(best, rest, mapping, selection_opts)
  end

  defp reranker_would_help?(best, rest, mapping, selection_opts) do
    best.fused_score < selection_opts.tool_threshold or
      mapping.missing != [] or
      candidate_margin(best, rest) <= selection_opts.fallback_margin
  end

  defp choose_with_reranker(
         al_text,
         scored_candidates,
         slots,
         selection_opts,
         primary,
         primary_mapping
       ) do
    pool = Enum.take(scored_candidates, selection_opts.fallback_top_k)
    pairs = reranker_pairs(al_text, pool)

    case selection_opts.reranker_module.score_batch(selection_opts.reranker, pairs) do
      {:ok, scores} ->
        chosen = select_reranked_candidate(pool, scores)
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

  defp reranker_pairs(al_text, candidates) do
    Enum.map(candidates, fn candidate ->
      {al_text, Registry.build_tool_card(candidate.action)}
    end)
  end

  defp select_reranked_candidate(pool, scores) do
    pool
    |> Enum.zip(scores)
    |> Enum.map(fn {candidate, reranker_score} ->
      Map.put(candidate, :reranker_score, reranker_score)
    end)
    |> Enum.sort_by(&{&1.reranker_score, &1.fused_score}, :desc)
    |> hd()
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

  defp plan_option(opts, key) do
    Map.get(opts, key, Keyword.fetch!(RuntimeConfig.built_in_plan_defaults(), key))
  end
end

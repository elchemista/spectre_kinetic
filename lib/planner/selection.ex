defmodule SpectreKinetic.Planner.Selection do
  @moduledoc false

  alias SpectreKinetic.Planner.Registry
  alias SpectreKinetic.Planner.SlotMapper
  alias SpectreKinetic.RuntimeConfig
  alias SpectreKinetic.Telemetry

  @reranker_fallback_event [:spectre_kinetic, :planner, :reranker, :fallback]

  @type opts :: %{
          tool_threshold: float(),
          mapping_threshold: float(),
          tool_selection_fallback: :disabled | :reranker,
          fallback_top_k: pos_integer(),
          fallback_margin: float(),
          reranker_threshold: float(),
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
      reranker_threshold: plan_option(opts, :reranker_threshold),
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
    if accepted_selection?(chosen, selection_opts) do
      {:ok,
       mapped_tool_result(chosen, mapping, reranker_notes, scored_candidates, selection_opts)}
    else
      no_tool_result(scored_candidates, selection_opts.tool_threshold)
    end
  end

  defp accepted_selection?(chosen, selection_opts) do
    chosen.fused_score >= selection_opts.tool_threshold and
      reranker_score_accepted?(chosen, selection_opts.reranker_threshold)
  end

  defp reranker_score_accepted?(%{reranker_score: score}, threshold), do: score >= threshold
  defp reranker_score_accepted?(_chosen, _threshold), do: true

  defp mapped_tool_result(chosen, mapping, reranker_notes, scored_candidates, selection_opts) do
    %{
      "status" => mapped_status(mapping, selection_opts.mapping_threshold),
      "selected_tool" => chosen.action["id"],
      "confidence" => chosen.fused_score,
      "tool_score" => chosen.embedding_score,
      "mapping_score" => mapping.mapping_score,
      "combined_score" => chosen.fused_score,
      "args" => mapping.args,
      "invalid" => mapping.invalid,
      "missing" => mapping.missing,
      "notes" => mapping.notes ++ reranker_notes,
      "candidates" => build_candidate_list(scored_candidates)
    }
  end

  defp mapped_status(%{mapping_score: score}, threshold) when score < threshold,
    do: "AMBIGUOUS_MAPPING"

  defp mapped_status(%{invalid: [_ | _]}, _threshold), do: "AMBIGUOUS_MAPPING"

  defp mapped_status(%{positional: [_ | _]}, _threshold), do: "AMBIGUOUS_MAPPING"

  defp mapped_status(%{missing: []}, _threshold), do: "ok"
  defp mapped_status(_mapping, _threshold), do: "MISSING_ARGS"

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
    best.fused_score >= selection_opts.tool_threshold and
      (mapping.missing != [] or
         candidate_margin(best, rest) <= selection_opts.fallback_margin)
  end

  defp choose_with_reranker(
         al_text,
         scored_candidates,
         slots,
         selection_opts,
         primary,
         primary_mapping
       ) do
    start = System.monotonic_time()
    pool = Enum.take(scored_candidates, selection_opts.fallback_top_k)
    pairs = reranker_pairs(al_text, pool)

    case safe_score_batch(
           selection_opts.reranker_module,
           selection_opts.reranker,
           pairs
         ) do
      {:ok, scores} ->
        handle_reranker_scores(
          scores,
          al_text,
          pool,
          slots,
          selection_opts,
          primary,
          primary_mapping,
          start
        )

      {:error, reason} ->
        reranker_error_fallback(
          reason,
          start,
          selection_opts,
          pool,
          primary,
          primary_mapping
        )
    end
  end

  defp safe_score_batch(module, runtime, pairs) do
    case module.score_batch(runtime, pairs) do
      {:ok, _scores} = ok ->
        ok

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:invalid_reranker_return, other}}
    end
  rescue
    error ->
      {:error,
       {:reranker_call_failed,
        %{kind: :raise, exception: error.__struct__, message: Exception.message(error)}}}
  catch
    kind, reason when kind in [:throw, :exit] ->
      {:error, {:reranker_call_failed, %{kind: kind, reason: reason}}}
  end

  defp handle_reranker_scores(
         scores,
         _al_text,
         pool,
         slots,
         selection_opts,
         primary,
         primary_mapping,
         start
       ) do
    case validate_reranker_scores(scores, length(pool)) do
      {:ok, scores} ->
        chosen = select_reranked_candidate(pool, scores)
        mapping = SlotMapper.map_slots(slots, chosen.action)
        notes = reranker_notes(chosen, primary, mapping, primary_mapping)

        emit_reranker_event(start, selection_opts, pool, primary, chosen, mapping, %{
          result: :fallback,
          reason: reranker_reason(chosen, primary, mapping, primary_mapping)
        })

        {:ok,
         %{
           candidate: chosen,
           mapping: mapping,
           notes: notes
         }}

      {:error, reason} ->
        reranker_error_fallback(
          reason,
          start,
          selection_opts,
          pool,
          primary,
          primary_mapping
        )
    end
  end

  defp reranker_error_fallback(
         reason,
         start,
         selection_opts,
         pool,
         primary,
         primary_mapping
       ) do
    emit_reranker_event(start, selection_opts, pool, primary, primary, primary_mapping, %{
      result: :error,
      reason: reason
    })

    {:ok, %{candidate: primary, mapping: primary_mapping, notes: []}}
  end

  defp validate_reranker_scores(scores, expected_count) when is_list(scores) do
    cond do
      length(scores) != expected_count ->
        {:error,
         {:invalid_reranker_scores,
          {:score_count_mismatch, %{expected: expected_count, actual: length(scores)}}}}

      true ->
        validate_score_values(scores)
    end
  end

  defp validate_reranker_scores(scores, _expected_count) do
    {:error, {:invalid_reranker_scores, {:invalid_shape, scores}}}
  end

  defp validate_score_values(scores) do
    case Enum.find_index(scores, &(not valid_probability?(&1))) do
      nil ->
        {:ok, Enum.map(scores, &(&1 / 1))}

      index ->
        {:error,
         {:invalid_reranker_scores,
          {:invalid_score, %{index: index, value: Enum.at(scores, index)}}}}
    end
  end

  # The range check rejects infinities and NaN in addition to ordinary
  # out-of-range values. NaN is never equal to itself and cannot satisfy both
  # bounds.
  defp valid_probability?(score) when is_number(score) do
    score == score and score >= 0.0 and score <= 1.0
  end

  defp valid_probability?(_score), do: false

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

  defp reranker_reason(
         %{action: %{"id" => chosen_id}},
         %{action: %{"id" => primary_id}},
         _mapping,
         _primary_mapping
       )
       when chosen_id != primary_id,
       do: :changed_selection

  defp reranker_reason(_chosen, _primary, %{missing: missing}, %{missing: primary_missing})
       when missing != primary_missing,
       do: :revalidated_selection

  defp reranker_reason(_chosen, _primary, _mapping, _primary_mapping), do: :confirmed_selection

  defp emit_reranker_event(start, selection_opts, pool, primary, chosen, mapping, metadata) do
    Telemetry.execute(
      @reranker_fallback_event,
      %{
        duration: System.monotonic_time() - start,
        candidate_count: length(pool),
        fallback_top_k: selection_opts.fallback_top_k,
        reranker_threshold: selection_opts.reranker_threshold,
        missing_count: length(mapping.missing)
      },
      Map.merge(metadata, %{
        primary_tool: primary.action["id"],
        chosen_tool: chosen.action["id"],
        selected_tool: chosen.action["id"]
      })
    )
  end

  defp plan_option(opts, key) do
    Map.get(opts, key, Keyword.fetch!(RuntimeConfig.built_in_plan_defaults(), key))
  end
end

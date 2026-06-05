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
  alias SpectreKinetic.Planner.Registry
  alias SpectreKinetic.Planner.Retrieval
  alias SpectreKinetic.Planner.Runtime, as: PlannerRuntime
  alias SpectreKinetic.Planner.Scorer
  alias SpectreKinetic.Planner.Selection
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
    with {:ok, normalized} <- normalize_al(al_text),
         parsed_args <- Parser.args(normalized),
         provided_slots <- Map.get(opts, :slots, parsed_args),
         {:ok, candidates} <- Retrieval.retrieve(normalized, Retrieval.options(opts)),
         {:ok, scored} <- score_candidates(normalized, provided_slots, candidates) do
      Selection.select(normalized, scored, provided_slots, Selection.options(opts))
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule SpectreKinetic.PlanContext do
  @moduledoc """
  Planning context passed through classifier pipeline modules.

  The context wraps the base planner result without taking ownership of tool
  selection or argument mapping. Classifiers may enrich this struct and adjust
  status, warnings, or classifier results before it is converted back into the
  public action payload.
  """

  alias SpectreKinetic.Parser
  alias SpectreKinetic.Planner.Runtime, as: PlannerRuntime

  defstruct [
    :runtime,
    :input,
    :mode,
    :planner_result,
    :status,
    :metadata,
    :classifier_results,
    :warnings,
    :halted?
  ]

  @type status ::
          :ok
          | :no_tool
          | :missing_args
          | :ambiguous_mapping
          | :needs_confirmation
          | :needs_clarification
          | :rejected
          | :error
          | atom()

  @type t :: %__MODULE__{
          runtime: PlannerRuntime.t() | nil,
          input: binary(),
          mode: :plan | :plan_chain,
          planner_result: map(),
          status: status(),
          metadata: map(),
          classifier_results: map(),
          warnings: [binary()],
          halted?: boolean()
        }

  @doc """
  Builds a classifier context from one base planner result.
  """
  @spec from_planner_result(PlannerRuntime.t(), binary(), :plan | :plan_chain, map()) :: t()
  def from_planner_result(%PlannerRuntime{} = runtime, input, mode, planner_result)
      when is_binary(input) and is_map(planner_result) do
    %__MODULE__{
      runtime: runtime,
      input: input,
      mode: mode,
      planner_result: planner_result,
      status: normalize_status(planner_result["status"]),
      metadata: planner_result["metadata"] || %{},
      classifier_results: planner_result["classifier_results"] || %{},
      warnings: planner_result["warnings"] || [],
      halted?: Map.get(planner_result, "halted?", false)
    }
  end

  @doc """
  Converts a classifier context back into the planner payload consumed by `Action`.
  """
  @spec to_planner_result(t()) :: map()
  def to_planner_result(%__MODULE__{} = context) do
    context.planner_result
    |> Map.put("status", denormalize_status(context.status))
    |> Map.put("classifier_results", context.classifier_results || %{})
    |> Map.put("warnings", context.warnings || [])
    |> Map.put("halted?", context.halted? || false)
  end

  @doc """
  Returns the normalized AL text for the context input.
  """
  @spec normalized_al(t()) :: binary()
  def normalized_al(%__MODULE__{input: input}), do: normalize_al(input)

  @doc """
  Returns parsed AL args from the normalized context input.
  """
  @spec parsed_args(t()) :: map()
  def parsed_args(%__MODULE__{} = context), do: Parser.args(normalized_al(context))

  @doc """
  Returns the planner-selected tool id.
  """
  @spec selected_tool(t()) :: binary() | nil
  def selected_tool(%__MODULE__{planner_result: planner_result}) do
    planner_result["selected_tool"]
  end

  @doc """
  Returns mapped planner args.
  """
  @spec args(t()) :: map()
  def args(%__MODULE__{planner_result: planner_result}), do: planner_result["args"] || %{}

  @doc """
  Returns missing required fields from the base planner result.
  """
  @spec missing_fields(t()) :: [binary()]
  def missing_fields(%__MODULE__{planner_result: planner_result}),
    do: planner_result["missing"] || []

  @doc """
  Returns ranked candidates or suggestions from the base planner result.
  """
  @spec ranked_tools(t()) :: [map()]
  def ranked_tools(%__MODULE__{planner_result: planner_result}),
    do: extract_ranked_tools(planner_result)

  @doc """
  Returns score features derived from the base planner result.
  """
  @spec scores(t()) :: map()
  def scores(%__MODULE__{planner_result: planner_result}), do: score_features(planner_result)

  @doc """
  Adds one classifier result under `key`.
  """
  @spec put_classifier_result(t(), atom() | binary(), map()) :: t()
  def put_classifier_result(%__MODULE__{} = context, key, value) when is_map(value) do
    %{context | classifier_results: Map.put(context.classifier_results || %{}, key, value)}
  end

  @doc """
  Appends a human-readable warning unless it is empty.
  """
  @spec add_warning(t(), binary() | nil) :: t()
  def add_warning(%__MODULE__{} = context, warning) when is_binary(warning) do
    warning = String.trim(warning)

    if warning == "" do
      context
    else
      %{context | warnings: (context.warnings || []) ++ [warning]}
    end
  end

  def add_warning(%__MODULE__{} = context, _warning), do: context

  @doc """
  Returns the registry action selected by the base planner, when available.
  """
  @spec selected_action(t()) :: map() | nil
  def selected_action(%__MODULE__{} = context) do
    selected_tool = selected_tool(context)

    case {context.runtime, selected_tool} do
      {%PlannerRuntime{} = runtime, id} when is_binary(id) ->
        runtime.registry_module.get_action(runtime.registry, id) || embedded_action(context)

      _ ->
        embedded_action(context)
    end
  end

  @spec embedded_action(t()) :: map() | nil
  defp embedded_action(%__MODULE__{planner_result: planner_result}) do
    planner_result["action"] || planner_result["selected_action"]
  end

  defp normalize_al(input) do
    case Parser.normalize(input) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> input
    end
  end

  defp extract_ranked_tools(%{"candidates" => candidates}) when is_list(candidates),
    do: candidates

  defp extract_ranked_tools(%{"suggestions" => suggestions}) when is_list(suggestions),
    do: suggestions

  defp extract_ranked_tools(_planner_result), do: []

  defp score_features(planner_result) do
    ranked = extract_ranked_tools(planner_result)
    top1 = planner_result["combined_score"] || planner_result["confidence"] || score_at(ranked, 0)
    top2 = score_at(ranked, 1)

    %{
      confidence: planner_result["confidence"],
      tool_score: planner_result["tool_score"],
      mapping_score: planner_result["mapping_score"],
      combined_score: planner_result["combined_score"],
      top1_score: top1,
      top2_score: top2,
      margin: score_margin(top1, top2)
    }
  end

  defp score_at(ranked, index) do
    ranked
    |> Enum.at(index)
    |> case do
      nil -> nil
      item -> item["combined_score"] || item["score"] || item["tool_score"]
    end
  end

  defp score_margin(score, nil) when is_number(score), do: 1.0
  defp score_margin(score, next) when is_number(score) and is_number(next), do: score - next
  defp score_margin(_score, _next), do: nil

  defp normalize_status("ok"), do: :ok
  defp normalize_status("NO_TOOL"), do: :no_tool
  defp normalize_status("MISSING_ARGS"), do: :missing_args
  defp normalize_status("AMBIGUOUS_MAPPING"), do: :ambiguous_mapping

  defp normalize_status(status) when is_binary(status),
    do: status |> String.downcase() |> String.to_atom()

  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status(_status), do: :ok

  defp denormalize_status(:ok), do: "ok"
  defp denormalize_status(:no_tool), do: "NO_TOOL"
  defp denormalize_status(:missing_args), do: "MISSING_ARGS"
  defp denormalize_status(:ambiguous_mapping), do: "AMBIGUOUS_MAPPING"
  defp denormalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp denormalize_status(status), do: status
end

defmodule SpectreKinetic.PlanContext do
  @moduledoc """
  Planning context passed through classifier pipeline modules.

  The context wraps the base planner result without taking ownership of tool
  selection or argument mapping. Classifiers may enrich this struct and adjust
  status, warnings, or classifier results before it is converted back into the
  public action payload.

  This is the classifier boundary object. The planner keeps its raw result map,
  while classifiers work with named accessors such as `selected_tool/1`,
  `args/1`, `scores/1`, and `selected_action/1`. That keeps classifier modules
  focused on decision rules instead of on the planner's map layout.

  ## Example

      context =
        SpectreKinetic.PlanContext.from_planner_result(
          runtime,
          "INSTALL PACKAGE WITH: PACKAGE=nginx",
          :plan,
          %{
            "status" => "ok",
            "selected_tool" => "Linux.Apt.install/1",
            "args" => %{"package" => "nginx"}
          }
        )

      context
      |> SpectreKinetic.PlanContext.put_classifier_result(:safety_risk, %{
        risk: :system_mutation
      })
      |> SpectreKinetic.PlanContext.add_warning("requires confirmation")
  """

  alias SpectreKinetic.Parser
  alias SpectreKinetic.Planner.Runtime, as: PlannerRuntime

  @known_statuses %{
    "ok" => :ok,
    "no_tool" => :no_tool,
    "missing_args" => :missing_args,
    "ambiguous_mapping" => :ambiguous_mapping,
    "needs_confirmation" => :needs_confirmation,
    "needs_clarification" => :needs_clarification,
    "rejected" => :rejected,
    "error" => :error
  }

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

  `planner_result` is deliberately kept intact in the struct. Classifiers can
  enrich the context through helper functions, and `to_planner_result/1` later
  merges those enrichments back into the public map consumed by `Action`.
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

  This is the only direction classifiers should use to write back to the public
  action payload. It preserves the original planner result and overlays the
  classifier-owned fields: status, classifier results, warnings, and halted flag.
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

  Classifiers use this when they need to compare what the user wrote with what
  the planner mapped. For example, slot confidence checks can inspect whether a
  mapped argument came from an exact key or from an alias.
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

  Classifier results are namespaced by key so independent plugs can add their
  own diagnostics without rewriting each other's output.

  ## Example

      iex> context = %SpectreKinetic.PlanContext{classifier_results: %{}}
      iex> context = SpectreKinetic.PlanContext.put_classifier_result(context, :risk, %{score: 0.8})
      iex> context.classifier_results
      %{risk: %{score: 0.8}}
  """
  @spec put_classifier_result(t(), atom() | binary(), map()) :: t()
  def put_classifier_result(%__MODULE__{} = context, key, value) when is_map(value) do
    %{context | classifier_results: Map.put(context.classifier_results || %{}, key, value)}
  end

  @doc """
  Appends a human-readable warning unless it is empty.

  Warnings are intended for explainability at the API boundary. Empty strings
  and non-binary values are ignored so classifiers can call this helper after
  optional checks without adding noise.
  """
  @spec add_warning(t(), binary() | nil) :: t()
  def add_warning(%__MODULE__{} = context, warning) when is_binary(warning) do
    warning = String.trim(warning)

    if warning == "" do
      context
    else
      %{context | warnings: Enum.concat(List.wrap(context.warnings), [warning])}
    end
  end

  def add_warning(%__MODULE__{} = context, _warning), do: context

  @doc """
  Returns the registry action selected by the base planner, when available.

  The live registry is preferred because it contains the normalized action
  currently used by the runtime. Embedded action snapshots are only a fallback
  for tests and serialized planner results that already include the action data.
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

  # Status enters this context from planner maps and serialized payloads. Keep
  # the translation explicit so arbitrary external strings do not create atoms.
  defp normalize_status(status) when is_binary(status) do
    Map.get(@known_statuses, String.downcase(status), :error)
  end

  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status(_status), do: :ok

  defp denormalize_status(:ok), do: "ok"
  defp denormalize_status(:no_tool), do: "NO_TOOL"
  defp denormalize_status(:missing_args), do: "MISSING_ARGS"
  defp denormalize_status(:ambiguous_mapping), do: "AMBIGUOUS_MAPPING"
  defp denormalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp denormalize_status(status), do: status
end

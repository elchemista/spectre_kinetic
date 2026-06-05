defmodule SpectreKinetic.PlanFinalizer do
  @moduledoc """
  Converts raw planner replies into public `SpectreKinetic.Action` structs.

  The planner returns a JSON-compatible map because retrieval, mapping, and
  reranker stages are easier to compose as data. The public API returns
  `Action` structs. This module owns that final boundary and is also where
  classifier plugs run, so the core planner does not need to know about policy
  enrichment, confirmation rules, or classifier pipeline state.
  """

  alias SpectreKinetic.Action
  alias SpectreKinetic.ClassifierPipeline
  alias SpectreKinetic.PlanContext
  alias SpectreKinetic.Planner.Runtime, as: PlannerRuntime
  alias SpectreKinetic.Telemetry

  @classifier_run_event [:spectre_kinetic, :classifier, :run]

  @spec to_action(
          PlannerRuntime.t(),
          binary(),
          {:ok, map()} | {:error, term()},
          keyword(),
          :plan | :plan_chain
        ) :: {:ok, Action.t()} | {:error, term()}
  @doc """
  Finalizes a planner result for one API call.

  Successful planner maps are optionally enriched by configured classifiers and
  then converted to `Action`. Planner errors pass through unchanged.
  """
  def to_action(%PlannerRuntime{} = runtime, al_text, {:ok, planner_result}, opts, mode)
      when is_binary(al_text) and is_map(planner_result) do
    classifiers = PlannerRuntime.classifiers(runtime, opts)

    if classifiers == [] do
      {:ok, Action.from_plan(al_text, planner_result)}
    else
      context = PlanContext.from_planner_result(runtime, al_text, mode, planner_result)

      with {:ok, context} <- run_classifiers(context, classifiers, mode) do
        {:ok, Action.from_plan(al_text, PlanContext.to_planner_result(context))}
      end
    end
  end

  def to_action(_runtime, _al_text, {:error, reason}, _opts, _mode), do: {:error, reason}

  defp run_classifiers(context, classifiers, mode) do
    start = System.monotonic_time()
    result = ClassifierPipeline.run(context, classifiers)
    emit_classifier_run(start, result, context, classifiers, mode)
    result
  end

  defp emit_classifier_run(start, {:ok, context}, _original_context, classifiers, mode) do
    Telemetry.execute(
      @classifier_run_event,
      %{
        duration: System.monotonic_time() - start,
        classifier_count: length(classifiers),
        missing_count: length(PlanContext.missing_fields(context))
      },
      %{
        result: classifier_result(context),
        mode: mode,
        status: context.status,
        selected_tool: PlanContext.selected_tool(context)
      }
    )
  end

  defp emit_classifier_run(start, {:error, reason}, original_context, classifiers, mode) do
    Telemetry.execute(
      @classifier_run_event,
      %{
        duration: System.monotonic_time() - start,
        classifier_count: length(classifiers),
        missing_count: length(PlanContext.missing_fields(original_context))
      },
      %{
        result: :error,
        reason: reason,
        mode: mode,
        status: original_context.status,
        selected_tool: PlanContext.selected_tool(original_context)
      }
    )
  end

  defp classifier_result(%PlanContext{halted?: true}), do: :halt
  defp classifier_result(_context), do: :ok
end

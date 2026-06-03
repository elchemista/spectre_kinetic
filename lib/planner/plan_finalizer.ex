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

      with {:ok, context} <- ClassifierPipeline.run(context, classifiers) do
        {:ok, Action.from_plan(al_text, PlanContext.to_planner_result(context))}
      end
    end
  end

  def to_action(_runtime, _al_text, {:error, reason}, _opts, _mode), do: {:error, reason}
end

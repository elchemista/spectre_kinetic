defmodule SpectreKinetic.Classifier do
  @moduledoc """
  Behaviour for planning-time classifier plugs.

  Classifiers receive a `SpectreKinetic.PlanContext` and may enrich it with
  scores, warnings, status changes, or controlled halts. They must not execute
  tools or freely replace the planner-selected tool and args.
  """

  alias SpectreKinetic.PlanContext

  @callback init(opts :: keyword()) :: term()

  @callback call(context :: PlanContext.t(), opts :: term()) ::
              {:ok, PlanContext.t()} | {:halt, PlanContext.t()} | {:error, term()}
end

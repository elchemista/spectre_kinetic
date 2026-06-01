defmodule SpectreKinetic.Classifier do
  @moduledoc """
  Behaviour for planning-time classifier plugs.

  Classifiers receive a `SpectreKinetic.PlanContext` and may enrich it with
  scores, warnings, status changes, or controlled halts. They must not execute
  tools or freely replace the planner-selected tool and args.

  The planner is still responsible for selecting and mapping tools. Classifiers
  are intentionally smaller: they explain or refine confidence, risk, and
  readiness. Keeping this contract narrow makes classifier modules easy to test
  with plain `%SpectreKinetic.PlanContext{}` structs.

  ## Example

      defmodule MyApp.RequireConfirmation do
        @behaviour SpectreKinetic.Classifier

        alias SpectreKinetic.PlanContext

        @impl SpectreKinetic.Classifier
        def init(opts), do: opts

        @impl SpectreKinetic.Classifier
        def call(%PlanContext{} = context, _opts) do
          context =
            context
            |> Map.put(:status, :needs_confirmation)
            |> PlanContext.add_warning("manual approval required")

          {:ok, context}
        end
      end
  """

  alias SpectreKinetic.PlanContext

  @callback init(opts :: keyword()) :: term()

  @callback call(context :: PlanContext.t(), opts :: term()) ::
              {:ok, PlanContext.t()} | {:halt, PlanContext.t()} | {:error, term()}
end

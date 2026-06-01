defmodule SpectreKinetic.TestFakeAxonClassifier do
  @moduledoc false

  alias SpectreKinetic.PlanContext
  alias SpectreKinetic.TestFakeFeatureSpec

  use SpectreKinetic.Classifiers.Internal.AxonClassifier,
    id: "fake_axon",
    features: TestFakeFeatureSpec,
    output: :binary,
    opts: [:threshold],
    load_error: "failed to load fake classifier"

  @impl SpectreKinetic.Classifier
  @doc false
  @spec call(PlanContext.t(), SpectreKinetic.Classifiers.Internal.AxonClassifier.state()) ::
          {:ok, PlanContext.t()}
  def call(%PlanContext{} = context, _state), do: {:ok, context}
end

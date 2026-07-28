defmodule SpectreKinetic.StackContractActions do
  @moduledoc false

  use SpectreKinetic

  @al ~s(PING TARGET="stack")
  @doc "Returns a deterministic ping result."
  @spec ping(String.t()) :: {:ok, String.t()}
  def ping(target), do: {:ok, "pong #{target}"}
end

defmodule SpectreKinetic.StackContractStack do
  @moduledoc false

  use Spectre.Stack, id: :kinetic_contract

  install Spectre.Kinetic,
    mode: :closed_moves,
    actions: SpectreKinetic.StackContractActions,
    modes: [ping: :read] do
    classifier(SpectreKinetic.Classifiers.PlanConfidence)

    classifier(SpectreKinetic.Classifiers.SafetyRisk,
      threshold: 0.85,
      outcome: :reject
    )
  end
end

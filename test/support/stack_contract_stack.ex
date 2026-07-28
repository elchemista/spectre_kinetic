defmodule SpectreKinetic.StackContractStack do
  @moduledoc false

  use Spectre.Stack, id: :kinetic_contract

  install Spectre.Kinetic, mode: :closed_moves do
    classifier(SpectreKinetic.Classifiers.PlanConfidence)

    classifier(SpectreKinetic.Classifiers.SafetyRisk,
      threshold: 0.85,
      outcome: :reject
    )
  end
end

defmodule SpectreKinetic.StackContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Stack.Contract.V1
  alias Spectre.Stack.Definition
  alias Spectre.Stack.Runtime
  alias SpectreKinetic.Classifiers.PlanConfidence
  alias SpectreKinetic.Classifiers.SafetyRisk
  alias SpectreKinetic.StackContractStack

  test "publishes the versioned decision-interpreter manifest" do
    assert SpectreKinetic.version() == "0.1.2"
    assert {:ok, package} = V1.verify_installable(Spectre.Kinetic)
    assert package.id == :kinetic
    assert package.version == "0.1.2"
    assert package.spectre == "~> 0.1.2"
    assert package.provides == [{:service, :kinetic}]
    assert package.operations == []
    assert package.actions == []
    assert package.resources == []
    assert package.metadata == %{role: :decision_interpreter}
  end

  test "compiles only classifier decisions into immutable Stack data" do
    assert {:ok, installation} =
             Definition.installation(StackContractStack, :kinetic)

    assert installation.config == %{
             options: [mode: :closed_moves],
             classifiers: [
               %{module: PlanConfidence, options: []},
               %{
                 module: SafetyRisk,
                 options: [threshold: 0.85, outcome: :reject]
               }
             ]
           }

    assert {:ok, reference} =
             Definition.resolve(StackContractStack, :service, :kinetic)

    assert reference.package == :kinetic
  end

  test "does not invent a Stack runtime or action executor" do
    assert {:ok, []} = Runtime.child_specs(StackContractStack)
  end
end

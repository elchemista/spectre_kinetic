defmodule SpectreKinetic.StackContractAgent do
  @moduledoc false

  use Spectre.Agent, stack: SpectreKinetic.StackContractStack

  flow :ping do
    on :ping, regex: ~r/^ping$/ do
      action({:kinetic, :ping}, args: %{"target" => "stack"})
    end
  end
end

defmodule SpectreKinetic.StackContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Stack.Contract.V1
  alias Spectre.Stack.Definition
  alias Spectre.Stack.Runtime
  alias SpectreKinetic.Classifiers.PlanConfidence
  alias SpectreKinetic.Classifiers.SafetyRisk
  alias SpectreKinetic.StackContractActions
  alias SpectreKinetic.StackContractAgent
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
    assert package.agent_extensions == [Spectre.Kinetic.Extension]
    assert package.metadata == %{role: :decision_interpreter}
  end

  test "selecting the Stack installs the Kinetic planner and classifier pipeline" do
    assert {:ok, config} = Spectre.Kinetic.config(StackContractAgent)

    assert config[:mode] == :closed_moves

    assert config[:classifiers] == [
             PlanConfidence,
             {SafetyRisk, [threshold: 0.85, outcome: :reject]}
           ]

    assert {Spectre.Kinetic.Planner, planner_opts} =
             Spectre.ActionConfig.planner(StackContractAgent)

    assert planner_opts[:classifiers] == config[:classifiers]
    assert StackContractAgent.__spectre_definition__().config[:kinetic] == config

    assert {:ok, provider} =
             Spectre.ActionConfig.provider(StackContractAgent, :kinetic)

    assert provider.module == Spectre.Kinetic.Actions
    assert {:ok, [spec]} = Spectre.Action.Provider.actions(provider, :all)
    assert spec.name == :ping
    assert spec.mode == :read

    assert {:ok, staged} = Spectre.ask(StackContractAgent, "ping")
    assert [%Spectre.Effect{kind: :action, status: :pending}] = staged.effects
    assert {:ok, completed} = Spectre.execute(StackContractAgent, staged)
    assert Spectre.Result.action_outcome(completed) == {:ok, "pong stack"}
  end

  test "compiles classifiers and provider selection into immutable Stack data" do
    assert {:ok, installation} =
             Definition.installation(StackContractStack, :kinetic)

    assert installation.config == %{
             options: [
               mode: :closed_moves,
               actions: StackContractActions,
               modes: [ping: :read]
             ],
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

  test "does not invent a global Stack runtime" do
    assert {:ok, []} = Runtime.child_specs(StackContractStack)
  end
end

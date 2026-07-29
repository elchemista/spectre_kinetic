defmodule SpectreKinetic.StackContractAgent do
  @moduledoc false

  use Spectre.Agent,
    stack: SpectreKinetic.StackContractStack,
    prompt_root: "test/fixtures/prompts"

  model(SpectreKinetic.StackContractModel)

  flow :ping do
    on :ping, regex: ~r/^ping$/ do
      ask(:ping)
    end
  end
end

defmodule SpectreKinetic.StackContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Action.Provider
  alias Spectre.Invocation
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Runtime, as: SpectreRuntime
  alias Spectre.Stack.Contract.V1
  alias Spectre.Stack.Definition
  alias Spectre.Stack.Runtime
  alias SpectreKinetic.Classifiers.PlanConfidence
  alias SpectreKinetic.Classifiers.SafetyRisk
  alias SpectreKinetic.StackContractActions
  alias SpectreKinetic.StackContractAgent
  alias SpectreKinetic.StackContractStack

  test "publishes the versioned decision-interpreter manifest" do
    assert SpectreKinetic.version() == "0.1.3"
    assert {:ok, package} = V1.verify_installable(Spectre.Kinetic)
    assert package.id == :kinetic
    assert package.version == "0.1.3"
    assert package.spectre == "~> 0.1.3"
    assert package.provides == [{:service, :kinetic}]
    assert package.operations == []
    assert package.actions == []
    assert package.resources == []
    assert package.agent_extensions == [Spectre.Kinetic.Extension]
    assert package.metadata == %{role: :decision_interpreter}
  end

  test "selecting the Stack installs the Kinetic planner and classifier pipeline" do
    Process.register(self(), SpectreKinetic.StackContractProbe)

    assert {:ok, config} = Spectre.Kinetic.config(StackContractAgent)

    assert config[:mode] == :closed_moves

    assert config[:classifiers] == [
             {PlanConfidence, [fallback: :heuristic]},
             {SafetyRisk, [fallback: :heuristic, threshold: 0.85, outcome: :reject]}
           ]

    assert {Spectre.Kinetic.Planner, planner_opts} =
             Spectre.ActionConfig.planner(StackContractAgent)

    assert planner_opts[:classifiers] == config[:classifiers]
    assert StackContractAgent.__spectre_definition__().config[:kinetic] == config

    assert {:ok, provider} =
             Spectre.ActionConfig.provider(StackContractAgent, :kinetic)

    assert provider.module == Spectre.Kinetic.Actions
    assert {:ok, [spec]} = Provider.actions(provider, :all)
    assert spec.name == :ping
    assert spec.mode == :read

    assert {:continue, %Run{} = started} =
             SpectreRuntime.start(StackContractAgent, "ping")

    assert {:ok, checkpoint} = Run.checkpoint(started)
    assert {:ok, restored} = Run.restore(checkpoint)

    assert {:await, %Invocation{operation: {:action, :ping}} = invocation, %Run{} = awaiting} =
             SpectreRuntime.advance(restored, test_pid: self())

    assert_receive :kinetic_model_called
    refute_received {:kinetic_action_executed, _target}

    assert [
             %Spectre.Effect{
               kind: :action,
               status: :pending,
               payload: %{planned_by: Spectre.Kinetic.Planner, source: :planner}
             }
           ] = awaiting.result.effects

    assert {:ok, awaiting_checkpoint} = Run.checkpoint(awaiting)
    assert {:ok, recovered} = Run.restore(awaiting_checkpoint)

    assert {:boundary, %Boundary{kind: :reply, output: "pong stack"}, %Run{} = replied_run} =
             SpectreRuntime.resume(recovered, {:execute, invocation.id})

    assert_receive {:kinetic_action_executed, "stack"}
    assert Spectre.Result.action_outcome(replied_run.result) == {:ok, "pong stack"}

    assert {:complete, completed, %Run{status: :complete} = completed_run} =
             SpectreRuntime.advance(replied_run)

    assert Spectre.Result.action_outcome(completed) == {:ok, "pong stack"}

    assert {:error, {:run_already_complete, _, _}, _run} =
             SpectreRuntime.resume(completed_run, {:execute, invocation.id})
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
               %{module: PlanConfidence, options: [fallback: :heuristic]},
               %{
                 module: SafetyRisk,
                 options: [fallback: :heuristic, threshold: 0.85, outcome: :reject]
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

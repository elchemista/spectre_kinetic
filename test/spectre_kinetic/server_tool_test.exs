defmodule Spectre.Kinetic.ServerToolTest do
  use ExUnit.Case, async: true

  alias Spectre.Kinetic.ServerTool

  defmodule Agent do
    use Spectre.Agent, stack: SpectreKinetic.StackContractStack
  end

  defmodule OtherAgent do
    use Spectre.Agent
  end

  test "registration is cognitive and does not export a fake kinetic function" do
    tools = Spectre.Kinetic.tools(%{})
    assert tools.kinetic.adapter == ServerTool
    assert tools.kinetic.operations.interpret.path == :cognitive
    assert Spectre.Stack.Tools.validate!(tools) == tools
    refute function_exported?(Spectre.Kinetic, :kinetic, 3)
  end

  test "only consolidated unplanned model output is accepted" do
    response = %{planning: false, model_output: "<al>PING</al>", text: "Public text"}

    assert {:ok, %{text: "<al>PING</al>"}} =
             ServerTool.prepare(:interpret, response, %{agent: Agent})

    assert {:ok, _} = ServerTool.prepare(:interpret, [response], %{agent: Agent})

    assert {:error, :response_already_planned} =
             ServerTool.prepare(:interpret, %{planning: true}, %{})

    assert {:error, :model_output_required} =
             ServerTool.prepare(:interpret, %{text: "cleaned"}, %{})

    assert {:error, :kinetic_planner_required} =
             ServerTool.prepare(:interpret, response, %{agent: OtherAgent})
  end

  test "the actual planner prepares a complete proposal without executing its action" do
    Process.register(self(), SpectreKinetic.StackContractProbe)
    response = %{planning: false, model_output: ~s(Ready. <al>PING TARGET="stack"</al>)}
    context = %{agent: Agent, options: [], input: nil, routing: %{}, assigns: %{}}
    assert {:ok, args} = ServerTool.prepare(:interpret, response, %{agent: Agent})
    raw = ServerTool.invoke(:interpret, args, %{service_context: context})
    assert {:ok, {:prepared, %{actions: [proposal]}}} = ServerTool.project(:interpret, raw)
    assert proposal.operation == {:kinetic, :ping}
    assert proposal.args == %{"target" => "stack"}
    assert proposal.metadata.provider
    assert proposal.metadata.schema_hash
    assert proposal.metadata.owner
    refute_received {:kinetic_action_executed, _}
  end

  test "closed-moves interpreter mode never becomes an invalid action effect mode" do
    for {options, expected} <- [
          {[mode: :closed_moves], nil},
          {[mode: :closed_moves, modes: [ping: :write]], :write},
          {[mode: :destructive], :destructive}
        ] do
      [{id, adapter, opts}] =
        Spectre.Kinetic.Extension.action_providers(
          Keyword.put(options, :actions, SpectreKinetic.StackContractActions)
        )

      mount = Spectre.Action.Provider.Mount.new(id, adapter, opts)
      assert {:ok, [spec]} = Spectre.Action.Provider.actions(mount, :planner)
      assert spec.mode == expected
    end
  end

  test "prepared results have a distinct tag and retain complete action metadata" do
    actions = [
      %{
        operation: :mail,
        args: %{},
        metadata: %{owner: Agent, scope: :agent, schema_hash: "schema"}
      }
    ]

    assert {:ok, {:prepared, %{text: "done", actions: ^actions}}} =
             ServerTool.project(:interpret, {:ok, %{text: "done", actions: actions}})

    assert {:error, :invalid_kinetic_result} = ServerTool.project(:interpret, {:ok, %{}})
  end
end

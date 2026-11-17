defmodule Spectre.Kinetic.ServerToolTest do
  # The shared Stack fixture publishes to one globally registered probe.
  use ExUnit.Case, async: false

  alias Spectre.Kinetic.ServerTool

  defmodule Agent do
    use Spectre.Agent, stack: SpectreKinetic.StackContractStack
  end

  defmodule OtherAgent do
    use Spectre.Agent
  end

  defmodule ResultActions do
    use SpectreKinetic

    @al ~s(REPORT OUTCOME RESULT="ok")
    @doc "Returns the host's observed execution result."
    @spec report(term()) :: term()
    def report(result) do
      send(self(), {:action_called, result})
      result
    end
  end

  test "registration is cognitive and does not export a fake kinetic function" do
    tools = Spectre.Kinetic.tools(%{})
    assert tools.kinetic.adapter == ServerTool
    assert tools.kinetic.operations.interpret.path == :cognitive
    assert Spectre.Stack.Tools.validate!(tools) == tools
    refute function_exported?(Spectre.Kinetic, :kinetic, 3)
  end

  test "managed execution resolves the registered catalog and freezes its schema" do
    alias Spectre.Server.GAM.Effect

    assert {:ok, effect} = Effect.resolve(Agent, {:kinetic, :ping})
    assert effect.adapter == ServerTool
    assert effect.operation == :ping
    assert is_binary(effect.schema_hash)
    assert String.starts_with?(effect.contract_ref, "spectre:effect:")

    assert {:ok, scoped} = Effect.resolve(Agent, {{:skill, :tools}, :kinetic, :ping})
    assert scoped.contract_ref == effect.contract_ref

    context = %{agent: Agent, command_id: "act:ping", identity: %{subject: "alice"}}
    assert {:ok, "pong reviewed"} = Effect.execute(effect, %{"target" => "reviewed"}, context)

    assert {:error, :definitive_no_effect, :effect_contract_changed} =
             Effect.execute(%{effect | contract_ref: "changed"}, %{"target" => "x"}, context)

    assert {:error, :effect_schema_mismatch} =
             Effect.resolve(Agent, {:kinetic, :ping}, %{schema_hash: "old"})

    assert {:error, {:unregistered_effect, {:kinetic, :unknown}}} =
             Effect.resolve(Agent, {:kinetic, :unknown})
  end

  test "effect registration preserves the closed catalog and rejects unavailable actions" do
    assert %{{:kinetic, :report} => effect} =
             Spectre.Kinetic.effects(%{options: [actions: ResultActions]})

    assert effect.adapter == ServerTool
    assert effect.side_effect == :non_idempotent
    assert effect.material == :arguments
    assert {:ok, hash} = ServerTool.effect_schema(:report, %{config: effect.config})
    assert is_binary(hash)

    assert {:error, :registered_action_unavailable} =
             ServerTool.effect_schema(:missing, %{config: effect.config})

    assert {:error, {:invalid_kinetic_actions_module, nil}} =
             ServerTool.effect_schema(:report, %{config: %{options: [module: nil]}})

    assert_raise ArgumentError, ~r/Kinetic actions unavailable/, fn ->
      Spectre.Kinetic.effects(%{options: [actions: SpectreKinetic.UnavailableResultActions]})
    end
  end

  test "admitted execution preserves uncertainty and never invokes an invalid request" do
    effect = Spectre.Kinetic.effects(%{options: [actions: ResultActions]})[{:kinetic, :report}]
    {:ok, hash} = ServerTool.effect_schema(:report, %{config: effect.config})
    context = %{effect_config: effect.config, effect_schema_hash: hash}

    for {reply, expected} <- [
          {:ok, {:ok, %{completed: true}}},
          {{:error, :failed, :rejected}, {:error, :failed, :rejected}},
          {{:error, :definitive_no_effect, :cancelled},
           {:error, :definitive_no_effect, :cancelled}},
          {{:error, :ambiguous, :timeout}, {:error, :ambiguous, :timeout}},
          {{:error, :offline}, {:error, :ambiguous, :offline}},
          {:unexpected_reply, {:error, :ambiguous, :invalid_action_result}}
        ] do
      assert ServerTool.execute_effect(:report, %{"result" => reply}, context) == expected
      assert_receive {:action_called, ^reply}
    end

    assert {:error, :definitive_no_effect, {:missing_action_argument, "result"}} =
             ServerTool.execute_effect(:report, %{}, context)

    refute_received {:action_called, _}

    assert {:ok, {:error, :planner_unavailable}} =
             ServerTool.project(:interpret, {:error, :planner_unavailable})
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

    assert {:error, :unknown_kinetic_operation} =
             ServerTool.prepare(:execute, response, %{agent: Agent})
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

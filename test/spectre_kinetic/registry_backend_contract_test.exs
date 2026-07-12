defmodule SpectreKinetic.RegistryBackendContractTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Planner.Registry.ETS

  test "ETS backend satisfies the planner registry contract" do
    {:ok, registry} = ETS.new()

    try do
      assert ETS.action_count(registry) == 0

      assert {:ok, registry} =
               ETS.add_action(registry, %{
                 id: "Dynamic.Task.update/3",
                 module: "Dynamic.Task",
                 name: "update",
                 arity: 3,
                 doc: "Update a task status and assignee",
                 spec: "update(id, status, assignee)",
                 args: [
                   %{name: "id", type: "String.t()", required: true, aliases: ["task_id"]},
                   %{name: "status", type: "String.t()", required: true, aliases: ["state"]},
                   %{name: "assignee", type: "String.t()", required: true, aliases: ["owner"]}
                 ],
                 examples: ["UPDATE WORK TASK WITH: ID=1 STATUS=done ASSIGNEE=alex"]
               })

      assert ETS.action_count(registry) == 1
      assert ETS.get_action(registry, "Dynamic.Task.update/3")["name"] == "update"
      assert ETS.resolve_alias(registry, "owner") == [{"Dynamic.Task.update/3", "assignee"}]
      assert [{"Dynamic.Task.update/3", _card}] = ETS.tool_cards(registry)

      assert {:ok, registry} =
               ETS.put_embedding(registry, "Dynamic.Task.update/3", Nx.tensor([1.0, 0.0]))

      assert {matrix, ids} = ETS.embedding_matrix(registry)
      assert ids == ["Dynamic.Task.update/3"]
      assert Nx.shape(matrix) == {1, 2}

      replacement = %{
        id: "Dynamic.Task.update/3",
        module: "Dynamic.Task",
        name: "update",
        arity: 3,
        args: [
          %{name: "id", aliases: ["work_id"]},
          %{name: "status", aliases: ["phase"]},
          %{name: "assignee", aliases: ["responsible"]}
        ]
      }

      assert {:ok, registry} = ETS.add_action(registry, replacement)
      assert ETS.action_count(registry) == 1
      assert ETS.resolve_alias(registry, "owner") == []

      assert ETS.resolve_alias(registry, "responsible") == [
               {"Dynamic.Task.update/3", "assignee"}
             ]

      assert ETS.embedding_matrix(registry) == nil

      assert {:error, :action_not_found} =
               ETS.put_embedding(registry, "Dynamic.Missing.run/0", Nx.tensor([1.0, 0.0]))

      assert {{:ok, true}, registry} = ETS.delete_action(registry, "Dynamic.Task.update/3")
      assert ETS.action_count(registry) == 0
      assert ETS.resolve_alias(registry, "responsible") == []
      assert ETS.embedding_matrix(registry) == nil
    after
      ETS.close(registry)
    end
  end
end

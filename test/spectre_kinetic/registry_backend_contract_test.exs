defmodule SpectreKinetic.RegistryBackendContractTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Planner.Registry
  alias SpectreKinetic.Planner.Registry.ETS
  alias SpectreKinetic.Planner.Runtime

  defmodule LegacyBackend do
    @behaviour SpectreKinetic.Planner.Registry

    alias SpectreKinetic.Planner.Registry.ETS

    defdelegate new(opts), to: ETS
    defdelegate load_json(registry, path), to: ETS
    defdelegate load_compiled(registry, path), to: ETS
    defdelegate all_actions(registry), to: ETS
    defdelegate get_action(registry, id), to: ETS
    defdelegate action_count(registry), to: ETS
    defdelegate add_action(registry, action), to: ETS
    defdelegate delete_action(registry, id), to: ETS
    defdelegate embedding_matrix(registry), to: ETS
    defdelegate put_embedding(registry, id, tensor), to: ETS
    defdelegate tool_cards(registry), to: ETS
    defdelegate resolve_alias(registry, name), to: ETS
    defdelegate close(registry), to: ETS
  end

  defmodule StageAwareBackend do
    def new(_opts), do: {:ok, :fallback_stage}

    def new_staging(active_registry, opts) do
      {:ok, {:staged_from, active_registry, opts}}
    end
  end

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

  test "new ownership and atomic-upsert callbacks remain optional" do
    {:ok, registry} = LegacyBackend.new([])

    try do
      assert Registry.mutation_owner(LegacyBackend, registry) == :shared

      assert {:ok, registry} =
               Registry.upsert(
                 LegacyBackend,
                 registry,
                 %{
                   id: "Example.run/0",
                   module: "Example",
                   name: "run",
                   arity: 0,
                   args: []
                 },
                 nil
               )

      assert LegacyBackend.action_count(registry) == 1

      assert {:error, {:unsupported_registry_operation, :atomic_upsert_with_embedding}} =
               Registry.upsert(
                 LegacyBackend,
                 registry,
                 %{
                   id: "Example.stop/0",
                   module: "Example",
                   name: "stop",
                   arity: 0,
                   args: []
                 },
                 Nx.tensor([1.0])
               )
    after
      LegacyBackend.close(registry)
    end
  end

  test "backend staging callbacks can retain backend-specific state" do
    assert {:ok, {:staged_from, :active_registry, [allow_empty_registry: true]}} =
             Registry.stage(
               StageAwareBackend,
               :active_registry,
               allow_empty_registry: true
             )
  end

  test "runtime loading accepts backends that implement the original contract" do
    path =
      Path.join(
        System.tmp_dir!(),
        "spectre-legacy-registry-#{System.unique_integer([:positive])}.json"
      )

    File.write!(
      path,
      Jason.encode!(%{
        "actions" => [
          %{
            "id" => "Example.run/0",
            "module" => "Example",
            "name" => "run",
            "arity" => 0,
            "args" => []
          }
        ]
      })
    )

    on_exit(fn -> File.rm(path) end)

    assert {:ok, runtime} =
             Runtime.load(registry_module: LegacyBackend, registry_json: path)

    assert Runtime.action_count(runtime) == 1
    assert :ok = Runtime.close(runtime)
  end
end

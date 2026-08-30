defmodule SpectreKinetic.DecisionBoundaryContractTest.Provider do
  @moduledoc false

  def actions(opts), do: Keyword.get(opts, :reply, Keyword.fetch!(opts, :specs))

  def execute(action, _context, opts) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, {:provider_executed, action})
    {:ok, :executed}
  end
end

defmodule SpectreKinetic.DecisionBoundaryContractTest.Unannotated do
  @moduledoc false
end

defmodule SpectreKinetic.DecisionBoundaryContractTest.Actions do
  @moduledoc false

  use SpectreKinetic

  @al ~s(RECORD AUDIT SUBJECT="deploy" DETAIL="approved")
  @doc """
  Records one audit entry.

  AL: RECORD AUDIT SUBJECT="release" DETAIL="ready"
  """
  @spec record(String.t(), String.t()) :: {:recorded, String.t(), String.t()}
  def record(subject, detail), do: {:recorded, subject, detail}
end

defmodule SpectreKinetic.DecisionBoundaryContractTest.LegacyAgent do
  @moduledoc false

  use Spectre.Agent

  use Spectre.Kinetic,
    actions: SpectreKinetic.DecisionBoundaryContractTest.Actions,
    provider: :audit,
    mode: :write,
    top_k: 2
end

defmodule SpectreKinetic.DecisionBoundaryContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Action
  alias Spectre.Action.Provider.Mount
  alias Spectre.Action.Spec
  alias Spectre.Kinetic.Actions
  alias Spectre.Kinetic.Catalog
  alias Spectre.Kinetic.Extension
  alias Spectre.Kinetic.Planner
  alias SpectreKinetic.DecisionBoundaryContractTest.Actions, as: AuditActions
  alias SpectreKinetic.DecisionBoundaryContractTest.LegacyAgent
  alias SpectreKinetic.DecisionBoundaryContractTest.Provider
  alias SpectreKinetic.DecisionBoundaryContractTest.Unannotated

  test "Stack declarations compile to immutable classifier data and reject executable values" do
    block =
      quote do
        classifier(SpectreKinetic.Classifiers.PlanConfidence)
        classifier(SpectreKinetic.Classifiers.SafetyRisk, threshold: 0.9)
      end

    assert {:ok, config} =
             Spectre.Kinetic.compile([mode: :closed_moves], block, __ENV__)

    assert config == %{
             options: [mode: :closed_moves],
             classifiers: [
               %{module: SpectreKinetic.Classifiers.PlanConfidence, options: []},
               %{
                 module: SpectreKinetic.Classifiers.SafetyRisk,
                 options: [threshold: 0.9]
               }
             ]
           }

    assert {:ok, %{classifiers: []}} = Spectre.Kinetic.compile([], nil, __ENV__)

    invalid_options =
      quote do
        classifier(SpectreKinetic.Classifiers.PlanConfidence, [:not_a_keyword])
      end

    assert_raise ArgumentError, ~r/classifier options must be a keyword list/, fn ->
      Spectre.Kinetic.compile([], invalid_options, __ENV__)
    end

    invalid_module =
      quote do
        classifier("not-a-module")
      end

    assert_raise ArgumentError, ~r/classifier must be a module/, fn ->
      Spectre.Kinetic.compile([], invalid_module, __ENV__)
    end
  end

  test "extension mounts discovery separately from planning and keeps runtime handles out of config" do
    stack_config = %{
      options: [mode: :closed_moves, actions: AuditActions, runtime: :borrowed],
      classifiers: [
        %{module: SpectreKinetic.Classifiers.PlanConfidence, options: []},
        %{
          module: SpectreKinetic.Classifiers.SafetyRisk,
          options: [threshold: 0.9]
        }
      ]
    }

    assert Extension.id() == :kinetic
    assert Extension.api_version() == 1

    assert {:ok, compiled} =
             Extension.compile(__MODULE__, stack_config: stack_config)

    assert compiled[:classifiers] == [
             SpectreKinetic.Classifiers.PlanConfidence,
             {SpectreKinetic.Classifiers.SafetyRisk, [threshold: 0.9]}
           ]

    assert Extension.agent_config(compiled) == [kinetic: compiled]
    assert Extension.compile(__MODULE__, mode: :closed_moves) == {:ok, [mode: :closed_moves]}

    assert Extension.compile(__MODULE__, stack_config: :invalid) ==
             {:error, {:invalid_kinetic_stack_config, :invalid}}

    assert Extension.action_providers([]) == []

    assert [{:audit, Actions, provider_opts}] =
             Extension.action_providers(
               actions: AuditActions,
               provider: :audit,
               mode: :read,
               modes: [record: :write],
               runtime: self()
             )

    assert provider_opts[:module] == AuditActions
    assert provider_opts[:mode] == :read
    assert provider_opts[:modes] == [record: :write]

    assert_raise ArgumentError, ~r/:actions must be a module/, fn ->
      Extension.action_providers(actions: "invalid")
    end

    assert {Planner, [runtime: :borrowed, top_k: 2]} =
             Extension.action_planner(
               actions: AuditActions,
               provider: :audit,
               mode: :write,
               modes: [record: :write],
               runtime: :borrowed,
               top_k: 2
             )

    assert {:ok, legacy_config} = Spectre.Kinetic.config(LegacyAgent)
    assert legacy_config[:actions] == AuditActions
    assert legacy_config[:provider] == :audit

    assert Spectre.Kinetic.config(__MODULE__) ==
             {:error, {:unknown_spectre_definition, __MODULE__}}
  end

  test "built-in provider discovers schemas but executes only after core dispatch" do
    opts = [module: AuditActions, provider_id: :audit, modes: %{record: :write}]
    assert [spec] = Actions.actions(opts)
    assert spec.name == :record
    assert spec.mode == :write
    assert spec.metadata.kinetic
    assert spec.metadata.kinetic_registry["name"] == "record"

    action =
      Action.new(:record,
        via: :audit,
        schema_hash:
          spec
          |> Map.put(:via, :audit)
          |> Spec.new()
          |> Map.fetch!(:schema_hash),
        args: %{"subject" => "deploy", detail: "approved"}
      )

    assert Actions.execute(action, %{}, opts) == {:recorded, "deploy", "approved"}

    assert {:error, {:missing_action_argument, "detail"}} =
             Actions.execute(%{action | args: %{subject: "deploy"}}, %{}, opts)

    assert {:error, {:invalid_action_args, []}} =
             Actions.execute(%{action | args: []}, %{}, opts)

    assert {:error, {:unknown_kinetic_action, AuditActions, :missing, nil}} =
             Actions.execute(%{action | name: :missing, schema_hash: nil}, %{}, opts)

    assert {:error, {:unknown_kinetic_action, AuditActions, :record, "stale"}} =
             Actions.execute(%{action | schema_hash: "stale"}, %{}, opts)

    assert Actions.actions(module: nil) ==
             {:error, {:invalid_kinetic_actions_module, nil}}

    assert Actions.actions(module: SpectreKinetic.MissingActions) ==
             {:error, {:unknown_kinetic_actions_module, SpectreKinetic.MissingActions}}

    assert Actions.actions(module: Unannotated) ==
             {:error, {:kinetic_actions_module_not_annotated, Unannotated}}
  end

  test "catalog closes planner choices over mounted provider schemas" do
    mount =
      Mount.new(:operations, Provider,
        specs: [
          %{
            name: :submit,
            description: "Submit a typed operation",
            mode: :write,
            schema: %{
              "type" => "object",
              "properties" => %{
                "active" => %{"type" => "boolean"},
                "count" => %{"type" => "integer"},
                "items" => %{"type" => "array", "items" => %{"type" => "string"}},
                "metadata" => %{"type" => "object"},
                "nullable" => %{"type" => ["string", "null"]},
                "ratio" => %{"type" => "number"},
                "unknown" => %{}
              },
              "required" => ["count", "items"]
            },
            metadata: %{
              examples: ["SUBMIT OPERATION COUNT=2 ITEMS=[a,b]"]
            }
          },
          %{
            "name" => "inspect",
            "description" => "Inspect one operation",
            "schema" => [
              :operation_id,
              %{"name" => "verbose", "type" => "boolean()", "required" => false}
            ],
            "metadata" => %{"examples" => ["INSPECT OPERATION ID=op-1"]}
          }
        ]
      )

    assert {:ok, %Catalog{} = catalog} = Catalog.build(action_providers: [mount])
    assert length(catalog.actions) == 2
    assert map_size(catalog.targets) == 2
    assert Enum.map(catalog.actions, & &1["name"]) == ["submit", "inspect"]

    submit = Enum.find(catalog.actions, &(&1["name"] == "submit"))
    inspect = Enum.find(catalog.actions, &(&1["name"] == "inspect"))

    assert submit["arity"] == 7

    assert Enum.map(submit["args"], &{&1["name"], &1["type"], &1["required"]}) == [
             {"active", "boolean()", false},
             {"count", "integer()", true},
             {"items", "[String.t()]", true},
             {"metadata", "map()", false},
             {"nullable", "String.t() | nil", false},
             {"ratio", "number()", false},
             {"unknown", "term()", false}
           ]

    assert inspect["arity"] == 2
    assert Enum.map(inspect["args"], & &1["name"]) == ["operation_id", "verbose"]

    assert {:ok, target} = Catalog.resolve(catalog, submit["id"])
    assert target.via == :operations
    assert target.name == :submit
    assert target.mode == :write

    assert Catalog.resolve(catalog, "outside.closed.catalog") ==
             {:error, {:unmapped_action_provider, "outside.closed.catalog"}}

    assert Catalog.exact_tool(catalog, "  submit   operation count=2 items=[a,b] ") ==
             submit["id"]

    assert Catalog.exact_tool(catalog, nil) == nil
    assert :ok = Catalog.verify_runtime(catalog, catalog.actions)

    assert {:error, {:kinetic_action_missing, missing_id}} =
             Catalog.verify_runtime(catalog, [submit])

    assert missing_id == inspect["id"]

    changed = Map.put(submit, "doc", "changed")

    assert {:error, {:kinetic_action_schema_changed, changed_id, ^changed}} =
             Catalog.verify_runtime(catalog, [changed, inspect])

    assert changed_id == submit["id"]

    extra =
      planner_action("External", "outside", [], ["OUTSIDE CLOSED CATALOG"])

    assert {:error, {:kinetic_action_not_mounted, extra_id}} =
             Catalog.verify_runtime(catalog, catalog.actions ++ [extra])

    assert extra_id == extra["id"]

    assert :ok =
             Catalog.verify_runtime(catalog, catalog.actions ++ [extra],
               allow_unmounted_actions: true
             )

    assert {:error, {:invalid_runtime_verification_options, _opts}} =
             Catalog.verify_runtime(catalog, catalog.actions, allow_unmounted_actions: :yes)

    assert {:error, {:invalid_runtime_verification_options, [:invalid]}} =
             Catalog.verify_runtime(catalog, catalog.actions, [:invalid])

    assert Catalog.verify_runtime(catalog, :invalid) ==
             {:error, {:invalid_kinetic_runtime_actions, :invalid}}

    assert {:error, {:duplicate_kinetic_runtime_action, duplicate_id}} =
             Catalog.verify_runtime(catalog, [submit, submit])

    assert duplicate_id == submit["id"]

    assert {:error, {:invalid_kinetic_runtime_action, _reason}} =
             Catalog.verify_runtime(catalog, [%{}])

    assert Catalog.build(action_providers: [:invalid]) ==
             {:error, {:invalid_action_provider_mount, :invalid}}

    failing = Mount.new(:failing, Provider, reply: {:error, :provider_down}, specs: [])
    assert Catalog.build(action_providers: [failing]) == {:error, :provider_down}

    assert {:error, {:duplicate_action_provider_tool, duplicate_tool}} =
             Catalog.build(action_providers: [mount, mount])

    assert duplicate_tool == submit["id"]

    ambiguous_examples =
      Mount.new(:ambiguous, Provider,
        specs: [
          %{name: :first, schema: [], metadata: %{examples: ["RUN SAME OPERATION"]}},
          %{name: :second, schema: [], metadata: %{examples: [" run   same operation "]}}
        ]
      )

    assert {:error, {:duplicate_action_provider_example, first_id, second_id}} =
             Catalog.build(action_providers: [ambiguous_examples])

    refute first_id == second_id

    assert Catalog.build(action_providers: :invalid) ==
             {:error, {:invalid_action_providers, :invalid}}

    assert Catalog.build([:invalid]) == {:error, {:invalid_catalog_options, [:invalid]}}

    assert Catalog.build(action_providers: [%{}]) ==
             {:error, {:invalid_action_provider_mount, %{}}}
  end

  test "planner interprets provider examples without executing the selected operation" do
    mount =
      Mount.new(:audit, Provider,
        test_pid: self(),
        specs: [
          %{
            name: :record,
            description: "Record one audit entry",
            mode: :write,
            schema: %{
              args: [
                %{name: :subject, type: "String.t()"},
                %{name: :detail, type: "String.t()"}
              ]
            },
            metadata: %{
              examples: [~s(RECORD AUDIT SUBJECT="deploy" DETAIL="approved")]
            }
          }
        ]
      )

    opts = [action_providers: [mount], tool_threshold: 0.0]

    assert {:ok, %Action{} = action} =
             Planner.plan(
               ~s(RECORD AUDIT SUBJECT="deploy" DETAIL="approved"),
               %{},
               opts
             )

    assert action.via == :audit
    assert action.name == :record
    assert action.mode == :write
    assert action.args == %{"subject" => "deploy", "detail" => "approved"}
    assert action.planned_by == Planner
    assert action.metadata.source == :planner
    refute_received {:provider_executed, _action}

    response =
      """
      The operation is ready.
      <al>RECORD AUDIT SUBJECT="deploy" DETAIL="approved"</al>
      """

    assert {:ok, %{reply_text: "The operation is ready.", actions: [planned]}} =
             Planner.plan_response(response, %{}, opts)

    assert planned.name == :record
    refute_received {:provider_executed, _action}

    assert Planner.clean_reply(response, %{}, []) == "The operation is ready."

    assert Planner.plan_response("No operation requested.", %{}, action_providers: [:invalid]) ==
             {:ok, %{reply_text: "No operation requested.", actions: []}}
  end

  test "a borrowed runtime is verified against the compiled provider catalog" do
    mount =
      Mount.new(:audit, Provider,
        specs: [
          %{
            name: :record,
            schema: %{args: [:subject]},
            metadata: %{examples: ["RECORD AUDIT SUBJECT=deploy"]}
          }
        ]
      )

    assert {:ok, catalog} = Catalog.build(action_providers: [mount])

    extra =
      planner_action("External", "outside", [], ["RUN OUTSIDE ACTION"])

    registry_path = write_registry(catalog.actions ++ [extra])

    assert {:ok, runtime} = SpectreKinetic.load_runtime(registry_json: registry_path)
    on_exit(fn -> SpectreKinetic.close_runtime(runtime) end)

    assert {:error, {:kinetic_action_not_mounted, extra_id}} =
             Planner.plan("RECORD AUDIT SUBJECT=deploy", %{},
               action_providers: [mount],
               runtime: runtime,
               tool_threshold: 0.0
             )

    assert extra_id == extra["id"]

    assert {:ok, %Action{via: :audit, name: :record}} =
             Planner.plan("RECORD AUDIT SUBJECT=deploy", %{},
               action_providers: [mount],
               runtime: runtime,
               allow_unmounted_actions: true,
               tool_threshold: 0.0
             )

    assert {:error, {:action_plan_not_executable, 0, :no_tool}} =
             Planner.plan("RUN OUTSIDE ACTION", %{},
               action_providers: [mount],
               runtime: runtime,
               allow_unmounted_actions: true,
               tool_threshold: 0.99
             )

    empty = SpectreKinetic.load_runtime!(allow_empty_registry: true)
    on_exit(fn -> SpectreKinetic.close_runtime(empty) end)

    assert {:error, {:kinetic_action_missing, _id}} =
             Planner.plan("RECORD AUDIT SUBJECT=deploy", %{},
               action_providers: [mount],
               runtime: empty
             )
  end

  defp planner_action(module, name, args, examples) do
    {:ok, action} =
      SpectreKinetic.Planner.Registry.normalize_action(%{
        "module" => module,
        "name" => name,
        "arity" => length(args),
        "args" => args,
        "examples" => examples
      })

    action
  end

  defp write_registry(actions) do
    path =
      Path.join(
        System.tmp_dir!(),
        "kinetic-boundary-#{System.unique_integer([:positive, :monotonic])}.json"
      )

    File.write!(path, Jason.encode!(%{"actions" => actions}))
    on_exit(fn -> File.rm(path) end)
    path
  end
end

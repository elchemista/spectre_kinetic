defmodule SpectreKinetic.ClassifierPlugSystemTest do
  use ExUnit.Case, async: false

  alias SpectreKinetic.Action
  alias SpectreKinetic.PlanContext
  alias SpectreKinetic.TestRegistryHelper

  defmodule CountingPlug do
    @behaviour SpectreKinetic.Classifier

    @impl true
    def init(opts) do
      init_agent = Keyword.fetch!(opts, :init_agent)
      Agent.update(init_agent, &(&1 + 1))

      %{
        call_agent: Keyword.fetch!(opts, :call_agent),
        key: Keyword.fetch!(opts, :key)
      }
    end

    @impl true
    def call(%PlanContext{} = context, state) do
      Agent.update(state.call_agent, &(&1 + 1))

      result = %{
        args: PlanContext.args(context),
        mode: context.mode,
        selected_tool: PlanContext.selected_tool(context),
        status: context.status
      }

      {:ok, PlanContext.put_classifier_result(context, state.key, result)}
    end
  end

  defmodule StatusPlug do
    @behaviour SpectreKinetic.Classifier

    @impl true
    def init(opts), do: Keyword.fetch!(opts, :status)

    @impl true
    def call(%PlanContext{} = context, status) do
      {:ok, %{context | status: status}}
    end
  end

  defmodule HaltPlug do
    @behaviour SpectreKinetic.Classifier

    @impl true
    def init(opts), do: Keyword.fetch!(opts, :warning)

    @impl true
    def call(%PlanContext{} = context, warning) do
      {:halt, PlanContext.add_warning(context, warning)}
    end
  end

  defmodule InitErrorPlug do
    @behaviour SpectreKinetic.Classifier

    @impl true
    def init(_opts), do: raise(ArgumentError, "bad plug config")

    @impl true
    def call(%PlanContext{} = context, _state), do: {:ok, context}
  end

  test "runtime configured plugs initialize once and enrich every planned action" do
    {:ok, init_agent} = Agent.start_link(fn -> 0 end)
    {:ok, call_agent} = Agent.start_link(fn -> 0 end)

    runtime =
      SpectreKinetic.load_runtime!(
        registry_json: TestRegistryHelper.registry_json(),
        classifiers: [
          {CountingPlug,
           init_agent: init_agent, call_agent: call_agent, key: :runtime_counting_plug}
        ]
      )

    assert Agent.get(init_agent, & &1) == 1

    assert {:ok, %Action{} = first} =
             SpectreKinetic.plan(runtime, ~s(INSTALL PACKAGE WITH: PACKAGE="nginx"))

    assert {:ok, %Action{} = second} =
             SpectreKinetic.plan(runtime, ~s(LIST DIRECTORY WITH: PATH="/tmp"))

    assert Agent.get(init_agent, & &1) == 1
    assert Agent.get(call_agent, & &1) == 2

    assert first.classifier_results.runtime_counting_plug == %{
             args: %{"package" => "nginx"},
             mode: :plan,
             selected_tool: "Linux.Apt.install/1",
             status: :ok
           }

    assert second.classifier_results.runtime_counting_plug == %{
             args: %{"path" => "/tmp"},
             mode: :plan,
             selected_tool: "Linux.Coreutils.ls/1",
             status: :ok
           }
  end

  test "per-call plugs override runtime plugs and initialize for each call" do
    {:ok, runtime_init_agent} = Agent.start_link(fn -> 0 end)
    {:ok, runtime_call_agent} = Agent.start_link(fn -> 0 end)
    {:ok, override_init_agent} = Agent.start_link(fn -> 0 end)
    {:ok, override_call_agent} = Agent.start_link(fn -> 0 end)

    runtime =
      SpectreKinetic.load_runtime!(
        registry_json: TestRegistryHelper.registry_json(),
        classifiers: [
          {CountingPlug,
           init_agent: runtime_init_agent, call_agent: runtime_call_agent, key: :runtime_plug}
        ]
      )

    override_spec = {
      CountingPlug,
      init_agent: override_init_agent, call_agent: override_call_agent, key: :override_plug
    }

    for _ <- 1..2 do
      assert {:ok, %Action{} = action} =
               SpectreKinetic.plan(runtime, ~s(INSTALL PACKAGE WITH: PACKAGE="nginx"),
                 classifiers: [override_spec]
               )

      assert Map.has_key?(action.classifier_results, :override_plug)
      refute Map.has_key?(action.classifier_results, :runtime_plug)
    end

    assert Agent.get(runtime_init_agent, & &1) == 1
    assert Agent.get(runtime_call_agent, & &1) == 0
    assert Agent.get(override_init_agent, & &1) == 2
    assert Agent.get(override_call_agent, & &1) == 2
  end

  test "plugs can change public action status through the plan context" do
    runtime =
      SpectreKinetic.load_runtime!(
        registry_json: TestRegistryHelper.registry_json(),
        classifiers: [{StatusPlug, status: :needs_clarification}]
      )

    assert {:ok, %Action{} = action} =
             SpectreKinetic.plan(runtime, ~s(INSTALL PACKAGE WITH: PACKAGE="nginx"))

    assert action.status == :needs_clarification
  end

  test "halted plugs mark action halted and stop later plugs" do
    {:ok, init_agent} = Agent.start_link(fn -> 0 end)
    {:ok, call_agent} = Agent.start_link(fn -> 0 end)

    runtime =
      SpectreKinetic.load_runtime!(
        registry_json: TestRegistryHelper.registry_json(),
        classifiers: [
          {HaltPlug, warning: "plug halted"},
          {CountingPlug, init_agent: init_agent, call_agent: call_agent, key: :after_halt}
        ]
      )

    assert Agent.get(init_agent, & &1) == 1

    assert {:ok, %Action{} = action} =
             SpectreKinetic.plan(runtime, ~s(INSTALL PACKAGE WITH: PACKAGE="nginx"))

    assert action.halted?
    assert action.warnings == ["plug halted"]
    assert action.classifier_results == %{}
    assert Agent.get(call_agent, & &1) == 0
  end

  test "plug init failures fail runtime loading with the plug module attached" do
    assert {:error, {InitErrorPlug, %ArgumentError{message: "bad plug config"}}} =
             SpectreKinetic.load_runtime(
               registry_json: TestRegistryHelper.registry_json(),
               classifiers: [InitErrorPlug]
             )
  end
end

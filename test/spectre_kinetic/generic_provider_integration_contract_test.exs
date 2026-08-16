defmodule SpectreKinetic.GenericProviderIntegrationContractTest.Provider do
  @moduledoc false

  @behaviour Spectre.Action.Provider

  @example ~s(OPEN ISSUE WITH: TITLE="Parser bug")

  @impl Spectre.Action.Provider
  def actions(_opts) do
    [
      %{
        name: :open_issue,
        description: "Opens an issue in a remote tracker.",
        mode: :write,
        # The schema stays inside Spectre's closed JSON-Schema subset. Slot
        # aliases are discovery metadata, not a schema constraint.
        schema: %{
          type: "object",
          properties: %{
            title: %{type: "string"}
          },
          required: ["title"]
        },
        metadata: %{examples: [@example], aliases: %{title: ["SUBJECT"]}}
      }
    ]
  end

  @impl Spectre.Action.Provider
  def execute(%Spectre.Action{name: :open_issue, args: args}, _context, opts) do
    %{
      opened_issue: Map.fetch!(args, "title"),
      provider_id: Keyword.fetch!(opts, :provider_id),
      namespace: Keyword.fetch!(opts, :namespace)
    }
  end
end

defmodule SpectreKinetic.GenericProviderIntegrationContractTest.Agent do
  @moduledoc false

  use Spectre.Agent

  action_provider(
    {:remote, :issues},
    SpectreKinetic.GenericProviderIntegrationContractTest.Provider,
    namespace: :integration
  )

  use Spectre.Kinetic,
    top_k: 1,
    tool_threshold: 0.0,
    mapping_threshold: 0.0
end

defmodule SpectreKinetic.GenericProviderIntegrationContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Action.Provider.Mount
  alias Spectre.ActionConfig
  alias Spectre.ActionDispatcher
  alias Spectre.ActionPlanner
  alias Spectre.Context
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.State

  alias __MODULE__.Agent
  alias __MODULE__.Provider

  @example ~s(OPEN ISSUE WITH: TITLE="Parser bug")
  @alias_example ~s(OPEN ISSUE WITH: SUBJECT="Parser bug")

  test "Kinetic plans and core dispatches an unrelated generic provider" do
    context = %Context{agent: Agent, input: Input.new(""), state: %State{}}

    assert [
             %Mount{
               id: {:remote, :issues},
               module: Provider
             }
           ] = ActionConfig.providers(Agent)

    planner_opts =
      ActionConfig.planner_opts(context,
        effect_owner: Agent,
        effect_scope: :agent
      )

    assert {:ok,
            %Effect{
              name: :open_issue,
              mode: :write,
              status: :pending,
              owner: Agent,
              scope: :agent,
              args: %{"title" => "Parser bug"}
            } = effect} = ActionPlanner.plan(@example, context, planner_opts)

    assert Effect.via(effect) == {:remote, :issues}
    assert is_binary(Effect.schema_hash(effect))

    assert {:ok,
            %{
              opened_issue: "Parser bug",
              provider_id: {:remote, :issues},
              namespace: :integration
            }} = ActionDispatcher.dispatch(effect, context)
  end

  test "metadata aliases map foreign slots onto the canonical schema argument" do
    context = %Context{agent: Agent, input: Input.new(""), state: %State{}}

    planner_opts =
      ActionConfig.planner_opts(context,
        effect_owner: Agent,
        effect_scope: :agent
      )

    assert {:ok, %Effect{name: :open_issue, args: %{"title" => "Parser bug"}} = effect} =
             ActionPlanner.plan(@alias_example, context, planner_opts)

    assert {:ok, %{opened_issue: "Parser bug"}} = ActionDispatcher.dispatch(effect, context)
  end
end

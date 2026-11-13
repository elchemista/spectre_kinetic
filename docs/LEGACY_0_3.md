# Historical Spectre 0.3 integration

These examples describe the former Instance/Run integration. They are retained
for maintaining existing applications, **not as the starting architecture for
core 0.4 AgentServer applications**. Use the [0.4 migration guide](MIGRATING_TO_SPECTRE_0_4.md)
and [current README](../README.md) for the new Stack → Agent → Server lifecycle.
A `protect`/policy block below is legacy application DSL; installing a package
never supplies a 0.4 GAM host binding or end-user consent.

## Spectre Agent Integration

### Stack installation

When Spectre is present, Kinetic publishes its planner and classifier
configuration through the package-local Stack DSL:

```elixir
defmodule MyApp.AI do
  use Spectre.Stack

  install Spectre.Kinetic,
    mode: :closed_moves,
    actions: MyApp.ProjectActions,
    modes: [create_project: :write] do
    classifier MyApp.IntentClassifier
    classifier MyApp.SafetyClassifier, threshold: 0.85
  end
end

defmodule MyApp.ProjectAgent do
  use Spectre.Agent, stack: MyApp.AI

  protect({:kinetic, :create_project}, with: :confirm_project)

  policy :confirm_project do
    request(:confirm_project)
    accept(:confirmed, regex: ~r/^yes$/i)
    reject(:cancelled, regex: ~r/^no$/i)
  end
end
```

Selecting the Stack automatically binds Kinetic as the Agent's Action planner.
When `actions:` is configured it also mounts the built-in Kinetic provider; if
Lens or another installed extension already contributes providers, omit
`actions:` and Kinetic plans over that catalog instead. No second
`use Spectre.Kinetic` is required.

Installation activates planning but does not authorize or execute a selected
move. Spectre still owns policy, staged effects, persistence, idempotency,
provider dispatch, Journal records, and terminal outcomes. Classifier modules
and options remain immutable package-owned configuration; no global planner or
runtime handle is embedded in the Stack.

The planner is re-resolved on every `Spectre.Runtime.advance/2`. It may
interpret Action Language and stage a provider-neutral `Spectre.Effect`, but
it never executes that effect. The host receives a revision-fenced
`Spectre.Invocation` and execution remains exclusively behind
`Spectre.Runtime.resume/3`. Any ETS tables, processes, borrowed runtimes, or
model clients used while planning stay outside serializable `Spectre.Run`
checkpoints.

### Agent Instance boundary

For subject continuity, create or look up the core-owned
`Spectre.Instance` and submit ordinary turns:

```elixir
{:ok, instance} =
  Spectre.instance(MyApp.SpectreSupervisor, MyApp.ProjectAgent, project_id)

{:ok, turn} = Spectre.turn(instance, "create the project")
```

Kinetic is re-resolved while the Instance advances each Run. It contributes a
planner and classifiers only: it does not create Instances, schedule Runs,
retain Agent State, own the ready queue or Invocation registry, authorize a
Move, or execute its staged Effect. Multi-Run fairness and effect resumption
remain core responsibilities. The optional integration does not create a
second operational scheduler or continuity lifecycle.

### Agent-local extension

Define application actions with the existing Kinetic DSL:

```elixir
defmodule MyApp.ProjectActions do
  use SpectreKinetic

  @al ~s(CREATE PROJECT WITH: TITLE="Marketplace MVP")
  @doc "Creates a project"
  @spec create_project(String.t()) :: {:ok, term()} | {:error, term()}
  def create_project(title), do: MyApp.Projects.create(%{title: title})
end
```

Then mount Kinetic on the Agent:

```elixir
defmodule MyApp.ProjectAgent do
  use Spectre.Agent
  use Spectre.Kinetic,
    actions: MyApp.ProjectActions,
    modes: [create_project: :write],
    top_k: 5

  protect({:kinetic, :create_project}, with: :confirm_project)

  policy :confirm_project do
    request(:confirm_project)
    accept(:confirmed, regex: ~r/^yes$/i)
    reject(:cancelled, regex: ~r/^no$/i)
  end

  flow :projects do
    on :CREATE_PROJECT, regex: ~r/\bcreate.*\bproject\b/i do
      act(:create_project)
    end
  end
end
```

The Agent-local form remains useful when no Stack is selected. Its order and
boundary are intentional:

```elixir
use Spectre.Agent
use Spectre.Kinetic, actions: MyApp.ProjectActions
```

`use Spectre.Agent` remains the Agent entry point. `use Spectre.Kinetic`
registers the planner and, when `:actions` is present, its built-in
`Spectre.Kinetic.Actions` provider. The application does not implement an
adapter and should not mount that internal provider with the core `actions`
macro.

At planning time Spectre passes the registered action providers to Kinetic.
Kinetic builds or uses its registry, selects an operation, maps arguments, and
returns a provider-neutral `%Spectre.Action{}`. Spectre then owns policy,
staging, persistence, idempotency, provider dispatch, journal events, and the
terminal outcome.

If MCP, Lens, or another extension already registers providers, use
`use Spectre.Kinetic` without `:actions`. With neither an `:actions` module nor
another provider, Kinetic has no operations to select.

Borrowed and precompiled runtimes are checked against that Agent's provider
catalog before planning. Missing, changed, or unmounted actions fail closed.

Standalone `SpectreKinetic` APIs remain available and do not require Spectre.

### Aliases for generic providers

Any `Spectre.Action.Provider` can be planned by Kinetic, not only the built-in
one. Spectre validates a declared action schema against a closed JSON-Schema
subset and rejects unknown keywords, so slot aliases belong in the action
metadata rather than inside the schema:

```elixir
%{
  name: :open_issue,
  description: "Opens an issue in a remote tracker.",
  mode: :write,
  schema: %{
    type: "object",
    properties: %{title: %{type: "string"}},
    required: ["title"]
  },
  metadata: %{
    examples: [~s(OPEN ISSUE WITH: TITLE="Parser bug")],
    aliases: %{title: ["SUBJECT"]}
  }
}
```

Kinetic then maps `OPEN ISSUE WITH: SUBJECT="Parser bug"` onto the canonical
`"title"` argument, and Spectre still validates the planned arguments against
the schema before the provider executes.

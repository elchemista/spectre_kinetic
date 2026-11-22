# Spectre Kinetic

Kinetic parses Action Language and prepares structured action proposals.
Its standalone runtime handles registries, retrieval and classifier pipelines.
Applications can also install the optional adapter in Spectre core 0.4.1.

[Standalone guide](docs/STANDALONE.md) · [Documentation index](docs/INDEX.md)

## Standalone installation

Add Kinetic from the GitHub branch `0.2.0` to your dependencies.

```elixir
{:spectre_kinetic, github: "elchemista/spectre_kinetic", branch: "0.2.0"}
```

Parse Action Language directly from your application.

```elixir
%{args: %{"TO" => "dev@example.com", "BODY" => "Hello"}} =
  SpectreKinetic.parse_al(~s(SEND EMAIL TO="dev@example.com" BODY="Hello"))
```

For planning against your application's tools, load a registry with
`SpectreKinetic.load_runtime/1` and call `SpectreKinetic.plan/3`. Application
code owns execution of the resulting proposal. See the
[standalone registry and planner example](docs/STANDALONE.md).

## Optional Spectre integration

Add Spectre Core from Hex and Kinetic from GitHub to an AgentServer application.

```elixir
defp deps do
  [
    {:spectre, "~> 0.4.1"},
    {:spectre_kinetic, github: "elchemista/spectre_kinetic", branch: "0.2.0"}
  ]
end
```

For sibling checkouts, replace these with `path: "../spectre"` and
`path: "../spectre_kinetic"` dependencies. Package integration tests use
`SPECTRE_PATH=../spectre mix test`.

### Stack, Agent and Server

![Spectre Kinetic integration architecture](docs/assets/readme-architecture.svg)

[Diagram source](docs/assets/readme-architecture.mmd) · [Migration guide](docs/MIGRATING_TO_SPECTRE_0_4.md).

The Stack installs capabilities, the Agent declares routes and the Server owns
the application callbacks. `Spectre.Kinetic.integration/1` registers the
planner service and the scoped cognitive tool `{:kinetic, :interpret}`.
`use Spectre.Server, tools:` generates its `kinetic/3` helper. Both routes
use the same tool binding.

```elixir
defmodule MyApp.MailActions do
  use SpectreKinetic
  @al ~s(SEND EMAIL TO="dev@example.com" BODY="Hello")
  @doc "Send an email through the host mail transport."
  @spec send_email(String.t(), String.t()) :: {:ok, map()}
  def send_email(to, body), do: {:ok, %{to: to, body: body, simulated: true}}
end

defmodule MyApp.MailAI do
  use Spectre.Stack
  install Spectre.Kinetic,
    mode: :closed_moves, actions: MyApp.MailActions,
    modes: [send_email: :write]
end

defmodule MyApp.MailServer do
  use Spectre.Server, tools: MyApp.MailAI, prompt_root: "priv/mail/prompts"

  def handle_flow({:mail, :send}, _input, ctx),
    do: generate(ctx, :send, planning: false, on_result: :draft)

  def handle_result(:draft, {:generated, response}, ctx),
    do: kinetic(ctx, response, on_result: :prepared)

  def handle_result(:prepared, {:prepared, %{actions: [proposal]}}, ctx) do
    propose(ctx, proposal.operation, proposal.args,
      proposal_metadata: proposal.metadata, on_result: :sent)
  end

  def handle_result(:sent, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
    do: respond(ctx, "The host confirmed the email operation.")

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end

defmodule MyApp.MailAgent do
  use Spectre.Agent, stack: MyApp.MailAI, server: MyApp.MailServer
  model(MyApp.TextModel)
  flow :mail do
    on(:send, regex: ~r/^send email/i)
  end
end
```

`MyApp.TextModel` is your configured model adapter; create
`priv/mail/prompts/send.eex` to request the declared Action Language. The example
mail function is deliberately a simulation: replace its body in the host.
Configure `gam: [operations: %{{:kinetic, :send_email} => [confirm: true]}]`
at AgentServer startup:

```elixir
{:ok, server} = Spectre.Server.start_link(
  agent: MyApp.MailAgent, consumer: self(),
  gam: [operations: %{{:kinetic, :send_email} => [confirm: true]}])
{:ok, interaction} = Spectre.Server.input(server, "send email to the team")
```

Spectre creates the Domain, frozen presentation and registered execution path.
`handle_action/2` can add recipient or business checks. See the [migration guide](docs/MIGRATING_TO_SPECTRE_0_4.md).

The helper accepts a **consolidated generated response**, with `planning: false`
and its original `model_output`. It is called in `handle_result`, after the
model has generated AL. A response already planned with `planning: true` is
rejected. To call the same binding by scope, use
`call_tool(ctx, {:kinetic, :interpret}, response, on_result: :prepared)`.
If the Stack installation uses `as:`, use that installation ID in the tuple.

## Result and recovery contract

`kinetic` returns `{:prepared, %{text: text, actions: proposals}}` to the named
`handle_result/3` callback. Preserve each proposal's provider, schema hash,
owner and scope metadata when calling `propose`. Planning never invokes the
action function. Empty/multiple proposals and errors are application decisions;
the single-proposal example intentionally falls back to the Server default.

The callback returns a context containing commands. Spectre checkpoints the
outbox before workers run, projects portable results and dispatches the next
callback. Streaming previews are not consolidated plans. Cognitive planning is
repeatable; the later governed effect has its own reconciliation lifecycle.
`mode: :closed_moves` is interpreter configuration; `modes:` describes action
effects (`:read`, `:write`, `:destructive`). Neither grants authority.


## Direct APIs and further reading

- [Standalone planning, classifiers, training and runtime guide](docs/STANDALONE.md)
- [Public API contract](docs/PUBLIC_API.md)
- [Classifier training](TRAIN.md)
- [Changes in this branch](CHANGELOG.md)

## Runtime and examples

The generated `kinetic` helper also works in [Skill Server callbacks](https://github.com/elchemista/spectre/blob/0.4.1/docs/SKILLS.md).
Skills share the root's GAM Domain; enable governed operations on the root and
allow them in the mount's `governed:` references. The
[core tool guide](https://github.com/elchemista/spectre/blob/0.4.1/docs/STACK_TOOLS.md) covers scheduling and recovery.
[Managed GAM](https://github.com/elchemista/spectre/blob/0.4.1/docs/MANAGED_GAM.md) covers consent and registered execution.

See the [LiveView demo](https://github.com/elchemista/demo_spectre) for an application,
the [Spectre guides](https://spectre.guide) for articles, and the
[release audit](https://github.com/elchemista/spectre/blob/0.4.1/docs/RELEASE_0_4.md) for verified revisions.

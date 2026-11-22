# Migrating Kinetic to Spectre core 0.4.1

This guide covers integration with Spectre Core `~> 0.4.1` from Hex. Use the
[README dependency example](../README.md#optional-spectre-integration)
to install Kinetic from the `0.2.0` GitHub branch.

## Upgrading from Kinetic 0.1.0

The Stack still uses `install Spectre.Kinetic`. The private `kinetic/3` helper
and its continuation result are unchanged. Kinetic now declares its planner
and interpreter through `integration/1`. Applications can also call
`call_tool(ctx, {:kinetic, :interpret}, response, on_result: :prepared)`.
Use your local installation ID in the tuple when you set `as:`.

Move any Agent-local `use Spectre.Kinetic` declaration and its options to
`install Spectre.Kinetic` in the Agent's Stack. Keep `use SpectreKinetic`
on modules that annotate Elixir functions with Action Language examples.

Keep the existing GAM operations and confirmation policies in the host.
Review any durable command checkpoints using the core migration procedure
before bringing existing sessions forward.

## What changes from core 0.3

| Concern | Existing 0.3 application | Core 0.4 application |
| --- | --- | --- |
| Installation | Stack package configuration | Typed planner and tool declarations through `integration/1` |
| Recognition | Flows and route strategies | Agent keeps declaration-only routes and classifiers |
| Application behavior | Flow bodies / Instance and Run continuation | `Spectre.Server` callbacks and queued commands |
| Tool entry | Direct call / Action provider | Generated helper schedules a command; no import from package |
| Results | Immediate value or Invocation resumption | `handle_result(tag, result, ctx)` after worker result acquisition |
| Effects | Legacy application policies | Automatic AgentServer GAM lifecycle and registered effect adapter |
| Durability | Legacy Run/Instance projection | Server checkpoint, inbox/outbox and typed portable results |

The standalone APIs for planning, registry management, classifiers and training
keep their existing contracts. Applications using those APIs own when and how
their selected actions execute.

## Server callbacks

`use Spectre.Server, tools: MyApp.AI` generates helpers from the installed Stack.
Return the context produced by a helper; the result arrives later through
`handle_result/3` using its `on_result:` tag. Keep process handles outside durable
arguments and assigns. The [core tool guide](https://github.com/elchemista/spectre/blob/0.4.1/docs/STACK_TOOLS.md) defines validation, checkpointing and recovery.

## From a model response to a governed action

In core 0.3, `ask`/`act` in a flow could stage effects for the Instance/Run loop.
In core 0.4 the declaration-only route enters `handle_flow/3`, calls `generate`
and handles the consolidated result with `kinetic` in `handle_result/3`.

```elixir
kinetic(ctx, response, on_result: :prepared)
# callback result: {:prepared, %{text: cleaned_text, actions: proposals}}
```

Use `planning: false` for this explicit step. `planning: true` already runs the
shared core planner; feeding that result back to `kinetic` is rejected as
`:response_already_planned`. Do not feed a preview token or cleaned reply into
the planner: the original `model_output` is needed to preserve AL across replay.

Each proposal carries `operation`, `args` and `metadata`. Forward that metadata
unchanged to `propose`; it includes provider, schema hash, owner and scope.
Kinetic never chooses the host's authority or executes the function. Install
`actions:` to mount Kinetic functions, or use other installed action providers.
`modes:` declares action effect types; `mode: :closed_moves` is not an action mode.

Enable the namespaced operation, for example `{:kinetic, :send_email}`, in the
root Server's `gam: [operations: ...]` configuration. Stack `effects/1`
registration supplies the execution adapter; Spectre automatically freezes the
Candidate, prepares any required Presentation and runs the GAM protocol. An
application `handle_action/2` callback can restrict recipient/content but does
not construct a Host or grant authority. Only the admitted executor calls the
action implementation. A direct action call inside `handle_result` would
bypass that declared boundary.

The [executable all-tools workflow](https://github.com/elchemista/spectre_ecosystem/blob/main/integration/stack_tools/support/workflow.ex)
and [automatic configuration fixture](https://github.com/elchemista/spectre_ecosystem/blob/main/integration/stack_tools/support/configuration.ex) show the
full model → kinetic → propose → GAM → executor → result sequence using fake
external transports. They test the same automatic GAM path used by applications;
real transport credentials and business authorization remain application setup.


## Migration checklist

1. Pin compatible core and package feature revisions; keep the old dependency
   lockfile available for rollback.
2. Separate Stack installation, Agent routes and Server callbacks.
3. Replace legacy flow effects with explicit helper commands/result handlers;
   retain direct APIs only where caller-owned execution is intentional.
4. Configure named resources and trusted identity required by the package.
5. Configure allowed operations and confirmation in AgentServer; use
   `handle_action/2` for business checks. Spectre constructs GAM records and runs
   the registered executor only after admission.
6. Test refused, uncertain and interrupted paths as well as successful results;
   verify portable snapshots before deploying existing conversations.
7. Review checkpoint/installation changes explicitly; never replay a potentially
   executed effect just to work around a migration error.

## Reusable Skill servers

The same helper works in a mounted Skill Server. Configure GAM on the root;
the mount's `governed:` references restrict its effect operations. Skills share
the root Domain while keeping their own state and checkpoints. See the
[Skill guide](https://github.com/elchemista/spectre/blob/0.4.1/docs/SKILLS.md) for setup and consent routing.

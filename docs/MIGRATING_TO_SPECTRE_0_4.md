# Migrating Kinetic to Spectre core 0.4

This guide describes the implemented `feature/stack-tools-0.4` branch, paired
with core `feature/agent-server-gam`. Core 0.4 is unreleased here; satellite
version numbers remain independent. Use the Git/path dependencies in the
[current README](../README.md), not an assumed published Hex version.

## What changes from core 0.3

| Concern | Existing 0.3 application | Core 0.4 application |
| --- | --- | --- |
| Installation | Stack package configuration | Same package registration plus optional `tools/1` descriptor |
| Recognition | Flows and route strategies | Agent keeps declaration-only routes and classifiers |
| Application behavior | Flow bodies / Instance and Run continuation | `Spectre.Server` callbacks and queued commands |
| Tool entry | Direct call / Action provider | Generated helper schedules a command; no import from package |
| Results | Immediate value or Invocation resumption | `handle_result(tag, result, ctx)` after worker result acquisition |
| Effects | Legacy application policies | Host GAM candidate, presentation, consent and admitted executor |
| Durability | Legacy Run/Instance projection | Server checkpoint, inbox/outbox and typed portable results |

The migration does **not** remove `SpectreKinetic.plan/3`, registries, classifiers and training. Direct calls do not acquire
Server semantics merely because the package is installed. Keep standalone
workflows explicitly caller-owned. Historical examples remain in
[the legacy guide](LEGACY_0_3.md).

## Registration and callback lifecycle

The package's existing `Spectre.Stack.Installable` registration contributes
`tools/1`: a versioned descriptor naming the helper, adapter, default operation
and allowed operations. `use Spectre.Server, tools: MyApp.AI` generates private
helper arities 2 and 3 from the immutable Stack. No package-specific import is
needed, and arbitrary public functions are not exposed automatically.

A helper appends a command to `ctx`; it does not synchronously call the library.
Return that context. Pure adapter preparation validates arguments, Spectre
commits the outbox, then a worker runs the selected cognitive operation or
submits the governed proposal. Projected results are acquired before dispatching
`handle_result/3`. `on_result:` selects the callback tag. Unknown operations and
invalid payloads produce typed rejections; declaration/collision mistakes fail
early. Never put PIDs, functions or provider clients into persisted arguments.

Cognitive `:safe` operations can replay after interruption. `:never` operations
return `{:tool_unknown, details}` after uncertain execution and need application
reconciliation. Governed operations require an explicit host binding and follow
GAM reconciliation; they are not automatically retried as cognitive calls.
Native GenServer callbacks remain available through the Server behavior; return
commands through that boundary rather than bypassing its bookkeeping.

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

The host binds the namespaced operation, for example
`{:kinetic, :send_email}`, in `Spectre.Server.GAM` configuration. Its candidate
factory validates recipient/content and supplies the governed material, required
consent/presentation and an executor contract. Only the admitted executor calls
the action implementation. Do not replace this with a direct action call inside
`handle_result`, which would bypass the declared boundary.

The [executable all-tools workflow](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/integration/stack_tools/support/workflow.ex)
and [host/executor fixture](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/integration/stack_tools/support/host.ex) show the
full model → kinetic → propose → GAM → executor → result sequence using fake
external transports. They are integration tests, not production authority policy.

## GAM and consent

Follow the [Governed Act Model manifesto](https://spectre.guide/en/governed-act-model).
Evidence informs decisions; a Mandate bounds authority; an admitted Act is
recorded before its capability is released. Unresolved obligations remain
represented by Duties. Package installation and model output are neither a
Mandate nor end-user consent.

Spectre's default cognitive calls do not ask permission for every model or
classifier computation. The host chooses the governed surface, which may include
protected disclosure or resource consumption. Effects requiring consent wait in
the Server's pending lifecycle; application handlers can confirm, reject,
suspend, resume or schedule audited closure. A topic change is not consent.

See [core AgentServer](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/AGENT_SERVER.md),
[pending lifecycle](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/PENDING_LIFECYCLE.md) and
[Stack tools](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/STACK_TOOLS.md) for host configuration and recovery.

## Migration checklist

1. Pin compatible core and package feature revisions; keep the old dependency
   lockfile available for rollback.
2. Separate Stack installation, Agent routes and Server callbacks.
3. Replace legacy flow effects with explicit helper commands/result handlers;
   retain direct APIs only where caller-owned execution is intentional.
4. Configure named resources and trusted identity required by the package.
5. Bind governed effects to the host's candidates/executors and consent handling.
6. Test refused, uncertain and interrupted paths as well as successful results;
   verify portable snapshots before deploying existing conversations.
7. Review checkpoint/installation changes explicitly; never replay a potentially
   executed effect just to work around a migration error.

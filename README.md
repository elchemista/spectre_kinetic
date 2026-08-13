# SpectreKinetic

Elixir-first planning from Action Language to validated function-call candidates.

The exact `0.3.0` compatibility surface is published in the
[public API manifest](docs/PUBLIC_API.md).

## Optional Spectre integration

Kinetic is a standalone planning toolkit. Spectre is not a runtime or package
dependency: the adapter under `Spectre.Kinetic` is loaded on demand when both
libraries are present. Its manifest targets Stack contract version 1 and
Spectre `~> 0.3.0`. Integration tests resolve Spectre `~> 0.3.0` from Hex.

Kinetic still selects and validates a provider-neutral Action; Spectre remains
responsible for authorization, staging, persistence, idempotency, execution,
and operational-loop ownership.

## 0.1.6 Recoverable Baseline

Version `0.1.6` is a consolidation-only release with no new runtime feature and
no intentional breaking change. Elixir 1.19 on Erlang/OTP 28 is the initially
guaranteed pair. Uniform CI runs format, warnings-as-errors compilation, tests,
Credo, Dialyzer, and ExDoc. Kinetic now lives
on `main`, owns its core-integration contracts, and remains a one-way consumer
of Spectre rather than a test dependency of core.

## Why Use This?

If you are building an agent, the usual question is:

> "Why do I need this? Can I just give the agent my tools?"

You can, but then every request starts by spending prompt space on tool
schemas, argument rules, naming conventions, and examples. With
`spectre_kinetic`, your app keeps that tool knowledge in a compiled registry
instead.

An agent can turn a messy user request:

```text
Tell ops the deploy failed and include the log link
```

into a small Action Language candidate:

```text
SEND MAIL TO="ops@example.com" BODY="Deploy failed: https://logs.example/run/42"
```

Then `spectre_kinetic` maps it to a structured proposal for your real function:

```elixir
%SpectreKinetic.Action{
  selected_tool: "MyApp.Emailer.send/2",
  args: %{
    "email" => "ops@example.com",
    "text" => "Deploy failed: https://logs.example/run/42"
  },
  status: :ok
}
```

That means the agent does not need to carry a giant live tool catalog in its
context window. Compared with exposing the same app surface through MCP, this
is often much lighter for in-app agents: fewer schema tokens, less ceremony,
and more context left for the actual user request, source code, logs, or
conversation history. MCP is useful when you need an external protocol for
tools. `spectre_kinetic` is for when your Elixir app already owns the tools
and you want a compact, local planning layer.

Instead of teaching a model to emit a giant JSON object and then politely
pretending it will never forget a field, you describe your tools in Elixir,
give the planner examples, and let `spectre_kinetic` find the best matching
tool, map the arguments, report missing fields, and leave execution to your
application.

```elixir
defmodule MyApp.Emailer do
  use SpectreKinetic

  @al ~s(SEND EMAIL TO=email@gmail.com BODY=text)
  @doc """
  Send an email to a recipient.

  AL: SEND EMAIL TO="dev@example.com" BODY="hello"
  AL: SEND MAIL TO="ops@example.com" BODY="pager"
  """
  @spec send(email :: String.t(), text :: String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def send(email, text) do
    {:ok, "#{email}:#{text}"}
  end
end
```

That one module gives the planner:

- a canonical Action Language example from `@al`
- extra examples from `AL:` lines in the docs
- the function name, arity, parameter names, and typespec
- argument aliases like `TO -> email` and `BODY -> text`

The result is a registry entry the planner can score, rank, and map from text
like:

```text
SEND MAIL TO="ops@example.com" BODY="pager"
```

In tests, that exact module shape is exercised end to end: extraction produces
`MyApp.Emailer.send/2`, the `AL:` doc examples are kept as examples, `TO` maps
to `email`, `BODY` maps to `text`, and planning `SEND MAIL ...` returns an
`:ok` action with those canonical argument names.

No tool execution happens inside the planner. It plans. Your app decides what
to execute. This is healthier than giving a language model root access and a
motivational quote.

## What You Get

- Code-first tool registration with `use SpectreKinetic`
- Action Language parsing, normalization, and validation
- tool retrieval, scoring, and slot mapping
- compiled registry artifacts with precomputed embeddings
- runtime planning from JSON or compiled ETF registries
- optional server adapter for long-lived runtimes
- optional reranker fallback
- classifier plug pipeline for confidence, slots, safety, and custom policy
- trainable built-in Axon classifiers with editable source datasets

## What It Does Not Do

- execute tools outside Spectre's action lifecycle
- orchestrate workflows
- retry side effects
- invent missing arguments
- hide policy decisions inside planner code

Those are application decisions. The planner gives you a structured action
candidate with scores, args, missing fields, warnings, and classifier results.

## Installation

```elixir
def deps do
  [
    {:spectre, "~> 0.3.0"},
    {:spectre_kinetic, github: "elchemista/spectre_kinetic", tag: "v0.3.0"}
  ]
end
```

The Spectre dependency is needed only for the optional Stack and Agent
integration. Standalone Kinetic planning does not require Spectre at runtime.

Spectre Kinetic is distributed exclusively from GitHub; there is no Hex
package.

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

## Quick Start

Extract tools from your app:

```bash
mix spectre_kinetic.extract \
  --app my_app \
  --out artifacts/registry/registry.json
```

Load the registry and plan:

```elixir
runtime =
  SpectreKinetic.load_runtime!(
    registry_json: "artifacts/registry/registry.json"
  )

{:ok, action} =
  SpectreKinetic.plan(
    runtime,
    ~s(SEND MAIL TO="ops@example.com" BODY="pager")
  )

action.selected_tool
# "MyApp.Emailer.send/2"

action.args
# %{"email" => "ops@example.com", "text" => "pager"}

action.status
# :ok
```

The standalone planner returns data and does not call
`MyApp.Emailer.send/2`. When mounted through `use Spectre.Kinetic`, its
built-in provider invokes the selected function only after Spectre has staged,
authorized, persisted, and dispatched the action.

Primitive argument types declared by the registry are enforced during slot
mapping. Integer, float, and boolean AL literals are safely coerced; invalid
required values are omitted, remain in `missing`, and keep the action
non-executable. Date and URI values are validated while remaining strings for
JSON-friendly output. Literal unions and typed lists are checked recursively;
unknown custom types fail closed until an explicit coercer is defined.

## Compile A Fast Registry

For production-ish use, download an encoder and compile the registry with
embeddings:

```bash
mix spectre_kinetic.download_encoder \
  --model BAAI/bge-small-en-v1.5 \
  --revision 5c38ec7c405ec4b44b94cc5a9bb96e735b38267a \
  --out artifacts/encoder
```

The revision is an immutable Hugging Face commit SHA. When using the default
model, omitting `--revision` uses the pinned SHA above; custom models must pass
their own full commit SHA.

Each download is staged, structurally checked, SHA-256 hashed, and atomically
renamed into place. An exclusive output lock prevents concurrent runs from
interleaving, and a failed install rolls back files already renamed. The task
also writes `encoder-manifest.json`, containing the immutable model identity,
byte sizes, source URLs, and hashes:

```text
artifacts/encoder/
|-- config.json
|-- encoder-manifest.json
|-- model.onnx
`-- tokenizer.json
```

To verify a later download against a trusted manifest, pass it explicitly:

```bash
mix spectre_kinetic.download_encoder \
  --model BAAI/bge-small-en-v1.5 \
  --revision 5c38ec7c405ec4b44b94cc5a9bb96e735b38267a \
  --checksum-manifest trusted/encoder-manifest.json \
  --out artifacts/encoder \
  --force
```

The task checks the manifest's model and revision before downloading, then
checks every artifact hash before replacing any existing artifact. Failed or
partial downloads are removed from the staging directory. JSON artifacts must
decode to objects, and a Git LFS pointer is rejected in place of ONNX bytes.
Without `--force`, existing artifacts are skipped only after verification
against either the explicit manifest or `encoder-manifest.json` already in the
output directory. Use `--force` once for encoder directories created by an
older task that have no manifest.

Then compile the registry:

```bash
mix spectre_kinetic.compile \
  --registry artifacts/registry/registry.json \
  --encoder artifacts/encoder \
  --out artifacts/registry/registry.etf
```

Or extract and compile in one pass:

```bash
mix spectre_kinetic.extract \
  --app my_app \
  --encoder artifacts/encoder \
  --out artifacts/registry/registry.etf
```

Use the compiled runtime:

```elixir
runtime =
  SpectreKinetic.load_runtime!(
    compiled_registry: "artifacts/registry/registry.etf"
  )
```

The ETF stores normalized actions, ordered action IDs, tool-card embeddings,
and registry metadata. In other words: less runtime ceremony, fewer excuses.

## Runtime Configuration

You can configure paths and thresholds in application config:

```elixir
config :spectre_kinetic,
  encoder_model_dir: "/abs/path/to/artifacts/encoder",
  compiled_registry: "/abs/path/to/artifacts/registry/registry.etf",
  registry_json: "/abs/path/to/registry.json",
  tool_threshold: 0.55,
  mapping_threshold: 0.0,
  top_k: 5,
  tool_selection_fallback: :disabled,
  fallback_model_dir: "/abs/path/to/artifacts/reranker",
  fallback_top_k: 3,
  fallback_margin: 0.12,
  reranker_threshold: 0.5,
  reranker_score_index: 1,
  reranker_score_transform: :softmax
```

Environment variables work too:

```bash
export SPECTRE_KINETIC_ENCODER_MODEL_DIR=/abs/path/to/artifacts/encoder
export SPECTRE_KINETIC_COMPILED_REGISTRY=/abs/path/to/artifacts/registry/registry.etf
export SPECTRE_KINETIC_REGISTRY_JSON=/abs/path/to/registry.json
export SPECTRE_KINETIC_TOOL_THRESHOLD=0.55
export SPECTRE_KINETIC_MAPPING_THRESHOLD=0.0
export SPECTRE_KINETIC_TOP_K=5
export SPECTRE_KINETIC_TOOL_SELECTION_FALLBACK=reranker
export SPECTRE_KINETIC_FALLBACK_MODEL_DIR=/abs/path/to/artifacts/reranker
export SPECTRE_KINETIC_FALLBACK_TOP_K=3
export SPECTRE_KINETIC_FALLBACK_MARGIN=0.12
export SPECTRE_KINETIC_RERANKER_THRESHOLD=0.5
```

Explicit options passed to `load_runtime!/1` win over config.

`mapping_threshold` is an execution gate, not just telemetry: a selected tool
whose slot-mapping score falls below it is returned with
`status: :ambiguous_mapping` and must not be executed without clarification.

Public planning calls validate AL, slots, candidate limits, and every score
threshold before touching the runtime. Invalid input returns field-level data,
for example `{:error, {:invalid_options, [%{field: :top_k, reason:
:must_be_positive_integer}]}}`; the supervised adapter remains available for
the next request.

For ONNX rerankers that return more than one class, set
`reranker_score_index` to the relevance-class index. Kinetic deliberately
rejects ambiguous multiclass output instead of assuming class `0`. Use
`reranker_score_transform: :softmax` for multiclass logits or `:sigmoid` for a
single raw logit; already-normalized scores use the default `:identity`.

Library-first runtimes own protected ETS tables in the process that loads
them. Other processes may plan with the runtime, but reload/add/delete and
closure must run in the owner process. Close the runtime when it is no longer
needed:

```elixir
runtime = SpectreKinetic.load_runtime!(registry_json: "registry.json")

try do
  SpectreKinetic.plan(runtime, "SEND EMAIL WITH: TO=dev@example.com")
after
  SpectreKinetic.close_runtime(runtime)
end
```

Use the supervised `SpectreKinetic` child when several callers need shared
registry mutations; its server owns and closes the runtime automatically.

## Classifier Plugs

The core planner stays small. It selects a tool and maps args. Then classifier
plugs can inspect the `PlanContext` and enrich the result.

A classifier can:

- add `classifier_results`
- add warnings
- change status to `:needs_confirmation`, `:needs_clarification`, or another policy status
- halt the classifier pipeline

A classifier should not:

- execute tools
- call an LLM
- secretly replace the selected action
- turn planning into workflow orchestration with a trench coat

Classifier decisions are monotone: a later classifier cannot promote a
restrictive status such as `:rejected`, `:needs_confirmation`, or
`:needs_clarification` back to `:ok`. Selection and mapped arguments remain
owned by the planner.

Custom classifier plugs implement `SpectreKinetic.Classifier`:

```elixir
defmodule MyApp.PlanningClassifier do
  @behaviour SpectreKinetic.Classifier

  alias SpectreKinetic.PlanContext

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%PlanContext{} = context, opts) do
    threshold = Keyword.get(opts, :threshold, 0.75)
    score = context |> PlanContext.scores() |> Map.get(:combined_score, 0.0)

    context =
      if score < threshold do
        context
        |> Map.put(:status, :needs_confirmation)
        |> PlanContext.add_warning("low planning confidence")
      else
        context
      end

    {:ok, PlanContext.put_classifier_result(context, :planning, %{score: score})}
  end
end
```

Configure classifiers once on the runtime:

```elixir
runtime =
  SpectreKinetic.load_runtime!(
    compiled_registry: "artifacts/registry/registry.etf",
    classifiers: [
      {MyApp.PlanningClassifier, threshold: 0.80}
    ]
  )
```

Or override them for one call:

```elixir
SpectreKinetic.plan(runtime, al_text,
  classifiers: [
    {MyApp.PlanningClassifier, threshold: 0.90}
  ]
)

SpectreKinetic.plan(runtime, al_text, classifiers: [])
```

## Optional Built-In Classifiers

The package ships optional built-in Axon classifiers:

- `SpectreKinetic.Classifiers.PlanConfidence`
- `SpectreKinetic.Classifiers.SlotConfidence`
- `SpectreKinetic.Classifiers.SafetyRisk`

They are built-ins, not planner core. Axon support lives under the classifier
namespace, and trained artifacts are not packaged. You train them and point the
runtime at the resulting `model_dir`.

```elixir
runtime =
  SpectreKinetic.load_runtime!(
    compiled_registry: "artifacts/registry/registry.etf",
    classifiers: [
      {SpectreKinetic.Classifiers.PlanConfidence,
       model_dir: "artifacts/classifiers/plan_confidence",
       accept_threshold: 0.80,
       clarify_threshold: 0.55},
      {SpectreKinetic.Classifiers.SlotConfidence,
       model_dir: "artifacts/classifiers/slot_confidence",
       min_slot_confidence: 0.70},
      {SpectreKinetic.Classifiers.SafetyRisk,
       model_dir: "artifacts/classifiers/safety_risk"}
    ]
  )
```

For development, skip artifacts and use deterministic heuristics:

```elixir
classifiers: [
  {SpectreKinetic.Classifiers.PlanConfidence, fallback: :heuristic},
  {SpectreKinetic.Classifiers.SlotConfidence, fallback: :heuristic},
  {SpectreKinetic.Classifiers.SafetyRisk, fallback: :heuristic}
]
```

Safety risk has hard guards. Model predictions can raise risk, and hard guards
can override a model that says something risky is safe. The reverse is not
allowed, because "the model thought deleting the database seemed chill" is not
a governance strategy.

## Training Built-In Classifiers

The bundled seed datasets live in `priv/dataset/`. They are source examples.
You edit text, planner scores, args, actions, slot definitions, and labels;
the training task derives features.

```bash
mix spectre_kinetic.train_classifier plan_confidence \
  --out artifacts/classifiers/plan_confidence

mix spectre_kinetic.train_classifier slot_confidence \
  --out artifacts/classifiers/slot_confidence

mix spectre_kinetic.train_classifier safety_risk \
  --out artifacts/classifiers/safety_risk
```

Train from your own dataset:

```bash
mix spectre_kinetic.train_classifier plan_confidence \
  --dataset data/classifiers/plan_confidence.jsonl \
  --out artifacts/classifiers/plan_confidence \
  --epochs 20 \
  --hidden-dim 32 \
  --batch-size 16 \
  --learning-rate 0.001 \
  --seed 42
```

Each classifier training run writes:

- `params.etf`
- `metadata.json`
- `calibration.json`

`calibration.json` is loaded with the artifact but does not currently choose
runtime thresholds automatically. Configure classifier thresholds explicitly.

The real workflow is:

1. embed/compile your registry
2. run the planner on real examples
3. label the planner output
4. train classifiers from those source rows
5. load the classifier artifact directories at runtime

See [priv/dataset/README.md](priv/dataset/README.md) for exact dataset row
formats and the full command sequence.

## Server Adapter

Use a long-lived runtime process when you do not want to reload artifacts for
every call:

```elixir
{:ok, pid} =
  SpectreKinetic.start_link(
    compiled_registry: "artifacts/registry/registry.etf"
  )

{:ok, action} =
  SpectreKinetic.plan(pid, ~s(LIST DIRECTORY WITH: PATH="/tmp"))
```

## Planning Chains

LLM responses are often a polite paragraph wrapped around the one useful thing.
`plan_chain/3` extracts AL blocks and plans each step:

````elixir
{:ok, chain} =
  SpectreKinetic.plan_chain(runtime, """
  I will do this in order.

  <al>INSTALL PACKAGE WITH: PACKAGE="nginx"</al>

  ```al
  LIST DIRECTORY WITH: PATH="/var/log"
  ```
    """)
````

Configured action classifiers run independently on each extracted action.
Kinetic intentionally has no separate `chain_classifiers` pipeline: ordering,
dependencies, retries, and whole-workflow policy belong to Spectre Directive.

## Reranker Fallback

The first-stage planner is fast. If top candidates are close, you can train an
Axon reranker for bounded fallback:

```bash
mix spectre_kinetic.train_reranker \
  --encoder artifacts/encoder \
  --dataset data/reranker.jsonl \
  --out artifacts/reranker
```

Example dataset row:

```json
{"query":"send message to dev@example.com","tool_card":"MyApp.Emailer.send - ...","label":1}
```

Load it:

```elixir
runtime =
  SpectreKinetic.load_runtime!(
    compiled_registry: "artifacts/registry/registry.etf",
    encoder_model_dir: "artifacts/encoder",
    tool_selection_fallback: :reranker,
    fallback_model_dir: "artifacts/reranker",
    fallback_runtime_module: SpectreKinetic.Reranker.Runtime.Axon
  )
```

For more detail, see [TRAIN.md](TRAIN.md).

## Prompt Helpers

Build dictionary text:

```elixir
SpectreKinetic.dictionary_text!(
  registry_json: "artifacts/registry/registry.json",
  actions: ["MyApp.Emailer.send/2"]
)
```

Build an AL prompt:

```elixir
SpectreKinetic.al_prompt!(
  registry_json: "artifacts/registry/registry.json",
  actions: ["MyApp.Emailer.send/2"],
  request: "send a message to dev@example.com"
)
```

## Mental Model

Think of `spectre_kinetic` as the planner layer between natural-ish text and
your actual application code:

```text
user/LLM text
  -> Action Language
  -> planner retrieval
  -> slot mapping
  -> classifier plugs
  -> action candidate
  -> your application executes or asks for clarification
```

That last arrow belongs to you. The library helps you make the decision with
less guessing and more structure.

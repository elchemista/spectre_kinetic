# spectre_kinetic

Elixir-first planning for turning Action Language into real function calls.

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

- execute your tools
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
    {:spectre_kinetic, github: "elchemista/spectre_kinetic"}
  ]
end
```

## Quick Start

Extract tools from your app:

```bash
mix extract_kinetic \
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

The planner returns data. It does not call `MyApp.Emailer.send/2` for you.
That boundary is the whole point.

## Compile A Fast Registry

For production-ish use, download an encoder and compile the registry with
embeddings:

```bash
mix spectre.download_encoder \
  --model BAAI/bge-small-en-v1.5 \
  --out artifacts/encoder
```

This writes:

```text
artifacts/encoder/
|-- config.json
|-- model.onnx
`-- tokenizer.json
```

Then compile the registry:

```bash
mix compile_kinetic \
  --registry artifacts/registry/registry.json \
  --encoder artifacts/encoder \
  --out artifacts/registry/registry.etf
```

Or extract and compile in one pass:

```bash
mix extract_kinetic \
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
  fallback_margin: 0.12
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
```

Explicit options passed to `load_runtime!/1` win over config.

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
mix spectre.train_classifier plan_confidence \
  --out artifacts/classifiers/plan_confidence

mix spectre.train_classifier slot_confidence \
  --out artifacts/classifiers/slot_confidence

mix spectre.train_classifier safety_risk \
  --out artifacts/classifiers/safety_risk
```

Train from your own dataset:

```bash
mix spectre.train_classifier plan_confidence \
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

```elixir
{:ok, chain} =
  SpectreKinetic.plan_chain(runtime, """
  I will do this in order.

  <al>INSTALL PACKAGE WITH: PACKAGE="nginx"</al>

  ```al
  LIST DIRECTORY WITH: PATH="/var/log"
  ```
  """)
```

## Reranker Fallback

The first-stage planner is fast. If top candidates are close, you can train an
Axon reranker for bounded fallback:

```bash
mix spectre.train_reranker \
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

# spectre_kinetic

Elixir-first planning toolkit for Action Language tool selection.

`spectre_kinetic` takes Action Language (AL) such as:

```text
INSTALL PACKAGE WITH: PACKAGE="nginx"
LIST DIRECTORY WITH: PATH="/var/log"
WRITE NEW BLOG POST FOR elchemista.com WITH: TITLE="My Post" BODY="Hello world"
```

and returns the best matching registered tool, mapped args, missing fields, and ranked alternatives.

## What It Owns

- AL extraction, normalization, and validation
- runtime loading from local artifacts
- tool retrieval, scoring, and slot mapping
- code-first tool extraction from Elixir modules
- registry compilation into `registry.etf`
- optional prompt and dictionary helpers
- optional bounded reranker fallback

## What It Does Not Own

- tool execution
- workflow orchestration
- retry/state-machine logic

## Installation

```elixir
def deps do
  [
    {:spectre_kinetic, path: "../spectre_kinetic"}
  ]
end
```

## Runtime Configuration

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

Environment variables also work:

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

## Quick Start

Load an explicit runtime and plan directly:

```elixir
runtime =
  SpectreKinetic.load_runtime!(
    registry_json: "/abs/path/to/registry.json"
  )

{:ok, action} =
  SpectreKinetic.plan(
    runtime,
    ~s(INSTALL PACKAGE WITH: PACKAGE="nginx")
  )

action.selected_tool
action.args
action.status
```

Use the optional server adapter:

```elixir
{:ok, pid} =
  SpectreKinetic.start_link(
    registry_json: "/abs/path/to/registry.json"
  )

{:ok, action} = SpectreKinetic.plan(pid, ~s(LIST DIRECTORY WITH: PATH="/tmp"))
```

Plan a noisy LLM response:

```elixir
{:ok, chain} =
  SpectreKinetic.plan_chain(runtime, """
  I will do this in order.

  <al>INSTALL PACKAGE WITH: PACKAGE="nginx"</al>

  ```al
  LIST DIRECTORY WITH: PATH="/var/log"
  ``
  """)
```

## Code-First Tool Registration

You mark planner-visible functions with:

- `use SpectreKinetic`

`@al` holds the canonical AL declaration for the next public function.
Any `AL:` lines inside `@doc` are collected as extra examples.

Example:

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

What gets inferred from that:

- canonical example from `@al`
- extra examples from `@doc`
- function name and arity
- parameter names from the function definition
- types from the typespec when available
- argument aliases from observed AL slot names

Argument mapping rule:

1. exact AL slot name to parameter name match
2. positional fallback for any remaining slots

So for:

```elixir
@al ~s(SEND EMAIL TO=email@gmail.com BODY=text)
def send(email, text), do: ...
```

the inferred args are effectively:

- `email` with alias `TO`
- `text` with alias `BODY`

If your function is:

```elixir
def send(to, body), do: ...
```

then no aliases need to be inferred for those slots because the exact-name rule already matches `TO -> to` and `BODY -> body`.

## Extracting Tools

Extract the code-defined tools from a compiled app into source registry JSON:

```bash
mix extract_kinetic --app my_app --out registry.json
```

Extract and compile directly into `registry.etf` in one step:

```bash
mix extract_kinetic \
  --app my_app \
  --encoder artifacts/encoder \
  --out artifacts/registry/registry.etf
```

This task:

1. compiles the app
2. finds modules exporting `__spectre_tools__/0`
3. reads docs and specs from compiled modules
4. merges `@al` and `AL:` doc examples
5. normalizes the result into the planner action schema
6. writes either `registry.json` or `registry.etf`

## Compiling Registry Artifacts

If you already have a `registry.json`, compile it with:

```bash
mix compile_kinetic \
  --registry registry.json \
  --encoder artifacts/encoder \
  --out artifacts/registry/registry.etf
```

This compiles:

- normalized action definitions
- ordered action IDs
- precomputed tool-card embeddings
- registry metadata

## Encoder Artifacts

Download encoder artifacts for runtime embedding:

```bash
mix spectre.download_encoder \
  --model BAAI/bge-small-en-v1.5 \
  --out artifacts/encoder
```

Typical layout:

```text
artifacts/encoder/
├── config.json
├── model.onnx
└── tokenizer.json
```

## Reranker Training

Reranker training is Elixir-native via `Nx` and `Axon`:

```bash
mix spectre.train_reranker \
  --encoder artifacts/encoder \
  --dataset data/reranker.jsonl \
  --out artifacts/reranker
```

Each JSONL line must contain:

```json
{"query":"send message to dev@example.com","tool_card":"Dynamic.Email.send - ...","label":1}
```

The task writes:

- `params.etf`
- `metadata.json`
- `calibration.json`

If you want to use the Axon reranker at runtime:

```elixir
runtime =
  SpectreKinetic.load_runtime!(
    registry_json: "/abs/path/to/registry.json",
    encoder_model_dir: "/abs/path/to/artifacts/encoder",
    tool_selection_fallback: :reranker,
    fallback_model_dir: "/abs/path/to/artifacts/reranker",
    fallback_runtime_module: SpectreKinetic.Reranker.Runtime.Axon
  )
```

For a fuller explanation of:

- how the training matrix is built
- what the model actually learns
- when the planner invokes reranking
- why the fallback stays efficient
- how Axon reranker artifacts differ from ONNX reranker artifacts

see [TRAIN.md](https://github.com/elchemista/spectre_kinetic/blob/master/TRAIN.md).

## Prompt Helpers

Build dictionary text:

```elixir
SpectreKinetic.dictionary_text!(
  registry_json: "/abs/path/to/registry.json",
  actions: ["Linux.Apt.install/1"]
)
```

Build AL prompt:

```elixir
SpectreKinetic.al_prompt!(
  registry_json: "/abs/path/to/registry.json",
  actions: ["Linux.Apt.install/1"],
  request: "install nginx"
)
```

# spectre_kinetic

Elixir-first planning toolkit for agent action selection.

`spectre_kinetic` takes Action Language (AL) such as:

```text
INSTALL PACKAGE WITH: PACKAGE="nginx"
LIST DIRECTORY WITH: PATH="/var/log"
WRITE NEW BLOG POST FOR elchemista.com WITH: TITLE="My Post" BODY="Hello world"
```

and returns the best matching registered tool, mapped args, missing fields, and ranked alternatives.

## What It Owns

- AL extraction, normalization, and validation
- planner runtime loading
- registry compilation and loading
- retrieval, scoring, and slot mapping
- optional prompt and dictionary helpers
- optional bounded reranker fallback for ambiguous tool selection

## What It Does Not Own

- tool execution
- workflow orchestration
- retry/state-machine logic
- Rust/NIF runtime infrastructure

## Runtime Model

The canonical runtime is a plain Elixir struct loaded from local artifacts:

- `encoder_model_dir` for ONNX encoder inference
- `compiled_registry` for precompiled `registry.etf`
- optional `registry_json` for development and compilation flows
- optional `fallback_model_dir` for reranker artifacts

The server wrapper is now only a thin adapter over that runtime.

## Installation

```elixir
def deps do
  [
    {:spectre_kinetic, path: "../spectre_kinetic"}
  ]
end
```

Core runtime dependencies:

- `Nx`
- `Ortex`
- `Tokenizers`
- optional `Axon` for Elixir-native reranker training

## Configuration

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

Library-first:

```elixir
runtime =
  SpectreKinetic.load_runtime!(
    registry_json: "/abs/path/to/registry.json"
  )

{:ok, action} =
  SpectreKinetic.plan(
    runtime,
    ~s|INSTALL PACKAGE WITH: PACKAGE="nginx"|
  )

action.selected_tool
action.args
action.status
```

Server wrapper:

```elixir
{:ok, pid} =
  SpectreKinetic.start_link(
    registry_json: "/abs/path/to/registry.json"
  )

{:ok, action} = SpectreKinetic.plan(pid, ~s|LIST DIRECTORY WITH: PATH="/tmp"|)
```

Plan a noisy LLM response:

```elixir
{:ok, chain} =
  SpectreKinetic.plan_chain(pid, """
  I will do this in order.

  <al>INSTALL PACKAGE WITH: PACKAGE="nginx"</al>

  ```al
  LIST DIRECTORY WITH: PATH="/var/log"
  ```
  """)
```

## Registry Pipeline

Compile a human-editable registry into `registry.etf`:

```bash
mix spectre.compile_registry \
  --registry registry.json \
  --encoder artifacts/encoder \
  --out artifacts/registry/registry.etf
```

## Encoder Pipeline

Download encoder artifacts for runtime embedding:

```bash
mix spectre.download_encoder \
  --model BAAI/bge-small-en-v1.5 \
  --out artifacts/encoder
```

## Elixir-Native Training

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

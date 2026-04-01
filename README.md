# spectre_kinetic

Elixir wrapper around [spectre-kinetic-engine](https://github.com/elchemista/spectre-kinetic-engine).

This project lets an Elixir app use the Rust planner as a fast deterministic tool selector for agent workflows. You give it Action Language (AL) text such as:

```text
INSTALL PACKAGE WITH: PACKAGE="nginx"
LIST DIRECTORY {path}
CREATE STRIPE PAYMENT LINK WITH: AMOUNT=5000 PRODUCT_NAME="Premium Plan"
```

and it returns the registered tool that best matches that instruction, plus mapped args, confidence, and fallback alternatives when nothing is strong enough.

## What This Project Is For

Use `spectre_kinetic` when:

- you want the LLM to describe an action in AL, but you do not want the LLM choosing the final tool directly
- you want tool dispatch to be deterministic and cheap at runtime
- you want reusable tool matching based on a fixed registry and a frozen embedding pack
- you want to extract multiple AL actions from a noisy LLM response and run them in order

This is not a general LLM orchestration framework. It is a thin Elixir host around the Rust `spectre-kinetic-engine`.

## How It Works

Runtime flow:

1. Your app sends one AL instruction, or a whole LLM response containing AL.
2. The Elixir layer extracts AL blocks or lines from the response.
3. The Rust planner normalizes the AL and builds an `action_text`.
4. The planner embeds that action text with a precomputed static pack.
5. The planner compares it against the compiled registry with cosine similarity.
6. The planner maps AL slots to tool params.
7. You get back the selected tool, confidence, args, missing params, notes, and alternatives.

Important design point:

- the Rust engine is the source of truth for planning
- the Elixir side is mainly for supervision, extraction, prompt generation, config, and result shaping

## Main Concepts

`model pack`

- A frozen embedding pack used by the planner at runtime.
- It contains files like `pack.json`, `tokenizer.json`, `token_embeddings.bin`, and `weights.json`.
- You need this because the engine still needs a token embedding space at runtime, even though it does not run a full teacher model during planning.

`registry.json`

- Human-editable description of your tools.
- Contains tool ids, docs, args, aliases, defaults, and AL examples.
- You use this to define or change what the planner can dispatch to.

`registry.mcr`

- Compiled binary registry built from `registry.json` and the model pack.
- This is what the Rust planner actually loads at runtime for fast dispatch.

`dictionary`

- Compact text derived from your registry and optionally a corpus.
- Intended for LLM prompts so the model sees allowed keywords, slots, and examples.

`AL`

- Action Language text the planner understands.
- `WITH:` is valid, but not mandatory.
- The engine also supports action-body placeholders and positional forms such as `INSTALL PACKAGE {package} VIA APT`.

## What You Keep In Production

For normal production inference, you only need:

- the Elixir app
- the compiled native library built by Rustler
- one model pack directory
- one compiled `registry.mcr`

Usually you do not need in production:

- `registry.json`
- training corpus files
- teacher ONNX model
- tokenizer used for training
- dictionary extraction inputs

Keep `registry.json` if you want:

- to rebuild registries in your deploy pipeline
- to generate prompt dictionaries at runtime
- to inspect/edit tool definitions outside the compiled `.mcr`

## Why Download A Model

The runtime planner depends on a pinned embedding pack. Without that pack, the Rust dispatcher cannot embed AL text and compare it to the registry.

The `mix spectre.download_model` task exists mainly to make local setup easier:

- for development
- for testing against the upstream example assets
- for bootstrapping a first local environment

In a real production system, you usually pin and ship the pack yourself as a versioned artifact instead of downloading it ad hoc on boot.

## Project Structure

```text
lib/
  engine/
    action.ex
    action_chain.ex
    native.ex
    runtime.ex
    server.ex
  llm/
    dictionary.ex
    extractor.ex
    parser.ex
    prompt.ex
  mix/tasks/
    spectre.build_registry.ex
    spectre.download_model.ex
    spectre.extract_dict.ex
    spectre.show.ex
    spectre.train.ex
  spectre_kinetic.ex
```

## Installation Shape

The app expects a Rust toolchain because the NIF is built from `native/spectre_ffi`.

Typical runtime config:

```elixir
config :spectre_kinetic,
  model_dir: "/abs/path/to/pack",
  registry_mcr: "/abs/path/to/registry.mcr",
  registry_json: "/abs/path/to/registry.json",
  confidence: 0.8,
  mapping_threshold: 0.35
```

Environment variables also work:

```bash
export SPECTRE_KINETIC_MODEL_DIR=/abs/path/to/pack
export SPECTRE_KINETIC_REGISTRY_MCR=/abs/path/to/registry.mcr
export SPECTRE_KINETIC_REGISTRY_JSON=/abs/path/to/registry.json
export SPECTRE_KINETIC_CONFIDENCE=0.8
export SPECTRE_KINETIC_MAPPING_THRESHOLD=0.35
```

`confidence`, `confidence_threshold`, and `tool_threshold` are treated as aliases for the tool-selection cutoff. If the best match scores below that threshold, the planner returns no selected tool and the action status becomes `:no_tool`.

## Quick Start

Start a dispatcher:

```elixir
{:ok, pid} =
  SpectreKinetic.start_link(
    model_dir: "/abs/path/to/pack",
    registry_mcr: "/abs/path/to/registry.mcr"
  )
```

Plan one AL instruction:

```elixir
{:ok, action} =
  SpectreKinetic.plan(
    pid,
    ~s|INSTALL PACKAGE WITH: PACKAGE="nginx"|
  )

action.selected_tool
action.confidence
action.args
action.status
action.alternatives
```

Plan a whole LLM response with multiple actions:

```elixir
{:ok, chain} =
  SpectreKinetic.plan_chain(pid, """
  I will do this in order.

  <al>INSTALL PACKAGE WITH: PACKAGE="nginx"</al>

  ```al
  LIST DIRECTORY WITH: PATH="/var/log"
  """)

Enum.map(chain.actions, &{&1.index, &1.selected_tool, &1.args})
```

Extract AL without planning:

```elixir
{clean_text, al_lines} = SpectreKinetic.extract_al(response_text)
```

Parse one AL helper-side:

```elixir
SpectreKinetic.parse_al(~s|CREATE PAYMENT LINK WITH: AMOUNT=5000 CURRENCY="usd"|)
```

## Dispatcher Concurrency And Scaling

One `SpectreKinetic` server is a good default when you want one supervised planner service:

- simple startup and supervision
- one shared named process to call from anywhere in the app
- one native handle opened once at boot

But one dispatcher also means one Elixir mailbox and one native handle. Under heavy traffic, that single process can become a bottleneck because every `plan/3`, `plan_request/2`, `plan_json/2`, `add_action/2`, and `delete_action/2` request is serialized through the same server.

If you need more throughput, start multiple dispatchers. Each dispatcher opens its own native handle, so planning work can run in parallel across workers.

```elixir
children = [
  {SpectreKinetic,
   name: :spectre_planner_a,
   model_dir: "/abs/path/to/pack",
   registry_mcr: "/abs/path/to/registry.mcr"},
  {SpectreKinetic,
   name: :spectre_planner_b,
   model_dir: "/abs/path/to/pack",
   registry_mcr: "/abs/path/to/registry.mcr"}
]

{:ok, _pid} = Supervisor.start_link(children, strategy: :one_for_one)

servers = [:spectre_planner_a, :spectre_planner_b]

results =
  [
    ~s|INSTALL PACKAGE WITH: PACKAGE="nginx"|,
    ~s|LIST DIRECTORY WITH: PATH="/var/log"|,
    ~s|CREATE STRIPE PAYMENT LINK WITH: AMOUNT=5000 PRODUCT_NAME="Premium Plan"|
  ]
  |> Task.async_stream(
    fn al ->
      server = Enum.random(servers)
      SpectreKinetic.plan(server, al)
    end,
    ordered: false,
    max_concurrency: length(servers)
  )
  |> Enum.to_list()
```

Keep these tradeoffs in mind:

- one dispatcher is easiest to reason about, but it serializes traffic
- many dispatchers can improve throughput, but each one opens its own model/registry handle
- more workers usually mean more memory use and more startup cost
- if you mutate the in-memory registry with `add_action/2`, `delete_action/2`, or `reload_registry/2`, apply the same change to every worker to keep them in sync

## Result Shapes

### `%SpectreKinetic.Action{}`

`plan/3`, `plan_request/2`, and `plan_json/2` return one `%SpectreKinetic.Action{}`.

Fields:

- `index`
  - Position inside a chain result.
  - `nil` for a standalone `plan/3` call.

- `al`
  - The AL string that was actually planned.
  - This is the normalized or extracted instruction the planner used as input.

- `status`
  - Planner outcome.
  - Common values are `:ok`, `:no_tool`, `:missing_args`, `:ambiguous_mapping`, and `:error`.

- `selected_tool`
  - The matched tool id.
  - `nil` when nothing passed the threshold or when planning failed before a tool could be selected.

- `confidence`
  - Similarity score for the selected tool.
  - Usually a float, or `nil` when no tool was selected.

- `args`
  - Final mapped arguments ready to send to the selected tool.
  - Always a map.

- `missing`
  - Required parameter names that are still missing after mapping and defaults.
  - Usually an empty list when `status == :ok`.

- `notes`
  - Planner notes about mapping quality, unmatched fields, or useful hints for the caller.
  - Always a list of strings.

- `alternatives`
  - Ranked fallback entries returned by the planner.
  - Each entry is a map with:
    - `:kind` as either `:candidate` or `:suggestion`
    - `:id` as the alternative tool id
    - `:score` as the alternative score
    - `:al` as a suggested AL command when the entry is a suggestion

- `error`
  - Wrapper-level or extraction-level failure reason.
  - Typically set only when `status == :error`.

Full example:

```elixir
%SpectreKinetic.Action{
  index: nil,
  al: ~s|INSTALL PACKAGE WITH: PACKAGE="nginx"|,
  status: :ok,
  selected_tool: "Linux.Apt.install/1",
  confidence: 0.9821,
  args: %{"package" => "nginx"},
  missing: [],
  notes: [],
  alternatives: [
    %{kind: :candidate, id: "Linux.Dnf.install/1", score: 0.7312},
    %{kind: :candidate, id: "Linux.Pacman.install/1", score: 0.7024}
  ],
  error: nil
}
```

Example when no tool passes the threshold:

```elixir
%SpectreKinetic.Action{
  index: nil,
  al: "DO SOMETHING COMPLETELY UNKNOWN",
  status: :no_tool,
  selected_tool: nil,
  confidence: nil,
  args: %{},
  missing: [],
  notes: [],
  alternatives: [
    %{
      kind: :suggestion,
      id: "Linux.Apt.install/1",
      score: 0.41,
      al: ~s|INSTALL PACKAGE WITH: PACKAGE="something"|
    }
  ],
  error: nil
}
```

### `%SpectreKinetic.ActionChain{}`

`plan_chain/3` returns one `%SpectreKinetic.ActionChain{}`.

Fields:

- `actions`
  - Ordered list of `%SpectreKinetic.Action{}` values.
  - Order matches the extracted execution order from the source text.
  - Entries can include successful actions and failed ones with `status: :error`.

Full example:

```elixir
%SpectreKinetic.ActionChain{
  actions: [
    %SpectreKinetic.Action{
      index: 0,
      al: ~s|INSTALL PACKAGE WITH: PACKAGE="nginx"|,
      status: :ok,
      selected_tool: "Linux.Apt.install/1",
      confidence: 0.9821,
      args: %{"package" => "nginx"},
      missing: [],
      notes: [],
      alternatives: [
        %{kind: :candidate, id: "Linux.Dnf.install/1", score: 0.7312}
      ],
      error: nil
    },
    %SpectreKinetic.Action{
      index: 1,
      al: ~s|LIST DIRECTORY WITH: PATH="/var/log"|,
      status: :ok,
      selected_tool: "Linux.Coreutils.ls/1",
      confidence: 0.9553,
      args: %{"path" => "/var/log"},
      missing: [],
      notes: [],
      alternatives: [],
      error: nil
    },
    %SpectreKinetic.Action{
      index: 2,
      al: "BROKEN ACTION",
      status: :error,
      selected_tool: nil,
      confidence: nil,
      args: %{},
      missing: [],
      notes: [],
      alternatives: [],
      error: :invalid_al_verb
    }
  ]
}
```

Useful helpers:

- `SpectreKinetic.ActionChain.count(chain)` returns the number of actions
- `SpectreKinetic.ActionChain.ok_actions(chain)` returns only actions with `status == :ok`

## LLM Workflow

This library includes a small LLM layer for AL generation.

Dictionary helpers:

```elixir
dictionary =
  SpectreKinetic.dictionary!(
    registry_json: "/abs/path/to/registry.json",
    actions: ["Linux.Apt.install/1", "Linux.Dnf.install/1"],
    top_n: 50,
    example_limit: 10
  )

prompt_text =
  SpectreKinetic.dictionary_text!(
    registry_json: "/abs/path/to/registry.json",
    actions: ["Linux.Apt.install/1"]
  )
```

Prompt builder:

```elixir
prompt =
  SpectreKinetic.al_prompt!(
    registry_json: "/abs/path/to/registry.json",
    actions: ["Linux.Apt.install/1", "Linux.Dnf.install/1"],
    request: "install nginx on this Ubuntu machine",
    top_n: 30,
    example_limit: 4
  )
```

Render from a prebuilt dictionary:

```elixir
dictionary = SpectreKinetic.dictionary!(registry_json: "/abs/path/to/registry.json")

prompt =
  SpectreKinetic.render_al_prompt(
    dictionary,
    request: "list the /tmp directory",
    output: :lines
  )
```

Prompt guidance:

- the best prompt is one that makes the LLM copy registry example structure
- do not force every action into `WITH: KEY=value`
- use only slots and examples that exist in the registry subset you expose
- return AL in a wrapper format that the extractor can recover reliably, such as `<al>...</al>` or `AL: ...`

## Mix Tasks

### `mix spectre.download_model`

Purpose:

- install the upstream example model pack locally
- optionally install the upstream test registry files

Typical use:

```bash
mix spectre.download_model \
  --out ./models/minilm \
  --with-test-registry \
  --registry-dir ./models/registry
```

Other useful flags:

- `--pack minilm`
- `--commit <git-sha>`
- `--source-dir /path/to/local/spectre-kinetic-engine`
- `--force`

Notes:

- this task prefers copying from a local checkout when available
- otherwise it derives the git ref from the native Cargo dependency and downloads matching raw files
- use it for setup and experimentation, not as your only production distribution strategy

### `mix spectre.show`

Purpose:

- inspect a model/registry pair
- plan one AL statement
- plan a whole LLM response containing multiple AL blocks

Show environment summary only:

```bash
mix spectre.show \
  --model ./models/minilm \
  --registry ./models/registry/test_registry.mcr
```

Inspect one AL instruction:

```bash
mix spectre.show \
  --model ./models/minilm \
  --registry ./models/registry/test_registry.mcr \
  --al 'INSTALL PACKAGE WITH: PACKAGE="nginx"' \
  --format json
```

Inspect a whole LLM response:

```bash
mix spectre.show \
  --model ./models/minilm \
  --registry ./models/registry/test_registry.mcr \
  --text $'Plan:\n<al>INSTALL PACKAGE WITH: PACKAGE="nginx"</al>\n```al\nLIST DIRECTORY WITH: PATH="/tmp"\n```' \
  --format json
```

Read the input from a file:

```bash
mix spectre.show \
  --model ./models/minilm \
  --registry ./models/registry/test_registry.mcr \
  --file ./sample_response.txt
```

Override planner thresholds:

```bash
mix spectre.show \
  --model ./models/minilm \
  --registry ./models/registry/test_registry.mcr \
  --al 'DO SOMETHING COMPLETELY UNKNOWN' \
  --tool-threshold 0.9 \
  --mapping-threshold 0.35
```

Pass explicit slots:

```bash
mix spectre.show \
  --model ./models/minilm \
  --registry ./models/registry/test_registry.mcr \
  --al 'INSTALL PACKAGE {package} VIA APT' \
  --slot package=nginx
```

### `mix spectre.build_registry`

Purpose:

- compile a human-editable `registry.json` into a runtime `registry.mcr`

Example:

```bash
mix spectre.build_registry \
  --model ./models/minilm \
  --registry ./registry.json \
  --out ./registry.mcr
```

Use this whenever:

- you create a new tool
- you change args, aliases, defaults, docs, or AL examples
- you want a fresh `.mcr` for deployment

### `mix spectre.extract_dict`

Purpose:

- build a compact prompt dictionary from a corpus and optional registry

Example:

```bash
mix spectre.extract_dict \
  --corpus ./corpus.jsonl \
  --registry ./registry.json \
  --out ./DICTIONARY.txt \
  --top-n 200
```

Useful flags:

- `--seed "INSTALL PACKAGE LIST DIRECTORY"`
- `--top-n 100`

Use this when:

- you want a small prompt artifact for zero-shot or low-shot AL generation
- you want to bias the LLM toward the right vocabulary before extraction/planning

### `mix spectre.train`

Purpose:

- train a new runtime pack using the upstream Rust training pipeline

Example:

```bash
mix spectre.train \
  --teacher-onnx ./teacher.onnx \
  --tokenizer ./tokenizer.json \
  --corpus ./corpus.jsonl \
  --out ./pack
```

Optional flags:

- `--max-len 32`
- `--dim 256`
- `--zipf`

Use this when:

- the upstream example pack is not enough for your domain
- you want a custom pack trained from your own corpus and examples

You do not run this in normal request-time production. It is an offline build step.

## Recommended Lifecycle

For local development:

1. Download or prepare a model pack.
2. Write a `registry.json`.
3. Build `registry.mcr`.
4. Use `mix spectre.show` to inspect matches.
5. Integrate `SpectreKinetic.plan/3` into your app.

For an LLM-integrated system:

1. Build a scoped dictionary or prompt from the registry.
2. Ask the LLM to output AL only.
3. Extract AL from the LLM response.
4. Plan each AL action through the Rust engine.
5. Execute only when confidence is above your configured threshold.

For production:

1. Version your model pack.
2. Version your `registry.json`.
3. Build and ship `registry.mcr`.
4. Configure a confidence threshold.
5. Keep the runtime surface small: Elixir app + native lib + model pack + `.mcr`.

## Notes

- `plan/3`, `plan_request/2`, and `plan_json/2` return `%SpectreKinetic.Action{}`.
- `plan_chain/3` is intended for mixed LLM prose plus AL extraction.
- the Elixir layer includes a narrow exact-slot-name fallback for obvious `WITH:` literals
- helper tasks run through the Rust helper binary in `native/spectre_ffi`
- set `SPECTRE_KINETIC_HELPER_RELEASE=1` to run helper tasks with `cargo run --release`

## Test

```bash
mix test
```

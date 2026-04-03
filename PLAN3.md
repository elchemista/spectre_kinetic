# PLAN3: Clean Elixir-First Agent Planning Toolkit

## Summary

Build a **breaking v2** that removes all legacy Rust infrastructure and makes this repo a focused **Elixir planning toolkit** for agent systems:

- AL extraction and parsing
- tool planning and slot mapping
- registry compilation/loading
- optional prompt/dictionary helpers
- optional bounded **reranker fallback** for hard cases

Key architectural decisions:

- **Remove Rust entirely** from the main package: no `rustler`, no NIF, no Rust helper CLI, no `.mcr`
- **Training is Elixir-native** with `Nx`/`Axon`; **ONNX is runtime inference/export only**
- **ETS is the only built-in registry backend**
- keep a **registry behavior** so users can implement PostgreSQL, MongoDB, etc. themselves
- fallback model is **reranker-only**, not generative

Important clarification for the new design:

- **model training artifact** and **compiled registry artifact** are different things
- training produces model artifacts such as `encoder.onnx`, `reranker.onnx`, tokenizer/config, and calibration metadata
- registry compilation produces the runtime tool bundle such as `registry.etf` with normalized tools, alias metadata, and precomputed embeddings

## Core Criticism

The current project is architecturally split across incompatible identities:

- it still markets itself as a Rust wrapper while the codebase is already moving toward an Elixir planner
- it has duplicated runtime concepts:
  runtime struct, server wrapper, native handle, helper CLI, mixed config aliases
- it mixes three concerns too tightly:
  planner core, prompt-generation helpers, and legacy native build/training flows
- it carries old compatibility shape directly in the public API, which makes the top-level facade too broad and harder to reason about
- the current test reality shows the planner is still unstable in meaningful cases, especially note insertion retrieval and task update slot assignment, so more abstraction without cleanup would make the package harder to fix
- training/build tasks are fragmented:
  Rust helper tasks for old flow, Elixir tasks for new flow, and artifact stories that are not cleanly separated

## Target Product Shape

### Package identity

This repo should become:

- an **Elixir-first planning toolkit** for agent action selection
- not a Rust wrapper
- not a workflow/execution framework

It should own:

- AL extraction/parsing/validation
- runtime loading
- retrieval/scoring/mapping
- compiled registry generation
- optional prompt/dictionary generation

It should not own:

- tool execution
- orchestration/retries/state machines
- native Rust training/build pipelines

### Runtime model

The only canonical runtime should be a plain runtime struct:

- loaded explicitly from local artifacts
- passed directly into plan functions
- immutable from caller perspective
- supports action add/delete/reload by returning updated runtime structs

The `GenServer` server, if kept at all, should be a thin adapter module, not the architectural center.

### Registry model

Keep:

- `Registry` behavior as the planner boundary
- `ETS` as the default and only built-in implementation

Do not ship first-party PostgreSQL or MongoDB backends in v2.

Do ship:

- a stable backend contract
- contract tests for third-party backend implementations
- a documented required data shape and indexing expectations

This gives persistence flexibility without turning the core package into a storage integration matrix.

## Required Removals And Simplifications

### Remove completely

Delete from the main package:

- `{:rustler, ...}` dependency
- [lib/engine/native.ex](/home/dev/Sviluppo/personal/spectre_kinetic/lib/engine/native.ex)
- [lib/engine/helper.ex](/home/dev/Sviluppo/personal/spectre_kinetic/lib/engine/helper.ex)
- [native/spectre_ffi](/home/dev/Sviluppo/personal/spectre_kinetic/native/spectre_ffi)
- Rust-driven Mix tasks:
  `spectre.train`
  `spectre.build_registry`
  `spectre.download_model`
  `spectre.extract_dict`
- Rust `.mcr` registry support
- `model_dir` / `registry_mcr` config path model
- threshold alias sprawl that keeps `confidence`, `confidence_threshold`, and `tool_threshold` all alive forever

### Simplify public config

Use one explicit config model:

- `encoder_model_dir`
- `compiled_registry`
- optional `registry_json` for development/compile flows
- `tool_threshold`
- `mapping_threshold`
- `top_k`
- `tool_selection_fallback`
- `fallback_model_dir`
- `fallback_top_k`
- `fallback_margin`

Recommended fallback flag name:

- `tool_selection_fallback`

Values:

- `:disabled`
- `:reranker`

Reason: it describes exactly where the fallback applies, and avoids vague names like `model_fallback`.

### Simplify public API

Make runtime-first usage the canonical API:

- `load_runtime/1`
- `load_runtime!/1`
- `plan/2`
- `plan/3`
- `plan_request/2`
- `plan_json/2`
- `reload_registry/2`
- `add_action/2`
- `delete_action/2`
- `action_count/1`

If a server adapter remains, move it under an adapter namespace and stop documenting it as the main entrypoint.

## Implementation Changes

### 1. Finish the runtime-first architecture

- planner internals operate on runtime/backend state only
- remove internal dependence on legacy process-oriented abstractions
- centralize request normalization and default resolution in one runtime/config module
- make top-level `SpectreKinetic` facade thin and predictable

### 2. Separate artifacts cleanly

Define two distinct offline pipelines:

- **Model pipeline**
  trains/distills encoder and optional reranker in Elixir
  exports ONNX runtime artifacts
- **Registry pipeline**
  compiles `registry.json` into `registry.etf`
  precomputes tool embeddings using the encoder artifacts

Artifact layout:

- `artifacts/encoder/{model.onnx, tokenizer.json, config.json, metadata.json}`
- `artifacts/reranker/{model.onnx, tokenizer.json, config.json, metadata.json}`
- `artifacts/registry/{registry.etf}`

### 3. Replace Rust training with Elixir training

Training plan for v2:

- use `Nx`/`Axon` for training or distillation
- export trained inference models to ONNX for runtime use
- do not treat registry compilation as “training”
- keep training optional, but first-party and Elixir-native

Recommended scope for first training implementation:

- encoder distillation or fine-tuning pipeline for tool retrieval text pairs
- optional reranker training for pairwise query-tool ranking
- calibration step that emits thresholds/margins metadata used by runtime

Do not attempt a “direct ONNX training” architecture.

### 4. Add bounded reranker fallback

Fallback behavior should be:

- disabled by default
- enabled with `tool_selection_fallback: :reranker`
- invoked only when:
  top candidate is below threshold, or
  top-2 margin is too small, or
  required args remain unresolved
- input is `(AL text, candidate tool card)` over top-K candidates only
- reranker may change selected tool
- final arg filling remains deterministic and schema-aware

If reranker still cannot choose confidently:

- return `:no_tool` or `:missing_args`
- do not add generative fallback in v2

### 5. Keep backend extensibility, but narrow core responsibility

Registry behavior should explicitly cover:

- init/load registry state
- load from JSON
- load from compiled artifact
- fetch actions and embeddings
- add/delete/reload action
- alias lookup and any planner-required metadata access

The planner should depend only on the behavior.

The package should ship:

- ETS backend
- backend contract tests
- adapter implementation guide

It should not ship database adapters itself in v2.

### 6. Reduce module sprawl

Refactor large mixed-responsibility modules into smaller boundaries:

- parser:
  lexical normalization, AL parse, slot extraction, validation
- planner:
  retrieval, score fusion, fallback routing, result shaping
- runtime:
  artifact loading, config resolution, backend wiring
- prompting:
  dictionary and prompt generation separated from planner runtime concerns

The top-level facade should stop carrying so much mixed policy logic.

## Test Plan

### Acceptance criteria

- `mix test` is green without requiring external Rust fixture repos
- all planner acceptance examples run on the Elixir runtime only
- no default test depends on NIFs, Cargo, or `.mcr`
- runtime loads fully offline from local ONNX artifacts and `registry.etf`
- fallback reranker behavior is covered with explicit ambiguity cases

### Must-add tests

- runtime-first API tests only
- registry behavior contract tests
- regression tests for the current major failure clusters:
  note insert retrieval
  task update status/assignee mapping
- artifact pipeline tests:
  compile registry from JSON + encoder
  load compiled registry
  load fallback reranker artifacts
- config tests for `tool_selection_fallback`
- tests proving prompt/dictionary helpers work independently of planner runtime boot

### Tests to remove or isolate

- Rust integration tests from the default suite
- tests requiring external `spectre-kinetic-engine` checkout
- tests asserting deprecated config aliases after the migration branch is done

## Assumptions And Defaults

- this is a **breaking v2**
- all legacy Rust support is removed, not preserved
- `tool_threshold` is the canonical threshold name
- `tool_selection_fallback` is the canonical fallback config name
- fallback is reranker-only
- training is Elixir-native with `Nx`/`Axon`
- ONNX is runtime/export format, not the training framework
- ETS is the only bundled backend
- persistent backends are supported via behavior implementation, not first-party adapters

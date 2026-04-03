# Library-First Elixir Planner with ONNX Runtime

## Summary

Replace the Rust planner core with an Elixir-first planner that keeps the current public API, moves planning logic into Elixir, and uses ONNX Runtime only for inference and tokenization-related native work.

This version is explicitly **library-first**, not application-first:

- no complex supervision tree
- no requirement to run a long-lived OTP application
- no automatic background orchestration beyond what is strictly needed
- startup and lifecycle stay under the caller's control

The goal is a package you install and call directly.

## Design Principle

This project is a library. That should shape the runtime model:

- keep the runtime simple
- prefer plain modules and structs over many processes
- use a process only when the native runtime or performance characteristics require one
- let the caller decide whether to keep a runtime alive or create one on demand
- avoid introducing a supervision hierarchy just to look more OTP-ish

A small, explicit runtime object is preferred over multiple supervised components.

## Selected Path

- Primary encoder: `BAAI/bge-small-en-v1.5` via ONNX + Ortex
- Tokenization: direct `Tokenizers` usage from local `tokenizer.json`
- Planner scoring and math: Elixir + `Nx`
- Registry lookup: a pluggable registry behavior, with a built-in `ETS` implementation as the default backend
- Hard-case fallback reranker: optional later step, not required for initial cutover
- End-state: Elixir owns planning, scoring, registry loading, and argument mapping; ONNX Runtime is only used for inference

## Runtime Architecture

### Library-first runtime shape

Instead of multiple supervised services, use one of these two modes:

- **Persistent runtime mode**
  - caller creates a runtime once
  - runtime holds loaded encoder session, tokenizer, and the selected registry backend/state
  - runtime can use the configured registry module while still loading data from `registry.json` or compiled artifacts
  - caller passes the runtime into planning calls

- **Stateless convenience mode**
  - caller passes paths/options directly
  - library loads what it needs and plans immediately
  - slower, but useful for scripts and simple integrations

The core abstraction should be a single runtime/context struct, for example:

- loaded encoder model
- loaded tokenizer
- selected registry module
- loaded registry handle/state
- optional reranker model
- planner thresholds and tuning

### No complex supervision

Do not build a tree like:

- `RegistryStore`
- `EmbeddingRuntime`
- `RerankerRuntime`
- `Planner`

as separate supervised children.

Instead:

- `Planner` should mostly be a plain module
- registry should be loaded into a runtime-owned data structure
- encoder/reranker sessions should be attached to that same runtime
- if a GenServer is needed for native session ownership, keep it as a single optional wrapper, not a subsystem

### Public API direction

Keep the current entrypoints working:

- `SpectreKinetic.plan/3`
- `plan_request/2`
- `plan_json/2`
- `add_action/2`
- `delete_action/2`
- `reload_registry/2`

But the preferred long-term API should become library-oriented, for example:

- `SpectreKinetic.load_runtime(opts)`
- `SpectreKinetic.plan(runtime, al, opts \\ [])`
- `SpectreKinetic.reload_registry(runtime, path)`
- `SpectreKinetic.add_action(runtime, action)`
- `SpectreKinetic.delete_action(runtime, action_id)`

The current server wrapper can remain as a compatibility layer, but it should not define the architecture.

## Registry and Artifacts

- Keep `registry.json` as the source of truth.
- Add an offline compile step that produces a compact Elixir-native registry bundle.
- Production use must be fully offline; no Hugging Face downloads at runtime.

### Registry backend behavior

Registry access should be defined as a behavior so different lookup/storage strategies can be swapped without changing planner logic.

- planner code should depend on a registry behavior, not directly on `ETS`
- the library should ship a default `ETS`-backed implementation so users do not need to build their own backend
- config or runtime opts should allow selecting the registry module to use
- alternate implementations should be possible, for example a PostgreSQL + vector-backed registry
- the selected backend should still support loading from `registry.json` and compiled registry artifacts, similar to the current flow

The behavior should cover the operations the planner needs, such as:

- initialize/load registry state
- load from `registry.json`
- load from compiled artifacts
- retrieve actions, aliases, tool cards, and embeddings
- add/delete/reload actions
- expose any lookup structures needed by retrieval and mapping

### Compiled registry should contain

- normalized tool metadata
- alias maps and slot hints
- precomputed tool-card embeddings
- optional arg-card embeddings if they materially improve mapping
- optional calibration metadata for thresholds

### Artifact layout

Keep artifact layout explicit and simple:

- `artifacts/encoder/{model.onnx, tokenizer.json, config.json}`
- `artifacts/reranker/{model.onnx, tokenizer.json, config.json}`
- `artifacts/registry/{registry.etf}`

Do not over-design the artifact format. One stable compiled registry bundle is enough unless large vector blobs prove to be a bottleneck.

## Retrieval and Mapping Logic

### Retrieval path

- normalize AL text
- build query embedding with the encoder
- score against precomputed tool embeddings with `Nx` cosine or dot product
- combine embedding score with lexical overlap, alias overlap, and action-shape heuristics
- choose the best candidate if confidence is high enough

### Argument mapping path

Keep mapping deterministic and schema-aware:

- exact arg name match first
- then alias and synonym match
- then inline extraction for `KEY=value`, `KEY: value`, and loose `KEY value`
- then value-shape and type priors: email, phone, URL, path, date, time, boolean, integer, float
- optional positional fallback only for very constrained cases

Argument mapping should remain in Elixir, not in a model.

## Reranker Strategy

A reranker is useful, but it should not block the core migration.

### Phase 1

- no reranker required
- ship a strong encoder + deterministic planner first
- make the example suite pass with retrieval and heuristic scoring alone

### Phase 2

Add an optional reranker for hard cases only:

- use `Alibaba-NLP/gte-reranker-modernbert-base` exported to ONNX
- invoke only when:
  - top candidate is below threshold
  - top-2 margin is too small
  - required args remain unresolved
- reranker only changes tool selection
- argument filling remains deterministic

If reranker still cannot decide confidently, return `:no_tool` or `:missing_args`.

## Config and Interfaces

Keep config small and explicit.

### Required for Elixir runtime

- `encoder_model_dir`
- `compiled_registry` or `registry_json`

### Optional

- `planner_runtime: :elixir_onnx`
- `registry_module`
- `confidence_threshold`
- `mapping_threshold`
- `top_k`
- `reranker_model_dir`
- `ambiguous_margin`
- `reranker_top_k`

If `registry_module` is not set, the library should default to the built-in `ETS` backend.

### Compatibility

- keep `model_dir` and `registry_mcr` only as Rust-compatibility settings during migration
- do not let old Rust config shape the new runtime API forever

## Testing Plan

### Acceptance tests

- the existing 1000-example ExUnit suite must pass on the Elixir runtime
- current integration tests must pass on the Elixir runtime
- library usage should be tested without requiring a full application boot

### Add focused tests for

- exact and alias slot mapping
- type-driven mapping for email, phone, URL, path, date, boolean, and number
- runtime creation from local artifacts only
- reload/add/delete action behavior in persistent runtime mode
- stateless one-shot planning mode
- registry behavior contract tests so alternate backends can be validated against the same planner expectations

### Later tests

If reranker is added:

- curated ambiguity set where reranker improves selection
- top-2 margin trigger behavior
- offline reranker artifact loading

### Benchmarks

Add benchmark scripts, not CI assertions, for:

- cold load time of runtime
- p50 and p95 planner latency without reranker
- p50 and p95 planner latency with reranker
- memory footprint of loaded encoder and registry bundle

## Implementation Order

1. Define the library-first runtime abstraction.
2. Define the registry behavior and ship the default `ETS` implementation.
3. Build the Elixir-native compiled registry format and loader.
4. Add the Ortex + Tokenizers encoder runtime and `Nx` retrieval scoring.
5. Port deterministic slot mapping, inline extraction, and type-shape matching to Elixir.
6. Make the 1000-example suite pass on the Elixir runtime without a reranker.
7. Add optional persistent runtime caching and ergonomic convenience APIs.
8. Add the optional reranker path for hard cases only.
9. Flip the default runtime to `:elixir_onnx` once parity is stable.
10. Remove the Rust planner path after confidence is high.

## Non-Goals

For this plan, do not spend time on:

- complex supervision trees
- multi-process runtime orchestration for its own sake
- distributed planner components
- generative LLM fallback in v1
- over-engineered artifact sharding unless profiling proves it is necessary

## Assumptions

- CPU-first deployment
- English-first planning
- short AL inputs and tool descriptions
- offline production artifacts
- caller-controlled lifecycle is preferred over application-managed lifecycle

## Bottom Line

The planner should feel like a normal Elixir library:

- load a runtime
- call `plan`
- optionally mutate or reload the registry
- keep the runtime around if you want speed
- skip it if you want simplicity

Use OTP where it is actually useful, but do not force a supervision-heavy architecture onto a library.

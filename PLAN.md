# Elixir-First Spectre Planner with ONNX Runtime

## Summary

Replace the Rust planner core with an Elixir-first planner that keeps the current public API, moves all orchestration and scoring into OTP processes, and only offloads model inference/tokenization to proven native runtimes.

**Selected path**
- Primary runtime encoder: `BAAI/bge-small-en-v1.5` via ONNX + Ortex
- Tokenization: direct `Tokenizers` usage from local `tokenizer.json`
- Hard-case fallback reranker: `Alibaba-NLP/gte-reranker-modernbert-base` exported and quantized to ONNX, called only for ambiguous / low-confidence cases
- Planner math and scoring: Elixir + `Nx`
- Fast metadata lookup: `ETS`
- End-state: Elixir owns planning, registry compilation, scoring, fallback routing, and telemetry; ONNX Runtime is only the inference engine

**Why this path**
- `bge-small-en-v1.5` is a better fit than ModernBERT as the primary encoder for short AL/tool strings: smaller, faster, 384-dim, and the model card explicitly shows ONNX usage.
- `gte-reranker-modernbert-base` is the right “smart” fallback: stronger pairwise decision quality, but only invoked on a tiny candidate set.
- `Ortex` is preferred over Bumblebee for the core planner because it can run exported ONNX models without depending on Axon architecture support.
- `Tokenizers` should be used directly instead of Bumblebee tokenization for the runtime planner, because it is simpler, architecture-agnostic, and already supports loading from Hugging Face or local files.

## Key Changes

### Runtime architecture
- Introduce a new Elixir planner runtime, e.g. `:elixir_onnx`, while preserving `SpectreKinetic.plan/3`, `plan_request/2`, `plan_json/2`, `add_action/2`, `delete_action/2`, and `reload_registry/2`.
- Keep the Rust NIF only as a temporary validation path during migration; the target state is that planning no longer depends on `spectre-core`.
- Add supervised components:
  - `RegistryStore`: owns ETS tables for tool defs, aliases, slot metadata, and compiled lookup structures
  - `EmbeddingRuntime`: owns one or more loaded Ortex embedding sessions
  - `RerankerRuntime`: owns one or more loaded Ortex reranker sessions
  - `Planner`: orchestrates normalization, retrieval, mapping, fallback reranking, and result shaping

### Registry and artifacts
- Keep `registry.json` as the source of truth.
- Add a new offline compile step that produces an Elixir-native compiled registry bundle containing:
  - normalized tool metadata
  - alias maps and slot hints
  - precomputed tool-card embeddings
  - precomputed arg-card embeddings
  - any calibration metadata needed for thresholds
- Vendor model artifacts locally; production must not download from Hugging Face at boot.
- Artifact layout should be explicit and stable:
  - `artifacts/encoder/{model.onnx, tokenizer.json, config.json}`
  - `artifacts/reranker/{model.onnx, tokenizer.json, config.json}`
  - `artifacts/registry/{registry.etf, tool_vectors.bin, arg_vectors.bin}`

### Retrieval and mapping logic
- Retrieval path:
  - normalize AL text
  - build query embedding with the encoder
  - score against precomputed tool embeddings with `Nx` cosine/dot product
  - combine embedding score with lexical overlap, alias overlap, and action-shape heuristics
- Argument mapping path:
  - use deterministic lexical matching first: exact arg name, aliases, synonyms
  - add value-shape/type priors: email, phone, URL, path, date, time, boolean, integer/float
  - keep inline extraction for `KEY=value`, `KEY: value`, and loose `KEY value`
  - score mapping in Elixir with `Nx`, not in the model
- Hard-case fallback:
  - call the reranker only when the top candidate is below calibrated confidence, the top-2 margin is too small, or required args remain unresolved
  - reranker input is `(AL text, candidate tool card)` pairs over top-K candidates only
  - reranker may change tool selection, but argument filling remains deterministic and schema-aware
  - if reranker still cannot produce a confident answer, return `:no_tool` or `:missing_args`; do not add a generative fallback in v1

### Model choices
- **Primary encoder**: `BAAI/bge-small-en-v1.5`
  - chosen for CPU-first speed, 384-dim output, and short-text retrieval fit
  - long-context models are unnecessary for AL/tool planning because the inputs are short
- **Hard-case reranker**: `Alibaba-NLP/gte-reranker-modernbert-base`
  - export to ONNX with Optimum and quantize to int8 for CPU use
  - only invoked on hard cases, so its size is acceptable
- **Not chosen**
  - `gte-modernbert-base` as primary encoder: too expensive for the hot path
  - Bumblebee as the core inference runtime: good for experimentation, but not the best base for a production planner that should accept arbitrary exported ONNX models
  - local generative LLM fallback in v1: too much latency and nondeterminism for the first replacement

### Public config and interfaces
- Preserve existing planner entrypoints.
- Add explicit config for the new runtime:
  - `planner_runtime: :elixir_onnx`
  - `encoder_model_dir`
  - `reranker_model_dir`
  - `compiled_registry_dir`
  - `embedding_batch_size`
  - `reranker_top_k`
  - `confidence_threshold`
  - `ambiguous_margin`
- Keep `model_dir` as a backward-compatible alias during migration, but mark it deprecated in docs once the new runtime lands.
- Add an offline task to export/quantize models and a task to compile the registry bundle from `registry.json`.

## Test Plan

- Keep the existing 1000-example ExUnit suite as the primary planner acceptance test; the new runtime must pass it unchanged.
- Add parity tests that run the same AL examples through both runtimes until cutover; failures must print tool, args, notes, and score deltas.
- Add focused tests for:
  - exact and alias slot mapping
  - type-driven mapping for email/phone/URL/path/date/boolean/number
  - hard-case reranker correction on ambiguous tools
  - dynamic `add_action/2` and `delete_action/2` re-embedding / matrix updates
  - compiled registry load from local artifacts without network access
- Add benchmark scripts, not CI assertions, for:
  - cold boot time
  - p50/p95 planner latency without reranker
  - p50/p95 latency when reranker fires
  - memory footprint of encoder, reranker, and registry matrix
- Acceptance criteria:
  - 1000-example planner suite is green
  - current integration tests are green
  - fallback reranker demonstrably fixes a curated ambiguity set
  - production runtime works fully offline from vendored artifacts

## Implementation Order

1. Build the Elixir-native compiled registry format and loader.
2. Add the Ortex + Tokenizers encoder runtime and replace retrieval with `Nx` scoring.
3. Port deterministic slot mapping, inline extraction, and type-shape matching to Elixir.
4. Make the 1000-example suite pass on the Elixir runtime with no reranker.
5. Add the ModernBERT reranker path for hard cases only.
6. Add telemetry, threshold calibration, and benchmark tooling.
7. Flip the default runtime to `:elixir_onnx`.
8. Remove the Rust planner path after parity is stable.

## Assumptions and Defaults

- CPU-first, English-first deployment.
- End state is full planner replacement, but a temporary dual-runtime validation window is allowed.
- Production artifacts are built offline and shipped with the release; no runtime model downloads.
- The first fallback is a local reranker, not a generative LLM.
- `Nx` is used for planner math; `ETS` is used for metadata and lookup tables; ONNX Runtime is used only for model inference.

## References

- Ortex docs: https://hexdocs.pm/ortex/Ortex.html
- Tokenizers docs: https://hexdocs.pm/tokenizers/Tokenizers.Tokenizer.html
- Bumblebee tokenizer / embedding APIs: https://hexdocs.pm/bumblebee/Bumblebee.html
- Bumblebee text embedding: https://hexdocs.pm/bumblebee/Bumblebee.Text.html
- Nx.Serving docs: https://hexdocs.pm/nx/Nx.Serving.html
- Optimum ONNX overview/export: https://huggingface.co/docs/optimum/main/en/onnxruntime/overview
- Optimum exporter support: https://huggingface.co/docs/optimum/exporters/onnx/overview
- `BAAI/bge-small-en-v1.5`: https://huggingface.co/BAAI/bge-small-en-v1.5
- `Alibaba-NLP/gte-reranker-modernbert-base`: https://huggingface.co/Alibaba-NLP/gte-reranker-modernbert-base
- `Alibaba-NLP/gte-modernbert-base`: https://huggingface.co/Alibaba-NLP/gte-modernbert-base
- ModernBERT docs: https://huggingface.co/docs/transformers/model_doc/modernbert
